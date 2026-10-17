@echo off
chcp 65001 >nul
REM ============================================================
REM  小米10青春版 (vangogh) 刷入改过的 super.img
REM
REM  用法：把 super.img、vbmeta*.img 和本脚本放同一个文件夹，双击运行。
REM  要求：手机已解锁 BL，并已进入 fastboot（关机后按住 音量下+电源）。
REM
REM  ★ 重要前提 ★
REM  本脚本只刷 super（+ vbmeta），不动 boot/modem/xbl 等底包分区。
REM  所以手机当前的底包必须和 super 的来源版本一致（例如都是 22.4.7）。
REM  如果底包不一致，请先用官方线刷包的 flash_all.bat 完整刷一遍，
REM  再回来跑本脚本；否则会无限重启或功能异常。
REM ============================================================
setlocal
cd /d "%~dp0"

echo.
echo === 0/4 设备检查 ===
fastboot devices
fastboot getvar product 2^>^&1 | findstr /I "vangogh" >nul
if errorlevel 1 (
  echo.
  echo [警告] 没检测到 vangogh。请确认：
  echo        - 手机已进入 fastboot 模式
  echo        - 已解锁 BL（未解锁无法刷入任何改动过的镜像）
  echo        - 数据线正常 / 已装驱动
  echo.
  pause
)

if not exist "super.img" (
  echo [错误] 当前目录没有 super.img。
  echo        如果下载到的是 super.img.part-aa 之类切片，先校验再合并：
  echo.
  echo          certutil -hashfile super.img.part-aa SHA256     (逐个和 SHA256SUMS.txt 比对)
  echo          copy /b super.img.part-aa+super.img.part-ab+super.img.part-ac+super.img.part-ad+super.img.part-ae super.img
  echo.
  echo        合并后应约 8.5 GB；小很多说明有分片没下全。
  pause
  exit /b 1
)

echo.
echo === 1/4 刷 super ===
fastboot flash super super.img
if errorlevel 1 goto err

echo.
echo === 2/4 关闭 AVB 校验（关键，不做会无限重启）===
REM vangogh 官方 flash_all.bat 只刷 vbmeta 和 vbmeta_system，没有 vbmeta_vendor
for %%f in (vbmeta vbmeta_system) do (
  if exist "%%f.img" (
    echo -- %%f
    fastboot --disable-verity --disable-verification flash %%f "%%f.img"
  ) else (
    echo [警告] 缺少 %%f.img，跳过（下载包不完整？）
  )
)

echo.
echo === 3/4 清除数据（换过 system 后建议清，避免开机异常）===
fastboot -w

echo.
echo === 4/4 重启 ===
fastboot reboot
echo.
echo [完成] 首次开机较慢（3~10 分钟）。
echo        若长时间卡在开机动画，多半是：AVB 没关 / 底包版本和 super 不一致。
pause
exit /b 0

:err
echo.
echo [失败] 刷 super 出错。可能原因：BL 未解锁 / 不在 fastboot / super.img 不完整。
pause
exit /b 1
