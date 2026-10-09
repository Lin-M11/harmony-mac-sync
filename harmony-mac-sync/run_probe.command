#!/bin/zsh
# 路径探测：借 Terminal 的蓝牙权限运行
#
# 用法一（推荐）：在 Finder 里双击本文件
# 用法二：在终端里执行 ./run_probe.command [设备地址] [RFCOMM通道]

cd "$(dirname "$0")" || exit 1

DEV="${1:-E8-1E-92-55-2D-D4}"
CH="${2:-26}"

echo "========================================"
echo " MAP 路径探测"
echo " 设备 $DEV   通道 $CH"
echo "========================================"
echo ""

./OBEXPathProbe.app/Contents/MacOS/OBEXPathProbe "$DEV" "$CH"

echo ""
echo "结果已写入 /tmp/obex_pathprobe_result.txt"
echo ""
echo "按回车关闭窗口"
read -r _
