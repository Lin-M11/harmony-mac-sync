#!/bin/zsh
# 诊断脚本 · 三段
#
#   第一段：SDP 发布状态探测（不需要手机）
#           上一轮除首个用例外全部「发布成功」且句柄相同，需要判断发布到底有没有真的建出记录。
#           用 getServiceName / attributes 原文 / remove() 返回值 / 同进程发布两次的句柄对比
#           / 换 128 位类 UUID / 按句柄删除 这几个硬指标来判定。
#
#   第二段：SDP 字典写法扫描（不需要手机）
#           12 种字典写法，每个用例各起一个进程。
#
#   第三段：客户端跑一轮（需要手机连着）
#           看生产程序里的 SDP 发布与事件订阅分别是什么结果。
#
# 用法：在 Finder 里双击本文件

cd "$(dirname "$0")" || exit 1

STATE_BIN="./SDPStateProbe.app/Contents/MacOS/SDPStateProbe"
SWEEP_BIN="./SDPPublishProbe.app/Contents/MacOS/SDPPublishProbe"
SYNC_BIN="./HarmonySync.app/Contents/MacOS/HarmonySync"
OUT=/tmp/sdp_state_result.txt

STATE_CASES=(
  attr
  pub-once
  pub-twice
  pub-128
  pub-prod
  local
  capi
  dlsym
)

SWEEP_CASES=(
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
  echo "# 第一段  SDP 发布状态探测"
  echo "########################################"
  echo ""

  for c in "${STATE_CASES[@]}"; do
    echo "----------------------------------------"
    echo "[$(date '+%H:%M:%S')] 状态用例 $c"
    "$STATE_BIN" "$c"
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
  echo "# 第二段  SDP 字典写法扫描"
  echo "########################################"
  echo ""

  for c in "${SWEEP_CASES[@]}"; do
    echo "----------------------------------------"
    echo "[$(date '+%H:%M:%S')] 写法用例 $c"
    "$SWEEP_BIN" "$c"
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
  echo "# 第三段  客户端跑一轮"
  echo "########################################"
  echo ""

  "$SYNC_BIN" --once
  rc=$?
  if [[ $rc -ne 0 ]]; then
    echo "  ⚠ 进程退出码 $rc"
  fi

  echo ""
  echo "=== 结束 ==="
} 2>&1 | tee "$OUT"

echo ""
echo "结果已保存：$OUT"
echo "客户端日志：/tmp/harmony_sync_result.txt"
echo "按回车关闭窗口"
read -r _
