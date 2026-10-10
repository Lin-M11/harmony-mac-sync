#!/bin/zsh
# 本机 SDP 服务器 · 重启后再验一次
#
# 上一轮的观察：同一份字典，09:22 那次能拿到对象，09:41 那次返回空。
# 字典没变、进程也是新起的，变的是本机 SDP 服务器的状态。
# 这一步先把它重启一次，再按「最简 → 对照 → 完整」的顺序各发一次，
# 最后守候 120 秒等手机连过来。
#
# 用法：在 Finder 里双击本文件

cd "$(dirname "$0")" || exit 1

PROBE_BIN="./SDPGroundProbe.app/Contents/MacOS/SDPGroundProbe"
OUT=/tmp/sdp_reset_result.txt

{
  echo "########################################"
  echo "# 第一步  重启蓝牙守护进程"
  echo "########################################"
  echo ""
  echo "  接下来会让你输一次密码（重启蓝牙服务需要管理员权限）。"
  echo "  蓝牙设备会短暂断开，几秒后自动重连。"
  echo ""
  if sudo killall bluetoothd 2>&1; then
    echo "  已发出重启信号"
  else
    echo "  ⚠ 重启没成功，可以跳过这一步继续往下跑"
  fi
  sleep 8
  echo ""
  echo "  当前蓝牙状态："
  system_profiler SPBluetoothDataType 2>/dev/null | sed -n '1,14p'
  echo ""

  echo "########################################"
  echo "# 第二步  逐项发布"
  echo "########################################"
  echo ""
  echo "  state       控制器电源、本机地址、当前连接的设备"
  echo "  minimal     最简记录：只有类 UUID + 服务名"
  echo "  control-128 对照：换一个从未用过的 128 位类 UUID"
  echo "  attr-*      完整 MNS 记录，数字元素换写法"
  echo ""

  for c in state minimal control-128 attr-dict-size attr-typed; do
    echo "----------------------------------------"
    echo "[$(date '+%H:%M:%S')] 用例 $c"
    "$PROBE_BIN" "$c"
    rc=$?
    if [[ $rc -ne 0 ]]; then
      echo "  ⚠ 进程退出码 $rc"
    fi
    sleep 2
  done

  echo ""
  echo "########################################"
  echo "# 第三步  守候 120 秒，等手机连过来"
  echo "########################################"
  echo ""
  echo "  >>> 请确认手机蓝牙连着，然后往手机发一条短信 <<<"
  echo "  >>> 手机若主动连过来，会打印「有设备连进来了：RFCOMM 通道 N」 <<<"
  echo ""

  "$PROBE_BIN" hold 120

  echo ""
  echo "=== 结束 ==="
} 2>&1 | tee "$OUT"

echo ""
echo "结果已保存：$OUT"
echo "按回车关闭窗口"
read -r _
