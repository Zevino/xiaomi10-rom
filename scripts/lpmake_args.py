#!/usr/bin/env python3
"""从 lpdump 输出 + lpunpack 产物生成 lpmake 命令行。

用法:
    lpmake_args.py <workdir> <output_raw_img>

读取:
    <workdir>/logs/lpdump.txt    原厂 super 的分区表（由 lpdump 打印）
    <workdir>/out/*.img          lpunpack 拆出来的分区镜像

输出:
    stdout 是一个可直接 `bash` 执行的脚本，内容是完整的一条 lpmake 命令。
    分区大小直接取镜像文件的实际大小 —— 因为 lpunpack 是按原分区尺寸落盘的，
    所以这样组出来的 super 与原厂布局完全一致，保证装得下、能刷。
"""
import glob
import os
import re
import sys


def parse_lpdump(text):
    info = {
        "md_size": None,
        "slots": None,
        "device_name": None,
        "device_size": None,
        "groups": [],      # [(name, max_size)]
        "parts": [],       # [(name, group, attributes)]
    }

    m = re.search(r"Metadata max size:\s*(\d+)", text)
    if m:
        info["md_size"] = int(m.group(1))
    m = re.search(r"Metadata slot count:\s*(\d+)", text)
    if m:
        info["slots"] = int(m.group(1))

    # 分区表
    if "Partition table:" in text:
        pt = text.split("Partition table:")[1]
        pt = pt.split("Block device table:")[0]
        for block in re.split(r"-{3,}", pt):
            n = re.search(r"Name:\s*(\S+)", block)
            if not n:
                continue
            g = re.search(r"Group:\s*(\S+)", block)
            a = re.search(r"Attributes:\s*(\d+)", block)
            info["parts"].append((
                n.group(1),
                g.group(1) if g else "",
                int(a.group(1)) if a else None,   # None = 没解析到
            ))

    # 块设备表
    if "Block device table:" in text:
        bd = text.split("Block device table:")[1]
        bd = bd.split("Group table:")[0]
        n = re.search(r"Name:\s*(\S+)", bd)
        s = re.search(r"Size:\s*(\d+)\s*bytes", bd)
        if n:
            info["device_name"] = n.group(1)
        if s:
            info["device_size"] = int(s.group(1))

    # 分组表
    if "Group table:" in text:
        gt = text.split("Group table:")[1]
        for block in re.split(r"-{3,}", gt):
            n = re.search(r"Name:\s*(\S+)", block)
            s = re.search(r"Maximum size:\s*(\d+)\s*bytes", block)
            if n and s:
                info["groups"].append((n.group(1), int(s.group(1))))

    return info


def main():
    if len(sys.argv) < 3:
        print(__doc__, file=sys.stderr)
        return 2

    work = sys.argv[1]
    out_raw = sys.argv[2]

    dump_path = os.path.join(work, "logs", "lpdump.txt")
    outdir = os.path.join(work, "out")

    if not os.path.exists(dump_path):
        print(f"找不到 {dump_path}", file=sys.stderr)
        return 1

    info = parse_lpdump(open(dump_path, encoding="utf-8", errors="replace").read())

    imgs = {}
    for p in glob.glob(os.path.join(outdir, "*.img")):
        imgs[os.path.splitext(os.path.basename(p))[0]] = p

    if not info["device_size"]:
        print("!! 没能从 lpdump.txt 解析出 super 总大小，请检查该文件内容", file=sys.stderr)
        return 1
    if not info["parts"]:
        print("!! 没能从 lpdump.txt 解析出分区表", file=sys.stderr)
        return 1
    if not info["groups"]:
        print("!! 没能从 lpdump.txt 解析出分组表（Group table），lpmake 无法组装", file=sys.stderr)
        return 1

    dev = info["device_name"] or "super"
    args = []
    args += ["--metadata-size", str(info["md_size"] or 65536)]
    args += ["--metadata-slots", str(info["slots"] or 2)]
    args += ["--super-name", dev]
    args += ["--device", f"{dev}:{info['device_size']}"]

    groups = info["groups"]
    default_group = groups[0][0]
    for g, s in groups:
        args += ["--group", f"{g}:{s}"]

    used = 0
    picked = []
    for name, group, attr in info["parts"]:
        if name not in imgs:
            continue
        size = os.path.getsize(imgs[name])
        used += size
        # 解析不到 Attributes 时按 readonly 处理（Android 原厂动态分区基本都是只读）
        a = "readonly" if (attr is None or (attr & 1)) else "none"
        group = group or default_group
        args += ["--partition", f"{name}:{a}:{size}:{group}"]
        picked.append((name, size, a, group))

    if not picked:
        print("!! out/ 里没有任何与 lpdump 分区名对得上的镜像", file=sys.stderr)
        return 1

    # 汇总给人看（走 stderr，不污染 stdout 的命令）
    print("---- lpmake 参数明细 ----", file=sys.stderr)
    print(f"super 设备大小 : {info['device_size']} bytes", file=sys.stderr)
    for g, s in groups:
        print(f"分组 {g:32s} 上限 {s} bytes", file=sys.stderr)
    for name, size, a, group in picked:
        print(f"  {name:16s} {size:>13d}  {a:8s} {group}", file=sys.stderr)
    total_group = sum(s for _, s in groups) or info["device_size"]
    if used > total_group:
        print(f"!!!! 分区总和 {used} 超过分组上限 {total_group}，一定会失败", file=sys.stderr)
    else:
        print(f"分区总和 {used} / 分组上限 {total_group}（余 {total_group - used}）", file=sys.stderr)

    # stdout：可执行的脚本
    pairs = []
    it = iter(args + ["--output", out_raw])
    for flag in it:
        try:
            pairs.append(f"{flag} {next(it)}")
        except StopIteration:
            pairs.append(flag)
    print("#!/usr/bin/env bash")
    print("set -euo pipefail")
    print("lpmake \\\n  " + " \\\n  ".join(pairs))
    return 0


if __name__ == "__main__":
    sys.exit(main())
