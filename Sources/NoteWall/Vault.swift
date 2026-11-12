import Foundation
import CryptoKit

// MARK: - 锁定的内容

/// 一张便签被锁住时，正文不再存在 `Note.text` 里，而是序列化成这个结构再整体加密。
/// 图片不进这里：图片文件会被原地换成密文，靠 `NoteImage.isEncrypted` 记账。
struct LockedPayload: Codable {
    var version: Int = 1
    var text: String = ""
}

enum VaultError: Error {
    case badFormat      // 密文格式不对（不是我们写的）
    case keyMissing     // 密钥文件读不出来
    case sealFailed
    case openFailed     // 认证失败：密钥不对 / 密文被改过 / AAD 不匹配
    case imageFailed
}

// MARK: - 主密钥 + AES-GCM

/// 便签内容加密。设计边界要说清楚：
///
/// - 密钥是 32 字节随机数，存在 `vault.key`（0600、排除出备份），**不进存档、不进 iCloud**；
/// - 每张便签的密文用**便签 id 作为 AAD**，把 A 的密文塞给 B 会直接认证失败；
/// - 这道锁防的是「别人翻我的文件 / 备份 / 存档预览」，不是「本机上以我的身份运行的恶意程序」。
///   后者只有 Secure Enclave/钥匙串生物识别才能防，而本机是 ad-hoc 签名，重新构建后钥匙串
///   每次都弹授权（实测过），所以没有把密钥放钥匙串。要做真正的硬件绑定，
///   只需要换掉这个文件里 `loadOrCreateKey()` 的实现，上层不用动。
final class Vault {
    static let shared = Vault(persistent: true)

    /// 离屏渲染 / 自检用：密钥只在内存里，绝不落盘
    static func ephemeral() -> Vault { Vault(persistent: false) }

    private let key: SymmetricKey
    let keyID: String          // 密钥指纹（sha256 前 6 字节），用于「密钥换过了」的报警

    init(persistent: Bool) {
        if persistent {
            key = Self.loadOrCreateKey()
        } else {
            key = SymmetricKey(size: .bits256)
        }
        keyID = Self.fingerprint(of: key)
    }

    // MARK: 载荷

    func seal<T: Encodable>(_ value: T, aad: String) throws -> String {
        let data = try JSONEncoder.archive.encode(value)
        guard let box = try? AES.GCM.seal(data, using: key, authenticating: Data(aad.utf8)),
              let combined = box.combined else {
            throw VaultError.sealFailed
        }
        return "v1:" + combined.base64EncodedString()
    }

    func open<T: Decodable>(_ sealed: String, as: T.Type, aad: String) throws -> T {
        guard sealed.hasPrefix("v1:"),
              let raw = Data(base64Encoded: String(sealed.dropFirst(3))) else {
            throw VaultError.badFormat
        }
        do {
            let box = try AES.GCM.SealedBox(combined: raw)
            let data = try AES.GCM.open(box, using: key, authenticating: Data(aad.utf8))
            return try JSONDecoder.archive.decode(T.self, from: data)
        } catch {
            throw VaultError.openFailed
        }
    }

    // MARK: 图片（原地换成密文）

    /// 先把两份密文都算出来再落盘：避免「主图已加密、缩略图没加密」的半截状态。
    /// 第二个文件写失败时把第一个文件还原成明文。
    func sealImage(_ image: NoteImage) throws {
        let files = [(image.fileName, false), (image.thumbName, true)]
        var plain: [Data] = []
        var sealed: [Data] = []
        do {
            for (name, thumb) in files {
                let data = try Data(contentsOf: ImageStore.url(name, thumb: thumb))
                guard let box = try? AES.GCM.seal(data, using: key),
                      let combined = box.combined else { throw VaultError.imageFailed }
                plain.append(data)
                sealed.append(combined)
            }
        } catch {
            throw VaultError.imageFailed
        }

        var written = 0
        do {
            for (i, (name, thumb)) in files.enumerated() {
                try sealed[i].write(to: ImageStore.url(name, thumb: thumb), options: .atomic)
                written += 1
            }
        } catch {
            for i in 0..<written {
                try? plain[i].write(to: ImageStore.url(files[i].0, thumb: files[i].1), options: .atomic)
            }
            throw VaultError.imageFailed
        }
    }

    /// 同样先全部解开再落盘：卡在第二个文件时把第一个还原成密文，不留半明半密的中间态。
    func openImage(_ image: NoteImage) throws {
        let files = [(image.fileName, false), (image.thumbName, true)]
        var sealed: [Data] = []
        var plain: [Data] = []
        do {
            for (name, thumb) in files {
                let raw = try Data(contentsOf: ImageStore.url(name, thumb: thumb))
                let box = try AES.GCM.SealedBox(combined: raw)
                sealed.append(raw)
                plain.append(try AES.GCM.open(box, using: key))
            }
        } catch {
            throw VaultError.openFailed
        }

        var written = 0
        do {
            for (i, (name, thumb)) in files.enumerated() {
                try plain[i].write(to: ImageStore.url(name, thumb: thumb), options: .atomic)
                written += 1
            }
        } catch {
            for i in 0..<written {
                try? sealed[i].write(to: ImageStore.url(files[i].0, thumb: files[i].1), options: .atomic)
            }
            throw VaultError.imageFailed
        }
    }

    // MARK: 密钥文件

    static var keyURL: URL { Paths.support.appendingPathComponent("vault.key") }

    private static func loadOrCreateKey() -> SymmetricKey {
        if let data = try? Data(contentsOf: keyURL), data.count == 32 {
            return SymmetricKey(data: data)
        }
        Paths.ensure()
        let key = SymmetricKey(size: .bits256)
        let raw = key.withUnsafeBytes { Data($0) }
        // 0600：只有当前用户能读；并排除出 Time Machine，密钥不跟着备份跑
        let url = keyURL
        try? raw.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        var excl = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? excl.setResourceValues(values)
        return key
    }

    private static func fingerprint(of key: SymmetricKey) -> String {
        let digest = SHA256.hash(data: key.withUnsafeBytes { Data($0) })
        return digest.prefix(6).map { String(format: "%02x", $0) }.joined()
    }
}
