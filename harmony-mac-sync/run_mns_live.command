#!/bin/zsh
# 事件订阅实测 · 含秒级轮询
#
# 分三段跑。
#
# 第一段回答「本机 SDP 记录到底挂上没有」：先查本机，再按两种数字写法各发一份记录、
# 各自用 remove() 的返回值配对判断，最后才对手机做一次 SDP 查询当对照组。
# 顺序有讲究——远端查询会占住协议栈，发布排在它后面容易拿不到对象。
#
# 第二段真跑客户端：MNS 服务端挂上记录并监听入站通道，同时在 MAS 通道上订阅新消息事件。
# 期间往手机发一条短信，观察三件事：订阅返回码、手机有没有回连、事件有没有到。
# 轮询间隔压到 2 秒、每轮取最新 20 条，顺带把秒级延迟量出来。
#
# 第三段再对手机做一次 SDP 查询收尾，作为查询路径的对照。
#
# 用法：在 Finder 里双击本文件

cd "$(dirname "$0")" || exit 1

GROUND="./SDPGroundProbe.app/Contents/MacOS/SDPGroundProbe"
SYNC_BIN="./HarmonySync.app/Contents/MacOS/HarmonySync"
OUT=/tmp/harmony_sync_result.txt
SECONDS_TO_RUN=200

{
  echo "########################################"
  echo "# 第零段  重启蓝牙守护进程，把本机 SDP 服务器恢复干净"
  echo "########################################"
  echo ""
  echo "  接下来会让你输一次密码。"
  echo ""

  sudo killall bluetoothd
  sleep 3
  echo "  已发出重启信号"
  echo ""

  echo "########################################"
  echo "# 第一段  本机 SDP 记录挂上没有"
  echo "########################################"
  echo ""
  echo "  >>> 这一段不用操作手机 <<<"
  echo ""

  "$GROUND" state
  echo ""
  "$GROUND" truth
  echo ""

  echo "########################################"
  echo "# 第二段  事件订阅实测（含秒级轮询）"
  echo "########################################"
  echo ""
  echo "  >>> 接下来 $SECONDS_TO_RUN 秒里，往手机发几条短信 <<<"
  echo "  >>> 通知弹出的时刻减去短信到达的时刻，就是一个轮询周期 <<<"
  echo "  >>> 手机若主动连过来，日志里会出现「有设备连进来了」 <<<"
  echo ""

  "$SYNC_BIN" --interval 2 &
  SYNC_PID=$!

  for i in {1..$SECONDS_TO_RUN}; do
    if (( i % 25 == 0 )); then
      echo "[$(date '+%H:%M:%S')] 已跑 $i 秒，还剩 $((SECONDS_TO_RUN - i)) 秒"
    fi
    sleep 1
  done

  kill $SYNC_PID 2>/dev/null
  wait $SYNC_PID 2>/dev/null

  echo ""
  echo "=== 结束 ==="
  echo ""
  echo "本轮抓到的短信条数："
  grep -c "★ 新短信" "$OUT" 2>/dev/null || echo "  0"
  echo ""
  echo "连接与事件订阅相关行："
  grep -E "已连接手机|事件订阅|\[MNS\]|心跳" "$OUT" 2>/dev/null | head -40 || echo "  （没有相关行）"
  echo ""
  echo "########################################"
  echo "# 第三段  对手机的 SDP 查询（对照组）"
  echo "########################################"
  echo ""
  echo "  远端查询会占住协议栈，所以排在最后，别影响前面的发布。"
  echo ""

  "$GROUND" phone
  echo ""
  echo "客户端完整日志：$OUT"
} 2>&1 | tee /tmp/mns_live_console.txt

echo ""
echo "按回车关闭窗口"
read -r _
