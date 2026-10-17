#!/usr/bin/env bash
# 解开 fastboot 线刷包 -> 得到 images/ -> 拆 super.img -> lpunpack 出各分区
set -euo pipefail

WORK=/mnt/rom
SRC="$WORK/src"
FW="$WORK/fw"
STOCK="$WORK/stock"
OUT="$WORK/out"
LOGS="$WORK/logs"
mkdir -p "$FW" "$STOCK" "$OUT" "$LOGS"

echo "== 解 .tgz =="
tar -xzf "$SRC/rom.tgz" -C "$FW"

echo "== 解内层 .tar =="
(
  cd "$FW"
  shopt -s nullglob
  for t in *.tar; do
    echo " -> $t"
    tar -xf "$t"
  done
)

IMAGES=$(find "$FW" -maxdepth 3 -type d -name images | head -1)
if [ -z "$IMAGES" ]; then
  echo "::error::解出来没找到 images/ 目录，请确认这是 fastboot 线刷包（.tgz）而不是卡刷包（.zip）"
  find "$FW" -maxdepth 2 | head -50
  exit 1
fi
echo "images 目录：$IMAGES"

cp -a "$IMAGES"/. "$STOCK"/
ls -lh "$STOCK" | head -60

# 立刻删掉 tgz / tar，省下 ~12GB
rm -rf "$FW" "$SRC"

SUPER="$STOCK/super.img"
if [ ! -f "$SUPER" ]; then
  echo "::error::images/ 里没有 super.img。这台可能不是动态分区方案，本流程不适用。"
  ls -1 "$STOCK"
  exit 1
fi

cd "$WORK"
echo "== 判断 super.img 是否 sparse =="
MAGIC=$(python3 -c "print(open('$SUPER','rb').read(4).hex())")
echo "magic=$MAGIC"

if [ "$MAGIC" = "3aff26ed" ]; then
  echo "是 Android sparse，转成 raw ..."
  simg2img "$SUPER" "$WORK/super_raw.img"
else
  echo "已是 raw，直接拷贝"
  cp "$SUPER" "$WORK/super_raw.img"
fi

echo "== lpdump（分区表）=="
lpdump "$WORK/super_raw.img" | tee "$LOGS/lpdump.txt"

echo "== lpunpack 拆分（8.5GB，需要几分钟）=="
lpunpack "$WORK/super_raw.img" "$OUT" 2>&1 | tee "$LOGS/lpunpack.txt"

echo "== 拆出来的分区 =="
ls -lh "$OUT"

# 原 super 不再需要，删掉省 ~8.5GB
rm -f "$WORK/super_raw.img" "$SUPER"

if [ -z "$(ls -A "$OUT")" ]; then
  echo "::error::lpunpack 没有产出文件，请看上面的 lpunpack 输出"
  exit 1
fi
