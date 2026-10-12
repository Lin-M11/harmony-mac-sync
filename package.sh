#!/bin/zsh
# 出一个可以直接装的应用：dist/HarmonySync.app 与 dist/HarmonySync-<版本>.dmg
#
# 安装方式：打开 dmg，把 HarmonySync 拖进 Applications（dmg 里已经放了快捷方式），双击运行。
# 应用自带图标、菜单栏模板图与 Info.plist，装到任何位置都能跑，数据落在
# ~/Library/Application Support/HarmonySync/。
#
# 用法：./package.sh

set -e
cd "$(dirname "$0")"

NAME=HarmonySync
DIST=dist

./build.sh

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$NAME.app/Contents/Info.plist")
echo "== 版本 $VERSION"

# dist 里只留这一次的产物
rm -rf "$DIST"
mkdir -p "$DIST"

# ditto 会连签名与资源一起搬，别用 cp -R
ditto "$NAME.app" "$DIST/$NAME.app"

STAGE="$(mktemp -d)/dmg"
mkdir -p "$STAGE"
ditto "$DIST/$NAME.app" "$STAGE/$NAME.app"
ln -s /Applications "$STAGE/Applications"

hdiutil create -volname "$NAME $VERSION" -srcfolder "$STAGE" -ov -format UDZO \
  "$DIST/$NAME-$VERSION.dmg" >/dev/null

echo ""
ls -lh "$DIST"
echo ""
echo "打开 $DIST/$NAME-$VERSION.dmg，把 $NAME 拖进 Applications 即可"
