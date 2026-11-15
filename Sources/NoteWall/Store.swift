import Foundation
import SwiftUI
import AppKit

// MARK: - 磁盘位置

enum Paths {
    /// 自检把存档/密钥/图片全指到临时目录，绝不碰真实数据。
    nonisolated(unsafe) static var overrideRoot: URL?

    /// 固定老路径（0.3.11 及以前唯一的数据目录）。认领逻辑用它，平时不用。
    static var legacySupport: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("NoteWall", isDirectory: true)
    }

    /// 当前仓库根：自检 override > 启动时解析出的 currentRoot > 老路径。
    /// currentRoot 在 NoteWallApp.init() 里、AppContext.shared.store 创建之前就定好
    /// （设计 §2.2 的不变量 1），之后只读；adoptRoot 不碰它（设计 §2.3）。
    static var support: URL {
        if let overrideRoot { return overrideRoot }
        if let currentRoot = VaultManager.currentRoot { return currentRoot }
        return legacySupport
    }
    static var images: URL { support.appendingPathComponent("images", isDirectory: true) }
    static var thumbs: URL { support.appendingPathComponent("thumbs", isDirectory: true) }
    static var storeFile: URL { support.appendingPathComponent("store.json") }

    static func ensure() {
        for d in [support, images, thumbs] {
            try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        }
    }
}

// MARK: - 存档结构

struct Archive: Codable {
    var version: Int = 2
    var notes: [Note] = []
    var walls: [Wall] = []
    var sortMode: SortMode = .newest
    var contentFilter: ContentFilter = .all
    var didSeed: Bool = false
    var lockEnabled: Bool = false
    var checkCountVisible: Bool = true
    /// 写这份存档时用的主密钥指纹。和当前密钥不一致 = 密钥换过，旧密文解不开了。
    var keyID: String? = nil
    /// Optional 是有意的：Swift 合成的解码器对非可选字段缺 key 会直接抛错，
    /// 老存档没这一项就会走进「存档损坏」分支。可选字段才是向前兼容的写法。
    var appearance: Appearance? = nil

    // 下面几项同理，一律 Optional
    var paperFilter: [Paper]? = nil
    var timeFilter: TimeFilter? = nil
    var statusFilter: StatusFilter? = nil
    /// 捕获面板上次的位置与尺寸 x, y, w, h
    var captureFrame: [Double]? = nil
    var unlockPolicy: UnlockPolicy? = nil
    /// 自定义全局快捷键。nil = 默认（⌥ Space / ⌘ ⇧ Space）
    var hotkeys: HotkeyConfig? = nil

    // 屏幕边缘条（Edge Deck）
    var edgeEnabled: Bool? = nil
    var edgeSide: EdgeSide? = nil
    var edgeMode: EdgeMode? = nil
    var edgeCount: Int? = nil
    /// 钉住模式下显示哪些便签，数组顺序即显示顺序。放存档而不放 Note 字段：
    /// Note 的解码牵一发动全身，存档加一个 Optional 数组才是向前兼容的改法。
    var edgePinnedIds: [UUID]? = nil
    /// 首次提示「边缘有条」是否已展示过
    var edgeIntroduced: Bool? = nil

    // 0.3.0：侧栏三态 / 主区视图 / 整齐模式。Optional，见上面注释。
    var sidebarMode: SidebarMode? = nil
    var viewMode: ViewMode? = nil
    var neatMode: Bool? = nil
    // 0.3.5：字号缩放倍率（0.85–1.30）。Optional，见上面注释。
    var fontScale: Double? = nil
    // 0.3.6：闲置自动重锁（D5）。Optional，见上面注释。
    var idleRelock: IdleRelockOption? = nil
}

// MARK: - Store

@MainActor
final class AppStore: ObservableObject {
    @Published private(set) var notes: [Note] = []
    @Published private(set) var walls: [Wall] = []
    @Published var sortMode: SortMode = .newest { didSet { scheduleSave() } }
    @Published var contentFilter: ContentFilter = .all { didSet { scheduleSave() } }
    @Published var checkCountVisible: Bool = true { didSet { scheduleSave() } }

    // 三个独立筛选维度，见 Filters.swift
    @Published var paperFilter = PaperFilter() { didSet { scheduleSave() } }
    @Published var timeFilter: TimeFilter = .any { didSet { scheduleSave() } }
    @Published var statusFilter: StatusFilter = .all { didSet { scheduleSave() } }

    /// 捕获面板的位置与尺寸记忆。窗口被拖到副屏后拔掉副屏时要在用的地方做一次可见性校正。
    @Published var captureFrame: CGRect? = nil { didSet { scheduleSave() } }

    /// 解锁后多久自动重新上锁
    @Published var unlockPolicy: UnlockPolicy = .everyTime {
        didSet { scheduleSave(); rescheduleRelocks(); rescheduleIdleRelock() }
    }

    /// 闲置自动重锁（D5）：默认 15 分钟无操作重锁。只对「本次运行」策略生效——
    /// 1/5/30 分钟策略已有逐张倒计时，「每次都要验证」靠关闭即锁。
    @Published var idleRelock: IdleRelockOption = .minutes15 {
        didSet { scheduleSave(); rescheduleIdleRelock() }
    }

    /// 全局快捷键。真正生效与否以 HotKeyCenter 的注册结果为准：
    /// 这里只保存「最后设置的值」，被占用时设置页会有明确的提示。
    @Published private(set) var hotkeys: HotkeyConfig = .standard
    /// 设置页里要展示的快捷键问题（冲突 / 拦截原因）。nil = 一切正常。
    @Published var hotkeyMessage: String? = nil

    // MARK: 屏幕边缘条

    /// 边缘条总开关。默认开（D2）：12pt 细条存在感极低，而功能的全部价值在「被发现」。
    @Published var edgeEnabled: Bool = true { didSet { scheduleSave() } }
    @Published var edgeSide: EdgeSide = .right { didSet { scheduleSave() } }
    @Published var edgeMode: EdgeMode = .recent { didSet { scheduleSave() } }
    /// 最近编辑模式下最多显示几张
    @Published var edgeCount: Int = 8 { didSet { scheduleSave() } }
    @Published private(set) var edgePinnedIds: [UUID] = [] { didSet { scheduleSave() } }
    /// 首次 Toast 只出现一次
    @Published var edgeIntroduced: Bool = false { didSet { scheduleSave() } }

    /// 外观（浅色 / 深色 / 跟随系统）。改完立刻作用到所有窗口，不等下次启动。
    @Published var appearance: Appearance = .system {
        didSet {
            ThemeApplier.apply(appearance)
            if persistent { scheduleSave() }
        }
    }

    /// 侧边栏三态（⌘B / 标题栏按钮循环）。重启保持。
    @Published var sidebarMode: SidebarMode = .expanded { didSet { scheduleSave() } }
    /// 主区视图：网格 / 列表。重启保持。
    @Published var viewMode: ViewMode = .grid { didSet { scheduleSave() } }
    /// 整齐模式：关掉卡片的旋转、胶带与折角。设置里可开。
    @Published var neatMode: Bool = true { didSet { scheduleSave() } }
    /// 字号缩放倍率（0.85–1.30，默认 1.0）。设置「外观」组可调，⌘+/⌘- 微调。
    /// 唯一写入口：didSet 同步 FontScale.current 并落盘。
    @Published var fontScale: CGFloat = 1.0 {
        didSet {
            FontScale.current = fontScale
            scheduleSave()
        }
    }

