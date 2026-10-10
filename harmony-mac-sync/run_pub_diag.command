#!/bin/zsh
# 诊断脚本 · 本机 SDP 服务器能不能放下记录
#
# 不需要手机。全程只在本机做，不对手机发起查询。
#
#   第零段：重启蓝牙守护进程，把之前几轮可能残留的状态清掉
#   第一段：进程身份（Bundle ID、用途说明、C 层符号是否齐全）与字典原文
#   第二段：内容隔离。每个用例前各重启一次蓝牙守护进程，
#           让每个用例都成为「重启后的第一个服务」——这样看到的差异只可能来自字典内容。
#   第三段：连续发布。同一份字典在同一个进程里连发四次，看第几次开始变。
#   第四段：抓蓝牙守护进程与探针自身的日志。服务器的拒绝理由都在这里。
#
# 用法：在 Finder 里双击本文件

cd "$(dirname "$0")" || exit 1

DIAG_BIN="./SDPPubDiag.app/Contents/MacOS/SDPPubDiag"
OUT=/tmp/sdp_pub_diag.txt

# 内容隔离：每个用例前都重启
ISOLATED_CASES=(
  mns-ours
  spp-num
  spp-obex
  mns-nobex
)

# 连续发布：不重启
REPEAT_CASES=(
  repeat-spp
  repeat-mns
)

{
  echo "########################################"
  echo "# 第零段  重启蓝牙守护进程"
  echo "########################################"
  echo ""
  sudo killall bluetoothd
  sleep 3
  echo "[$(date '+%H:%M:%S')] 已重启，等 3 秒"
  echo ""
  echo ""

  echo "########################################"
  echo "# 第一段  进程身份与字典原文（不发布）"
  echo "########################################"
  echo ""

  for c in bundle parse; do
    echo "----------------------------------------"
    echo "[$(date '+%H:%M:%S')] 用例 $c"
    "$DIAG_BIN" "$c"
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
  echo "# 第二段  内容隔离（每个用例前各重启一次）"
  echo "########################################"
  echo ""

  for c in "${ISOLATED_CASES[@]}"; do
    echo "========================================"
    echo "[$(date '+%H:%M:%S')] 重启蓝牙守护进程，为用例 $c 清场"
    sudo killall bluetoothd
    sleep 3
    echo "[$(date '+%H:%M:%S')] 用例 $c"
    "$DIAG_BIN" "$c"
    rc=$?
    if [[ $rc -ne 0 ]]; then
      echo "  ⚠ 进程退出码 $rc"
    fi
    sleep 1
  done

  echo "========================================"
  echo ""
  echo ""
  echo "########################################"
  echo "# 第三段  连续发布（同一进程内，不重启）"
  echo "########################################"
  echo ""

  for c in "${REPEAT_CASES[@]}"; do
    echo "----------------------------------------"
    echo "[$(date '+%H:%M:%S')] 用例 $c"
    "$DIAG_BIN" "$c"
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
  echo "# 第四段  蓝牙守护进程日志（近 6 分钟）"
  echo "########################################"
  echo ""

  /usr/bin/log show --last 6m --style compact \
    --predicate 'process == "bluetoothd" OR process == "SDPPubDiag"' 2>&1 | tail -400

  echo ""
  echo "=== 结束 ==="
} 2>&1 | tee "$OUT"

echo ""
echo "结果已保存：$OUT"
echo "按回车关闭窗口"
read -r _
