import Foundation

/// 一次加载的状态(「所有列表有空状态、错误状态、重试入口」)。
enum LoadState<Value: Sendable>: Sendable {
    /// 还没开始(初次进入、等待服务器切换)
    case idle
    case loading
    case loaded(Value)
    case failed(LoadFailure)
}

extension LoadState: Equatable where Value: Equatable {}

extension LoadState {
    var value: Value? {
        if case .loaded(let value) = self { return value }
        return nil
    }

    var isLoading: Bool {
        if case .loading = self { return true }
        return false
    }
}

/// 加载失败的用户可见信息。
///
/// `needsLogin` 单独标出来:401 的处置是「重新登录」而不是「重试」
/// (API_CONTRACT.md 2.5),两者混在一个按钮上会让用户反复重试一个必然失败的
/// 请求。
struct LoadFailure: Sendable, Equatable {
    let message: String
    let needsLogin: Bool

    init(message: String, needsLogin: Bool = false) {
        self.message = message
        self.needsLogin = needsLogin
    }

    init(_ error: EmbyAPIError) {
        self.message = error.userMessage
        self.needsLogin = (error == .unauthorized)
    }
}
