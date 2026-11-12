#!/bin/bash
# 构建并打包成可运行的 StickySide.app（随手贴）
set -e
cd "$(dirname "$0")"
CONFIG="${1:-release}"
swift build -c "$CONFIG" --disable-sandbox
BIN=".build/$CONFIG/NoteWall"
APP="StickySide.app"

# 图标缺失时先生成（矢量渲染，改动 tools/icongen.swift 后删掉 Resources/AppIcon.icns 即可重出）
[ -f Resources/AppIcon.icns ] || ./tools/make-icon.sh

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/NoteWall"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>NoteWall</string>
  <key>CFBundleIdentifier</key><string>com.local.notewall</string>
  <key>CFBundleName</key><string>随手贴</string>
  <key>CFBundleDisplayName</key><string>随手贴</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleShortVersionString</key><string>0.2.2</string>
  <key>CFBundleVersion</key><string>22</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
</dict>
</plist>
PLIST
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true
echo "built: $(pwd)/$APP"
