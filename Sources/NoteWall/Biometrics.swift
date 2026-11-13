import Foundation
import LocalAuthentication

// MARK: - 解锁凭证

enum AuthKind: Equatable {
    case touchID      // 本机有 Touch ID，用它
    case password     // 没有生物识别时退到系统登录密码
    case none         // 两者都不可用（极少见），此时不允许锁定

    var title: String {
        switch self {
        case .touchID: return "Touch ID"
        case .password: return "Mac 登录密码"
        case .none: return "不可用"
        }
    }

    var available: Bool { self != .none }
}

/// 解锁有效期（PRD §2.8）。默认「本次运行」：退出应用即重新上锁，
/// 比「5 分钟」更符合便签的使用节奏——没人会为了看一张便签反复验指纹，
/// 但也不该让明文在磁盘上躺一整天。
enum UnlockPolicy: String, Codable, CaseIterable, Identifiable {
    case session, minutes1, minutes5, minutes30, everyTime

    var id: String { rawValue }

    var title: String {
        switch self {
        case .session:    return "本次运行"
        case .minutes1:   return "1 分钟"
        case .minutes5:   return "5 分钟"
        case .minutes30:  return "30 分钟"
        case .everyTime:  return "每次都要验证"
        }
    }

    /// nil = 不按时间自动上锁（交给退出流程）
    var seconds: TimeInterval? {
        switch self {
        case .session:   return nil
        case .minutes1:  return 60
        case .minutes5:  return 300
        case .minutes30: return 1800
        case .everyTime: return 0   // 0 = 关闭查看界面就立刻上锁
        }
    }

    var hint: String {
        switch self {
        case .session:   return "本次运行期间保持解锁，退出应用时重新上锁。App 常驻菜单栏时，本次运行可能持续很久，期间锁定便签保持解锁。"
        case .everyTime: return "关掉详情页就立刻重新上锁，明文不在磁盘上多留一秒。"
        default:         return "解锁后 \(title)自动重新上锁，期间不重复验证。"
        }
    }
}

/// 抽成协议只为一件事：自检里能跑完整的「锁定 → 拒绝解锁 → 允许解锁」流程，
/// 不必真的让机器弹一次 Touch ID（那样测试没法无人值守）。
protocol Authenticating {
    var kind: AuthKind { get }
    func authenticate(reason: String, completion: @escaping @MainActor (Bool) -> Void)
}

/// 系统生物识别。没有 Touch ID 的 Mac（或外接键盘合盖）退到登录密码，
/// 这样锁定功能在任何机器上都不会变成「打不开的死结」。
struct BiometricGate: Authenticating {
    var kind: AuthKind { Self.availability }

    static var availability: AuthKind {
        let ctx = LAContext()
        var err: NSError?
        if ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &err) { return .touchID }
        if ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &err) { return .password }
        return .none
    }

    func authenticate(reason: String, completion: @escaping @MainActor (Bool) -> Void) {
        let ctx = LAContext()
        ctx.localizedCancelTitle = "取消"
        let policy: LAPolicy = ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
            ? .deviceOwnerAuthenticationWithBiometrics
            : .deviceOwnerAuthentication
        ctx.evaluatePolicy(policy, localizedReason: reason) { ok, _ in
            // LAContext 的回调不在主线程，UI 与 store 都在主线程上
            DispatchQueue.main.async {
                MainActor.assumeIsolated { completion(ok) }
            }
        }
    }
}

/// 仅自检使用：同步给出结果，让「拒绝 → 内容不变」「允许 → 内容恢复」两条路径都能无人值守跑完。
struct TestAuthenticator: Authenticating {
    var kind: AuthKind = .touchID
    var allow: Bool

    func authenticate(reason: String, completion: @escaping @MainActor (Bool) -> Void) {
        MainActor.assumeIsolated { completion(allow) }
    }
}
