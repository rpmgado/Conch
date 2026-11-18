import Foundation

/// 一次远端拖放必须属于当前 SFTP 连接；不同窗口或重连前的拖放不能用当前服务器解释。
public struct RemoteFilesDrag: Codable, Sendable {
    public let sourceID: UUID
    public let paths: [String]

    public init(sourceID: UUID, paths: [String]) {
        self.sourceID = sourceID
        self.paths = paths
    }

    public func paths(for destinationID: UUID) -> [String]? {
        guard sourceID == destinationID, !paths.isEmpty else { return nil }
        return paths
    }
}
