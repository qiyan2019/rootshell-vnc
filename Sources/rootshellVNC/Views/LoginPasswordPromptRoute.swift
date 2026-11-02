import Foundation

/// 登录密码确认交给内置框还是宿主。
enum LoginPasswordPromptDecision: Equatable, Sendable {
    /// 弹出内置确认框。自动路径要先消费 pending，手动路径不消费。
    case presentBuiltIn(consumingPending: Bool)
    /// 调用宿主闭包。不消费 pending，不弹内置框。
    case notifyHost
    /// 什么都不做。
    case ignore
}

/// 自动 pending 和手动快捷键共用的路由。回调为 nil 时保持上游行为。
enum LoginPasswordPromptRoute {
    /// 视图出现或 `loginPasswordPromptPending` 变成 true。
    /// 宿主接管时不消费 pending，留给宿主自己读。
    static func automatic(
        hostHandlesRequest: Bool,
        pending: Bool,
        canSend: Bool
    ) -> LoginPasswordPromptDecision {
        // canSend 由 consumeLoginPasswordPromptRequest 自己判断。
        // 这里仍要消费，不能发时它会清掉 pending，和上游一致。
        _ = canSend
        guard pending, !hostHandlesRequest else { return .ignore }
        return .presentBuiltIn(consumingPending: true)
    }

    /// Ctrl+Shift+P 或 HUD「输入密码」。不能发密码时两条路都不动作。
    static func manual(
        hostHandlesRequest: Bool,
        canSend: Bool
    ) -> LoginPasswordPromptDecision {
        guard canSend else { return .ignore }
        if hostHandlesRequest { return .notifyHost }
        return .presentBuiltIn(consumingPending: false)
    }
}
