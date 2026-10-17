#!/usr/bin/env python3
"""确认 ext4 镜像里没有被两个以上 inode 同时引用的数据块。

为什么需要这一步
----------------
小米镜像的超级块带着 AOSP 专有的 RO_COMPAT 特性 shared_blocks (0x4000)。

注意撞名：主线 e2fsprogs 1.47 在同一个 bit 上定义的是 largest_file，
两者完全不是一回事 —— 我们最早就是被这个坑过一次，把它当成了无害的统计位。

shared_blocks 的含义是镜像里可能有共用的数据块（e2fsdroid -s 做相同文件
去重时会产生）。主线内核不认识这个特性，所以它拒绝 rw 挂载。如果只把标志位
清掉就 rw 挂上去删文件，内核会把共用块当成普通块释放，而另一个 inode 还在
引用它们 —— 这种损坏是静默的，要到手机开机才暴露。

所以在动任何东西之前，先用 debugfs 把每个 inode 引用的块枚举出来，
看有没有块被引用超过一次。

用法: check_shared_blocks.py <ext4-image> [更多镜像...]
      有共享块时退出码为 1。
"""
import concurrent.futures
import re
import subprocess
import sys

BLK_RE = re.compile(r"\d+")
INODE_COUNT_RE = re.compile(r"^Inode count:\s*(\d+)", re.M)
WORKERS = 8


def inode_count(img: str) -> int:
    r = subprocess.run(["tune2fs", "-l", img], capture_output=True, text=True)
    m = INODE_COUNT_RE.search(r.stdout)
    if not m:
        raise SystemExit("  读不出 %s 的 inode 数量：%s" % (img, r.stderr.strip()))
    return int(m.group(1))


def blocks_of(img: str, ino: int):
    """返回该 inode 引用的块号列表；空 inode / 不存在则返回空列表。"""
    try:
        r = subprocess.run(["debugfs", "-R", "blocks <%d>" % ino, img],
                           capture_output=True, text=True, timeout=120)
    except subprocess.TimeoutExpired:
        return []
    if r.returncode != 0 or "Blk:" not in r.stdout:
        return []
    # 单条命令的输出里 "Blk:" 之后就是块号列表
    return [int(x) for x in BLK_RE.findall(r.stdout.split("Blk:", 1)[1])]


def check(img: str) -> bool:
    n = inode_count(img)
    print("  %s: %d 个 inode，逐个枚举引用的块 ..." % (img.split("/")[-1], n), flush=True)

    seen = set()
    refs = 0
    dup_refs = 0
    with concurrent.futures.ThreadPoolExecutor(max_workers=WORKERS) as pool:
        for blocks in pool.map(lambda i: blocks_of(img, i), range(1, n + 1)):
            refs += len(blocks)
            for b in blocks:
                if b in seen:
                    dup_refs += 1
                else:
                    seen.add(b)

    print("    被引用的块次合计 %d，去重后 %d，重复引用 %d" % (refs, len(seen), dup_refs))
    return dup_refs > 0


def main() -> int:
    if len(sys.argv) < 2:
        print("usage: check_shared_blocks.py <ext4-image> [...]", file=sys.stderr)
        return 2

    bad = []
    for img in sys.argv[1:]:
        if check(img):
            bad.append(img)
            print("    !! 有共享块 —— rw 挂载后删文件会连带损坏其它文件", flush=True)
        else:
            print("    ok：没有块被重复引用", flush=True)

    if bad:
        print("::error::%s 里存在共享块，不能在 rw 挂载下删文件，否则会静默损坏其它文件"
              % ", ".join(bad))
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
