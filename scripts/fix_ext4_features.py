#!/usr/bin/env python3
"""把内核不认识的 ext4 ro_compat 特性位清掉，好让镜像能 rw 挂载。

背景
----
小米这些分区镜像带着 AOSP 专有的 RO_COMPAT 特性 shared_blocks(0x4000)。

这里有个要命的撞名：主线 e2fsprogs 1.47 在同一个 bit 上定义的是 largest_file，
一个无害的「最大文件大小」统计位。小米镜像是 AOSP 的 e2fsprogs fork 做出来的，
同一个 bit 在那边叫 shared_blocks，含义完全不同 —— 它表示镜像里可能有被多个
inode 共用的数据块（e2fsdroid -s 做相同文件去重时产生的）。

内核发现不认识的 ro_compat 位就直接拒绝读写挂载（只读是允许的），dmesg 里是：
    EXT4-fs (loop0): couldn't mount RDWR because of unsupported optional features (4000)

所以必须清掉这个位才能 rw 挂上去改文件。但清位本身并不解决共享块问题：
如果镜像里真有共享块，rw 挂载后删文件会把别的 inode 还在用的块释放掉。
因此 03-modify.sh 在清位之前会先跑 check_shared_blocks.py 确认干净。

改过超级块之后 s_checksum 就对不上了，所以下一步必须跑 e2fsck 重算校验和。

用法: fix_ext4_features.py <ext4-image>
"""
import struct
import sys

SUPERBLOCK_OFFSET = 1024
S_RO_COMPAT = SUPERBLOCK_OFFSET + 0x64  # struct ext4_super_block::s_feature_ro_compat

# Linux 6.8（ubuntu-24.04 runner 的内核）里的 EXT4_FEATURE_RO_COMPAT_SUPP。
# 只保留这些位，其它一律清掉。
KERNEL_SUPP = (
    0x0001 |      # sparse_super
    0x0002 |      # large_file
    0x0004 |      # btree_dir
    0x0008 |      # huge_file
    0x0010 |      # gdt_csum (uninit_bg)
    0x0020 |      # dir_nlink
    0x0040 |      # extra_isize
    0x0100 |      # quota
    0x0200 |      # bigalloc
    0x0400 |      # metadata_csum
    0x1000 |      # readonly
    0x2000 |      # project
    0x8000 |      # verity
    0x10000       # orphan_present
)


def selftest() -> int:
    """偏移量一旦算错，改坏的是分区表看起来完全正常的 super —— 必须挡住。"""
    import os
    import struct as st
    import tempfile

    SB = SUPERBLOCK_OFFSET

    def mk(ro: int, magic: int = 0xEF53) -> str:
        buf = bytearray(2048)
        st.pack_into("<H", buf, SB + 0x38, magic)
        st.pack_into("<I", buf, SB + 0x64, ro)
        p = os.path.join(tempfile.gettempdir(), "fix_ext4_selftest.img")
        with open(p, "wb") as fh:
            fh.write(buf)
        return p

    def after(p: str) -> int:
        with open(p, "rb") as fh:
            return st.unpack_from("<I", fh.read(), SB + 0x64)[0]

    cases = [
        ("小米镜像：带 shared_blocks(0x4000)", 0x046B | 0x4000, 0x046B),
        ("本来就干净，不能误伤", 0x046B, 0x046B),
        ("多个未知位 0x4000|0x0800", 0x046B | 0x4000 | 0x0800, 0x046B),
        ("orphan_present(0x10000) 内核支持，保留", 0x046B | 0x4000 | 0x10000, 0x1046B),
        ("metadata_csum(0x400) 保留", 0x0400 | 0x4000, 0x0400),
    ]
    failed = 0
    for name, inp, exp in cases:
        p = mk(inp)
        patch(p)
        got = after(p)
        ok = got == exp
        failed += 0 if ok else 1
        print(f"    [{'PASS' if ok else 'FAIL'}] {name}: 0x{inp:05x} -> 0x{got:05x} (期望 0x{exp:05x})")

    # --no-csum 是策略 2 的兜底路径：连 metadata_csum 一起清，内核就不再校验超级块
    p = mk(0x046B | 0x4000 | 0x0400)
    patch(p, drop_extra=0x0400)
    got = after(p)
    ok = got == 0x006B
    failed += 0 if ok else 1
    print(f"    [{'PASS' if ok else 'FAIL'}] --no-csum 连 metadata_csum 一起清: "
          f"0x0446b -> 0x{got:05x} (期望 0x0006b)")

    # 非 ext4 文件一个字节都不能动
    p = mk(0, magic=0)
    buf_before = open(p, "rb").read()
    patch(p)
    ok = open(p, "rb").read() == buf_before
    failed += 0 if ok else 1
    print(f"    [{'PASS' if ok else 'FAIL'}] 非 ext4 不改动")
    os.remove(p)

    return 1 if failed else 0


def patch(img: str, drop_extra: int = 0) -> None:
    """把 img 超级块里内核不认识的 ro_compat 位清掉。非 ext4 文件原样不动。

    drop_extra: 额外要清掉的位。策略 1 只清内核不认识的位；如果超级块校验和
    没被 e2fsck 修好、挂载仍然失败，策略 2 会带上 metadata_csum(0x400) 再试一次
    —— 校验和特性没了，内核就干脆不去校验它。
    """
    with open(img, "r+b") as f:
        f.seek(SUPERBLOCK_OFFSET + 0x38)  # s_magic
        magic = struct.unpack("<H", f.read(2))[0]
        if magic != 0xEF53:
            print("    不是 ext4 (magic=0x%04x)，不动它" % magic)
            return

        f.seek(S_RO_COMPAT)
        raw = struct.unpack("<I", f.read(4))[0]
        keep = KERNEL_SUPP & ~drop_extra
        new = raw & keep
        print("    ro_compat: 0x%05x -> 0x%05x   (清掉 0x%05x)" % (raw, new, raw & ~keep))
        if new == raw:
            return

        f.seek(S_RO_COMPAT)
        f.write(struct.pack("<I", new))

    # 超级块校验和 (s_checksum，偏移 0x3FC) 现在对不上了，交给 e2fsck 重算写回。
    print("    已改写超级块，等 e2fsck 重算校验和")


def main() -> int:
    args = sys.argv[1:]
    if args == ["--selftest"]:
        return selftest()

    drop_extra = 0
    if args and args[0] == "--no-csum":
        # metadata_csum：清掉之后内核不再校验超级块/GDT 校验和，是策略 1 失败时的兜底
        drop_extra = 0x0400
        args = args[1:]

    if len(args) != 1:
        print("usage: fix_ext4_features.py [--no-csum] <ext4-image> | --selftest",
              file=sys.stderr)
        return 2

    patch(args[0], drop_extra)
    return 0


if __name__ == "__main__":
    sys.exit(main())
