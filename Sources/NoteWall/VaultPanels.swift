import AppKit
import Foundation

/// 仓库选择用的两个系统面板。只返回用户选到的目录 URL，不校验、不认领
/// （校验归 `VaultManager.validateVault`，认领归 `VaultManager.adoptRoot`）。
enum VaultPanels {
    /// 打开已有仓库：只选文件夹，取消返回 nil。
    static func pickExisting() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK else { return nil }
        return panel.urls.first
    }

    /// 新建仓库：默认 ~/Documents，建议名 StickySide，取消返回 nil。
    /// 返回的目录可能还不存在（用户刚起的名字），建目录是调用方的事
    /// （`validateVault` 对不存在的目录返回 false，所以调用方要先建目录再校验）。
    static func createNew() -> URL? {
        let panel = NSSavePanel()
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents", isDirectory: true)
        panel.nameFieldStringValue = "StickySide"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }
}
