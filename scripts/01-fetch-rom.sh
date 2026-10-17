#!/usr/bin/env bash
# 把 ROM 弄到 /mnt/rom/src/rom.tgz
# 优先用 rom_url 直链；否则从本仓库的 Release 拉切片并合并。
set -euo pipefail

WORK=/mnt/rom
SRC="$WORK/src"
mkdir -p "$SRC" "$WORK/logs"

cd "$SRC"

if [ -n "${ROM_URL:-}" ]; then
  echo "== 直接从 URL 下载 =="
  echo "$ROM_URL"
  curl -fL --retry 5 --retry-delay 5 --retry-all-errors -o rom.tgz "$ROM_URL"

elif [ -n "${ROM_RELEASE_TAG:-}" ]; then
  echo "== 从 Release 拉取：$ROM_RELEASE_TAG =="
  gh release download "$ROM_RELEASE_TAG" -D "$SRC" --clobber

  shopt -s nullglob
  parts=( *.part-* )
  if [ ${#parts[@]} -gt 0 ]; then
    echo "发现 ${#parts[@]} 个切片，合并中 ..."
    ls -1 *.part-* | sort > parts.list
    # shellcheck disable=SC2046
    cat $(cat parts.list) > rom.tgz
    rm -f parts.list *.part-*
  else
    echo "没有切片，直接当单个 .tgz 处理"
    set -- *.tgz
    if [ "$1" != "rom.tgz" ]; then mv -f "$1" rom.tgz; fi
  fi

else
  echo "::error::必须提供 rom_url 或 rom_release_tag 之一"
  exit 1
fi

echo "== 下载结果 =="
ls -lh "$SRC"
echo "== 文件类型 =="
file rom.tgz || true

SIZE=$(stat -c%s rom.tgz)
if [ "$SIZE" -lt 1000000000 ]; then
  echo "::warning::文件只有 $((SIZE/1024/1024)) MB，看起来不像完整的 fastboot 线刷包（正常 3~6 GB）"
fi
