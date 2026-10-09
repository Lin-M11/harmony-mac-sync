#!/bin/zsh
# 诊断脚本 · 两段
#
#   第一段：SDP 记录发布探测（不需要手机）
#           每个用例各起一个进程，先本地解析再发布。
#
#   第二段：手机 MAP 能力探查（需要手机连着）
#           读出手机 MAS 记录里的 SupportedFeatures，判断手机是否接受「通知注册」。
#
# 用法：在 Finder 里双击本文件

cd "$(dirname "$0")" || exit 1

SDP_BIN="./SDPPublishProbe.app/Contents/MacOS/SDPPublishProbe"
CAP_BIN="./PhoneCapProbe.app/Contents/MacOS/PhoneCapProbe"
OUT=/tmp/sdp_diag_result.txt

CASES=(
  scl
  scl-name
  pdl-uuids
  pdl-l2cap-only
  pdl-rfcomm-obex
  pdl-raw
  pdl-numsize
  pdl-bare
  pdl-psm1001
  full
  full-handle
  full-plist
)

{
  echo "########################################"
  echo "# 第一段  SDP 记录发布探测"
  echo "# 每个用例独立进程，先本地解析再发布"
  echo "########################################"
  echo ""

  for c in "${CASES[@]}"; do
    echo "----------------------------------------"
    echo "[$(date '+%H:%M:%S')] 用例 $c"
    "$SDP_BIN" "$c"
    rc=$?
    if [[ $rc -ne 0 ]]; then
      echo "  ⚠ 进程退出码 $rc"
    fi
    sleep 1
  done

  echo "----------------------------------------"
  echo ""
  echo ""
  echo "########################################"
  echo "# 第二段  手机 MAP 能力探查"
  echo "########################################"
  echo ""

  "$CAP_BIN"
  rc=$?
  if [[ $rc -ne 0 ]]; then
    echo "  ⚠ 进程退出码 $rc"
  fi

  echo ""
  echo "=== 结束 ==="
} 2>&1 | tee "$OUT"

echo ""
echo "结果已保存：$OUT"
echo "手机能力部分另存一份：/tmp/phone_map_result.txt"
echo "按回车关闭窗口"
read -r _
