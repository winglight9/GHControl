#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="GHControl"
BUNDLE_ID="local.hades.GHControl"
MIN_SYSTEM_VERSION="13.0"
APP_VERSION="0.7.0"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_BINARY="$APP_MACOS/$APP_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"
ICON_SOURCE="$ROOT_DIR/Resources/AppIcon.png"
ICONSET_DIR="$DIST_DIR/GHControl.iconset"

cd "$ROOT_DIR"
swift build -c release
BUILD_BINARY="$(swift build -c release --show-bin-path)/$APP_NAME"

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_MACOS" "$APP_RESOURCES"
cp "$BUILD_BINARY" "$APP_BINARY"
chmod +x "$APP_BINARY"

make_icon() {
  local icon_size="$1"
  local icon_name="$2"
  sips -z "$icon_size" "$icon_size" "$ICON_SOURCE" --out "$ICONSET_DIR/$icon_name" >/dev/null
}

rm -rf "$ICONSET_DIR"
mkdir -p "$ICONSET_DIR"
make_icon 16 icon_16x16.png
make_icon 32 icon_16x16@2x.png
make_icon 32 icon_32x32.png
make_icon 64 icon_32x32@2x.png
make_icon 128 icon_128x128.png
make_icon 256 icon_128x128@2x.png
make_icon 256 icon_256x256.png
make_icon 512 icon_256x256@2x.png
make_icon 512 icon_512x512.png
make_icon 1024 icon_512x512@2x.png
/usr/bin/iconutil -c icns --output "$APP_RESOURCES/AppIcon.icns" "$ICONSET_DIR"
rm -rf "$ICONSET_DIR"

cat >"$INFO_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleName</key>
  <string>GH Control</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>$APP_VERSION</string>
  <key>CFBundleVersion</key>
  <string>$APP_VERSION</string>
  <key>LSMinimumSystemVersion</key>
  <string>$MIN_SYSTEM_VERSION</string>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
PLIST

open_app() {
  /usr/bin/open -n "$APP_BUNDLE"
}

case "$MODE" in
  --build-only|build-only)
    ;;
  run)
    open_app
    ;;
  --debug|debug)
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    open_app
    sleep 1
    pgrep -x "$APP_NAME" >/dev/null
    ;;
  --package|package)
    DMG_STAGE="$DIST_DIR/GHControl-DMG-Staging"
    DMG_PATH="$DIST_DIR/$APP_NAME-$APP_VERSION.dmg"
    rm -rf "$DMG_STAGE" "$DMG_PATH"
    mkdir -p "$DMG_STAGE"
    cp -R "$APP_BUNDLE" "$DMG_STAGE/$APP_NAME.app"
    ln -s /Applications "$DMG_STAGE/Applications"
    cat >"$DMG_STAGE/Install Instructions.txt" <<'INSTALL'
GH Control — 安装说明 / Installation

中文
1. 双击打开此磁盘映像。
2. 将 GHControl.app 拖入 Applications 文件夹。
3. 首次打开时，如果 macOS 提示无法验证开发者，请在 Finder 中右键点击应用，选择“打开”，再确认打开。
4. 菜单栏图标可重新打开主窗口。关闭窗口后应用仍在菜单栏运行。

English
1. Double-click this disk image to open it.
2. Drag GHControl.app to the Applications folder.
3. On first launch, if macOS cannot verify the developer, Control-click the app in Finder, choose Open, then confirm.
4. Use the menu bar icon to reopen the main window. Closing the window leaves GH Control running in the menu bar.

此版本未使用 Apple Developer ID 签名或公证，因此首次打开可能需要上述确认。
This build is not signed with an Apple Developer ID or notarized, so the first-launch confirmation may be required.
INSTALL
    /usr/bin/hdiutil create -volname "GH Control $APP_VERSION" -srcfolder "$DMG_STAGE" -format UDZO -ov "$DMG_PATH"
    rm -rf "$DMG_STAGE"
    echo "Created $DMG_PATH"
    ;;
  *)
    echo "usage: $0 [run|--build-only|--package|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac
