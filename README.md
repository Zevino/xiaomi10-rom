# vangogh ROM 构建流水线（小米10青春版 / Mi 10 Lite Zoom）

在 **GitHub Actions** 上解包官方 fastboot 线刷包 → 去预装 / 改机型 → 重组 `super.img` →
发布到 **GitHub Release** 供你下载。**本机只需要 Windows + `fastboot`**，不用装 Linux。

- 设备：`vangogh`（小米10青春版 / Mi 10 Youth / Mi 10 Lite Zoom）
- 平台：SM7250 骁龙 765G，**A-only 单槽 + 动态分区**，`system/vendor/product/system_ext/odm` 全是 **ext4**
- `super` 大小：`9126805504` 字节；校验：AVB（`vbmeta` / `vbmeta_system` / `vbmeta_vendor`）

---

## 0. 一次性准备：把这份代码推到 GitHub

本机已经有 `git`。先建一个**公开仓库**（公开仓库的 Actions 分钟数无限免费），然后：

```bash
cd "C:/Users/a/Desktop/code-v1/C++/xiaomirom"
git init -b main
git add .
git commit -m "vangogh rom pipeline"
git remote add origin https://github.com/<你的用户名>/<仓库名>.git
git push -u origin main
```

之后如果改了 `config/` 里的清单，`git add . && git commit -m update && git push` 即可。

> 可选：装 `gh` 会方便些 —— `winget install GitHub.cli`，然后 `gh auth login`。

---

## 1. 给 CI 提供 ROM

两条路，**任选一条**：

### 方案 A：给一个直链（推荐，省掉 5GB 上传）
在 小米 ROM 站点（如 mifirm.net 的 vangogh 页 / xiaomirom.com）点“Download”，
用浏览器 F12 → Network 找到最终跳转的 `https://bigota.d.miui.com/V13.0.x.0.SJVCNXM/vangogh_images_....tgz`，
把这条 URL 填进 workflow 的 `rom_url`。

> 官方 CDN 的下载一般不需要登录、无验证码，CI 能直接 `curl`。

### 方案 B：自己上传到 Release（直链拿不到时用）
1. 本机下好 vangogh 的 fastboot 线刷包（`.tgz`，约 5 GB）。
2. 切片（Git Bash 里执行；Release 单文件上限 2 GiB，所以切 1800M）：
   ```bash
   split -b 1800M vangogh_images_XXXX.tgz vangogh_images_XXXX.tgz.part-
   ```
   Windows CMD 出不来 split 的话，用 Git Bash（你已经装了 `/usr/bin/split`）。
3. 在 GitHub 仓库 → Releases → 新建一个 Release（比如标签 `rom-src`），把这几个
   `*.part-aa / -ab / -ac` 拖进去上传。
4. 跑 workflow 时把 `rom_release_tag` 填成 `rom-src`。

---

## 2. 跑流水线

仓库页面 → **Actions** → 左侧 **Build vangogh ROM** → **Run workflow**，填参数：

| 参数 | 说明 |
|---|---|
| `rom_url` | 方案 A 的直链 |
| `rom_release_tag` | 方案 B 的 Release 标签 |
| `do_debloat` | 执行去预装（按 `config/debloat.txt`） |
| `apply_props` | 执行属性修改（按 `config/props.tsv`） |
| `build_super` | 是否重组完整 `super.img`（推荐开） |
| `out_release_tag` | 产物发到哪个 Release，留空=自动 `rom-<运行号>` |

跑完大约 20–40 分钟。**建议第一次先 `do_debloat=false`、`apply_props=false` 跑一遍**，
确认链路能通、拿到 `logs/apps.txt`（里面是各分区真实的 app 文件夹名），再定稿清单。

---

## 3. 下载并合并切片

Release 里你会看到：

```
super.img.part-aa / part-ab / part-ac     # 5GB 左右，切片的完整 super
system_modified.img(.part-*)              # 可选：只改过的 system 分区
vbmeta.img / vbmeta_system.img / vbmeta_vendor.img
flash-modded.bat / flash-modded.sh
SHA256SUMS.txt / debloat-used.txt / props-used.tsv
```

合并（**Windows CMD**，把 `*` 换成 aa、ab、ac 逐个拼）：

```cmd
copy /b super.img.part-aa + super.img.part-ab + super.img.part-ac super.img
```

或 **Git Bash**：

```bash
cat super.img.part-* > super.img
```

校验（Git Bash）：`sha256sum -c SHA256SUMS.txt`（切片文件跳过即可）。

---

## 4. 刷机（Windows）

前置：**必须先解锁 BL**（小米解锁工具 Mi Unlock，绑账号 + 通常要等 168 小时）。
未解锁的话，任何改动过的镜像都刷不进去。

