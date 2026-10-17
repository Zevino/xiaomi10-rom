#!/usr/bin/env python3
"""对比原厂和新生成 super 的 lpdump 输出，确认分区表没被改坏。

用法: verify_lpdump.py <原厂 lpdump.txt> <新的 lpdump.txt>

为什么需要它
------------
lpmake 只要参数齐全就会产出一份「语法正确」的元数据 —— 但如果某个分区漏了
--image=，它照样能写出合法分区表，只是内容全零，刷进去就是砖。lpdump 自己也
读不出这种错。所以必须拿原厂的表逐项比对：分区名、大小、所属分组、属性。

不一致就退出码 1。
"""
import re
import sys

ANSI = re.compile(r"\x1b\[[0-9;]*m")


def parse(path):
    txt = ANSI.sub("", open(path, encoding="utf-8", errors="replace").read())

    parts = {}
    if "Partition table:" in txt:
        seg = txt.split("Partition table:", 1)[1]
        seg = re.split(r"\n\s*(?:Super partition layout|Block device table|Group table):", seg)[0]
        for blk in re.split(r"\n(?=\s*Name:)", seg):
            m = re.search(r"Name:\s*(\S+)", blk)
            if not m:
                continue
            name = m.group(1)
            g = re.search(r"Group:\s*(\S+)", blk)
            a = re.search(r"Attributes:\s*([^\r\n]*)", blk)
            sectors = 0
            for e in re.finditer(r"^\s*(\d+)\s*\.\.\s*(\d+)\s+linear\s+\S+\s+(\d+)", blk, re.M):
                sectors += int(e.group(2)) - int(e.group(1)) + 1
            parts[name] = {
                "sectors": sectors,
                "group": g.group(1) if g else None,
                "attrs": (a.group(1).strip().lower() if a else ""),
            }

    groups = {}
    if "Group table:" in txt:
        seg = txt.split("Group table:", 1)[1]
        for blk in re.split(r"\n(?=\s*Name:)", seg):
            m = re.search(r"Name:\s*(\S+)", blk)
            s = re.search(r"Maximum size:\s*(\d+)", blk)
            if m and s:
                groups[m.group(1)] = int(s.group(1))

    dev = None
    m = re.search(r"Block device table:.*?Size:\s*(\d+)", txt, re.S)
    if m:
        dev = int(m.group(1))

    return {"parts": parts, "groups": groups, "dev": dev}


def main():
    if len(sys.argv) != 3:
        print("usage: verify_lpdump.py <stock.txt> <new.txt>", file=sys.stderr)
        return 2

    stock = parse(sys.argv[1])
    new = parse(sys.argv[2])
    bad = []

    if stock["dev"] != new["dev"]:
        bad.append(f"super 设备大小: 原厂 {stock['dev']} -> 新 {new['dev']}")
    else:
        print(f"  super 设备大小 {new['dev']:,} bytes  一致")

    if stock["groups"] != new["groups"]:
        bad.append(f"分组表不一致: 原厂 {stock['groups']} -> 新 {new['groups']}")
    else:
        for g, v in new["groups"].items():
            print(f"  分组 {g:<24} 上限 {v:>14,}  一致")

    missing = set(stock["parts"]) - set(new["parts"])
    extra = set(new["parts"]) - set(stock["parts"])
    if missing:
        bad.append(f"新 super 缺少分区: {sorted(missing)}")
    if extra:
        bad.append(f"新 super 多出分区: {sorted(extra)}")

    for name in sorted(set(stock["parts"]) & set(new["parts"])):
        s, n = stock["parts"][name], new["parts"][name]
        if s["sectors"] != n["sectors"]:
            bad.append(f"分区 {name} 大小变了: {s['sectors']} -> {n['sectors']} sectors")
            continue
        # 原厂可能只写「readonly」也可能写数值，统一成是否只读
        ro_s = "readonly" in s["attrs"] or s["attrs"] == "1"
        ro_n = "readonly" in n["attrs"] or n["attrs"] == "1"
        note = []
        if ro_s != ro_n:
            bad.append(f"分区 {name} readonly 属性变了: {s['attrs']!r} -> {n['attrs']!r}")
        if s["group"] != n["group"]:
            bad.append(f"分区 {name} 分组变了: {s['group']} -> {n['group']}")
        print(f"  分区 {name:<14} {n['sectors']:>9} sectors  group={n['group']:<24} {''.join(note)} 一致")

    if bad:
        for b in bad:
            print(f"::error::{b}")
        return 1
    print("  分区表与原厂完全一致")
    return 0


if __name__ == "__main__":
    sys.exit(main())
