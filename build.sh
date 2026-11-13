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
# 菜单栏模板图标（设计稿位图 1x/2x）：文件在才拷，缺失时 App 内自动回退代码绘制
for icon in Resources/StickySideMenuBar.png Resources/StickySideMenuBar@2x.png; do
  if [ -f "$icon" ]; then cp "$icon" "$APP/Contents/Resources/"; fi
done
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
  <key>CFBundleShortVersionString</key><string>0.3.5</string>
  <key>CFBundleVersion</key><string>35</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
</dict>
</plist>
PLIST
# 版本号自检（P1-18）：工作流从 build.sh 里 grep 版本号打 Release 标签，
# 模板写坏会打出空标签 `v`。这里校验刚生成的 Info.plist——模板坏了，
# plist 一定跟着坏，构建直接失败，别等发版才发现。
PLIST_VER=$(grep '<key>CFBundleShortVersionString</key>' "$APP/Contents/Info.plist" | grep -o '<string>[^<]*' | sed 's/<[^>]*>//')
PLIST_BUILD=$(grep '<key>CFBundleVersion</key>' "$APP/Contents/Info.plist" | grep -o '<string>[^<]*' | sed 's/<[^>]*>//')
case "$PLIST_VER" in ''|*[!0-9.]*) echo "build.sh: 版本号异常: '$PLIST_VER'" >&2; exit 1;; esac
case "$PLIST_BUILD" in ''|*[!0-9]*) echo "build.sh: 构建号异常: '$PLIST_BUILD'" >&2; exit 1;; esac
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true
echo "built: $(pwd)/$APP"
