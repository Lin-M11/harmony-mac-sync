#!/bin/zsh
# 通知自检 · 看通知的样子
#
# 发一条测试短信样子的通知，用来确认通知里显示的是 App 的名字与图标，
# 并且能在通知中心里翻到。不碰蓝牙，不读手机。
#
# 用法：在 Finder 里双击本文件
# 若弹出的通知不是「鸿蒙短信同步 + 图标」，看窗口里打印的授权状态。

cd "$(dirname "$0")" || exit 1

SYNC_BIN="./HarmonySync.app/Contents/MacOS/HarmonySync"
OUT=/tmp/harmony_sync_result.txt

{
  echo "########################################"
  echo "# 通知自检"
  echo "########################################"
  echo ""
  echo "  接下来会弹一条测试通知。看三处："
  echo "    1. 通知上显示的名字是不是「鸿蒙短信同步」"
  echo "    2. 通知左侧有没有图标"
  echo "    3. 通知中心（点右上角日期时间）里能不能翻到这条"
  echo ""
  echo "  若系统弹出授权询问，点「允许」。"
  echo "  若没有弹出，到「系统设置 → 通知」里把本 App 的开关打开。"
  echo ""

  # 先清掉可能还在跑的旧实例，避免它把日志覆盖掉
  pkill -f "HarmonySync.app/Contents/MacOS/HarmonySync" 2>/dev/null
  sleep 1
  rm -f "$OUT"

  echo "[$(date '+%H:%M:%S')] 开始自检，若弹出授权询问请点「允许」"
  echo ""

  "$SYNC_BIN" --test-notify

  echo ""
  echo "=== 自检日志 ==="
  cat "$OUT" 2>/dev/null || echo "（没读到日志）"

  echo ""
  echo "=== 通知中心里本 App 的登记状态 ==="
  defaults read com.apple.ncprefs 2>/dev/null \
    | awk '/bundle-id" = "com.linlu.harmonysync"/{found=1} found{print; n++} n>3{exit}' \
    || echo "（没读到）"

  echo ""
  echo "=== 结束 ==="
} 2>&1 | tee /tmp/notify_check_console.txt

echo ""
echo "按回车关闭窗口"
read -r _
