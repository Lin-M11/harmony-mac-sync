#!/bin/zsh
# HFP 通话探针 · 在 Mac 上接电话
#
# 走蓝牙 HFP，让 Mac 当免提端：接听来电、建立 SCO 音频通道、把通话音频转到电脑。
# 用来确认「在 Mac 上接电话、用连着 Mac 的耳机通话」是否成立。
#
# 用法：在 Finder 里双击本文件。按提示用另一部手机拨打这台手机。

cd "$(dirname "$0")" || exit 1

OUT=/tmp/hfp_probe_result.txt
BIN=/tmp/hfp_probe

{
  echo "########################################"
  echo "# HFP 通话探针"
  echo "########################################"
  echo ""
  echo "  探针会做这些事："
  echo "    1. 连上手机，建立信令通道"
  echo "    2. 你用另一部手机拨打这台手机"
  echo "    3. 探针自动接听，建立音频通道，把通话音频转到电脑"
  echo "    4. 你对着耳机麦克风说话，听对方能否听到；同时听耳机里有没有对方"
  echo "    5. 探针自动挂断"
  echo ""
  echo "  开始前请确认："
  echo "    · 蓝牙耳机已连到 Mac，并且是 Mac 当前的输出设备"
  echo "    · 手机与 Mac 已配对（探针用固定地址 E8-1E-92-55-2D-D4）"
  echo ""

  pkill -f "hfp_probe" 2>/dev/null
  sleep 1
  rm -f "$OUT" "$BIN"

  echo "编译探针…"
  xcrun swiftc -O -framework IOBluetooth hfp_probe.swift -o "$BIN" 2>&1
  if [ ! -x "$BIN" ]; then
    echo ""
    echo "✗ 编译失败，看上面的报错"
    echo ""
    echo "按回车关闭窗口"
    read -r _
    exit 1
  fi
  echo "编译完成，开始跑"
  echo ""

  "$BIN"

  echo ""
  echo "=== 完整日志 ==="
  cat "$OUT" 2>/dev/null || echo "（没读到日志）"
} 2>&1 | tee /tmp/hfp_probe_console.txt

echo ""
echo "按回车关闭窗口"
read -r _
