#!/bin/bash
# 便签墙 · 自动化检查
# 覆盖：存档/清单/时间等纯逻辑、锁定与加密、快捷键占用、刘海几何（入口是否被物理刘海遮挡）
set -e
cd "$(dirname "$0")/.."

BIN=.build/release/NoteWall
if [ ! -x "$BIN" ]; then
  echo "→ 编译 release"
  swift build -c release --disable-sandbox >/dev/null
fi

echo "── 逻辑自检（清单解析 / 时间显示 / 存档往返）"
"$BIN" --selftest

echo
echo "── 锁定与加密（AES-GCM / 拒绝解锁 / 图片密文 / 旧存档迁移）"
"$BIN" --locktest

echo
echo "── 全局快捷键是否可用"
"$BIN" --hotkeys

echo
echo "── 刘海入口几何"
"$BIN" --notchtest /tmp/notch-preview.png

echo
echo "── 菜单栏图标（三张便签实心版 / 内部镂空 / 模板图 / 1x2x3x）"
"$BIN" --menubaricon

echo
echo "── 菜单栏右键菜单（条目 / 快捷键 / target / 点设置能弹面板）"
"$BIN" --menutest

echo
echo "── 菜单「设置…」端到端（真实窗口挂 sheet）"
"$BIN" --settingsfrommenu

echo
echo "── 手型光标状态机（进入即变 / 离开去抖 / 点击不闪）"
"$BIN" --handtest

echo
echo "── 边缘悬浮窗口不再接手型（真实点击 + 抽出全程不得出现手型）"
"$BIN" --clickfliptest

echo
echo "全部检查通过"
