import Foundation

/// 会话文件的持久层。checkpoint 同时保存共同版本和未同步版本，重启也不丢离线修改。
/// 同步盘本身不提供跨 Mac 的分布式事务；冲突时保留本机操作，并把双方快照写入本机备份。
public final class SessionRepository {
    public private(set) var library: SessionLibrary
    public private(set) var waitingForSyncFolder = false
    public private(set) var message: String?
    public private(set) var syncURL: URL?
    public let localURL: URL
    private var base: SessionLibrary
    private var pendingLocalSave = false
    private var checkpointURL: URL { localURL.deletingLastPathComponent().appendingPathComponent("sessions-sync-state.json") }
    public var fileURL: URL { waitingForSyncFolder ? localURL : (syncURL ?? localURL) }

    private struct Checkpoint: Codable {
        var syncPath: String
        var base: SessionLibrary
        var local: SessionLibrary
    }
    private struct Conflict: Codable {
        var base: SessionLibrary
        var local: SessionLibrary
        var remote: SessionLibrary
    }

    public init(localURL: URL, syncURL: URL? = nil) throws {
        self.localURL = localURL
        self.syncURL = syncURL
        library = try Self.read(SessionLibrary.self, at: localURL) ?? SessionLibrary()
        base = library
        if let syncURL {
            if let saved = try Self.read(Checkpoint.self, at: checkpointURL), saved.syncPath == syncURL.path {
                base = saved.base
                library = saved.local
            } else if let shared = try? Self.read(SessionLibrary.self, at: syncURL) {
                library = shared
                base = shared
            } else {
                // 旧版本没有 checkpoint，或者首次打开不可用的同步目录：本机记录作为待同步新增项。
                base = SessionLibrary()
            }
            try saveLocal()
            try? refresh()
        }
    }

    public func refresh() throws {
        // 本机写入失败时，先重试保存，不能用旧磁盘内容冲掉内存里的修改。
        if pendingLocalSave { try saveLocal() }
        guard let syncURL else {
            if let latest = try Self.read(SessionLibrary.self, at: localURL) { library = latest }
            return
        }
        do {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: syncURL.deletingLastPathComponent().path, isDirectory: &isDirectory),
                  isDirectory.boolValue else { throw StorageError.unavailable }
            let remote = try Self.read(SessionLibrary.self, at: syncURL) ?? SessionLibrary()
            let merged = SessionSyncMerge(base: base, local: library, remote: remote)
            if merged.hasConflicts {
                let folder = localURL.deletingLastPathComponent().appendingPathComponent("Sync Conflicts", isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let backup = folder.appendingPathComponent("sessions-\(UUID().uuidString).json")
                try Self.write(Conflict(base: base, local: library, remote: remote), to: backup)
                message = "会话同步有冲突，已保留本机操作；双方版本已备份到 \(backup.path)"
            }
            if merged.library != remote || !FileManager.default.fileExists(atPath: syncURL.path) {
                try Self.write(merged.library, to: syncURL)
            }
            let changed = merged.library != base || merged.library != library
            library = merged.library
            base = merged.library
            if changed { try saveLocal() }
            waitingForSyncFolder = false
            if message?.hasPrefix("同步暂不可用") == true { message = nil }
        } catch {
            waitingForSyncFolder = true
            message = "同步暂不可用，修改保存在本机：\(error.localizedDescription)"
            throw error
        }
    }

    public func update(_ change: (inout SessionLibrary) -> Void) throws {
        // 先接收已到达本机的远端版本，离线时允许继续修改。
        if syncURL != nil { try? refresh() } else { try refresh() }
        let previous = library
        change(&library)
        guard library != previous else { return }
        // 先持久化离线状态，再尝试发布。同步失败不能丢掉此次操作。
        pendingLocalSave = true
        try saveLocal()
        if syncURL != nil { try? refresh() }
    }

    public func relocate(to destination: URL?, mergeCurrent: Bool) throws {
        if destination == syncURL { try refresh(); return }
        var next = library
        var nextBase = SessionLibrary()
        if let destination, let existing = try Self.read(SessionLibrary.self, at: destination) {
            nextBase = existing
            if mergeCurrent { next = existing; next.absorb(library) }
        }
        syncURL = destination
        base = nextBase
        library = next
        message = nil
        try saveLocal()
        if destination != nil { try? refresh() }
        else {
            waitingForSyncFolder = false
            if FileManager.default.fileExists(atPath: checkpointURL.path) { try FileManager.default.removeItem(at: checkpointURL) }
        }
    }

    private func saveLocal() throws {
        if let syncURL {
            try Self.write(Checkpoint(syncPath: syncURL.path, base: base, local: library), to: checkpointURL)
        }
        try Self.write(library, to: localURL)
        pendingLocalSave = false
    }

    private static func read<T: Decodable>(_ type: T.Type, at url: URL) throws -> T? {
        if !FileManager.default.fileExists(atPath: url.path) {
            let placeholder = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).icloud")
            if FileManager.default.fileExists(atPath: placeholder.path) {
                try? FileManager.default.startDownloadingUbiquitousItem(at: url)
                throw StorageError.downloading
            }
            return nil
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: Data(contentsOf: url))
    }

    private static func write<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(value).write(to: url, options: .atomic)
    }

    private enum StorageError: LocalizedError {
        case unavailable, downloading
        var errorDescription: String? {
            switch self {
            case .unavailable: "同步文件夹尚未挂载"
            case .downloading: "正在等待 iCloud 下载会话文件"
            }
        }
    }
}
