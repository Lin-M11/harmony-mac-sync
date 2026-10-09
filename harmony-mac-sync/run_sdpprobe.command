#!/bin/zsh
# SDP 记录发布探测：不连手机，试各种字典写法，看哪一种能发布成功
#
# 用法：在 Finder 里双击本文件

cd "$(dirname "$0")" || exit 1

echo "========================================"
echo " SDP 记录发布探测"
echo "========================================"
echo ""

./SDPPublishProbe.app/Contents/MacOS/SDPPublishProbe 2>&1 | tee /tmp/sdp_publish_result.txt

echo ""
echo "结果已保存：/tmp/sdp_publish_result.txt"
echo "按回车关闭窗口"
read -r _