    /// 当前倍率最接近的预设（取距离最近的一档；误差 ≤0.02 时即为该档）。
    var fontPreset: FontSizePreset {
        FontSizePreset.closest(to: fontScale)
    }

    /// ⌘+/⌘- 微调：0.05 一档，0.85–1.30，到顶/到底给提示不再动。
    /// *20 取整消浮点漂移；百分比先 round 再取整，1.15 不会显示成 114%。
    func bumpFontScale(by delta: CGFloat) {
        let next = (min(max(fontScale + delta, 0.85), 1.30) * 20).rounded() / 20
        if next == fontScale {
            ToastCenter.shared.show(delta > 0 ? "已是最大" : "已是最小")
            return
        }
        fontScale = next
        ToastCenter.shared.show("字体 \(Int((next * 100).rounded()))%")
    }
    /// 侧栏智能视图（收藏 / 最近 / 桌面便签）。会话态，不存盘——
    /// 和 selectedWallID / searchText 一样，重启回到全部。
    @Published var smartView: SmartView? = nil
    /// 刚添加的便签 id：卡片用它做一次「贴上去」的落下动画，1 秒后清掉。
    @Published private(set) var lastAddedID: UUID? = nil
    /// 刚捕捉的便签（最多 3 张）：英雄纸下面那排胶囊，点开详情、× 只是从这排拿掉。
    /// 会话态——重启后这排是空的，墙上的便签不受影响。
    @Published private(set) var recentCaptures: [UUID] = []

    /// nil 代表「全部」
    @Published var selectedWallID: UUID? = nil
    @Published var searchText: String = ""
    @Published var tagFilter: String? = nil

    private var didSeed = false
    private var saveTask: Task<Void, Never>?
    /// 内存实例（演示 / 自检 / 快照）永远不写盘，避免覆盖真实存档
    private let persistent: Bool

    /// 内容加密。内存实例用临时密钥，不落 `vault.key`。
    let vault: Vault
    /// 解锁凭证。自检里换成假实现。
    var authenticator: Authenticating = BiometricGate()
    /// 存档里的密文不是用当前密钥加密的（密钥文件被删/换过）
    @Published private(set) var keyStale = false
    /// 损坏存档的备份文件（运行时态，不落盘）。load() 的 catch 分支当场追加，
    /// init 再扫描磁盘补齐历史备份，按修改时间倒序。
    @Published private(set) var corruptBackups: [URL] = []
    /// 存档损坏且备份也失败（磁盘满/权限问题）：启动提示改文案，不撒谎。
    @Published private(set) var corruptRebuildWithoutBackup: Bool = false
    /// 本次运行内解过锁的便签：退出时会重新锁上，明文不留在磁盘上过夜
    private(set) var unlockedThisSession: Set<UUID> = []

    // MARK: 撤销栈
    private var undoStack: [UndoStep] = []
    private var redoStack: [UndoStep] = []
    /// 只发布「有没有得撤销 + 那一步叫什么」，闭包栈本身留在内部
    @Published private(set) var undoLabel: String? = nil
    @Published private(set) var redoLabel: String? = nil

    // MARK: 解锁计时
    private var relockTimers: [UUID: DispatchWorkItem] = [:]
    /// 闲置重锁计时（D5）。只在 session 策略 + 有本次解锁过的便签时排。
    private var idleRelockWork: DispatchWorkItem? = nil

    // MARK: 载入 / 保存

    init(inMemory: Bool = false, vault: Vault? = nil) {
        persistent = !inMemory
        self.vault = vault ?? (inMemory ? Vault.ephemeral() : Vault.shared)
        if inMemory { didSeed = true; return }
        Paths.ensure()
        load()
        scanCorruptBackups()
        // 损坏存档的启动提示（D4）：只报一次（init 内消费，与 P0-6 的旗子消费同一模式）。
        // 备份文件在，恢复是手动的——给文件、给路径、给说明，不承诺自动修复。
        if !corruptBackups.isEmpty {
            ToastCenter.shared.show("旧存档已损坏，已重建为空白墙", actionTitle: "在访达中显示", action: { [weak self] in
                guard let self else { return }
                NSWorkspace.shared.activateFileViewerSelecting(self.corruptBackups)
            }, seconds: 6)
        } else if corruptRebuildWithoutBackup {
            ToastCenter.shared.show("旧存档已损坏且无法备份，已重建为空白墙", seconds: 6)
        }
        // 密钥出过问题（P0-6）：损坏重建 / 写失败都要明说，旧锁定便签打不开是有原因的。
        // 只报一次：消费完清掉旗子，免得预览/重建时重复弹。
        if Vault.keyRegenerated {
            Vault.keyRegenerated = false
            keyStale = true
            ToastCenter.shared.show("密钥文件已损坏，已生成新密钥，旧锁定便签无法打开", seconds: 6)
        }
        if Vault.keyWriteFailed {
            Vault.keyWriteFailed = false
            keyStale = true
            ToastCenter.shared.show("密钥无法写入，锁定功能已暂停", seconds: 6)
        }
        migrateLegacyLocks()  // 旧版本只有「锁」的 UI，正文还是明文：这里补成真加密
        purgeExpiredTrash()   // 回收站只留 30 天（PRD AC-8），清理连图片一起删
    }

    /// 供演示/预览装载内存数据
    func loadDemo(notes: [Note], walls: [Wall]) {
        self.notes = notes
        self.walls = walls
    }

    /// 只给离屏渲染/预览用的演示数据，不落盘
    static func demo() -> AppStore {
        let s = AppStore(inMemory: true)
        let wall = Wall(name: "我的便签", sortOrder: 0, isDefault: true, tint: .yellow)
        let work = Wall(name: "工作", sortOrder: 10, tint: .blue)
        let idea = Wall(name: "灵感", sortOrder: 20, tint: .purple)
        s.loadDemo(notes: [], walls: [wall, work, idea])
        let now = Date()
        let secret = Note(wallID: work.id, text: "客户那边的报价底线是 18 万，超过就要走二次审批。",
                          paper: .purple, tag: "资料", createdAt: now.addingTimeInterval(-86400))
        s.loadDemo(notes: [
            Note(wallID: idea.id, text: "优化后，便签墙终于变好看了", paper: .pink, tag: "想法",
                 createdAt: now.addingTimeInterval(-3 * 86400)),
            Note(wallID: wall.id, text: "测试便签", paper: .yellow, tag: "灵感",
                 createdAt: now.addingTimeInterval(-3 * 86400 - 3600)),
            Note(wallID: wall.id,
                 text: "周五前要处理的三件事\n- [x] 给设计稿加标注\n- [ ] 改完原型里的三段文案\n- [ ] 把导出功能列进 v1.2",
                 paper: .mint, tag: "待办", createdAt: now.addingTimeInterval(-2 * 86400)),
            Note(wallID: work.id, text: "这个交互要改：刘海展开时不要抢焦点，否则正在打的字就断了",
                 paper: .blue, tag: "资料", createdAt: now.addingTimeInterval(-7200)),
            Note(wallID: idea.id, text: "便签不需要更聪明，只需要更快出现。", paper: .pink, tag: "灵感",
                 createdAt: now.addingTimeInterval(-400 * 86400)),
            Note(wallID: work.id, text: "新机器装环境，一条命令跑完：\nbrew install --cask raycast rectangle arc",
                 paper: .cream, tag: "资料", createdAt: now.addingTimeInterval(-6 * 86400)),
            secret,
        ], walls: [wall, work, idea])
        // 演示数据也走真实加密路径：isLocked 但正文明文是旧版本的不一致状态
        s.lock(secret.id)
        return s
    }

