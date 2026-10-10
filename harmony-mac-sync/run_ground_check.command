#!/bin/zsh
# 本机 SDP 服务器 · 地面真相检查
#
# 三段：
#   第一段  审计：只查不发，看本机 SDP 服务器现在存着什么
#   第二段  读数写法：数字元素换四种规范允许的表达方式，看哪一种能让 0004 协议栈留下来
#   第三段  守候：三种写法各发一条记录一起挂着，看手机能不能主动连过来
#
# 建议先做一步：系统设置 → 蓝牙，关掉再打开。本机 SDP 服务器上的临时记录
# 会随进程退出清掉，但服务器本身要是卡住了，关一下蓝牙最省事。
#
# 用法：在 Finder 里双击本文件

cd "$(dirname "$0")" || exit 1

PROBE_BIN="./SDPGroundProbe.app/Contents/MacOS/SDPGroundProbe"
OUT=/tmp/sdp_ground_result.txt

CASES=(audit attr-dict-size attr-typed attr-number attr-dict-plain)

{
  echo "########################################"
  echo "# 第一、二段  审计 + 读数写法"
  echo "########################################"

  for c in "${CASES[@]}"; do
    echo ""
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
  echo "----------------------------------------"
  echo "等 3 秒，让临时记录收干净"
  sleep 3

  echo ""
  echo "########################################"
  echo "# 第三段  守候 150 秒，等手机连过来"
  echo "########################################"
  echo ""
  echo "  >>> 请确认手机蓝牙连着，然后往手机发一条短信 <<<"
  echo "  >>> 手机若主动连过来，会打印「有设备连进来了：RFCOMM 通道 N」 <<<"
  echo ""

  "$PROBE_BIN" hold 150

  echo ""
  echo "=== 结束 ==="
} 2>&1 | tee "$OUT"

echo ""
echo "结果已保存：$OUT"
echo "按回车关闭窗口"
read -r _
