import ConchKit
import Foundation

extension Error {
    /// 内核的错误自带中文说明，直接取出来；UniFFI 默认的 localizedDescription 是调试格式
    var userMessage: String {
        if let error = self as? CoreError {
            switch error {
            case .Connect(let message), .HostKey(let message), .Auth(let message),
                 .Cancelled(let message), .Session(let message):
                return message
            }
        }
        if let error = self as? SessionLibrary.ChainError {
            return error.description
        }
        return localizedDescription
    }

    /// 网络类的错误，自动重连时值得再试；认证失败、主机密钥不对、用户取消就没必要了
    var isRetryable: Bool {
        guard let error = self as? CoreError else { return false }
        switch error {
        case .Connect, .Session: return true
        case .HostKey, .Auth, .Cancelled: return false
        }
    }

    var isCancellation: Bool {
        if case .Cancelled = self as? CoreError { return true }
        return false
    }
}
