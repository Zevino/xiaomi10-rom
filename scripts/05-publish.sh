#!/usr/bin/env bash
# 把产物切片后上传到 GitHub Release（Release 附件不占 Actions artifact 的 500MB 配额）
set -euo pipefail

WORK=/mnt/rom
BUILD="$WORK/build"
STOCK="$WORK/stock"
REPO="${GITHUB_WORKSPACE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
TAG="${OUT_TAG:-rom-${GITHUB_RUN_NUMBER:-manual}}"

STAGE="$WORK/stage"
rm -rf "$STAGE"; mkdir -p "$STAGE"

# ---- 一起分发的小文件（刷机必需）----
# vangogh 只有 vbmeta 和 vbmeta_system（没有 vbmeta_vendor）
for f in vbmeta.img vbmeta_system.img; do
  if [ -f "$STOCK/$f" ]; then cp "$STOCK/$f" "$STAGE/"; else echo "[提示] stock 里没有 $f"; fi
done
cp "$REPO/scripts/flash-modded.sh" "$STAGE/"
cp "$REPO/scripts/flash-modded.bat" "$STAGE/"
cp "$REPO/config/debloat.txt" "$STAGE/debloat-used.txt"
cp "$REPO/config/props.tsv" "$STAGE/props-used.tsv"

# ---- 大镜像：超过 1.9GB 就切片（Release 单文件上限 2GiB）----
shopt -s nullglob
for big in "$BUILD"/*.img; do
  b=$(basename "$big")
  size=$(stat -c%s "$big")
  if [ "$size" -gt 1900000000 ]; then
    echo "切片 $b ($((size/1024/1024)) MB)"
    split -b 1800M "$big" "$STAGE/${b}.part-"
  else
    cp "$big" "$STAGE/"
  fi
done

if [ -z "$(ls -A "$STAGE")" ]; then
  echo "::error::stage 为空，没有可发布的产物"
  exit 1
fi

( cd "$STAGE" && sha256sum ./* > SHA256SUMS.txt && ls -lh )

echo "== 创建/更新 Release: $TAG =="
if ! gh release view "$TAG" >/dev/null 2>&1; then
  gh release create "$TAG" \
    --title "vangogh ROM ${TAG}" \
    --notes "自动化构建产物（设备 vangogh / 小米10青春版）。

下载后用 \`cat *.part-* > super.img\` 合并切片（Windows 见 README）。
刷机脚本：flash-modded.bat（Windows）/ flash-modded.sh（Linux）。
**务必先解锁 BL，并在刷完 super 后关闭 AVB 校验，否则开不了机。**"
fi

gh release upload "$TAG" "$STAGE"/* --clobber

echo "== 发布完成 =="
gh release view "$TAG" --json url -q .url || true
