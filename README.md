# 随手贴 · StickySide

> **贴在手边，用着顺手。**
> **Your notes, always within reach.**

随手贴是一款专为 macOS 打造的轻量级便签与桌面效率工具。它让你像使用真实便利贴一样，快速记录任务、提醒、清单、文字和图片，并通过屏幕边缘便签与便签墙，随时查看和取用重要信息。

StickySide is a lightweight sticky notes and productivity app for macOS. Capture quick thoughts, tasks, reminders, checklists, text, and images in seconds — and keep important notes within easy reach using a screen-edge panel and a visual note wall.

**随手记录 → 贴在手边 → 随时取用**

## 核心功能

- **随手记录**：按 `⌥ Space` 在任何应用里唤起快速捕获面板，记下文字、清单、截图；6 种便签纸色、标签、粘贴与拖拽图片都支持（快捷键可在设置里修改）
- **便签墙**：按 `⇧ ⌘ Space` 打开便签墙——多面墙、标签、四维筛选与搜索语法、瀑布流布局、拖拽排序与跨墙移动，把零散信息整理成一面墙
- **屏幕边缘便签**：便签贴在屏幕边缘（左/右停靠、三态收起），鼠标滑过去就能抽出查看、编辑和复制，不用在窗口之间翻找
- **刘海入口与菜单栏**：刘海屏有专属入口，菜单栏常驻，随时新建与打开
- **随取随用**：一键复制整张便签（文字 + 图片一起复制），邀请码、常用文字、临时资料贴在手边，用时即取
- **清单与图文**：待办清单带完成进度，文字、图片、图文混排都支持
- **隐私与安全**：敏感便签可用 Touch ID 锁定，正文与图片以 AES-GCM 加密落盘；本地优先，数据只保存在你自己的 Mac 上
- **顺手的细节**：回收站 30 天自动清理、自研撤销/重做、开机自动启动

## 下载与安装

到 [Releases](https://github.com/DeepCarry/dc-notewall/releases) 下载最新版 DMG，打开后把「随手贴」拖进 Applications 即可。

系统要求：macOS 14+，Apple 芯片。

> 当前版本为 ad-hoc 签名、未做 Apple 公证。首次打开如被系统拦截，请到「系统设置 → 隐私与安全性」里点「仍要打开」放行。

## 本地构建

需要 macOS 14+ 与 Swift 工具链（安装 Xcode Command Line Tools 即可）：

```bash
./build.sh        # 构建并打包出 StickySide.app
./tools/test.sh   # 运行自动化检查
```

推送到 `main` 分支后，GitHub Actions 会自动构建并把安装包发布到 Releases。

## 文档

- [品牌命名方案](docs/品牌命名方案.md)——随手贴 · StickySide 的命名、定位与 Slogan
- [产品需求文档（PRD v0.4）](docs/PRD-便签墙-v0.4.md)
- [开发自检](docs/开发自检.md)
- [测试报告](docs/TEST-REPORT.md)

## 技术

Swift Package（swift-tools 5.9）可执行目标，SwiftUI + AppKit，零第三方依赖。
