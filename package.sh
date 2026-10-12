#!/bin/zsh
# 出一个可以直接装的应用：dist/HarmonySync.app 与 dist/HarmonySync-<版本>.dmg
#
# 安装方式：打开 dmg，把 HarmonySync 拖进 Applications（dmg 里已经放了快捷方式），双击运行。
# 也可以直接 `./package.sh --install`，脚本会把它装进 /Applications 并登记。
#
# 应用自带图标、菜单栏模板图与 Info.plist，装到任何位置都能跑，数据落在
# ~/Library/Application Support/HarmonySync/。
#
# 用法：./package.sh [--install]

set -e
cd "$(dirname "$0")"

NAME=HarmonySync
BUNDLE_ID=com.linlu.harmonysync
DIST=dist
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

INSTALL=0
[[ "$1" == "--install" ]] && INSTALL=1

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

if [[ $INSTALL -eq 1 ]]; then
  DEST="/Applications/$NAME.app"
  # 只动自己的包，别误伤同名目录
  if [[ -e "$DEST" ]]; then
    EXISTING=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$DEST/Contents/Info.plist" 2>/dev/null || echo "")
    if [[ "$EXISTING" != "$BUNDLE_ID" ]]; then
      echo "✗ $DEST 已存在，且不是本应用，请先手动处理"
      exit 1
    fi
    rm -rf "$DEST"
  fi
  if pgrep -x "$NAME" >/dev/null 2>&1; then
    echo "提示：$NAME 有实例在跑，装好后先退出旧实例再打开新的"
  fi
  ditto "$DIST/$NAME.app" "$DEST"
  [[ -x "$LSREGISTER" ]] && "$LSREGISTER" -f "$DEST" 2>/dev/null || true
  echo ""
  echo "已装到 $DEST，在访达或聚焦里打开 $NAME 即可"
else
  echo ""
  echo "打开 $DIST/$NAME-$VERSION.dmg，把 $NAME 拖进 Applications 即可"
  echo "或者直接跑 ./package.sh --install 装到 /Applications"
fi
