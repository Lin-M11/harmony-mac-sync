#!/bin/zsh
# 编译全部探针与客户端，并组装成带蓝牙用途说明的 .app（ad-hoc 签名）
#
# 之所以要包成 .app：蓝牙属于系统受保护资源，权限记录在「发起进程」上。
# 从终端直接跑裸二进制时，归因会落到终端身上，权限判定容易出岔子；
# 包成 .app 并写明用途说明后，双击运行最稳。
#
# 用法：./build.sh

set -e
cd "$(dirname "$0")"

# 名称|源码|额外链接参数
TARGETS=(
  "HarmonySync|harmony_sync.swift|-lsqlite3"
  "SDPFinalProbe|sdp_final_probe.swift|"
  "SDPStateProbe|sdp_state_probe.swift|"
  "SDPPublishProbe|sdp_publish_probe.swift|"
  "PhoneCapProbe|phone_cap_probe.swift|"
  "MAPClient|map_client.swift|"
  "OBEXBodyProbe|obex_bodyprobe.swift|"
)

DESC="用于连接手机并读取短信与通知"

for t in $TARGETS; do
  name="${t%%|*}"
  rest="${t#*|}"
  src="${rest%%|*}"
  extra="${rest#*|}"
  [[ -f "$src" ]] || { echo "-- 跳过 $name（$src 不存在）"; continue }

  echo "== $name"
  xcrun swiftc -O -framework IOBluetooth $=extra -o "$name.bin" "$src"

  rm -rf "$name.app"
  mkdir -p "$name.app/Contents/MacOS"
  cp "$name.bin" "$name.app/Contents/MacOS/$name"

  cat > "$name.app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key><string>$name</string>
	<key>CFBundleIdentifier</key><string>com.linlu.${name:l}</string>
	<key>CFBundleName</key><string>$name</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>LSMinimumSystemVersion</key><string>12.0</string>
	<key>NSBluetoothAlwaysUsageDescription</key><string>$DESC</string>
	<key>NSBluetoothPeripheralUsageDescription</key><string>$DESC</string>
</dict>
</plist>
PLIST

  codesign -f -s - "$name.app" >/dev/null 2>&1
done

echo ""
echo "全部完成"
