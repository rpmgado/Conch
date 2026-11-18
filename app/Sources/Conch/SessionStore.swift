import ConchKit
import Foundation

/// UI 使用的会话库。持久化、离线恢复和冲突备份由可独立测试的 SessionRepository 处理。
final class SessionStore: ObservableObject {
    static let shared = SessionStore()
    @Published private(set) var library = SessionLibrary()
    @Published private(set) var waitingForSyncFolder = false
    @Published private(set) var persistenceMessage: String?
    private var repository: SessionRepository?
    private var watcher: Timer?
    private let fallbackURL: URL

    var fileURL: URL { repository?.fileURL ?? fallbackURL }

    init(fileURL: URL = AppPaths.sessionsFile) {
        fallbackURL = fileURL
        do {
            let syncing = SyncSettings.directory != nil && fileURL != AppPaths.localSessionsFile
            repository = try SessionRepository(localURL: syncing ? AppPaths.localSessionsFile : fileURL,
                                               syncURL: syncing ? fileURL : nil)
            publish()
        } catch {
            // 读不懂时保留原文件，停止写入并向用户提示，不能用空库覆盖。
            persistenceMessage = "会话文件读取失败，原文件已保留：\(error.localizedDescription)"
        }
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.reloadIfChanged() }
        RunLoop.main.add(timer, forMode: .common)
        watcher = timer
    }

    deinit { watcher?.invalidate() }

    @discardableResult
    func reloadIfChanged() -> Bool {
        guard let repository else { return false }
        let previous = library
        do { try repository.refresh() } catch { NSLog("Conch：会话同步暂不可用：\(error)") }
        publish()
        return previous != library
    }

    func update(_ change: (inout SessionLibrary) -> Void) {
        guard let repository else { return }
        do { try repository.update(change); publish() }
        catch {
            publish()
            persistenceMessage = "保存会话失败，请保留当前窗口：\(error.localizedDescription)"
        }
    }

    func relocate(to url: URL, mergeCurrent: Bool) {
        guard let repository else { return }
        do {
            try repository.relocate(to: url == AppPaths.localSessionsFile ? nil : url, mergeCurrent: mergeCurrent)
            publish()
        } catch {
            publish()
            persistenceMessage = "切换同步位置失败，原文件已保留：\(error.localizedDescription)"
        }
    }

    private func publish() {
        guard let repository else { return }
        if library != repository.library { library = repository.library }
        if waitingForSyncFolder != repository.waitingForSyncFolder { waitingForSyncFolder = repository.waitingForSyncFolder }
        if persistenceMessage != repository.message { persistenceMessage = repository.message }
    }

    func session(_ id: UUID?) -> SessionProfile? { library.session(id) }
    func contains(_ id: UUID) -> Bool { library.session(id) != nil }
    func upsert(_ profile: SessionProfile) { update { $0.upsert(profile) } }
    func markConnected(_ id: UUID) {
        guard contains(id) else { return }
        update { $0.markConnected(id) }
    }
    @discardableResult
    func merge(_ profiles: [SessionProfile]) -> (added: Int, skipped: Int) {
        var result = (added: 0, skipped: 0)
        update { result = $0.merge(profiles) }
        return result
    }
}

extension JSONEncoder {
    static var conch: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

extension JSONDecoder {
    static var conch: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

/// 快速连接的历史记录（输入的原文），存在 UserDefaults
enum QuickConnectHistory {
    private static let key = "quickConnectHistory"
    private static let limit = 8

    static func load() -> [String] {
        guard !TestHooks.isActive else { return [] }
        return UserDefaults.standard.stringArray(forKey: key) ?? []
    }

    static func remember(_ text: String) {
        guard !TestHooks.isActive else { return }
        var list = load().filter { $0 != text }
        list.insert(text, at: 0)
        UserDefaults.standard.set(Array(list.prefix(limit)), forKey: key)
    }

    static func remove(_ text: String) {
        UserDefaults.standard.set(load().filter { $0 != text }, forKey: key)
    }
}
