@echo off
REM ============================================================
REM  小米10青春版 (vangogh) 刷入改过的 super.img
REM  用法：把 super.img 和本脚本、vbmeta*.img 放同一个文件夹，
REM        双击运行（或在本目录开 cmd 执行本脚本）。
REM  要求：手机已解锁 BL，并已进入 fastboot（关机后按住 音量下+电源）。
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
  echo        如果下载到的是 super.img.part-aa 之类切片，请先合并：
  echo        type super.img.part-* ^> super.img
  pause
  exit /b 1
)

echo.
echo === 1/4 刷 super ===
fastboot flash super super.img
if errorlevel 1 goto err

echo.
echo === 2/4 关闭 AVB 校验（关键，不做会无限重启）===
for %%f in (vbmeta vbmeta_system vbmeta_vendor) do (
  if exist "%%f.img" (
    echo -- %%f
    fastboot --disable-verity --disable-verification flash %%f "%%f.img"
  )
)

echo.
echo === 3/4 清除数据（改过 system 后建议清，避免开机异常）===
fastboot -w

echo.
echo === 4/4 重启 ===
fastboot reboot
echo.
echo [完成] 首次开机较慢（3~10 分钟）。若长时间卡在开机动画，多半是 AVB 没关或分区不匹配。
pause
exit /b 0

:err
echo.
echo [失败] 刷 super 出错。可能原因：BL 未解锁 / 不在 fastboot / super.img 不完整。
pause
exit /b 1
