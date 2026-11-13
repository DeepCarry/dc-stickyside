import AppKit
import ImageIO
import UniformTypeIdentifiers

/// 图片落盘：统一压到长边 ≤ 2048、生成 640pt 缩略图。
/// 便签墙里图片是"看一眼"的信息，原图没必要保留 12MP 的体量。
enum ImageStore {

    static let maxLongEdge: CGFloat = 2048
    static let thumbLongEdge: CGFloat = 640

    // MARK: 写入

    static func save(_ image: NSImage) -> NoteImage? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        Paths.ensure()

        let id = UUID().uuidString
        let mainName = "\(id).jpg"
        let thumbName = "\(id)-t.jpg"

        guard let main = encode(cg, maxEdge: maxLongEdge, quality: 0.86) else { return nil }
        guard let thumb = encode(cg, maxEdge: thumbLongEdge, quality: 0.8) else { return nil }

        do {
            try main.data.write(to: Paths.images.appendingPathComponent(mainName), options: .atomic)
            do {
                try thumb.data.write(to: Paths.thumbs.appendingPathComponent(thumbName), options: .atomic)
            } catch {
                // 缩略图没写成：已落盘的主图是孤儿，删掉再报失败（P1-16）。
                try? FileManager.default.removeItem(at: Paths.images.appendingPathComponent(mainName))
                throw error
            }
        } catch {
            return nil
        }

        return NoteImage(
            fileName: mainName,
            thumbName: thumbName,
            pixelWidth: main.width,
            pixelHeight: main.height,
            byteSize: main.data.count + thumb.data.count
        )
    }

    static func save(data: Data) -> NoteImage? {
        guard let img = NSImage(data: data) else { return nil }
        return save(img)
    }

    // MARK: 读取

    static func url(_ name: String, thumb: Bool) -> URL {
        (thumb ? Paths.thumbs : Paths.images).appendingPathComponent(name)
    }

    static func load(_ name: String, thumb: Bool) -> NSImage? {
        NSImage(contentsOf: url(name, thumb: thumb))
    }

    static func delete(_ image: NoteImage) {
        try? FileManager.default.removeItem(at: url(image.fileName, thumb: false))
        try? FileManager.default.removeItem(at: url(image.thumbName, thumb: true))
    }

    // MARK: 编码

    private struct Encoded {
        let data: Data
        let width: Int
        let height: Int
    }

    private static func encode(_ cg: CGImage, maxEdge: CGFloat, quality: Double) -> Encoded? {
        let w = CGFloat(cg.width), h = CGFloat(cg.height)
        let scale = min(1, maxEdge / max(w, h))
        let tw = Int(round(w * scale)), th = Int(round(h * scale))

        // 透明 PNG 直接压 JPEG：alpha 丢掉后透明处会变黑，先铺白底再画图（P1-17）。
        // 带 alpha 的图即使不用缩放也要走合成；CGContext 建不出来就记日志并失败，
        // 不再静默回落原图（回落会突破 2048 上限，黑底问题也还在）。
        let hasAlpha: Bool = {
            switch cg.alphaInfo {
            case .premultipliedFirst, .premultipliedLast, .first, .last: return true
            default: return false
            }
        }()
        let target: CGImage
        if scale < 1 || hasAlpha {
            guard let ctx = CGContext(
                data: nil, width: tw, height: th, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            ) else {
                NSLog("NoteWall: 图片编码建 CGContext 失败（\(tw)x\(th)）")
                return nil
            }
            ctx.interpolationQuality = .high
            ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: tw, height: th))
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: tw, height: th))
            guard let made = ctx.makeImage() else {
                NSLog("NoteWall: 图片编码 CGContext 出图失败")
                return nil
            }
            target = made
        } else {
            target = cg
        }

        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(dest, target, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }

        return Encoded(data: out as Data, width: target.width, height: target.height)
    }

    // MARK: 粘贴板

    /// 从粘贴板取图，优先取"文件 URL"再退到位图数据
    static func imageFromPasteboard(_ pb: NSPasteboard = .general) -> NSImage? {
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           let url = urls.first, let img = NSImage(contentsOf: url) {
            return img
        }
        if let imgs = pb.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage],
           let img = imgs.first {
            return img
        }
        if let data = pb.data(forType: .tiff) ?? pb.data(forType: .png) {
            return NSImage(data: data)
        }
        return nil
    }

    /// 剪贴板里是否有可用的图片。
    ///
    /// 三种来源都要认：
    /// ① 位图（截图、浏览器「复制图片」→ tiff/png）；
    /// ② `NSImage` 对象；
    /// ③ **访达里复制的图片文件**——这时剪贴板里是 fileURL，没有位图数据。
    /// 漏掉第三种的话，⌘V 会把路径当普通文本插进输入框（用户看到一串 /Users/…，
    /// 以为「便签不支持图片」）。
    static func pasteboardHasImage(_ pb: NSPasteboard = .general) -> Bool {
        if pb.canReadObject(forClasses: [NSImage.self], options: nil) { return true }
        if pb.types?.contains(.tiff) == true || pb.types?.contains(.png) == true { return true }
        if let urls = pb.readObjects(forClasses: [NSURL.self],
                                     options: [.urlReadingFileURLsOnly: true]) as? [URL],
           urls.contains(where: { UTType(filenameExtension: $0.pathExtension)?.conforms(to: .image) == true }) {
            return true
        }
        return false
    }

    // MARK: 拖拽
    /// 从拖拽的 NSItemProvider 取图。两种来源都要支持：
    /// 访达里拖文件（fileURL）和浏览器里直接拖图（位图数据）。
    /// 回调统一回主线程：调用方要改 @Published 状态、要重排窗口。
    static func loadImage(from provider: NSItemProvider,
                          completion: @escaping @MainActor (NSImage?) -> Void) {
        func finish(_ img: NSImage?) {
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(img) } }
        }

        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                var url: URL?
                if let data = item as? Data {
                    url = URL(dataRepresentation: data, relativeTo: nil)
                } else if let u = item as? URL {
                    url = u
                }
                finish(url.flatMap { NSImage(contentsOf: $0) })
            }
            return
        }

        if provider.canLoadObject(ofClass: NSImage.self) {
            _ = provider.loadObject(ofClass: NSImage.self) { obj, _ in
                finish(obj as? NSImage)
            }
            return
        }

        if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
            provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                finish(data.flatMap { NSImage(data: $0) })
            }
            return
        }

        finish(nil)
    }
}

/// 输入区粘图：剪贴板里有图就返回它，否则 nil。
///
/// 单独抽出来是为了能脱离 UI 测试——`--imagetest` 用三种剪贴板内容
/// （位图 / 图片文件 / 纯文本）验证「该不该接管这次 ⌘V」。
enum ComposerPaste {
    static func image(_ pb: NSPasteboard = .general) -> NSImage? {
        guard ImageStore.pasteboardHasImage(pb) else { return nil }
        return ImageStore.imageFromPasteboard(pb)
    }
}
