#!/bin/zsh
# 编译全部探针与客户端，并组装成带蓝牙用途说明、带图标的 .app（ad-hoc 签名）
#
# 之所以要包成 .app：蓝牙属于系统受保护资源，权限记录在「发起进程」上；
# 系统通知也要靠 .app 的身份，才会显示成 App 自己的名字和图标。
# 从终端直接跑裸二进制时，归因会落到终端身上，权限判定与通知身份都容易出岔子。
#
# 用法：./build.sh

set -e
cd "$(dirname "$0")"

# ---- 图标 ----
if [[ -f make_icon.swift ]]; then
  xcrun swiftc -O -o MakeIcon make_icon.swift
  ./MakeIcon AppIcon.iconset >/dev/null
  iconutil -c icns AppIcon.iconset -o AppIcon.icns
  echo "== 图标 AppIcon.icns"
fi

# 名称|源码|额外链接参数
TARGETS=(
  "HarmonySync|harmony_sync.swift|-lsqlite3"
  "SDPFinalProbe|sdp_final_probe.swift|"
  "SDPGroundProbe|sdp_ground_probe.swift|"
  "SDPStateProbe|sdp_state_probe.swift|"
  "SDPPublishProbe|sdp_publish_probe.swift|"
  "SDPPubDiag|sdp_pub_diag.swift|"
  "PhoneCapProbe|phone_cap_probe.swift|"
  "MAPClient|map_client.swift|"
  "OBEXBodyProbe|obex_bodyprobe.swift|"
)

DESC="用于连接手机并读取短信与通知"

# 显示名：通知与访达里看到的名字
display_name() {
  case "$1" in
    HarmonySync) echo "鸿蒙短信同步" ;;
    *) echo "$1" ;;
  esac
}

for t in $TARGETS; do
  name="${t%%|*}"
  rest="${t#*|}"
  src="${rest%%|*}"
  extra="${rest#*|}"
  [[ -f "$src" ]] || { echo "-- 跳过 $name（$src 不存在）"; continue }

  echo "== $name"
  xcrun swiftc -O -framework IOBluetooth $=extra -o "$name.bin" "$src"

  rm -rf "$name.app"
  mkdir -p "$name.app/Contents/MacOS" "$name.app/Contents/Resources"
  cp "$name.bin" "$name.app/Contents/MacOS/$name"
  [[ -f AppIcon.icns ]] && cp AppIcon.icns "$name.app/Contents/Resources/AppIcon.icns"

  cat > "$name.app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key><string>$name</string>
	<key>CFBundleIdentifier</key><string>com.linlu.${name:l}</string>
	<key>CFBundleName</key><string>$name</string>
	<key>CFBundleDisplayName</key><string>$(display_name "$name")</string>
	<key>CFBundleIconFile</key><string>AppIcon</string>
	<key>CFBundleShortVersionString</key><string>1.0</string>
	<key>CFBundleVersion</key><string>1</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>LSMinimumSystemVersion</key><string>12.0</string>
	<key>NSBluetoothAlwaysUsageDescription</key><string>$DESC</string>
	<key>NSBluetoothPeripheralUsageDescription</key><string>$DESC</string>
</dict>
</plist>
PLIST

  codesign -f -s - "$name.app" >/dev/null 2>&1
done

# 让访达与通知中心认得这个 App（图标、名称、通知身份都靠它）
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
if [[ -x "$LSREGISTER" && -d HarmonySync.app ]]; then
  "$LSREGISTER" -f "$PWD/HarmonySync.app" 2>/dev/null || true
fi

echo ""
echo "全部完成"
