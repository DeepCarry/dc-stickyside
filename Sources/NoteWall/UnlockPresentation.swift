/// 详情页只在便签真的解开时打开。验证失败、密钥过期，都只在原地说明原因，不开详情。
enum UnlockPresentation {
    static func shouldOpenDetail(unlockOK: Bool, isLocked: Bool) -> Bool {
        unlockOK && !isLocked
    }
}
