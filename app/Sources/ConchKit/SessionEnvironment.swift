import Foundation

/// 分组的环境标签。“环境色”主题按它给会话上色，连到生产环境时窗口上有醒目的提示。
/// 标签设在分组上，下级分组没设时跟着上级。
public enum SessionEnvironment: String, Codable, CaseIterable, Sendable {
    case production
    case testing
    case device

    public var title: String {
        switch self {
        case .production: "生产"
        case .testing: "测试"
        case .device: "设备"
        }
    }
}
