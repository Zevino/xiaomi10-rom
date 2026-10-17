#!/usr/bin/env bash
# 挂载各分区 -> 去预装 -> 改 props -> 卸载
#
# 说明：vangogh 的 system/vendor/product/system_ext/odm 都是 ext4，
# 直接 rw 挂载后删文件，SELinux 上下文/权限天然保留，不用 e2fsdroid 重建。
#
# 分区名兼容：lpunpack 可能输出 system_a.img（带 _a 后缀），也可能输出 system.img。
# 这里统一做别名映射，所以 config 里写 system:... 两种都能命中。
set -euo pipefail

WORK=/mnt/rom
OUT="$WORK/out"
LOGS="$WORK/logs"
MNT="$WORK/mnt"
REPO="${GITHUB_WORKSPACE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

mkdir -p "$LOGS" "$MNT"
shopt -s nullglob

declare -A MPATH   # 逻辑名 -> 挂载目录（含别名）

# ---------- 1. 挂载所有 ext4 分区 ----------
declare -A MOUNTED  # 真实挂载目录 -> 1（用于最终卸载）
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
    MOUNTED["$MNT/$p"]=1
    MPATH["$p"]="$MNT/$p"
    # 别名：system_a -> system（A-only 机型只是命名习惯带 _a）
    case "$p" in
      *_a)
        alias="${p%_a}"
        MPATH["$alias"]="$MNT/$p"
        echo "  已挂载 -> $MNT/$p  （别名：$alias）"
        ;;
      *_b)
        echo "::warning::$p 是 _b 槽？vangogh 是 A-only，正常不该出现"
        echo "  已挂载 -> $MNT/$p"
        ;;
      *)
        echo "  已挂载 -> $MNT/$p"
        ;;
    esac
  else
    echo "::warning::$p 挂载失败，跳过修改"
  fi
done

if [ ${#MOUNTED[@]} -eq 0 ]; then
  echo "::error::没有任何分区挂载成功"
  exit 1
fi

echo "== 可用的分区名（config 里可用的前缀）=="
printf '  %s\n' "$(printf '%s\n' "${!MPATH[@]}" | sort | tr '\n' ' ')"

# ---------- 2. 导出目录清单，方便定稿 debloat 列表 ----------
{
  for d in "${!MOUNTED[@]}"; do
    echo "########## $d ##########"
    echo "--- 顶层 ---"
    ls -1 "$d"
    for sub in "$d" "$d"/system "$d"/system_ext "$d"/product "$d"/vendor; do
      [ -d "$sub" ] || continue
      for a in app priv-app; do
        [ -d "$sub/$a" ] || continue
        echo "--- $sub/$a ---"
        ls -1 "$sub/$a"
      done
    done
  done
} > "$LOGS/apps.txt" 2>&1 || true
echo "目录清单已写入 logs/apps.txt"

# ---------- 3. 路径解析：兼容布局 + 忽略大小写兜底 + 剔除被父目录覆盖的项 ----------
# $1=分区逻辑名 $2=相对路径（可含通配符）；每行输出一个匹配到的绝对路径
resolve() {
  local part="$1" rel="$2" base c m
  local root="${MPATH[$part]:-}"
  [ -z "$root" ] && return 0
  base="$(basename "$rel")"
  local -a cand=()

  for c in \
      "$root/$rel" \
      "$root/system/$rel" \
      "$root/system_ext/$rel" \
      "$root/product/$rel" \
      "$root/$part/$rel"; do
    for m in $c; do
      [ -e "$m" ] && cand+=("$m")
    done
  done

  if [ ${#cand[@]} -eq 0 ]; then
    # 兜底：按最后一段的名字忽略大小写找（MIUI 文件夹大小写经常不一致）
    while IFS= read -r m; do
      [ -n "$m" ] && cand+=("$m")
    done < <(find "$root" -maxdepth 6 -iname "$base" 2>/dev/null || true)
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
  n_del=0
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%%#*}"
    line="$(printf '%s' "$line" | tr -d '\r' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    [ -z "$line" ] && continue

    part="${line%%:*}"
    rel="${line#*:}"
    if [ -z "${MPATH[$part]:-}" ]; then
      echo "跳过（分区未挂载/名字不对） $part:$rel"
      continue
    fi

    found=0
    while IFS= read -r m; do
      [ -z "$m" ] && continue
      found=1
      n_del=$((n_del + 1))
      echo "删除 ${m#/mnt/rom/mnt/}"
      sudo rm -rf -- "$m"
    done < <(resolve "$part" "$rel")

    if [ "$found" -eq 0 ]; then echo "跳过（不存在） $part:$rel"; fi
  done < "$REPO/config/debloat.txt"
  echo "共删除 $n_del 个条目"
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

    if [ -z "${MPATH[$part]:-}" ]; then
      echo "跳过（分区未挂载/名字不对） $part:$file"
      continue
    fi

    found=0
    while IFS= read -r f; do
      [ -z "$f" ] && continue
      found=1
      if sudo grep -qE "^[[:space:]]*${key}=" "$f"; then
        sudo sed -i -E "s|^[[:space:]]*${key}=.*|${key}=${val}|" "$f"
        echo "改写 ${f#/mnt/rom/mnt/} :: ${key}=${val}"
      else
        printf '\n%s=%s\n' "$key" "$val" | sudo tee -a "$f" >/dev/null
        echo "追加 ${f#/mnt/rom/mnt/} :: ${key}=${val}"
      fi
    done < <(resolve "$part" "$file")

    if [ "$found" -eq 0 ]; then echo "跳过（文件不存在） $part:$file"; fi
  done < "$REPO/config/props.tsv"
else
  echo "跳过 props 修改"
fi

# ---------- 6. 卸载 + fsck ----------
echo "== 卸载 =="
for d in "${!MOUNTED[@]}"; do
  sudo sync
  sudo umount "$d" || sudo umount -l "$d" || true
  name=$(basename "$d")
  sudo e2fsck -fy "$OUT/$name.img" > "$LOGS/e2fsck-$name.txt" 2>&1 || true
  echo "$name 已卸载"
done

echo "== 修改完成 =="
