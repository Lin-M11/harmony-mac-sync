#!/bin/zsh
# 诊断脚本 · 本机 SDP 服务器能不能放下记录
#
# 不需要手机。全程只在本机做，不对手机发起查询。
#
#   第零段：重启蓝牙守护进程，把之前几轮可能残留的状态清掉
#   第一段：进程身份（Bundle ID、用途说明、C 层符号是否齐全）
#   第二段：本地解析，不发布（看字典本身能不能被解析）
#   第三段：发布判定
#           · 串口服务是对照组，系统文档里的示例就是它
#           · MAP MNS 试三种收敛写法
#           · Objective-C 层与 C 层各试一遍
#   第四段：抓蓝牙守护进程的日志，看它对发布请求说了什么
#
# 用法：在 Finder 里双击本文件

cd "$(dirname "$0")" || exit 1

DIAG_BIN="./SDPPubDiag.app/Contents/MacOS/SDPPubDiag"
OUT=/tmp/sdp_pub_diag.txt

DIAG_CASES=(
  bundle
  parse
  spp-num
  spp-data
  mns-ours
  mns-min
  mns-l2cap
  mns-persist
  capi-spp
  capi-mns
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
  echo "# 第一段 ~ 第三段  发布判定"
  echo "########################################"
  echo ""

  for c in "${DIAG_CASES[@]}"; do
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
  echo "# 第四段  蓝牙守护进程日志（近 3 分钟）"
  echo "########################################"
  echo ""

  /usr/bin/log show --last 3m --style compact \
    --predicate 'process == "bluetoothd" OR process == "SDPPubDiag"' 2>&1 | tail -150

  echo ""
  echo "----- 含 SDP 字样的系统日志 -----"
  echo ""
  /usr/bin/log show --last 3m --style compact \
    --predicate 'eventMessage CONTAINS[c] "sdp"' 2>&1 | tail -120

  echo ""
  echo "=== 结束 ==="
} 2>&1 | tee "$OUT"

echo ""
echo "结果已保存：$OUT"
echo "按回车关闭窗口"
read -r _
