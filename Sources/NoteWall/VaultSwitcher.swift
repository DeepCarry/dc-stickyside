import AppKit
import Foundation

/// 切换仓库后重启 App：先把新实例排好再退出，保证不断档。
/// 用 `Bundle.main.bundlePath`（无论 App 装在哪都指当前这份）。
enum VaultSwitcher {
    /// 0.3s 后用 `/usr/bin/open -n` 启动新实例，随后退出旧进程。
    /// 延时必须活在子进程里（`/bin/sh -c "sleep 0.3; …"`）：`NSApp.terminate`
    /// 会停掉本进程的 runloop，`DispatchQueue.main.asyncAfter` 排的 0.3s 永远等不到。
    /// UserDefaults 的写操作在 `relaunch()` 之前完成（`adoptRoot` 里同步写，
    /// 不靠 `synchronize()`）；0.3s 的空档是给旧进程退出落盘留的。
    /// Bundle 路径以 `$1` 参数传，不拼进 shell 字符串（路径里有 `"` 或 `$` 也不会
    /// 断开命令）。返回值：新实例排上队为 true；排队失败返回 false 且不退出，
    /// 调用方负责把失败告诉用户。
    static func relaunch() -> Bool {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sh")
        proc.arguments = ["-c", "sleep 0.3; exec /usr/bin/open -n \"$1\"", "sh", Bundle.main.bundlePath]
        do {
            try proc.run()
        } catch {
            return false
        }
        NSApp.terminate(nil)
        return true
    }
}
