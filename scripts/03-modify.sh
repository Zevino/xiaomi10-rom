#!/usr/bin/env bash
# 挂载各分区 -> 去预装 -> 改 props -> 卸载
#
# 说明：vangogh 的 system/vendor/product/system_ext/odm 都是 ext4，
# 直接 rw 挂载后删文件，SELinux 上下文/权限天然保留，不用 e2fsdroid 重建。
set -euo pipefail

WORK=/mnt/rom
OUT="$WORK/out"
LOGS="$WORK/logs"
MNT="$WORK/mnt"
REPO="${GITHUB_WORKSPACE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

mkdir -p "$LOGS" "$MNT"
shopt -s nullglob

# ---------- 1. 挂载所有 ext4 分区 ----------
declare -A MP
for img in "$OUT"/*.img; do
  p=$(basename "$img" .img)
  t=$(file -b "$img")
  echo "$p : $t"

  if echo "$t" | grep -qi 'EROFS'; then
    echo "::warning::$p 是 eROFS，本流程跳过（vangogh 正常应为 ext4）"
    continue
  fi
  if ! echo "$t" | grep -qiE 'ext[234]|Linux rev'; then
    echo "::warning::$p 不是 ext4，跳过"
    continue
  fi

  sudo mkdir -p "$MNT/$p"
  if sudo mount -o loop,rw "$img" "$MNT/$p"; then
    MP[$p]=1
    echo "  已挂载 -> $MNT/$p"
  else
    echo "::warning::$p 挂载失败，跳过修改"
  fi
done

if [ ${#MP[@]} -eq 0 ]; then
  echo "::error::没有任何分区挂载成功"
  exit 1
fi

# ---------- 2. 导出目录清单，方便你定稿 debloat 列表 ----------
{
  for p in "${!MP[@]}"; do
    echo "########## $p (顶层) ##########"
    ls -1 "$MNT/$p"
    for sub in "$MNT/$p" "$MNT/$p"/system "$MNT/$p"/system_ext "$MNT/$p"/product "$MNT/$p"/vendor; do
      [ -d "$sub" ] || continue
      for d in app priv-app; do
        [ -d "$sub/$d" ] || continue
        echo "--- $sub/$d ---"
        ls -1 "$sub/$d"
      done
    done
  done
} > "$LOGS/apps.txt" 2>&1 || true
echo "目录清单已写入 logs/apps.txt（去预装前请先看它确认文件夹名）"

# ---------- 3. 路径解析：兼容各种布局 + 忽略大小写兜底 + 剔除被父目录覆盖的项 ----------
# $1=分区名 $2=相对路径（可含通配符）；每行输出一个匹配到的绝对路径
resolve() {
  local part="$1" rel="$2" base c m
  base="$(basename "$rel")"
  local -a cand=()

  for c in \
      "$MNT/$part/$rel" \
      "$MNT/$part/system/$rel" \
      "$MNT/$part/system_ext/$rel" \
      "$MNT/$part/product/$rel" \
      "$MNT/$part/$part/$rel"; do
    for m in $c; do
      [ -e "$m" ] && cand+=("$m")
    done
  done

  if [ ${#cand[@]} -eq 0 ]; then
    # 兜底：按最后一段的名字忽略大小写找（MIUI 文件夹大小写经常不一致）
    while IFS= read -r m; do
      [ -n "$m" ] && cand+=("$m")
    done < <(find "$MNT/$part" -maxdepth 6 -iname "$base" 2>/dev/null || true)
  fi

  [ ${#cand[@]} -eq 0 ] && return 0

  # 去重；若某条路径是另一条的父目录，只保留父目录
  printf '%s\n' "${cand[@]}" | sort -u | awk '
    { p = $0; for (k in keep) if (index(p, k) == 1) next; keep[p] = 1; print p }
  '
}

# ---------- 4. 去预装 ----------
if [ "${DO_DEBLOAT:-true}" = "true" ]; then
  echo "== 去预装 =="
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%%#*}"
    line="$(printf '%s' "$line" | tr -d '\r' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    [ -z "$line" ] && continue

    part="${line%%:*}"
    rel="${line#*:}"
    if [ -z "${MP[$part]:-}" ]; then
      echo "跳过（分区未挂载） $part:$rel"
      continue
    fi

    found=0
    while IFS= read -r m; do
      [ -z "$m" ] && continue
      found=1
      echo "删除 ${m#"$MNT/"}"
      sudo rm -rf -- "$m"
    done < <(resolve "$part" "$rel")

    if [ "$found" -eq 0 ]; then echo "跳过（不存在） $part:$rel"; fi
  done < "$REPO/config/debloat.txt"
else
  echo "跳过去预装"
fi

# ---------- 5. 改 props ----------
if [ "${APPLY_PROPS:-true}" = "true" ]; then
  echo "== 改 props =="
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%%#*}"
    line="$(printf '%s' "$line" | tr -d '\r' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    [ -z "$line" ] && continue

    part="${line%%:*}"; rest="${line#*:}"
    file="${rest%%:*}"; kv="${rest#*:}"
    key="${kv%%=*}"; val="${kv#*=}"

    if [ -z "${MP[$part]:-}" ]; then
      echo "跳过（分区未挂载） $part:$file"
      continue
    fi

    found=0
    while IFS= read -r f; do
      [ -z "$f" ] && continue
      found=1
      if sudo grep -qE "^[[:space:]]*${key}=" "$f"; then
        sudo sed -i -E "s|^[[:space:]]*${key}=.*|${key}=${val}|" "$f"
        echo "改写 ${f#"$MNT/"} :: ${key}=${val}"
      else
        printf '\n%s=%s\n' "$key" "$val" | sudo tee -a "$f" >/dev/null
        echo "追加 ${f#"$MNT/"} :: ${key}=${val}"
      fi
    done < <(resolve "$part" "$file")

    if [ "$found" -eq 0 ]; then echo "跳过（文件不存在） $part:$file"; fi
  done < "$REPO/config/props.tsv"
else
  echo "跳过 props 修改"
fi

# ---------- 6. 卸载 + fsck ----------
echo "== 卸载 =="
for p in "${!MP[@]}"; do
  sudo sync
  sudo umount "$MNT/$p" || sudo umount -l "$MNT/$p" || true
  sudo e2fsck -fy "$OUT/$p.img" > "$LOGS/e2fsck-$p.txt" 2>&1 || true
  echo "$p 已卸载"
done

echo "== 修改完成 =="
