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

# 注意：脚本开着 set -euo pipefail，`写命令 | head` 这种写法非常危险 ——
# head 读够行数就关管道，上游（ls/find）再写就是 SIGPIPE，pipefail 会把它变成
# 非零退出码，直接把整个脚本干掉（纯竞态，上次跑过纯属运气）。
# 所以：一律先落盘，再用 head 读文件。
IMAGES=$(find "$FW" -maxdepth 3 -type d -name images -print -quit)
if [ -z "$IMAGES" ]; then
  echo "::error::解出来没找到 images/ 目录，请确认这是 fastboot 线刷包（.tgz）而不是卡刷包（.zip）"
  find "$FW" -maxdepth 2 > "$LOGS/fw_tree.txt" 2>&1 || true
  head -50 "$LOGS/fw_tree.txt"
  exit 1
fi
echo "images 目录：$IMAGES"

cp -a "$IMAGES"/. "$STOCK"/
ls -lh "$STOCK" > "$LOGS/stock_images.txt" 2>&1 || true
echo "images/ 共 $(wc -l < "$LOGS/stock_images.txt") 行，前 60 行："
head -60 "$LOGS/stock_images.txt"

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
