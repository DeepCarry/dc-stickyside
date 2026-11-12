#!/bin/bash
# 生成 AppIcon.icns（矢量渲染每一档，不靠缩放）
# 依赖：Xcode 命令行工具（swiftc / iconutil）
set -e
cd "$(dirname "$0")/.."

SRC=tools/icongen.swift
BIN=/tmp/notewall-icongen
ICONSET=/tmp/AppIcon.iconset
OUT=Resources/AppIcon.icns

mkdir -p Resources

echo "→ 编译图标渲染器"
swiftc -O "$SRC" -o "$BIN"

echo "→ 渲染各尺寸"
rm -rf "$ICONSET"; mkdir -p "$ICONSET"
render() { "$BIN" A "$1" "$ICONSET/$2"; }
render 16   icon_16x16.png
render 32   icon_16x16@2x.png
render 32   icon_32x32.png
render 64   icon_32x32@2x.png
render 128  icon_128x128.png
render 256  icon_128x128@2x.png
render 256  icon_256x256.png
render 512  icon_256x256@2x.png
render 512  icon_512x512.png
render 1024 icon_512x512@2x.png

echo "→ 打包 icns"
iconutil -c icns "$ICONSET" -o "$OUT"
echo "✓ $OUT  ($(du -h "$OUT" | cut -f1))"
