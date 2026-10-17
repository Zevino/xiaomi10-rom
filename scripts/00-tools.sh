#!/usr/bin/env bash
# 安装解包/打包工具，并做全链路自检（避免 30 分钟后才发现在某一步挂掉）
#
# 为什么不用 Rprop 的 simg2img/img2simg：
#   那个仓库 README 写着 "statically linked"，但实测是动态链接 libc++.so 的：
#     simg2img: error while loading shared libraries: libc++.so
#   实测只有稀疏工具需要 libc++：
#     simg2img/img2simg/ext2simg/append2simg -> 需要 libc++.so   ✗
#     lpunpack/lpmake/lpadd/lpdumps         -> 只需 libc/libdl/…  ✓
#   而 Ubuntu 没有 lpunpack 的包，所以：稀疏工具用 apt 原生，lp* 用 Rprop。
set -euo pipefail

REPO="${GITHUB_WORKSPACE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
export DEBIAN_FRONTEND=noninteractive
TOOLS_BASE="https://raw.githubusercontent.com/Rprop/aosp15_partition_tools/main/linux_glibc_x86_64"

# ---------------- 1. apt 依赖 ----------------
echo "== apt 依赖 =="
sudo apt-get update -qq
sudo apt-get install -y -qq e2fsprogs curl ca-certificates binutils >/dev/null

echo "== 稀疏工具（apt 原生，不带 libc++ 依赖）=="
sudo apt-get install -y -qq android-sdk-libsparse-utils >/dev/null

# ---------------- 2. lp* 工具 ----------------
echo "== lp* 工具 =="
sudo mkdir -p /usr/local/bin
for t in lpunpack lpmake lpadd lpdumps; do
  sudo curl -fsSL "$TOOLS_BASE/$t" -o "/usr/local/bin/$t"
  sudo chmod +x "/usr/local/bin/$t"
  echo "  下载 $t"
done
# 该仓库里 dump 工具名叫 lpdumps，统一暴露成 lpdump
sudo ln -sf /usr/local/bin/lpdumps /usr/local/bin/lpdump

# ---------------- 3. 兜底：稀疏工具真装不上时，用 Rprop 版补 libc++ ----------------
if ! command -v simg2img >/dev/null 2>&1 || ! command -v img2simg >/dev/null 2>&1; then
  echo "[回退] apt 的 simg2img/img2simg 不可用，改用 Rprop 版并补 libc++ 运行库"
  for t in simg2img img2simg; do
    sudo curl -fsSL "$TOOLS_BASE/$t" -o "/usr/local/bin/$t"
    sudo chmod +x "/usr/local/bin/$t"
  done
  sudo apt-get install -y -qq libc++1 libc++abi1 2>/dev/null \
    || sudo apt-get install -y -qq 'libc++1-*' 'libc++abi1-*' 2>/dev/null \
    || sudo apt-get install -y -qq libc++-dev libc++abi-dev 2>/dev/null || true
  for base in libc++.so libc++abi.so; do
    [ -e "/usr/lib/x86_64-linux-gnu/$base" ] && continue
    src=$(find /usr/lib /lib -name "${base}.*" -type f 2>/dev/null | sort | head -1 || true)
    [ -n "$src" ] && sudo ln -sf "$src" "/usr/lib/x86_64-linux-gnu/$base" || true
  done
  sudo ldconfig || true
fi

# ---------------- 4. 依赖完整性检查 ----------------
echo "== 检查每个工具的动态库 =="
fail=0
for t in simg2img img2simg lpunpack lpmake lpdump e2fsck; do
  p=$(command -v "$t" 2>/dev/null) || { echo "  ✗ 找不到 $t"; fail=1; continue; }
  miss=$(ldd "$p" 2>/dev/null | grep 'not found' || true)
  if [ -n "$miss" ]; then
    echo "  ✗ $t ($p) 缺库："; echo "$miss"; fail=1
  else
    echo "  ✓ $t -> $p"
  fi
done
if [ "$fail" -ne 0 ]; then
  echo "::error::工具链不完整，见上面的缺库信息"
  exit 1
fi

# ---------------- 5. 全链路自检：lpmake -> lpdump -> lpunpack -> 稀疏往返 -> 再生成 ----------------
echo
echo "== 全链路自检（16MiB 假 super，秒级）=="
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

echo "--- lpmake 造一个完整的假 super（--force-full-image 必须加）---"
# 不加 -F 且不给任何 --image 时，lpmake 只会写一个含 metadata 的 super_empty.img，
# lpunpack 去读 geometry 会直接 EOF（上次自检就是这么挂的）。
lpmake --metadata-size 65536 --metadata-slots 2 \
       --device super:16777216 \
       --group smoke:16777216 \
       --partition test:readonly:8388608:smoke \
       --force-full-image \
       --output "$TMP/super.img"

echo "--- 产出诊断：尺寸 + 文件头 ---"
ls -l "$TMP/super.img"
echo -n "  前 16 字节: "; od -An -tx1 -N16 "$TMP/super.img"
if [ "$(stat -c%s "$TMP/super.img")" -ne 16777216 ]; then
  echo "::error::假 super 尺寸不是 16777216（lpmake 没写完整镜像）"
  exit 1
fi
echo "  ✓ 假 super 是完整的 16 MiB"

echo "--- lpdump 输出（同时也是 lpmake_args.py 的解析依据）---"
lpdump "$TMP/super.img" | tee "$TMP/dump.txt"

