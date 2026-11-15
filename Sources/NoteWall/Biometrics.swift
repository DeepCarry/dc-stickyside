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

/// 生物识别失败的原因：取消 / 被锁 / 没硬件在调用方看来不能全是一个 false。
enum AuthFailure: String, Equatable, Error {
    case cancelled    // 用户点了取消（或系统取消）：不弹提示，静默失败
    case lockedOut    // 生物识别多次失败被锁：提示改用 Mac 登录密码
    case notAvailable // 无硬件/未录入：提示本机无法验证
    case unknown      // 其余（含验证失败）：提示“验证失败，请再试一次”
}

/// 闲置自动重锁（D5）：只对「本次运行」策略生效。1/5/30 分钟策略已有逐张倒计时，
/// 「每次都要验证」靠关闭即锁，闲置计时是重复建设。
enum IdleRelockOption: String, Codable, CaseIterable, Identifiable {
    case off, minutes15, minutes60

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off: return "关闭"
        case .minutes15: return "15 分钟"
        case .minutes60: return "60 分钟"
        }
    }

    /// nil = 关闭
    var minutes: Int? {
        switch self {
        case .off: return nil
        case .minutes15: return 15
        case .minutes60: return 60
        }
    }
}

/// 解锁有效期（PRD §2.8）。默认「每次都要验证」：像保险箱一样，
/// 关掉详情页就立刻重新上锁，看一次验一次——墙上凡是锁着的，就是锁着的。
/// Touch ID 一次验证不到一秒；想回到会话解锁，随时可以在设置里改回「本次运行」。
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
        case .session:   return "本次运行期间保持解锁，退出应用时重新上锁。App 常驻菜单栏时，本次运行可能持续很久，期间锁定便签保持解锁。闲置一段时间后也会自动上锁（见下方「闲置自动重锁」）。"
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

extension Authenticating {
    /// 默认实现：旧的 Bool 入口只能分出成功/失败，失败一律映射为 .unknown。
    /// 遵循者（BiometricGate）重写本方法给出真实原因；TestAuthenticator 不用改。
    func authenticateDetailed(reason: String, completion: @escaping @MainActor (Result<Void, AuthFailure>) -> Void) {
        authenticate(reason: reason) { ok in
            completion(ok ? .success(()) : .failure(.unknown))
        }
    }
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

    /// 与 authenticate() 完全一致的策略选择，但把 LAError 的原因分出来。
    func authenticateDetailed(reason: String, completion: @escaping @MainActor (Result<Void, AuthFailure>) -> Void) {
        let ctx = LAContext()
        ctx.localizedCancelTitle = "取消"
        let policy: LAPolicy = ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
            ? .deviceOwnerAuthenticationWithBiometrics
            : .deviceOwnerAuthentication
        ctx.evaluatePolicy(policy, localizedReason: reason) { ok, error in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if ok { completion(.success(())); return }
                    let code = (error as? LAError)?.code
                    switch code {
                    case .userCancel, .appCancel, .systemCancel: completion(.failure(.cancelled))
                    case .biometryLockout: completion(.failure(.lockedOut))
                    case .biometryNotAvailable, .biometryNotEnrolled: completion(.failure(.notAvailable))
                    default: completion(.failure(.unknown))
                    }
                }
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
