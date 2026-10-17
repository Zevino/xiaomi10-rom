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
echo "== 全链路自检（8MiB 假 super，秒级）=="
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

lpmake --metadata-size 65536 --metadata-slots 2 \
       --device super:16777216 \
       --group smoke:16777216 \
       --partition test:readonly:8388608:smoke \
       --output "$TMP/super.img"

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

mkdir -p "$TMP/out"
lpunpack "$TMP/super.img" "$TMP/out"
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
echo "执行它："
bash "$TMP/w/gen.sh"
lpdump "$TMP/w/super_new.img" >/dev/null && echo "  ✓ 用生成参数重建的 super 能被 lpdump 正常读回"

echo
echo "工具链全部就绪 ✅"
