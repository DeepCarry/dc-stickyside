import Foundation

/// 仓库解析结果。
enum VaultResolution: Equatable {
    case use(URL)                    // 直接用这个根目录开 App
    case needsChoice(ChoiceReason)   // 弹仓库选择器
    enum ChoiceReason: Equatable { case fresh, storedMissing }

    /// 是否要弹仓库选择器。启动分支与 AppDelegate 门控读它（设计 §2.2 / §2.2.1）。
    var isNeedsChoice: Bool {
        if case .needsChoice = self { return true }
        return false
    }
}

/// 当前仓库的根目录。UserDefaults 只记路径字符串。
enum VaultManager {
    static let defaultsKey = "VaultRootPath"

    /// 启动时解析出的结果。由 NoteWallApp.init() 定好，AppDelegate 读它来决定
    /// 要不要跳过建 store、接控制器、装快捷键（设计 §2.2）。
    static var launchResolution: VaultResolution?

    /// 首次启动解析（纯函数，不碰磁盘以外的任何状态）：
    /// - 存过路径且目录还在 → 用它；
    /// - 存过路径但目录没了 → 弹选择器，理由 storedMissing（不静默回落到老目录，
    ///   否则用户会看到一份旧数据却不知道为什么）；
    /// - 没存过路径、老存档在 → 认领老目录为仓库（用它，并由调用方写回 defaultsKey）；
    /// - 没存过路径、老存档也不在 → 弹选择器，理由 fresh（真·首次安装）。
    static func resolve(storedPath: String?, storedRootExists: Bool,
                        legacyStoreExists: Bool) -> VaultResolution {
        if let storedPath {
            if storedRootExists { return .use(URL(fileURLWithPath: storedPath, isDirectory: true)) }
            return .needsChoice(.storedMissing)
        }
        if legacyStoreExists { return .use(Paths.legacySupport) }
        return .needsChoice(.fresh)
    }

    /// 内存中的当前根。启动时由 resolve 的结果定好，之后只读——
    /// adoptRoot 绝不碰它（见设计 §2.3 的写盘顺序，那是丢数据的坑）。
    static var currentRoot: URL?

    /// 校验一个目录能不能当仓库：有 store.json，或是「空文件夹」。
    /// 「空」指没有非隐藏文件（`.DS_Store` 之类以 `.` 开头的文件不算——
    /// Finder 建的文件夹打开过就有它，按字面判空会把正常空文件夹拒掉）。
    /// 非空又没有 store.json → 不能当，调用方弹错、留在选择器。
    static func validateVault(at url: URL) -> Bool {
        let fm = FileManager.default
        if fm.fileExists(atPath: url.appendingPathComponent("store.json").path) { return true }
        guard let names = try? fm.contentsOfDirectory(atPath: url.path) else { return false }
        return !names.contains { !$0.hasPrefix(".") }
    }

    /// 选完仓库后调用：只写 UserDefaults（defaultsKey），不碰 currentRoot、
    /// 不碰任何 store。写完就重启（设计 §2.3），新进程从 UserDefaults 重新解析。
    /// 绝不在旧进程里改 currentRoot——Paths.support 是实时计算属性，
    /// 一改它，旧进程此后所有的写盘（显式 saveNow、防抖 saveTask、退出时
    /// relock + saveNow、EdgeDeck.flushSave）都会写进新仓库，把旧仓库整份
    /// store.json 盖过去、新仓库的种子也被旧 didSeed 顶掉。
    /// `defaults` 默认标准偏好；自测传独立 suite，不碰真实偏好（设计 §4）。
    static func adoptRoot(_ url: URL, defaults: UserDefaults = .standard) {
        defaults.set(url.path, forKey: defaultsKey)
    }
}
