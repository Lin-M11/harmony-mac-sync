#!/bin/zsh
# MAP 正文请求探测：试出手机接受哪一种正文请求写法
#
# 用法一（推荐）：在 Finder 里双击本文件
# 用法二：在终端里执行 ./run_bodyprobe.command [设备地址] [RFCOMM通道]

cd "$(dirname "$0")" || exit 1

DEV="${1:-E8-1E-92-55-2D-D4}"
CH="${2:-26}"

echo "========================================"
echo " MAP 正文请求探测"
echo " 设备 $DEV   通道 $CH"
echo "========================================"
echo ""

./OBEXBodyProbe.app/Contents/MacOS/OBEXBodyProbe "$DEV" "$CH"

echo ""
echo "运行日志 ：/tmp/obex_bodyprobe_result.txt"
echo "正文样本 ：/tmp/map_body_probe.txt"
echo ""
echo "按回车关闭窗口"
read -r _