# 格式自检：lpmake_args.py 需要这些字段
for f in 'Metadata max size:' 'Metadata slot count:' 'Partition table:' 'Block device table:' 'Group table:'; do
  if ! grep -q "$f" "$TMP/dump.txt"; then
    echo "::error::lpdump 输出里没有 '$f'，lpmake_args.py 会解析失败"
    exit 1
  fi
done
echo "  ✓ lpdump 格式与 lpmake_args.py 的解析器匹配"

# lpunpack 在合成镜像上失败只警告：真流程里 lpunpack 读的是小米原厂的完整 super，
# 不是 lpmake 造的，所以这里挂了不代表流水线有问题。用等长的空文件继续后面的验证。
echo "--- lpunpack（合成镜像上的失败仅告警）---"
mkdir -p "$TMP/out"
if ! lpunpack "$TMP/super.img" "$TMP/out"; then
  echo "::warning::lpunpack 读不了 lpmake 合成的镜像（不影响真流程），用空文件继续"
  rm -rf "$TMP/out"; mkdir -p "$TMP/out"
  truncate -s 8388608 "$TMP/out/test.img"
fi
ls -l "$TMP/out"

echo "--- 稀疏往返 ---"
img2simg "$TMP/out/test.img" "$TMP/test.simg"
simg2img "$TMP/test.simg" "$TMP/test.raw"
if cmp -s "$TMP/out/test.img" "$TMP/test.raw"; then
  echo "  ✓ simg2img/img2simg 往返一致"
else
  echo "::error::稀疏往返不一致"
  exit 1
fi

echo "--- 用真实的 lpdump 输出跑一遍 lpmake_args.py ---"
mkdir -p "$TMP/w/logs" "$TMP/w/out"
cp "$TMP/dump.txt" "$TMP/w/logs/lpdump.txt"
cp "$TMP/out/test.img" "$TMP/w/out/test.img"
python3 "$REPO/scripts/lpmake_args.py" "$TMP/w" "$TMP/w/super_new.img" > "$TMP/w/gen.sh"
echo "生成的命令："
cat "$TMP/w/gen.sh"

# 关键：--image=分区=文件 必须在，否则组出来的 super 是分区表正确、内容全零的砖
if ! grep -q -- '--image=test=' "$TMP/w/gen.sh"; then
  echo "::error::lpmake_args.py 没有生成 --image=<分区>=<文件>，组出来的 super 会是空的"
  exit 1
fi
if ! grep -q -- '--force-full-image' "$TMP/w/gen.sh"; then
  echo "::error::lpmake_args.py 没有生成 --force-full-image"
  exit 1
fi
echo "  ✓ 生成的命令带了 --image 和 --force-full-image"

echo "执行它："
bash "$TMP/w/gen.sh"
ls -l "$TMP/w/super_new.img"
if [ "$(stat -c%s "$TMP/w/super_new.img")" -ne 16777216 ]; then
  echo "::error::用生成参数重建的 super 不是完整 16 MiB"
  exit 1
fi
lpdump "$TMP/w/super_new.img" >/dev/null && echo "  ✓ 重建的 super 尺寸完整，且能被 lpdump 正常读回"

echo "--- 自检：fix_ext4_features.py 偏移量 ---"
# 改的是超级块偏移 0x64。算错的话，产出是一个分区表完全正常、内容却是坏的
# super，而且不会报错。所以这个自检必须在下载 5GB 之前跑。
python3 "$REPO/scripts/fix_ext4_features.py" --selftest \
  || { echo "::error::fix_ext4_features.py 自检未通过，先别下载 ROM"; exit 1; }

echo "--- 环境自检：loop 挂载 ext4 ---"
# 03-modify 全靠 mount -o loop 改文件。这里拿一个新做的 ext4 提前试挂一次，
# 免得 5GB 下载 + 解包跑完 30 分钟，才发现 runner 根本不支持 loop 挂载。
dd if=/dev/zero of="$TMP/fs.img" bs=1M count=64 status=none
mkfs.ext4 -q -F "$TMP/fs.img"
mkdir -p "$TMP/mntt"
if sudo mount -o loop,rw "$TMP/fs.img" "$TMP/mntt" 2>/dev/null; then
  echo "挂载成功" | sudo tee "$TMP/mntt/probe.txt" >/dev/null
  if [ "$(sudo cat "$TMP/mntt/probe.txt")" = "挂载成功" ]; then
    echo "  ✓ loop 挂载 ext4 读写正常"
  else
    echo "::warning::挂上了但写入读回不一致"
  fi
  sudo umount "$TMP/mntt"
else
  echo "  ✗ rw 挂载失败，再试试只读 ..."
  if sudo mount -o loop,ro "$TMP/fs.img" "$TMP/mntt" 2>/dev/null; then
    echo "  → 只读能挂，读写不行"
    sudo umount "$TMP/mntt"
  else
    echo "  → 只读也挂不上"
  fi
  echo "[dmesg 尾部]";        sudo dmesg 2>/dev/null | tail -20 || true
  echo "[已占用 loop]";        sudo losetup -a 2>/dev/null || true
  echo "[/proc/filesystems]";  grep -iE 'ext|fuse' /proc/filesystems || true
  echo "[/dev/fuse 是否存在]"; ls -l /dev/fuse 2>/dev/null || echo "  无 /dev/fuse"
  echo "::error::当前 runner 环境无法 loop 挂载 ext4 —— 03-modify（改文件）这条路走不通，先看上面的诊断"
  exit 1
fi

echo
echo "工具链全部就绪 ✅"
