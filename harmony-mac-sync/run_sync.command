#!/bin/zsh
# 鸿蒙短信 → Mac 增量同步
#
# 用法一（推荐）：在 Finder 里双击本文件，然后保持窗口开着
# 用法二：在终端里执行
#   ./run_sync.command                  持续轮询，默认 5 秒一轮
#   ./run_sync.command --interval 3     改轮询间隔（秒）
#   ./run_sync.command --once           只跑一轮
#   ./run_sync.command --reset --once   清空本地记录后重新建立基线
#
# 停止：在这个窗口按 Control-C

cd "$(dirname "$0")" || exit 1

BIN="./HarmonySync.app/Contents/MacOS/HarmonySync"

echo "========================================"
echo " 鸿蒙短信 → Mac 同步"
echo "========================================"
echo ""
echo "本轮参数：$@"
echo ""

"$BIN" "$@"

echo ""
echo "运行日志 ：/tmp/harmony_sync_result.txt"
echo "本地数据库：~/Library/Application Support/HarmonySync/messages.db"
echo ""
echo "按回车关闭窗口"
read -r _
