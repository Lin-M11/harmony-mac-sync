#!/bin/zsh
# MNS 联调检查 · 两段
#
#   第一段：SDP 记录定论探针（不需要手机）
#           上一轮发布后读回来的属性里，0004 协议栈与 0009 Profile 描述都不见了。
#           这一轮只回答三件事：是不是读太早、是不是读到旧记录、本机 SDP 服务器实际存了什么。
#
#   第二段：客户端持续跑 90 秒（需要手机连着、并且手机蓝牙是连着的）
#           看订阅新消息事件的响应码，以及手机有没有回连事件通道。
#           这 90 秒里请往手机发一条短信，看事件是不是秒级到。
#
# 用法：在 Finder 里双击本文件

cd "$(dirname "$0")" || exit 1

PROBE_BIN="./SDPFinalProbe.app/Contents/MacOS/SDPFinalProbe"
SYNC_BIN="./HarmonySync.app/Contents/MacOS/HarmonySync"
OUT=/tmp/sdp_final_result.txt

PROBE_CASES=(
  now
  name-a
  name-b
  minimal
  uuid-only
  element-tree
  self-query
)

{
  echo "########################################"
  echo "# 第一段  SDP 记录定论探针"
  echo "########################################"
  echo ""

  for c in "${PROBE_CASES[@]}"; do
    echo "----------------------------------------"
    echo "[$(date '+%H:%M:%S')] 用例 $c"
    "$PROBE_BIN" "$c"
    rc=$?
    if [[ $rc -ne 0 ]]; then
      echo "  ⚠ 进程退出码 $rc"
    fi
    sleep 2
  done

  echo "----------------------------------------"
  echo ""
  echo "等 3 秒，让本机 SDP 服务器把上面几条临时记录收干净"
  sleep 3
  echo ""
  echo ""
  echo "########################################"
  echo "# 第二段  客户端持续跑 90 秒"
  echo "########################################"
  echo ""
  echo "  >>> 这 90 秒里请往手机发一条短信 <<<"
  echo ""

  "$SYNC_BIN" --interval 10 &
  SYNC_PID=$!

  for i in {90..1}; do
    if (( i % 15 == 0 )); then
      echo "[$(date '+%H:%M:%S')] 还剩 $i 秒"
    fi
    sleep 1
  done

  kill $SYNC_PID 2>/dev/null
  wait $SYNC_PID 2>/dev/null

  echo ""
  echo "=== 结束 ==="
} 2>&1 | tee "$OUT"

echo ""
echo "结果已保存：$OUT"
echo "客户端日志：/tmp/harmony_sync_result.txt"
echo "按回车关闭窗口"
read -r _
