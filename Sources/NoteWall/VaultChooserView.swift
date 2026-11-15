import SwiftUI
import AppKit

/// 首次启动 / 仓库丢了时出现的仓库选择器（设计 §2.2）。
/// 跑在内存 store 上，不碰真实数据；选完即 `adoptRoot` + 重启。
/// 文案与布局按设计 §2.2 的草图；字体与颜色走全站 token（`Font.ui` / `T.*`），
/// 它们只读静态状态，不碰 `AppContext.shared.store`。
struct VaultChooserView: View {
    /// 打开已有仓库时校验不过的行内报错；新建失败（建目录失败）也写这里。
    @State private var errorMessage: String? = nil
    /// 选择器窗口只调一次尺寸（挂载时从墙默认尺寸缩到 480×360）。
    @State private var didSizeWindow = false

    /// 只有「上次的仓库找不到了」时才在顶部显示提示（设计 §2.2）。
    private var isStoredMissing: Bool {
        if case .needsChoice(.storedMissing) = VaultManager.launchResolution { return true }
        return false
    }

    var body: some View {
        VStack(spacing: 16) {
            if isStoredMissing {
                Text("上次的仓库找不到了（可能被移动或删除），请重新选择。")
                    .font(.ui(13))
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
            }
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 56, height: 56)
            Text("欢迎使用随手贴")
                .font(.ui(20, .semibold))
                .foregroundStyle(T.text)
            Text("你的便签存在这台电脑的一个文件夹（仓库）里，\n卸载软件不会删掉它；换电脑时把文件夹拷走就行。")
                .font(.ui(13))
                .foregroundStyle(T.textDim)
                .multilineTextAlignment(.center)
            HStack(spacing: 12) {
                Button("新建仓库…") { createVault() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                Button("打开已有仓库…") { openVault() }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
            }
            if let errorMessage {
                Text(errorMessage)
                    .font(.ui(12))
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }
            Text("首次使用建议选「新建仓库」。")
                .font(.ui(12))
                .foregroundStyle(T.textFaint)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(T.bg)
        // 0.3.12 修复：选择器和墙共用一扇 WindowGroup（窗口场景不能用 if/else 分支），
        // 窗口初始是墙的 1180×820，挂载时把这扇窗一次调到 480×360 并居中。
        .background(WindowAccessor { win in
            guard let win = win, !didSizeWindow else { return }
            didSizeWindow = true
            // 0.3.14：选择器窗口也禁分组，免得这扇小窗以后被并进选项卡条。
            win.tabbingMode = .disallowed
            win.setContentSize(NSSize(width: 480, height: 360))
            win.title = "欢迎使用随手贴"
            win.center()
        })
    }

    /// 新建：面板 → （不存在就）建目录 → 校验 → 认领 → 重启。
    /// 目录已存在且是合法仓库（有 store.json）→ 当作打开处理，不重复建；
    /// 已存在但非空又没有 store.json → 报错，留在选择器。
    private func createVault() {
        guard let url = VaultPanels.createNew() else { return }
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            do {
                try fm.createDirectory(at: url, withIntermediateDirectories: true)
            } catch {
                errorMessage = "创建文件夹失败：\(error.localizedDescription)"
                return
            }
        }
        guard VaultManager.validateVault(at: url) else {
            errorMessage = "这个文件夹里没有随手贴仓库，也不是空文件夹"
            return
        }
        VaultManager.adoptRoot(url)
        if !VaultSwitcher.relaunch() {
            errorMessage = "切换失败：无法启动新实例，请手动退出并重新打开随手贴。"
        }
    }

    /// 打开：面板 → 校验 → 认领 → 重启。校验不过 → 行内报错，留在选择器。
    private func openVault() {
        guard let url = VaultPanels.pickExisting() else { return }
        guard VaultManager.validateVault(at: url) else {
            errorMessage = "这个文件夹里没有随手贴仓库，也不是空文件夹"
            return
        }
        VaultManager.adoptRoot(url)
        if !VaultSwitcher.relaunch() {
            errorMessage = "切换失败：无法启动新实例，请手动退出并重新打开随手贴。"
        }
    }
}
