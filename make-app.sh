#!/bin/bash
# make-app — 把 OpenDeck 组装成 macOS .app 包(dist/OpenDeck.app)
# 用法:./make-app.sh(在 mirabox/ 目录下执行)
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="OpenDeck"
BUNDLE_ID="com.opendeck.app"
VERSION="0.1.0"
DIST="dist"
APP="$DIST/$APP_NAME.app"

# 构建溯源:记录被编译的源码状态,让 dist/OpenDeck.app 能回答"我是哪个 commit"。
# 只看 mirabox 子树——父仓库是 ShortcutGeneral,它的改动与本 app 无关,不该误报 dirty。
BUILD_COMMIT=$(git rev-parse --short HEAD 2>/dev/null || echo unknown)
if [ -n "$(git status --porcelain --untracked-files=no -- . 2>/dev/null)" ]; then
  BUILD_STATE="dirty"            # 已跟踪文件有未提交改动:二进制无法对应任何 commit
elif [ -n "$(git status --porcelain -- . 2>/dev/null)" ]; then
  BUILD_STATE="dirty+untracked"  # 源码与 HEAD 一致,但目录里有未入库文件
else
  BUILD_STATE="clean"
fi

echo "▸ 1/5 编译 release"
swift build -c release

echo "▸ 2/5 生成应用图标"
mkdir -p "$DIST"
ICON_PNG="$DIST/AppIcon.png"
swift Scripts/MakeIcon.swift "$ICON_PNG"

# iconset:一套尺寸 → icns
ICONSET="$DIST/AppIcon.iconset"
rm -rf "$ICONSET"
mkdir -p "$ICONSET"
for size in 16 32 64 128 256 512; do
  sips -z $size $size "$ICON_PNG" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  let double=size*2
  sips -z $double $double "$ICON_PNG" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
sips -z 1024 1024 "$ICON_PNG" --out "$ICONSET/icon_512x512@2x.png" >/dev/null
iconutil -c icns "$ICONSET" -o "$DIST/AppIcon.icns"

echo "▸ 3/5 组装 .app"
BUILD_TIME=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/OpenDeck "$APP/Contents/MacOS/$APP_NAME"
cp "$DIST/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>                <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>         <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>          <string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key>          <string>$APP_NAME</string>
    <key>CFBundleIconFile</key>            <string>AppIcon</string>
    <key>CFBundlePackageType</key>         <string>APPL</string>
    <key>CFBundleShortVersionString</key>  <string>$VERSION</string>
    <key>CFBundleVersion</key>             <string>1</string>
    <key>OpenDeckBuildCommit</key>         <string>$BUILD_COMMIT</string>
    <key>OpenDeckBuildState</key>          <string>$BUILD_STATE</string>
    <key>OpenDeckBuildTime</key>           <string>$BUILD_TIME</string>
    <key>LSMinimumSystemVersion</key>      <string>26.0</string>
    <key>LSApplicationCategoryType</key>   <string>public.app-category.utilities</string>
    <key>NSPrincipalClass</key>            <string>NSApplication</string>
    <key>NSHumanReadableCopyright</key>    <string>© 2026 — 本机自用</string>
</dict>
</plist>
PLIST

echo "▸ 4/5 ad-hoc 签名"
codesign --force --sign - "$APP"

echo "▸ 5/5 完成"
ls -la "$APP/Contents/MacOS" "$APP/Contents/Resources"
du -sh "$APP"
echo "✅ $APP(打开:open $APP 或 open -a $APP_NAME)"