    private func load() {
        guard let data = try? Data(contentsOf: Paths.storeFile) else {
            seedIfNeeded()
            return
        }
        do {
            let a = try JSONDecoder.archive.decode(Archive.self, from: data)
            notes = a.notes
            walls = a.walls
            sortMode = a.sortMode
            contentFilter = a.contentFilter
            checkCountVisible = a.checkCountVisible
            appearance = a.appearance ?? .system
            paperFilter.papers = Set(a.paperFilter ?? [])
            timeFilter = a.timeFilter ?? .any
            statusFilter = a.statusFilter ?? .all
            unlockPolicy = a.unlockPolicy ?? .everyTime
            hotkeys = a.hotkeys ?? .standard
            edgeEnabled = a.edgeEnabled ?? true
            edgeSide = a.edgeSide ?? .right
            edgeMode = a.edgeMode ?? .recent
            edgeCount = a.edgeCount ?? 8
            edgePinnedIds = a.edgePinnedIds ?? []
            edgeIntroduced = a.edgeIntroduced ?? false
            sidebarMode = a.sidebarMode ?? .expanded
            viewMode = a.viewMode ?? .grid
            neatMode = a.neatMode ?? true
            fontScale = a.fontScale.map { CGFloat($0) } ?? 1.0
            FontScale.current = fontScale
            idleRelock = a.idleRelock ?? .minutes15
            if let f = a.captureFrame, f.count == 4 {
                captureFrame = CGRect(x: f[0], y: f[1], width: f[2], height: f[3])
            }
            didSeed = a.didSeed
            if let kid = a.keyID, kid != vault.keyID,
               notes.contains(where: { $0.isLocked }) {
                // 密文还在，钥匙换了。不静默丢数据：如实标出来，锁着的便签会显示「无法解锁」。
                keyStale = true
                NSLog("NoteWall: 存档密钥指纹 \(kid) 与当前 \(vault.keyID) 不一致")
            }
            if walls.isEmpty { seedIfNeeded() }
        } catch {
            // 存档损坏：备份后重建为空白墙，绝不静默丢数据，也不再撒种子覆盖。
            let bak = Paths.support.appendingPathComponent("store.corrupt-\(Int(Date().timeIntervalSince1970)).json")
            if (try? FileManager.default.copyItem(at: Paths.storeFile, to: bak)) != nil {
                corruptBackups.insert(bak, at: 0)
            } else {
                corruptRebuildWithoutBackup = true
                NSLog("NoteWall: 存档损坏且备份失败")
            }
            rebuildAfterCorruption()
        }
    }

