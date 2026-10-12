#!/bin/zsh
# 编译客户端并组装成带蓝牙用途说明、带图标的 .app（ad-hoc 签名）
#
# 之所以要包成 .app：蓝牙属于系统受保护资源，权限记录在「发起进程」上；
# 系统通知也要靠 .app 的身份，才会显示成 App 自己的名字和图标。
# 从终端直接跑裸二进制时，归因会落到终端身上，权限判定与通知身份都容易出岔子。
#
# 同时出一个命令行版本，用来做各种本地自检（见 README 的参数表）。
#
# 用法：./build.sh

set -e
cd "$(dirname "$0")"

NAME=HarmonySync
CLI_NAME=HarmonyCLI
# 两个目标各有自己的入口，分开编译：App 走 SwiftUI 的 @main，命令行走 CLI 的 @main
APP_SRC="HarmonyCore.swift DesignSystem.swift AppModel.swift PanelView.swift MessageWindowView.swift HarmonyApp.swift"
CLI_SRC="HarmonyCore.swift HarmonyCLI.swift"
APP_FRAMEWORKS=(-framework IOBluetooth -framework SwiftUI -framework AppKit
                -framework ServiceManagement -framework UserNotifications)
DISPLAY_NAME="鸿蒙短信同步"
DESC="用于连接手机并读取短信与通知"

# ---- 图标 ----
if [[ -f make_icon.swift ]]; then
  xcrun swiftc -O -o MakeIcon make_icon.swift
  ./MakeIcon AppIcon.iconset >/dev/null
  iconutil -c icns AppIcon.iconset -o AppIcon.icns
  ./MakeIcon --menubar MenuBarIcons >/dev/null
  echo "== 图标 AppIcon.icns + 菜单栏模板图"
fi

echo "== $NAME"
xcrun swiftc -parse-as-library -O $=APP_FRAMEWORKS -lsqlite3 -o "$NAME.bin" $=APP_SRC

echo "== $CLI_NAME"
xcrun swiftc -parse-as-library -O -framework IOBluetooth -framework UserNotifications \
  -lsqlite3 -o "$CLI_NAME.bin" $=CLI_SRC

# 就地覆盖：包里只有可执行文件、图标、Info.plist 和签名，逐项重写即可。
# 逐项重写能避开批量删除保护，也不会留下半截目录。
mkdir -p "$NAME.app/Contents/MacOS" "$NAME.app/Contents/Resources"
cp "$NAME.bin" "$NAME.app/Contents/MacOS/$NAME"
[[ -f AppIcon.icns ]] && cp AppIcon.icns "$NAME.app/Contents/Resources/AppIcon.icns"
# 菜单栏模板图：名字以 Template 结尾，AppKit 取用时自动按模板图处理（单色，随菜单栏明暗反相）
# 两套：链路通、链路断
for f in MenuBarIcons/MenuBarIconTemplate.png MenuBarIcons/MenuBarIconTemplate@2x.png MenuBarIcons/MenuBarIconTemplate@3x.png \
         MenuBarIcons/MenuBarIconOffTemplate.png MenuBarIcons/MenuBarIconOffTemplate@2x.png MenuBarIcons/MenuBarIconOffTemplate@3x.png; do
  [[ -f "$f" ]] && cp "$f" "$NAME.app/Contents/Resources/$(basename "$f")"
done

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
	<key>LSMinimumSystemVersion</key><string>13.0</string>
	<key>LSUIElement</key><true/>
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
