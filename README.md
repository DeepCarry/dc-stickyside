# 纸签墙

纸签墙是一个本地优先的 macOS 便签工具。按 `⌥ Space` 随手记下文字、截图或清单，按 `⇧ ⌘ Space` 打开便签墙。快捷键可在设置里修改。

## 本地构建

需要 macOS 14 或更新版本，以及支持 Swift 5.9 的 Xcode 或命令行工具。

```bash
cd NoteWall
./build.sh
open 便签墙.app
```

现有构建的 App 显示名为「便签墙」。应用数据保存在 `~/Library/Application Support/NoteWall/`。

## 项目资料

- [应用开发与自检](NoteWall/README.md)
- [已有测试记录](NoteWall/TEST-REPORT.md)
- [产品需求](PRD-便签墙-v0.4.md)
- [主界面高保真原型](prototype/index.html) · [屏幕边缘条原型](prototype/edge-deck.html) · [原型截图](prototype/shots/)