1. 把所有文件放同一个文件夹（`super.img`、`vbmeta*.img`、`flash-modded.bat`）。
2. 手机关机 → 按住 **音量下 + 电源** 进入 fastboot（屏幕出现 FASTBOOT 字样）。
3. 双击 `flash-modded.bat`。它会：
   - `fastboot flash super super.img`
   - 对 `vbmeta / vbmeta_system / vbmeta_vendor` 加 `--disable-verity --disable-verification` 重刷
     → **这一步是必须的**，否则改过的 system 过不了校验，会无限重启
   - `fastboot -w` 清数据 → `fastboot reboot`
4. 首次开机慢（3–10 分钟）属正常。

**如果只想小改一处**：也可以只用 `system_modified.img`，进 `fastbootd` 单刷（不用整包）：

```cmd
adb reboot fastboot
fastboot flash system system_modified.img
fastboot --disable-verity --disable-verification flash vbmeta_system vbmeta_system.img
fastboot reboot
```

也可以用回官方 `flash_all.bat`：把官方 `images\super.img` 换成我们的 `super.img` 再跑，
但**跑完必须再单独执行三条 vbmeta 命令**（`flash_all.bat` 会把官方 vbmeta 又写回去）。

---

## 5. 改配置

### `config/debloat.txt` — 去预装
格式 `<分区>:<路径>`，支持通配符 `*`，**大小写不敏感兜底**，找不到的条目自动跳过。

先看第一次构建产出的 `logs/apps.txt`，里面有每个分区 `app/`、`priv-app/` 下的真实文件夹名，
照着改：

```
system:priv-app/MIUIBrowser*
system:app/MiShop*
system_ext:priv-app/MiuiSuperMarket*
```

⚠️ 别删 `system/framework`、`system/priv-app/MIUI*` 这类核心组件，会开不了机。

### `config/props.tsv` — 改属性 / 机型
格式 `<分区>:<文件>:<键>=<值>`，键存在则替换、不存在则追加。例如改机型名：

```
system:build.prop:ro.product.model=Xiaomi Mi 10 Lite Zoom
system:build.prop:ro.product.system.model=Xiaomi Mi 10 Lite Zoom
vendor:build.prop:ro.product.vendor.model=Xiaomi Mi 10 Lite Zoom
```

---

## 6. 原理 & 为什么这么做

```
fastboot .tgz ──tar──> images/super.img ──simg2img──> raw ──lpunpack──> system/vendor/product/...
                                                                              │
                             ext4 rw 挂载，直接删文件/改 props（SELinux 上下文天然保留）
                                                                              ▼
             lpmake（分区大小=镜像实际大小，与原厂布局完全一致）──> super.img ──img2simg──> 稀疏
```

- **分区大小保持原样**：`lpunpack` 按原分区尺寸落盘，`lpmake` 再用这个尺寸重建，
  所以新 super 与原厂布局一模一样，必然装得下、能刷。
- **不用 e2fsdroid 重建**：rw 挂载方式下 SELinux label 不会被破坏，比“解包目录再重新
  `mkfs`”省事得多，也不会把分区大小搞错。
- **不用管 WSL**：全部跑在 GitHub 的 Ubuntu runner 上，`/mnt` 有 ~70 GB，工作目录放那里。

---

## 7. 注意 / 常见坑

1. **BL 必须解锁**，这是硬门槛。
2. **AVB 必须关**（第 4 步的 `--disable-verity --disable-verification`），否则无限重启。
3. **第一次跑建议关掉修改**，先确认链路通、拿到 `logs/apps.txt`。
4. **`rom_url` 拿不到直链**就用 Release 切片，别硬猜 bigota 的文件名（末尾有 hash）。
5. Artifact 存储只有 500 MB（Free 计划），所以产物**只走 Release**，不要指望 artifact。
6. 反回滚：别拿 Android 12 的包往更高版本的机器上倒刷。
7. 官方 vangogh 最终版是 **MIUI 13 / Android 12**（`V13.0.9.0.SJVCNXM` 卡刷 / `V13.0.7.0` 线刷），没有 HyperOS。

---

## 目录结构

```
.github/workflows/build-rom.yml   # 流水线定义
scripts/
  00-tools.sh        # 装 lpunpack/lpmake/e2fsprogs
  01-fetch-rom.sh    # 拉 ROM（直链 or Release 切片）
  02-unpack.sh       # 解 tgz -> 拆 super -> lpunpack
  03-modify.sh       # 挂载 -> 去预装 -> 改 props -> 卸载
  04-repack.sh       # lpmake 重组 super + 产出 system 镜像
  05-publish.sh      # 切片 + 发布到 Release
  lpmake_args.py     # 从 lpdump 输出生成 lpmake 命令
  flash-modded.bat   # Windows 刷机脚本
  flash-modded.sh    # Linux/macOS 刷机脚本
config/
  debloat.txt        # 去预装清单
  props.tsv          # 属性修改清单
```
