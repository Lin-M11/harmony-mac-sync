#!/bin/zsh
# MAP 客户端原型：读取手机短信列表与正文
#
# 用法一（推荐）：在 Finder 里双击本文件
# 用法二：在终端里执行 ./run_client.command [设备地址] [RFCOMM通道]

cd "$(dirname "$0")" || exit 1

DEV="${1:-E8-1E-92-55-2D-D4}"
CH="${2:-26}"

echo "========================================"
echo " MAP 客户端原型"
echo " 设备 $DEV   通道 $CH"
echo "========================================"
echo ""

./MAPClient.app/Contents/MacOS/MAPClient "$DEV" "$CH"

echo ""
echo "短信列表 XML ：/tmp/map_listing.xml"
echo "短信正文     ：/tmp/map_body_*.txt"
echo "运行日志     ：/tmp/map_client_result.txt"
echo ""
echo "按回车关闭窗口"
read -r _