    private func scheduleSave() {
        guard persistent else { return }
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            await self?.saveNow()
        }
    }

    func saveNow() {
        guard persistent else { return }
        Paths.ensure()
        var a = Archive(notes: notes, walls: walls, sortMode: sortMode,
                        contentFilter: contentFilter, didSeed: didSeed,
                        checkCountVisible: checkCountVisible,
                        keyID: notes.contains(where: { $0.isLocked }) ? vault.keyID : nil,
                        appearance: appearance)
        a.paperFilter = paperFilter.papers.isEmpty ? nil : Array(paperFilter.papers)
        a.timeFilter = timeFilter
        a.statusFilter = statusFilter
        a.unlockPolicy = unlockPolicy
        a.hotkeys = hotkeys
        a.edgeEnabled = edgeEnabled
        a.edgeSide = edgeSide
        a.edgeMode = edgeMode
        a.edgeCount = edgeCount
        a.edgePinnedIds = edgePinnedIds.isEmpty ? nil : edgePinnedIds
        a.edgeIntroduced = edgeIntroduced
        a.sidebarMode = sidebarMode
        a.viewMode = viewMode
        a.neatMode = neatMode
        a.fontScale = Double(fontScale)
        a.idleRelock = idleRelock
        if let f = captureFrame {
            a.captureFrame = [Double(f.origin.x), Double(f.origin.y),
                              Double(f.size.width), Double(f.size.height)]
        }
        guard let data = try? JSONEncoder.archive.encode(a) else { return }
        try? data.write(to: Paths.storeFile, options: .atomic)
    }

    // MARK: 首次启动

    private func seedIfNeeded() {
        guard !didSeed else { return }
        let wall = Wall(name: "我的便签", sortOrder: 0, isDefault: true)
        walls = [wall]
        notes = [
            Note(wallID: wall.id,
                 text: "欢迎使用随手贴\n这是你的第一张便签。灵感、待办、临时要用的东西，都可以贴在这里。",
                 paper: .yellow, tag: "灵感",
                 createdAt: Date().addingTimeInterval(-10), updatedAt: Date().addingTimeInterval(-10),
                 isPinned: true),
            Note(wallID: wall.id,
                 text: "三秒上手\n⌥Space 随时记，⇧⌘Space 打开便签墙。两个快捷键，都能在设置里改。",
                 paper: .blue, tag: "资料",
                 createdAt: Date().addingTimeInterval(-20), updatedAt: Date().addingTimeInterval(-20)),
            Note(wallID: wall.id,
                 text: "新手任务\n- [x] 按 ⌥Space 记下第一条\n- [ ] 换一张喜欢的纸色\n- [ ] 把这张便签置顶",
                 paper: .mint, tag: "待办",
                 createdAt: Date().addingTimeInterval(-30), updatedAt: Date().addingTimeInterval(-30)),
            Note(wallID: wall.id,
                 text: "贴在手边\n屏幕边缘、刘海、菜单栏——不用打开 App，便签就在眼前。",
                 paper: .purple, tag: "想法",
                 createdAt: Date().addingTimeInterval(-40), updatedAt: Date().addingTimeInterval(-40)),
            Note(wallID: wall.id,
                 text: "一键复制整张\n点卡片菜单「复制便签」，文字和图片整张带走，粘贴到任何地方。",
                 paper: .cream, tag: "资料",
                 createdAt: Date().addingTimeInterval(-50), updatedAt: Date().addingTimeInterval(-50)),
            Note(wallID: wall.id,
                 text: "一句话\n工具要轻，轻到不打断想法本身。",
                 paper: .yellow, tag: "灵感",
                 createdAt: Date().addingTimeInterval(-60), updatedAt: Date().addingTimeInterval(-60),
                 isFavorite: true)
        ]
        didSeed = true
        saveNow()
    }

    /// 损坏重建（D4）：建一面空墙，不撒种子。种子只在全新安装时出现——
    /// load() 成功路径的 `if walls.isEmpty { seedIfNeeded() }` 保持原样。
    private func rebuildAfterCorruption() {
        walls = [Wall(name: "我的便签", sortOrder: 0, isDefault: true)]
        notes = []
        didSeed = true
        saveNow()
    }

    /// 扫描磁盘上的损坏存档备份，按修改时间倒序。init 内调用，
    /// 补齐上次启动留下、用户还没处理的备份；本次 catch 追加的也在磁盘上，不会丢。
    private func scanCorruptBackups() {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: Paths.support,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]) else { return }
        let dated = files.compactMap { url -> (URL, Date)? in
            guard url.lastPathComponent.hasPrefix("store.corrupt-"),
                  url.pathExtension == "json" else { return nil }
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate) ?? .distantPast
            return (url, date)
        }
        corruptBackups = dated.sorted { $0.1 > $1.1 }.map(\.0)
    }

    /// 忽略一条损坏备份：进废纸篓而非直接删，可反悔。成功后才从列表里拿掉。
    func dismissCorruptBackup(_ url: URL) {
        guard (try? FileManager.default.trashItem(at: url, resultingItemURL: nil)) != nil else { return }
        corruptBackups.removeAll { $0 == url }
    }

    /// 供调试与「重置」使用
    func clearSamples() {
        notes.removeAll { $0.createdAt > Date().addingTimeInterval(-60) && !$0.hasContent }
        saveNow()
    }

    // MARK: 增删改

    @discardableResult
    func add(text: String, paper: Paper, tag: String, image: NoteImage? = nil, wallID: UUID? = nil) -> Note? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || image != nil else { return nil }
        let target = wallID ?? selectedWallID ?? walls.first?.id ?? ensureDefaultWall().id
        let maxOrder = notes.map(\.sortOrder).max() ?? 0
        // 待办自动转清单（P2-19）：收进数据层，创建与编辑走同一入口。
        let converted = Checklist.asTodoListIfNeeded(text: trimmed, tag: tag)
        var note = Note(wallID: target, text: converted, paper: paper, tag: tag)
        note.image = image
        note.sortOrder = maxOrder + 100
        notes.append(note)
        // 刚贴上的那张：卡片落下动画用；胶囊行也记一笔，三个入口都看得到它。
        lastAddedID = note.id
        recentCaptures.removeAll { $0 == note.id }
        recentCaptures.insert(note.id, at: 0)
        if recentCaptures.count > 3 { recentCaptures = Array(recentCaptures.prefix(3)) }
        let addedID = note.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self, self.lastAddedID == addedID else { return }
            self.lastAddedID = nil
        }
        saveNow()
        // 撤销“新建” = 软删除进回收站（不是 deleteForever，图片文件不删，可恢复）。
        // 闭包里只调不入栈的 setDeleted + 直接改字段，不调会入栈的 delete()。
        pushUndo(UndoStep(title: "新建便签",
                          undo: { [weak self] in self?.undoAdd(addedID) },
                          redo: { [weak self] in self?.setDeleted(addedID, false) }))
        return note
    }

    /// 撤销新建的反操作：软删除进回收站，同时清 recentCaptures 与 lastAddedID
    ///（与 delete() 的清理一致）。
    private func undoAdd(_ id: UUID) {
        setDeleted(id, true)
        recentCaptures.removeAll { $0 == id }
        if lastAddedID == id { lastAddedID = nil }
    }

    /// 胶囊行里的 ×：只是把这张从「刚捕捉」那排拿掉，墙上的便签不动。
    func dismissRecentCapture(_ id: UUID) {
        recentCaptures.removeAll { $0 == id }
    }

    func update(_ note: Note) {
        guard let i = notes.firstIndex(where: { $0.id == note.id }) else { return }
        var n = note
        // 待办自动转清单（P2-19）：详情/边缘/刘海三路写回的唯一入口。
        n.text = Checklist.asTodoListIfNeeded(text: n.text, tag: n.tag)
        // 脏检查：三路写回共用这一个入口，只看不改时不 bump updatedAt、不落盘。
        // 比较在 asTodoListIfNeeded 归一化之后做，只比用户可改的字段（toggleCheck
        // 已有的「全文不变不 bump」模式）；updatedAt、deletedAt、锁字段不参与比较。
        guard n.text != notes[i].text || n.paper != notes[i].paper || n.tag != notes[i].tag
            || n.image != notes[i].image || n.isPinned != notes[i].isPinned
            || n.favorite != notes[i].favorite || n.wallID != notes[i].wallID else { return }
        n.updatedAt = Date()
        // 添加时间永不改写（PRD AC-11）
        n.createdAt = notes[i].createdAt
        notes[i] = n
        saveNow()
    }

    func binding(for id: UUID) -> Binding<Note>? {
        guard let i = notes.firstIndex(where: { $0.id == id }) else { return nil }
        return Binding(get: { self.notes[i] }, set: { self.notes[i] = $0 })
    }

    func toggleCheck(noteID: UUID, itemID: Int) {
        guard let i = notes.firstIndex(where: { $0.id == noteID }) else { return }
        let oldText = notes[i].text
        let newText = Checklist.toggle(oldText, itemID: itemID)
        // itemID 越界时全文不变：不入栈、不 bump updatedAt，⌘Z 不会撤销一次“什么都没发生”。
        guard oldText != newText else { return }
        notes[i].text = newText
        notes[i].updatedAt = Date()
        pushUndo(UndoStep(title: "切换清单勾选",
                          undo: { [weak self] in self?.applyText(noteID, oldText) },
                          redo: { [weak self] in self?.applyText(noteID, newText) }))
        saveNow()
    }

    /// 打勾撤销的写回入口（不入栈，写回 + updatedAt + 落盘）。update() 本身不改，
    /// 仍是详情/边缘/刘海的写回入口。
    private func applyText(_ id: UUID, _ text: String) {
        guard let i = notes.firstIndex(where: { $0.id == id }) else { return }
        notes[i].text = text
        notes[i].updatedAt = Date()
        saveNow()
    }

    func togglePin(_ id: UUID) {
        guard let i = notes.firstIndex(where: { $0.id == id }) else { return }
        let old = notes[i].isPinned
        notes[i].isPinned.toggle()
        let new = notes[i].isPinned
        pushUndo(UndoStep(title: new ? "置顶" : "取消置顶",
                          undo: { [weak self] in self?.applyPin(id, old) },
                          redo: { [weak self] in self?.applyPin(id, new) }))
        saveNow()
    }

    private func applyPin(_ id: UUID, _ pinned: Bool) {
        guard let i = notes.firstIndex(where: { $0.id == id }) else { return }
        notes[i].isPinned = pinned
        saveNow()
    }

    /// 收藏 / 取消收藏。置顶是「排在墙的最前面」，收藏是「收进侧栏的集合」，
    /// 两件事不互相代替——参考图的侧栏同时有「收藏」和图钉，就是这个意思。
    func toggleFavorite(_ id: UUID) {
        guard let i = notes.firstIndex(where: { $0.id == id }) else { return }
        let old = notes[i].isFavorite ?? false
        notes[i].isFavorite = !old
        let new = !old
        pushUndo(UndoStep(title: new ? "收藏" : "取消收藏",
                          undo: { [weak self] in self?.applyFavorite(id, old) },
                          redo: { [weak self] in self?.applyFavorite(id, new) }))
        saveNow()
    }

    private func applyFavorite(_ id: UUID, _ favorite: Bool) {
        guard let i = notes.firstIndex(where: { $0.id == id }) else { return }
        notes[i].isFavorite = favorite
        saveNow()
    }

    /// 侧栏智能视图的计数。最近 = 30 天内动过的便签；桌面便签尚未实现，返回 0。
    func smartCount(_ view: SmartView) -> Int {
        switch view {
        case .favorites:
            return notes.filter { $0.deletedAt == nil && $0.favorite }.count
        case .recent:
            let cutoff = Date().addingTimeInterval(-30 * 86400)
            return notes.filter { $0.deletedAt == nil && $0.updatedAt > cutoff }.count
        case .desktop:
            return 0
        }
    }

    func move(_ id: UUID, to wallID: UUID) {
        guard let i = notes.firstIndex(where: { $0.id == id }),
              notes[i].wallID != wallID,
              walls.contains(where: { $0.id == wallID }) else { return }
        let from = notes[i].wallID
        let prevOrder = notes[i].sortOrder
        let maxOrder = notes.filter { $0.wallID == wallID && $0.id != id }.map(\.sortOrder).max() ?? 0
        notes[i].wallID = wallID
        // 落到目标墙末尾：拖进去的便签不该插进别人的版面里
        notes[i].sortOrder = maxOrder + 100
        pushUndo(UndoStep(title: "移动到别的墙",
                          undo: { [weak self] in self?.applyMove(id, wall: from, order: prevOrder) },
                          redo: { [weak self] in self?.applyMove(id, wall: wallID, order: maxOrder + 100) }))
        saveNow()
    }

    private func applyMove(_ id: UUID, wall: UUID, order: Int) {
        guard let i = notes.firstIndex(where: { $0.id == id }) else { return }
        notes[i].wallID = wall
        notes[i].sortOrder = order
        saveNow()
    }

    func delete(_ id: UUID) {
        guard let i = notes.firstIndex(where: { $0.id == id }), notes[i].deletedAt == nil else { return }
        notes[i].deletedAt = Date()
        recentCaptures.removeAll { $0 == id }
        pushUndo(UndoStep(title: "删除便签",
                          undo: { [weak self] in self?.setDeleted(id, false) },
                          redo: { [weak self] in self?.setDeleted(id, true) }))
        saveNow()
    }

    private func setDeleted(_ id: UUID, _ deleted: Bool) {
        guard let i = notes.firstIndex(where: { $0.id == id }) else { return }
        notes[i].deletedAt = deleted ? Date() : nil
        saveNow()
    }

    func restore(_ id: UUID) {
        setDeleted(id, false)
        pushUndo(UndoStep(title: "恢复便签",
                          undo: { [weak self] in self?.setDeleted(id, true) },
                          redo: { [weak self] in self?.setDeleted(id, false) }))
    }

    func deleteForever(_ id: UUID) {
        guard let i = notes.firstIndex(where: { $0.id == id }) else { return }
        if let img = notes[i].image {
            ImageStore.delete(img)
        }
        notes.remove(at: i)
        saveNow()
    }

    func emptyTrash() {
        for n in notes where n.deletedAt != nil {
            if let img = n.image { ImageStore.delete(img) }
        }
        notes.removeAll { $0.deletedAt != nil }
        // 图片文件已经删了，之前那步「删除便签」就算撤销回来也只剩空壳。
        // 清空回收站明确不可逆，顺手清掉历史，不给一个假的后悔入口。
        undoStack.removeAll()
        redoStack.removeAll()
        refreshUndoLabels()
        saveNow()
    }

    /// 回收站保留 30 天，过期连图片文件一起删除（PRD AC-8）。
    /// 每次启动跑一次即可：便签不是高频数据，没必要上定时器。
    @discardableResult
    func purgeExpiredTrash(days: Int = 30, now: Date = Date()) -> Int {
        let cutoff = now.addingTimeInterval(-Double(days) * 86400)
        let expired = notes.filter { note in
            guard let d = note.deletedAt else { return false }
            return d < cutoff
        }
        guard !expired.isEmpty else { return 0 }
        for n in expired {
            if let img = n.image { ImageStore.delete(img) }
        }
        notes.removeAll { note in
            guard let d = note.deletedAt else { return false }
            return d < cutoff
        }
        saveNow()
        return expired.count
    }

    // MARK: 撤销

    /// 焦点感知的撤销结果：焦点在 NSTextView 里时必须把按键还给 AppKit，
    /// 不可吞——文字编辑走原生 undo，结构操作走自定义栈，两条通道互不串扰。
    enum FocusUndoOutcome {
        case passThrough   // 焦点在 NSTextView 里：调用方必须把按键事件还给 AppKit，不可吞
        case done(String)  // 已执行一次结构撤销/重做，关联值为步骤标题，供 Toast
        case empty         // 栈空，无事可做
    }

    /// 焦点在 NSTextView 里（包括搜索框的 field editor）时返回 .passThrough；
    /// 否则按现有 undo() 执行，有步骤返回 .done(title)，栈空返回 .empty。
    func undoRespectingFocus() -> FocusUndoOutcome {
        if let responder = NSApp.keyWindow?.firstResponder, responder is NSTextView { return .passThrough }
        if let title = undo() { return .done(title) }
        return .empty
    }

    func redoRespectingFocus() -> FocusUndoOutcome {
        if let responder = NSApp.keyWindow?.firstResponder, responder is NSTextView { return .passThrough }
        if let title = redo() { return .done(title) }
        return .empty
    }

    private func pushUndo(_ step: UndoStep) {
        undoStack.append(step)
        if undoStack.count > 30 { undoStack.removeFirst(undoStack.count - 30) }
        // 新操作让「重做」失效，这是所有编辑器的通行规则
        redoStack.removeAll()
        refreshUndoLabels()
    }

    private func refreshUndoLabels() {
        undoLabel = undoStack.last?.title
        redoLabel = redoStack.last?.title
    }

    /// 返回被撤销的那一步的名字，供 Toast 显示「已撤销：删除便签」
    @discardableResult
    func undo() -> String? {
        guard let step = undoStack.popLast() else { return nil }
        step.undo()
        redoStack.append(step)
        refreshUndoLabels()
        return step.title
    }

    @discardableResult
    func redo() -> String? {
        guard let step = redoStack.popLast() else { return nil }
        step.redo()
        undoStack.append(step)
        refreshUndoLabels()
        return step.title
    }

    // MARK: 手动排序

    /// 把一张便签插到另一张前面/后面。
    /// 只重整**同一面墙**内的顺序号：在「全部」视图里拖动时如果把所有墙一起编号，
    /// 切回单面墙会看到顺序莫名其妙地变了。
    func reorder(_ id: UUID, droppingOn target: DropTarget) {
        guard case let .note(targetID, after) = target, targetID != id,
              let moved = notes.first(where: { $0.id == id }) else { return }

        let wall = moved.wallID
        var order = notes.filter { $0.deletedAt == nil && $0.wallID == wall }
            .sorted { $0.sortOrder < $1.sortOrder }
        guard order.contains(where: { $0.id == id }),
              order.contains(where: { $0.id == targetID }) else { return }

        let before = Dictionary(uniqueKeysWithValues: order.map { ($0.id, $0.sortOrder) })
        let prevMode = sortMode

        order.removeAll { $0.id == id }
        guard let t = order.firstIndex(where: { $0.id == targetID }) else { return }
        order.insert(moved, at: after ? t + 1 : t)

        let newOrder = applyOrder(order)
        sortMode = .manual
        pushUndo(UndoStep(title: "调整顺序",
                          undo: { [weak self] in self?.restoreOrder(before, mode: prevMode) },
                          redo: { [weak self] in self?.restoreOrder(newOrder, mode: .manual) }))
        saveNow()
    }

    @discardableResult
    private func applyOrder(_ order: [Note]) -> [UUID: Int] {
        var map: [UUID: Int] = [:]
        for (i, n) in order.enumerated() {
            guard let j = notes.firstIndex(where: { $0.id == n.id }) else { continue }
            notes[j].sortOrder = i * 100
            map[n.id] = i * 100
        }
        return map
    }

    private func restoreOrder(_ map: [UUID: Int], mode: SortMode) {
        for (id, value) in map {
            guard let i = notes.firstIndex(where: { $0.id == id }) else { continue }
            notes[i].sortOrder = value
        }
        sortMode = mode
        saveNow()
    }

    // MARK: 锁定 / 解锁（PRD §2.8）

    func canLock(_ note: Note) -> Bool {
        // 密钥写失败时本次运行没有可用的 durable 钥匙：不许新锁，免得内容
        // 被加密进一个谁也打不开的状态（P0-6）。
        guard !Vault.keyWriteFailed else { return false }
        return !note.isLocked && note.hasContent && authenticator.kind.available
    }

    /// 锁定是「安全方向」，不需要验身份。但解锁方式不可用时不允许锁：
    /// 否则内容会被加密进一个谁也打不开的状态，那叫数据丢失，不叫安全。
    @discardableResult
    func lock(_ id: UUID) -> Bool {
        // 同 canLock：没有 durable 钥匙时不许新锁（否则 migrateLegacyLocks 会把
        // 旧明文锁进一把重启就消失的临时钥匙里）。
        guard !Vault.keyWriteFailed, authenticator.kind.available,
              let i = notes.firstIndex(where: { $0.id == id }) else { return false }
        return sealNote(at: i, force: false)
    }

    /// 解锁必须过 Touch ID：验证失败就保持密文，绝不「拒了也给你看」。
    func unlock(_ id: UUID, completion: @escaping @MainActor (Bool) -> Void = { _ in }) {
        guard let n = notes.first(where: { $0.id == id }) else {
            NSLog("NoteWall: 解锁拒绝：便签不存在")
            completion(false)
            return
        }
        guard n.isLocked else {
            NSLog("NoteWall: 解锁拒绝：便签未锁定")
            completion(false)
            return
        }
        guard let payload = n.lockPayload else {
            NSLog("NoteWall: 解锁拒绝：便签无密文")
            completion(false)
            return
        }
        guard authenticator.kind.available else {
            NSLog("NoteWall: 解锁拒绝：验证方式不可用")
            completion(false)
            return
        }
        authenticator.authenticateDetailed(reason: "解锁这张便签") { [weak self] result in
            guard let self else { completion(false); return }
            switch result {
            case .success:
                NSLog("NoteWall: 解锁成功")
                completion(self.performUnlock(id, payload: payload))
            case .failure(.cancelled):
                // 用户点了取消：不弹提示，静默失败
                NSLog("NoteWall: 解锁失败：用户取消")
                completion(false)
            case .failure(.lockedOut):
                NSLog("NoteWall: 解锁失败：Touch ID 已锁定")
                ToastCenter.shared.show("Touch ID 已锁定，请改用 Mac 登录密码再试一次")
                completion(false)
            case .failure(.notAvailable):
                NSLog("NoteWall: 解锁失败：验证方式不可用")
                ToastCenter.shared.show("这台 Mac 上无法验证身份（没有 Touch ID，也没设登录密码）")
                completion(false)
            case .failure(.unknown):
                NSLog("NoteWall: 解锁失败：原因未知")
                ToastCenter.shared.show("验证失败，请再试一次")
                completion(false)
            }
        }
    }

    // MARK: 解锁有效期（PRD §2.8）

    /// 解锁成功后按策略排一次自动上锁。「每次都要验证」不排定时——
    /// 它靠详情页关闭时立刻上锁实现（relockAfterViewing）。
    private func scheduleRelock(_ id: UUID) {
        relockTimers[id]?.cancel()
        relockTimers[id] = nil
        guard let ttl = unlockPolicy.seconds, ttl > 0 else { return }
        let item = DispatchWorkItem { [weak self] in
            guard let self,
                  let i = self.notes.firstIndex(where: { $0.id == id }),
                  !self.notes[i].isLocked else { return }
            _ = self.sealNote(at: i, force: true)
        }
        relockTimers[id] = item
        DispatchQueue.main.asyncAfter(deadline: .now() + ttl, execute: item)
    }

    /// 策略一改就该重新计时：从「30 分钟」改成「1 分钟」，
    /// 已经在解锁状态的那张便签必须按新规则走，而不是等下次解锁才生效。
    func rescheduleRelocks() {
        for id in unlockedThisSession where !notes.contains(where: { $0.id == id && $0.isLocked }) {
            scheduleRelock(id)
        }
    }

    /// 「每次都要验证」：关掉详情页就上锁
    func relockAfterViewing(_ id: UUID) {
        guard unlockPolicy == .everyTime,
              notes.contains(where: { $0.id == id && !$0.isLocked }) else { return }
        relock(id)
    }

    func relock(_ id: UUID) {
        guard let i = notes.firstIndex(where: { $0.id == id }) else { return }
        relockTimers[id]?.cancel()
        relockTimers[id] = nil
        _ = sealNote(at: i, force: true)
    }

    /// 有用户活动就重排闲置计时；其余情况（已关闭 / 非 session 策略 / 无已解锁便签）
    /// 取消计时——与 rescheduleIdleRelock 同一逻辑。
    func noteUserActivity() {
        rescheduleIdleRelock()
    }

    /// 只在 session 策略 + 有本次解锁过的便签时排一个 m 分钟后的计时；
    /// 其余情况取消计时。performUnlock 成功后与 unlockPolicy 切换时都要调。
    func rescheduleIdleRelock() {
        idleRelockWork?.cancel()
        idleRelockWork = nil
        guard let m = idleRelock.minutes, unlockPolicy == .session,
              !unlockedThisSession.isEmpty else { return }
        let item = DispatchWorkItem { [weak self] in self?.fireIdleRelock() }
        idleRelockWork = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Double(m * 60), execute: item)
    }

    private func fireIdleRelock() {
        relockSessionNotes()
        ToastCenter.shared.show("已闲置 \(idleRelock.title)，锁定的便签已重新上锁")
    }

    /// 退出前把本次会话解过锁的便签重新封上：明文不在磁盘上过夜。
    func relockSessionNotes() {        guard !unlockedThisSession.isEmpty else { return }
        // 锁都上完了，闲置计时器无事可做，取消它。
        idleRelockWork?.cancel()
        idleRelockWork = nil
        for id in Array(unlockedThisSession) {
            guard let i = notes.firstIndex(where: { $0.id == id }) else { continue }
            _ = sealNote(at: i, force: false, save: false)
        }
        saveNow()
    }

    @discardableResult
    private func sealNote(at i: Int, force: Bool, save: Bool = true) -> Bool {
        var n = notes[i]
        guard force || !n.isLocked, n.hasContent else { return false }
        do {
            let sealed = try vault.seal(LockedPayload(text: n.text), aad: n.id.uuidString)
            if let img = n.image, !img.isEncrypted {
                try vault.sealImage(img)
                n.image?.isEncrypted = true
            }
            n.text = ""
            n.lockPayload = sealed
            n.isLocked = true
            n.lockedAt = Date()
            // 不碰 updatedAt：锁上/解开不是「编辑」，否则「最近编辑」排序会被打乱
            notes[i] = n
            unlockedThisSession.remove(n.id)
            relockTimers[n.id]?.cancel()
            relockTimers[n.id] = nil
            ThumbCache.shared.evict(n.image)   // 内存里还留着明文缩略图就不算锁上了
            if save { saveNow() }
            return true
        } catch {
            NSLog("NoteWall: 锁定失败 \(error)")
            return false
        }
    }

    private func performUnlock(_ id: UUID, payload: String) -> Bool {
        guard let i = notes.firstIndex(where: { $0.id == id }) else { return false }
        var n = notes[i]
        do {
            let p = try vault.open(payload, as: LockedPayload.self, aad: n.id.uuidString)
            if let img = n.image, img.isEncrypted {
                try vault.openImage(img)
                n.image?.isEncrypted = false
            }
            n.text = p.text
            n.isLocked = false
            n.lockPayload = nil
            n.lockedAt = nil
            notes[i] = n
            unlockedThisSession.insert(id)
            scheduleRelock(id)
            rescheduleIdleRelock()
            saveNow()
            return true
        } catch {
            NSLog("NoteWall: 解锁失败 \(error)")
            return false
        }
    }

    /// 旧存档迁移：以前「锁定」只有一层遮罩，正文还是明文，这里补成真正的加密。
    /// 没有可用的解锁方式时不动——宁可留着明文遮罩，也不能把它锁死。
    private func migrateLegacyLocks() {
        guard authenticator.kind.available else { return }
        let legacy = notes.indices.filter {
            notes[$0].isLocked && notes[$0].lockPayload == nil && notes[$0].hasContent
        }
        guard !legacy.isEmpty else { return }
        var changed = 0
        for i in legacy where sealNote(at: i, force: true, save: false) { changed += 1 }
        if changed > 0 {
            NSLog("NoteWall: 迁移 \(changed) 张旧版「假锁」便签为密文")
            saveNow()
        }
    }

    // MARK: 墙

    @discardableResult
    func ensureDefaultWall() -> Wall {
        if let w = walls.first { return w }
        let w = Wall(name: "我的便签", sortOrder: 0, isDefault: true)
        walls = [w]
        return w
    }

    @discardableResult
    func addWall(_ name: String) -> Wall {
        let w = Wall(name: name, sortOrder: (walls.map(\.sortOrder).max() ?? 0) + 10)
        walls.append(w)
        saveNow()
        return w
    }

    func renameWall(_ id: UUID, to name: String) {
        guard let i = walls.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        walls[i].name = trimmed
        saveNow()
    }

    /// 换墙的标识色。只影响 tab 上的小圆点与墙管理面板，不碰便签纸色——
    /// 纸色是用户记住一张便签的依据，不能被墙的配色覆盖。
    func tintWall(_ id: UUID, _ paper: Paper) {
        guard let i = walls.firstIndex(where: { $0.id == id }) else { return }
        walls[i].tint = paper
        saveNow()
    }

    /// 墙的左右移动。用 sortOrder 重排，不用数组下标，
    /// 这样存档里被手工改过的墙顺序也能被一次操作纠正回来。
    func moveWall(_ id: UUID, by delta: Int) {
        var ordered = walls.sorted { $0.sortOrder < $1.sortOrder }
        guard let i = ordered.firstIndex(where: { $0.id == id }),
              ordered.indices.contains(i + delta) else { return }
        ordered.swapAt(i, i + delta)
        for (k, w) in ordered.enumerated() {
            guard let j = walls.firstIndex(where: { $0.id == w.id }) else { continue }
            walls[j].sortOrder = k * 10
        }
        saveNow()
    }

    func deleteWall(_ id: UUID) {
        guard walls.count > 1, let i = walls.firstIndex(where: { $0.id == id }) else { return }
        let removed = walls[i]
        let fallback = walls[(i + 1) % walls.count].id
        let movedIDs = notes.filter { $0.wallID == id }.map(\.id)
        for n in notes.indices where notes[n].wallID == id { notes[n].wallID = fallback }
        walls.remove(at: i)
        if selectedWallID == id { selectedWallID = nil }
        pushUndo(UndoStep(title: "删除墙「\(removed.name)」",
                          undo: { [weak self] in self?.restoreWall(removed, noteIDs: movedIDs) },
                          redo: { [weak self] in self?.deleteWallAgain(removed.id, fallback: fallback) }))
        saveNow()
    }

    private func restoreWall(_ wall: Wall, noteIDs: [UUID]) {
        if !walls.contains(where: { $0.id == wall.id }) { walls.append(wall) }
        for id in noteIDs {
            guard let i = notes.firstIndex(where: { $0.id == id }) else { continue }
            notes[i].wallID = wall.id
        }
        saveNow()
    }

    private func deleteWallAgain(_ id: UUID, fallback: UUID) {
        guard walls.count > 1, let i = walls.firstIndex(where: { $0.id == id }) else { return }
        for n in notes.indices where notes[n].wallID == id { notes[n].wallID = fallback }
        walls.remove(at: i)
        if selectedWallID == id { selectedWallID = nil }
        saveNow()
    }

    // MARK: 屏幕边缘条

    /// 出现在边缘的便签。安全规则比主窗口更严：锁定与回收站在数据层就排除——
    /// 边缘条是「路过就能看到」的界面，不能成为锁定内容的泄漏口。
    var edgeNotes: [Note] {
        let pool = notes.filter { $0.deletedAt == nil && !$0.isLocked }
        switch edgeMode {
        case .recent:
            return Array(pool.sorted { $0.updatedAt > $1.updatedAt }.prefix(edgeCount))
        case .pinned:
            // 数组顺序即显示顺序；compactMap 顺手清掉已被彻底删除的 id
            return edgePinnedIds.compactMap { id in pool.first { $0.id == id } }
        }
    }

    func isEdgePinned(_ id: UUID) -> Bool { edgePinnedIds.contains(id) }

    /// 钉住 / 取消钉住，均可撤销。
    /// 最近编辑模式下钉住不立即改变边缘内容，Toast 给一个「切过去看看」的入口。
    func toggleEdgePin(_ id: UUID) {
        guard notes.contains(where: { $0.id == id }) else { return }
        let before = edgePinnedIds
        var after = edgePinnedIds
        let pinning: Bool
        if let k = after.firstIndex(of: id) {
            after.remove(at: k)
            pinning = false
        } else {
            after.append(id)
            pinning = true
        }
        edgePinnedIds = after
        pushUndo(UndoStep(title: pinning ? "钉到屏幕边缘" : "从边缘移除",
                          undo: { [weak self] in self?.setEdgePins(before) },
                          redo: { [weak self] in self?.setEdgePins(after) }))
        if pinning {
            if edgeMode == .pinned {
                ToastCenter.shared.show("已钉到屏幕\(edgeSide == .right ? "右" : "左")缘")
            } else {
                ToastCenter.shared.show("已加入边缘钉住区", actionTitle: "切过去看") { [weak self] in
                    self?.edgeMode = .pinned
                }
            }
        } else {
            ToastCenter.shared.show("已从屏幕边缘移除")
        }
        saveNow()
    }

    private func setEdgePins(_ ids: [UUID]) {
        edgePinnedIds = ids
        saveNow()
    }

    // MARK: 快捷键

    /// 改一个位的快捷键。顺序是：硬性规则 → 与另一位查重 → 真实注册。
    /// 注册失败（被其他 App 占用）时保持原值不动，并把原因写进 hotkeyMessage。
    func setHotkey(_ slot: HotkeySlot, to combo: HotkeyCombo) {
        if hotkeys.clashes(combo, in: slot) {
            hotkeyMessage = "和「\(slot == .newNote ? HotkeySlot.openWall.title : HotkeySlot.newNote.title)」用的是同一个组合键"
            return
        }
        if let problem = HotkeyRules.problem(combo) {
            hotkeyMessage = problem
            return
        }
        var config = hotkeys
        config.set(slot, combo)
        if HotKeyCenter.shared.apply(config) != nil {
            // strict 模式已在 HotKeyCenter 里整体回滚，这里只需告诉用户为什么
            hotkeyMessage = "\(combo.display) 已被其他应用占用，换一组试试"
            return
        }
        hotkeys = config
        hotkeyMessage = nil
        saveNow()
    }

    func resetHotkeys() {
        if HotKeyCenter.shared.apply(.standard) != nil {
            hotkeyMessage = "默认快捷键被其他应用占用，换一组试试"
            return
        }
        hotkeys = .standard
        hotkeyMessage = nil
        saveNow()
    }

    // MARK: 查询

    /// 当前视图下的便签：墙 → 标签 → 内容类型 → 关键词 → 排序
    var visibleNotes: [Note] {
        var list = notes.filter { $0.deletedAt == nil }

        // 智能视图先定集合：收藏 / 最近是规则算出来的，桌面便签尚未实现（空集合 + 专属空态）。
        switch smartView {
        case .favorites:
            list = list.filter(\.favorite)
        case .recent:
            let cutoff = Date().addingTimeInterval(-30 * 86400)
            list = list.filter { $0.updatedAt > cutoff }
        case .desktop:
            return []
        case .none:
            break
        }

        // 智能视图里不按墙筛：选了收藏/最近时 selectedWallID 已经清掉，这里再守一道。
        if smartView == nil, let wid = selectedWallID {
            list = list.filter { $0.wallID == wid }
        }
        if let tag = tagFilter {
            list = list.filter { $0.tag == tag }
        }
        switch contentFilter {
        case .all: break
        case .text: list = list.filter { $0.image == nil && !$0.text.isEmpty }
        case .image: list = list.filter { $0.image != nil }
        case .checklist: list = list.filter { $0.isChecklist }
        }

        // 三个独立维度，可叠加
        if !paperFilter.isEmpty {
            list = list.filter { paperFilter.matches($0) }
        }
        if timeFilter != .any {
            let now = Date()
            list = list.filter { timeFilter.contains($0.createdAt, now: now) }
        }
        if statusFilter != .all {
            list = list.filter { statusFilter.matches($0) }
        }

        let query = SearchQuery.parse(searchText)
        if !query.isEmpty {
            list = list.filter { SearchQuery.matches($0, query: query, walls: walls) }
        }

        let pinned = list.filter(\.isPinned)
        var rest = list.filter { !$0.isPinned }
        if smartView == .recent {
            // 「最近」按动过的时间排，不跟墙的排序模式走
            rest.sort { $0.updatedAt > $1.updatedAt }
        } else {
            switch sortMode {
            case .newest: rest.sort { $0.createdAt > $1.createdAt }
            case .oldest: rest.sort { $0.createdAt < $1.createdAt }
            case .edited: rest.sort { $0.updatedAt > $1.updatedAt }
            case .manual: rest.sort { $0.sortOrder < $1.sortOrder }
            }
        }
        if !pinned.isEmpty {
            rest = pinned.sorted { $0.sortOrder < $1.sortOrder } + rest
        }
        return rest
    }

    var trashedNotes: [Note] {
        notes.filter { $0.deletedAt != nil }.sorted { ($0.deletedAt ?? .distantPast) > ($1.deletedAt ?? .distantPast) }
    }

    /// 顶栏要不要出现「清除筛选」：搜索框不算，它有自己的清除方式
    var hasActiveFilters: Bool {
        contentFilter != .all || !paperFilter.isEmpty || timeFilter != .any || statusFilter != .all || tagFilter != nil
    }

    func clearFilters() {
        contentFilter = .all
        paperFilter.papers = []
        timeFilter = .any
        statusFilter = .all
        tagFilter = nil
    }

    var allTags: [String] {
        let set = Set(notes.filter { $0.deletedAt == nil && !$0.isLocked }.map(\.tag).filter { !$0.isEmpty })
        let known = ["想法", "灵感", "待办", "资料", "参考"]
        let extra = set.subtracting(known).sorted()
        return known.filter { set.contains($0) } + extra
    }

    func count(for wallID: UUID?) -> Int {
        notes.filter { $0.deletedAt == nil && (wallID == nil || $0.wallID == wallID) }.count
    }
}

