#!/bin/zsh
# 秒级同步 · 高频轮询
#
# 事件订阅那条路要 Mac 先在本机 SDP 服务器上挂出记录，手机才找得到回连的通道；
# 这条路还在验。高频轮询不依赖它：把每轮间隔压到 2 秒、每轮只取最新 20 条，
# 请求固定 46 字节（条数只占其中 2 字节），延迟就是一个轮询周期。
#
# 用法：在 Finder 里双击本文件
# 期间往手机发短信，看通知多快弹出来

cd "$(dirname "$0")" || exit 1

SYNC_BIN="./HarmonySync.app/Contents/MacOS/HarmonySync"
OUT=/tmp/harmony_sync_result.txt
SECONDS_TO_RUN=240

{
  echo "########################################"
  echo "# 秒级同步：间隔 2 秒，每轮最新 20 条"
  echo "########################################"
  echo ""
  echo "  >>> 接下来 $SECONDS_TO_RUN 秒里，往手机发几条短信 <<<"
  echo "  >>> 通知弹出的时刻减去短信到达的时刻，就是一个轮询周期 <<<"
  echo ""

  "$SYNC_BIN" --interval 2 &
  SYNC_PID=$!

  for i in {1..$SECONDS_TO_RUN}; do
    if (( i % 30 == 0 )); then
      echo "[$(date '+%H:%M:%S')] 已跑 $i 秒，还剩 $((SECONDS_TO_RUN - i)) 秒"
    fi
    sleep 1
  done

  kill $SYNC_PID 2>/dev/null
  wait $SYNC_PID 2>/dev/null

  echo ""
  echo "=== 结束 ==="
  echo ""
  echo "客户端日志：$OUT"
  echo "本轮跑出的通知条数："
  grep -c "★ 新短信" "$OUT" 2>/dev/null || echo "  （没读到日志）"
} 2>&1 | tee /tmp/fast_sync_console.txt

echo ""
echo "按回车关闭窗口"
read -r _
