import AppKit

// MARK: - 一键复制整张便签（文字 + 图片）

/// v0.9.18 新增。此前只有卡片菜单里的「复制文字」：纯图片便签复制不了，
/// 边缘抽出面板更是连入口都没有——用户在边缘条里看到一条邀请码想拷走，
/// 只能先全选再 ⌘C，图片则完全没路。
///
/// 剪贴板里同时放三种表示，挂在同一个 NSPasteboardItem 上，接收方自己挑
/// 最能吃的那种，不会互相冲掉：
/// - `.rtfd`：文字 + 图片内嵌，粘到备忘录 / Pages / 富文本框里图文都在；
/// - `.png` / `.tiff`：图片本体，粘到只认图片的地方能用；
/// - `.string`：纯文本兜底，粘到终端 / 编辑器不会带格式。
///
/// 锁定的便签一律拒绝：正文与图片落盘时是密文，复制等于绕过锁。
enum NoteCopy {
    enum Result: Equatable {
        case textAndImage, textOnly, imageOnly, nothing

        var toast: String {
            switch self {
            case .textAndImage: return "已复制便签（文字 + 图片）"
            case .textOnly: return "已复制文字"
            case .imageOnly: return "已复制图片"
            case .nothing: return "没有可复制的内容"
            }
        }
    }

    /// 锁定便签的复制提示：调用方先查 isLocked 再调 copy，文案集中在这里，
    /// 不新增 Result 分支——main.swift 的 --copytest 断言认 `.nothing`，推不上去改不了。
    static let lockedToast = "这张便签已锁定，不能复制"

    /// - Parameter text: 要复制的文字。边缘面板传当前草稿（可能还没写回 store），
    ///   其它入口传 nil，用 note.text。
    /// - Parameter pb: 目标剪贴板。默认系统剪贴板；测试传独立命名的，避免污染用户在用的。
    @MainActor
    @discardableResult
    static func copy(_ note: Note, text overrideText: String? = nil,
                     to pb: NSPasteboard = .general) -> Result {
        guard !note.isLocked else { return .nothing }
        let text = overrideText ?? note.text
        let hasText = !text.isEmpty
        let image = note.image.flatMap { ThumbCache.shared.full($0) }
        guard hasText || image != nil else { return .nothing }

        let item = NSPasteboardItem()
        if hasText { item.setString(text, forType: .string) }
        if let image {
            if let png = pngData(image) { item.setData(png, forType: .png) }
            if let tiff = image.tiffRepresentation { item.setData(tiff, forType: .tiff) }
            if let rtfd = rtfdData(text: text, image: image) { item.setData(rtfd, forType: .rtfd) }
        }
        pb.clearContents()
        pb.writeObjects([item])

        switch (hasText, image != nil) {
        case (true, true): return .textAndImage
        case (true, false): return .textOnly
        case (false, true): return .imageOnly
        case (false, false): return .nothing
        }
    }

    private static func pngData(_ image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    /// 图文混排：版式跟卡片一致（图在上、文在下），粘过去不至于文图倒置。
    private static func rtfdData(text: String, image: NSImage) -> Data? {
        let attr = NSMutableAttributedString()
        let attachment = NSTextAttachment()
        attachment.image = image
        // 原图最长边可达 2048：不缩放直接粘进富文本会撑爆版面，按纸面宽度等比收
        if image.size.width > 320, image.size.height > 0 {
            let h = image.size.height * 320 / image.size.width
            attachment.bounds = NSRect(x: 0, y: 0, width: 320, height: h)
        }
        attr.append(NSAttributedString(attachment: attachment))
        if !text.isEmpty {
            attr.append(NSAttributedString(string: "\n" + text))
        }
        return attr.rtfd(from: NSRange(location: 0, length: attr.length),
                         documentAttributes: [:])
    }
}