// MARK: - 搜索语法（PRD §2.6）

/// 支持 `#标签`、`墙:工作`、`有图`、`锁:` 四种简易语法，其余词按关键词做全文匹配。
/// 用空格分隔，可与关键词混用（AND 叠加）。
struct SearchQuery {
    var keyword: String = ""
    var tag: String? = nil
    var wallName: String? = nil
    var hasImage: Bool = false
    var lockedOnly: Bool = false

    var isEmpty: Bool {
        keyword.isEmpty && tag == nil && wallName == nil && !hasImage && !lockedOnly
    }

    static func parse(_ raw: String) -> SearchQuery {
        var q = SearchQuery()
        var words: [String] = []
        for token in raw.split(whereSeparator: { $0 == " " || $0 == "\u{3000}" }) {
            let t = String(token)
            let lower = t.lowercased()
            if t.hasPrefix("#"), t.count > 1 {
                q.tag = String(t.dropFirst())
            } else if lower.hasPrefix("墙:") || lower.hasPrefix("墙：") {
                let name = String(t.dropFirst(2))
                if !name.isEmpty { q.wallName = name }
            } else if t == "有图" {
                q.hasImage = true
            } else if lower.hasPrefix("锁:") || lower.hasPrefix("锁：") {
                q.lockedOnly = true
            } else {
                words.append(t)
            }
        }
        q.keyword = words.joined(separator: " ")
        return q
    }

    /// 全局搜索（⌘K 浮层）与墙内搜索共用同一套匹配规则：两处一旦分叉，
    /// 同一个词在浮层里找得到、墙里找不到，用户会以为搜索坏了。
    static func matches(_ note: Note, query: SearchQuery, walls: [Wall]) -> Bool {
        if let t = query.tag, note.tag != t { return false }
        if let w = query.wallName {
            let ids = Set(walls.filter { $0.name == w }.map(\.id))
            guard ids.contains(note.wallID) else { return false }
        }
        if query.hasImage, note.image == nil { return false }
        if query.lockedOnly, !note.isLocked { return false }
        let kw = query.keyword.lowercased()
        if !kw.isEmpty {
            // 锁定便签的正文不参与索引；命中标签时仍以「已锁定」形态出现（PRD §2.6）
            if note.tag.lowercased().contains(kw) { return true }
            if note.isLocked { return false }
            return note.text.lowercased().contains(kw)
        }
        return true
    }
}

// MARK: - JSON 编解码

extension JSONEncoder {
    static var archive: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }
}

extension JSONDecoder {
    static var archive: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
