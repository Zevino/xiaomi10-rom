#!/usr/bin/env bash
# 小米10青春版 (vangogh) 刷入改过的 super.img —— Linux / macOS 版
# 把 super.img、vbmeta*.img 和本脚本放同目录，然后：bash flash-modded.sh
#
# ★ 本脚本只刷 super（+ vbmeta），不动 boot/modem/xbl 等底包分区。
#   所以手机当前底包必须和 super 的来源版本一致（例如都是 22.4.7）。
#   底包不一致时，先用官方线刷包的 flash_all.bat 完整刷一遍，再跑本脚本。
set -euo pipefail
cd "$(dirname "$0")"

echo
echo "=== 0/4 设备检查 ==="
fastboot devices
if ! fastboot getvar product 2>&1 | grep -qi vangogh; then
  echo
  echo "[警告] 没检测到 vangogh。确认手机已进 fastboot、BL 已解锁、数据线正常。"
  read -r -p "继续按回车，或 Ctrl+C 退出 ..." _
fi

if [ ! -f super.img ]; then
  echo "[错误] 当前目录没有 super.img"
  echo "        若下载到 super.img.part-aa 之类切片，先合并：cat super.img.part-* > super.img"
  exit 1
fi

echo
echo "=== 1/4 刷 super ==="
fastboot flash super super.img

echo
echo "=== 2/4 关闭 AVB 校验（关键）==="
# vangogh 官方 flash_all.bat 只刷 vbmeta 和 vbmeta_system，没有 vbmeta_vendor
for f in vbmeta vbmeta_system; do
  if [ -f "$f.img" ]; then
    echo "-- $f"
    fastboot --disable-verity --disable-verification flash "$f" "$f.img"
  else
    echo "[警告] 缺少 $f.img，跳过"
  fi
done

echo
echo "=== 3/4 清除数据 ==="
fastboot -w

echo
echo "=== 4/4 重启 ==="
fastboot reboot

echo
echo "[完成] 首次开机较慢（3~10 分钟）。若长时间卡开机动画，多半是 AVB 没关或分区不匹配。"
