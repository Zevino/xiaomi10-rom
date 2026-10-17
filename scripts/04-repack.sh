#!/usr/bin/env bash
# 产出：
#   build/system_modified.img  改过的 system 分区（稀疏，用于 fastbootd 单刷）
#   build/super.img            完整 super（稀疏，用于替换进 images/ 走 flash_all）
set -euo pipefail

WORK=/mnt/rom
OUT="$WORK/out"
BUILD="$WORK/build"
LOGS="$WORK/logs"
REPO="${GITHUB_WORKSPACE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
mkdir -p "$BUILD" "$LOGS"

# ---------- 1. 单独产出改过的 system 分区（体积小，~2-3GB，方便单刷）----------
SYSTEM_IMG=$(ls -1 "$OUT" 2>/dev/null | grep -E '^system(_a)?\.img$' | head -1 || true)
if [ -n "$SYSTEM_IMG" ]; then
  echo "== 生成稀疏版 system 分区镜像 =="
  if img2simg "$OUT/$SYSTEM_IMG" "$BUILD/system_modified.img"; then
    echo "-> build/system_modified.img"
  else
    cp "$OUT/$SYSTEM_IMG" "$BUILD/system_modified.img"
  fi
fi

# ---------- 2. 重组完整 super ----------
if [ "${BUILD_SUPER:-true}" != "true" ]; then
  echo "已选择不重组 super，只保留 system 分区镜像"
  ls -lh "$BUILD"
  exit 0
fi

echo "== 生成 lpmake 命令 =="
python3 "$REPO/scripts/lpmake_args.py" "$WORK" "$BUILD/super_raw.img" \
  > "$LOGS/lpmake_cmd.sh" 2> "$LOGS/lpmake_args.txt"

echo "---- 参数明细 ----"
cat "$LOGS/lpmake_args.txt"
echo "---- 将要执行的命令 ----"
cat "$LOGS/lpmake_cmd.sh"

echo "== 执行 lpmake（写 9GB，需要几分钟）=="
bash "$LOGS/lpmake_cmd.sh"

if [ ! -f "$BUILD/super_raw.img" ]; then
  echo "::error::lpmake 没有产出 super_raw.img"
  exit 1
fi
ls -lh "$BUILD/super_raw.img"

echo "== 转成稀疏镜像（体积约减半，便于下载）=="
img2simg "$BUILD/super_raw.img" "$BUILD/super.img"

echo "== 校验：能否被 lpdump 正常读回 =="
lpdump "$BUILD/super.img" > "$LOGS/lpdump_new.txt" 2>&1 && echo "回读 OK" || {
  echo "::warning::lpdump 读不回新 super，先不删 raw"
}
tail -40 "$LOGS/lpdump_new.txt" || true

rm -f "$BUILD/super_raw.img"
echo "== 完成 =="
ls -lh "$BUILD"
