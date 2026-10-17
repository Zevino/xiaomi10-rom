#!/usr/bin/env python3
"""从 lpdump 输出 + lpunpack 产物生成 lpmake 命令行。

用法:
    lpmake_args.py <workdir> <output_raw_img>

读取:
    <workdir>/logs/lpdump.txt    原厂 super 的分区表（由 lpdump 打印）
    <workdir>/out/*.img          lpunpack 拆出来的分区镜像

输出:
    stdout 是一个可直接 `bash` 执行的脚本，内容是完整的一条 lpmake 命令。

几个坑（都踩过）:
  1. 必须给每个分区配 --image=<name>=<file>。只给 --partition 的话，lpmake 会写出
     一个分区表正确、内容全零的镜像 —— 刷进去就是砖。
  2. 必须加 --force-full-image，否则若某个分区没有对应镜像文件，lpmake 会退化成
     写一个只含 metadata 的 super_empty.img。
  3. lpdump 有的版本把属性打印成词法（Attributes: readonly），有的打印成数值
     （Attributes: 1），两种都要认。
  4. --group <name>:0 会触发 "Partition group must have a valid maximum size."，
     所以 max size 为 0 且没有分区引用的分组要跳过。
"""
import glob
import os
import re
import shlex
import sys

LP_PARTITION_ATTR_READONLY = 1


def parse_attributes(block):
    """返回分区属性的数值形式；解析不到返回 None（调用方按 readonly 兜底）。"""
    m = re.search(r"Attributes:\s*([^\r\n]*)", block)
    if not m:
        return None
    v = m.group(1).strip()
    if not v:
        return None
    # 数值形式：1 / 0 / 0x0000000000000001
    if re.fullmatch(r"0[xX][0-9a-fA-F]+|\d+", v):
        return int(v, 0)
    # 词法形式：none / readonly / readwrite / readonly,xxx ...
    tokens = {t.lower() for t in re.split(r"[,\s]+", v) if t}
    tokens.discard("none")
    return LP_PARTITION_ATTR_READONLY if "readonly" in tokens else 0


def parse_lpdump(text):
    info = {
        "md_size": None,
        "slots": None,
        "device_name": None,
        "device_size": None,
        "groups": [],      # [(name, max_size)]
        "parts": [],       # [(name, group, attributes)]
    }

    # lpdump 会按槽位分节打印（"Slot 0:" / "Slot 1:"）。只解析第一节，
    # 否则分组表/分区表会被解析两遍，--group 传两次 lpmake 会直接报错。
    slot_marks = list(re.finditer(r"^Slot \d+:\s*$", text, re.M))
    if len(slot_marks) >= 2:
        text = text[: slot_marks[1].start()]

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
            info["parts"].append((
                n.group(1),
                g.group(1) if g else "",
                parse_attributes(block),      # None / int
            ))

    # 块设备表
    if "Block device table:" in text:
        bd = text.split("Block device table:")[1]
        bd = bd.split("Group table:")[0]
        n = re.search(r"Partition name:\s*(\S+)", bd) or re.search(r"Name:\s*(\S+)", bd)
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


def emit(cmd_args, out_raw):
    """把参数列表拼成可直接执行的脚本（走 stdout）。

    排版上把 `--flag value` 放在一行，方便人眼核对；带引号的只是 Windows 路径
    在本地测试时才会出现，CI 的 /mnt/rom 路径不会被引号包起来。
    """
    tokens = cmd_args + ["--output", out_raw]
    parts = []
    i = 0
    while i < len(tokens):
        t = tokens[i]
        if (t.startswith("-") and i + 1 < len(tokens)
                and not tokens[i + 1].startswith("-")):
            parts.append(f"{shlex.quote(t)} {shlex.quote(tokens[i + 1])}")
            i += 2
        else:
            parts.append(shlex.quote(t))
            i += 1
    print("#!/usr/bin/env bash")
    print("set -euo pipefail")
    print("lpmake \\\n  " + " \\\n  ".join(parts))


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

    # max size 为 0 的分组传给 --group 会直接报错，只要没有分区引用就可以跳过
    named_groups = [g for g in info["groups"] if g[1] > 0] or list(info["groups"])

    dev = info["device_name"] or "super"
    args = []
    args += ["--metadata-size", str(info["md_size"] or 65536)]
    args += ["--metadata-slots", str(info["slots"] or 2)]
    args += ["--super-name", dev]
    args += ["--device", f"{dev}:{info['device_size']}"]
    args += ["--force-full-image"]
    for g, s in named_groups:
        args += ["--group", f"{g}:{s}"]

    default_group = named_groups[0][0]
    used = 0
    picked = []
    missing = []
    for name, group, attr in info["parts"]:
        if name not in imgs:
            missing.append(name)
            continue
        path = imgs[name]
        size = os.path.getsize(path)
        used += size
        # 属性解析不到时按 readonly 处理（Android 原厂动态分区基本都是只读）
        a = "readonly" if (attr is None or (attr & LP_PARTITION_ATTR_READONLY)) else "none"
        group = group or default_group
        args += ["--partition", f"{name}:{a}:{size}:{group}"]
        # 关键：不给 --image 的话 lpmake 只写分区表，内容是零
        args += [f"--image={name}={path}"]
        picked.append((name, size, a, group))

    if not picked:
        print("!! out/ 里没有任何与 lpdump 分区名对得上的镜像", file=sys.stderr)
        return 1
    if missing:
        msg = "super 里这些分区没有对应镜像，会被丢弃: " + ", ".join(missing)
        print(f"!! {msg}", file=sys.stderr)
        print(f"::warning::{msg}", file=sys.stderr)

    # 汇总给人看（走 stderr，不污染 stdout 的命令）
    print("---- lpmake 参数明细 ----", file=sys.stderr)
    print(f"super 设备大小 : {info['device_size']} bytes", file=sys.stderr)
    for g, s in info["groups"]:
        note = "" if s > 0 else "  (size=0，跳过)"
        print(f"分组 {g:32s} 上限 {s} bytes{note}", file=sys.stderr)
    for name, size, a, group in picked:
        print(f"  {name:16s} {size:>13d}  {a:8s} {group}", file=sys.stderr)
    total_group = sum(s for _, s in named_groups) or info["device_size"]
    if used > total_group:
        print(f"!!!! 分区总和 {used} 超过分组上限 {total_group}，一定会失败", file=sys.stderr)
    else:
        print(f"分区总和 {used} / 分组上限 {total_group}（余 {total_group - used}）", file=sys.stderr)

    emit(args, out_raw)
    return 0


if __name__ == "__main__":
    sys.exit(main())
