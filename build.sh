#!/bin/zsh
# 编译客户端并组装成带蓝牙用途说明、带图标的 .app（ad-hoc 签名）
#
# 之所以要包成 .app：蓝牙属于系统受保护资源，权限记录在「发起进程」上；
# 系统通知也要靠 .app 的身份，才会显示成 App 自己的名字和图标。
# 从终端直接跑裸二进制时，归因会落到终端身上，权限判定与通知身份都容易出岔子。
#
# 用法：./build.sh

set -e
cd "$(dirname "$0")"

NAME=HarmonySync
SRC=harmony_sync.swift
DISPLAY_NAME="鸿蒙短信同步"
DESC="用于连接手机并读取短信与通知"

# ---- 图标 ----
if [[ -f make_icon.swift ]]; then
  xcrun swiftc -O -o MakeIcon make_icon.swift
  ./MakeIcon AppIcon.iconset >/dev/null
  iconutil -c icns AppIcon.iconset -o AppIcon.icns
  echo "== 图标 AppIcon.icns"
fi

echo "== $NAME"
xcrun swiftc -O -framework IOBluetooth -lsqlite3 -o "$NAME.bin" "$SRC"

# 就地覆盖：包里只有可执行文件、图标、Info.plist 和签名，逐项重写即可，
# 不整目录删掉，省得跟删除保护打架，也不会留下半截目录
mkdir -p "$NAME.app/Contents/MacOS" "$NAME.app/Contents/Resources"
cp "$NAME.bin" "$NAME.app/Contents/MacOS/$NAME"
[[ -f AppIcon.icns ]] && cp AppIcon.icns "$NAME.app/Contents/Resources/AppIcon.icns"

cat > "$NAME.app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key><string>$NAME</string>
	<key>CFBundleIdentifier</key><string>com.linlu.${NAME:l}</string>
	<key>CFBundleName</key><string>$NAME</string>
	<key>CFBundleDisplayName</key><string>$DISPLAY_NAME</string>
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

codesign -f -s - "$NAME.app" >/dev/null 2>&1

# 让访达与通知中心认得这个 App（图标、名称、通知身份都靠它）
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
if [[ -x "$LSREGISTER" && -d "$NAME.app" ]]; then
  "$LSREGISTER" -f "$PWD/$NAME.app" 2>/dev/null || true
fi

echo ""
echo "全部完成"
