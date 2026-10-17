#!/usr/bin/env bash
# 安装解包/打包 tools。全部来自 AOSP system/extras 的预编译静态二进制。
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

echo "== apt 依赖 =="
sudo apt-get update -qq
# e2fsprogs 提供 e2fsck / resize2fs；android-sdk-libsparse-utils 提供 simg2img(备用)
sudo apt-get install -y -qq e2fsprogs curl ca-certificates >/dev/null
sudo apt-get install -y -qq android-sdk-libsparse-utils >/dev/null 2>&1 || echo "[提示] 没装上 android-sdk-libsparse-utils，改用下面的预编译版"

TOOLS_BASE="https://raw.githubusercontent.com/Rprop/aosp15_partition_tools/main/linux_glibc_x86_64"
sudo mkdir -p /usr/local/bin

for t in lpunpack lpmake lpadd lpdumps simg2img img2simg ext2simg append2simg; do
  echo "下载 $t ..."
  sudo curl -fsSL "$TOOLS_BASE/$t" -o "/usr/local/bin/$t"
  sudo chmod +x "/usr/local/bin/$t"
done

# 该仓库里 dump 工具名叫 lpdumps，统一暴露成 lpdump
sudo ln -sf /usr/local/bin/lpdumps /usr/local/bin/lpdump

echo "== 校验 =="
for t in lpunpack lpmake lpdump simg2img img2simg e2fsck; do
  printf '%-10s -> ' "$t"; command -v "$t" || { echo "缺少 $t"; exit 1; }
done

# lpdumps 到底是不是普通 dumper？用 --help 探测一下
if ! lpdump --help 2>&1 | grep -qi 'dump'; then
  echo "[警告] lpdump 行为可疑，输出如下："
  lpdump --help 2>&1 | head -20 || true
fi

echo "工具安装完成"
