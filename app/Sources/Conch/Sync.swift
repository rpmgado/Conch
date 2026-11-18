import ConchKit
import Foundation
import LocalAuthentication

/// 会话同步：会话列表、分组和快捷命令放进一个同步文件夹（iCloud 云盘、坚果云、群晖或飞牛的同步盘……），
/// 几台 Mac 选同一个文件夹就能共用。保存的密码在各自的钥匙串里，信任过的主机密钥也留在各自的 Mac 上，都不同步。
enum SyncSettings {
    static let sessionsFileName = "sessions.json"
    static let quickCommandsFileName = "quick-commands.json"

    /// 同步文件夹；nil 表示没开同步
    static var directory: URL? {
        if TestHooks.isActive { return TestHooks.syncDirectory }
        let path = UserDefaults.standard.string(forKey: Prefs.syncDirectory) ?? ""
        return path.isEmpty ? nil : URL(fileURLWithPath: path, isDirectory: true)
    }

    /// 同步文件夹现在能不能用（在移动硬盘、NAS 上的可能还没挂上）
    static var directoryAvailable: Bool {
        guard let directory else { return false }
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    /// iCloud 云盘的根目录（没开 iCloud 云盘时为 nil）
    static var iCloudDriveRoot: URL? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// 打开同步：本机的会话和快捷命令并进同步文件夹（那边已经有的以那边为准）
    static func enable(_ directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // 先加载本机数据，再改变存储位置；首次调用时 shared 尚未初始化也不能丢本机记录。
        let sessions = SessionStore.shared
        let commands = QuickCommandStore.shared
        if TestHooks.isActive {
            TestHooks.syncDirectory = directory
        } else {
            UserDefaults.standard.set(directory.path, forKey: Prefs.syncDirectory)
        }
        sessions.relocate(to: directory.appendingPathComponent(sessionsFileName), mergeCurrent: true)
        commands.relocate(to: directory.appendingPathComponent(quickCommandsFileName), mergeCurrent: true)
    }

    /// 关闭同步：当前的会话和快捷命令在本机留一份，以后只改本机的
    static func disable() {
        if TestHooks.isActive {
            TestHooks.syncDirectory = nil
        } else {
            UserDefaults.standard.set("", forKey: Prefs.syncDirectory)
        }
        SessionStore.shared.relocate(to: AppPaths.localSessionsFile, mergeCurrent: false)
        QuickCommandStore.shared.relocate(to: nil, mergeCurrent: false)
    }
}

/// 一个可能被别处（另一台 Mac 通过同步盘、或者手动）修改的 JSON 文件：记住上次读写时的修改时间，变了就要重新读
final class WatchedJSONFile {
    let url: URL
    private var knownModified: Date?

    init(url: URL) {
        self.url = url
    }

    private var modified: Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    var changedOnDisk: Bool {
        modified != knownModified
    }

    /// 文件不存在时返回 nil；内容坏了抛错
    func read<T: Decodable>(_ type: T.Type) throws -> T? {
        requestDownloadIfNeeded()
        let stamp = modified
        guard FileManager.default.fileExists(atPath: url.path) else {
            knownModified = nil
            return nil
        }
        let data = try Data(contentsOf: url)
        let value = try JSONDecoder.conch.decode(T.self, from: data)
        // 用读之前的时间：读的过程中又被改了，下次检查还会再读
        knownModified = stamp
        return value
    }

    /// 不会自动建目录：同步文件夹没挂上时写失败，而不是在别处凭空建一个
    func write<T: Encodable>(_ value: T) throws {
        let data = try JSONEncoder.conch.encode(value)
        try data.write(to: url, options: .atomic)
        knownModified = modified
    }

    /// iCloud 云盘里还没下载到这台 Mac 的文件只是个占位文件（.sessions.json.icloud），先让系统下载
    private func requestDownloadIfNeeded() {
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        let placeholder = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).icloud")
        if FileManager.default.fileExists(atPath: placeholder.path) {
            try? FileManager.default.startDownloadingUbiquitousItem(at: url)
        }
    }
}

/// “使用保存的密码前验证身份”：Touch ID，或者 Mac 的登录密码。验证通过后 5 分钟内不再问
enum SecretGate {
    static let gracePeriod: TimeInterval = 300

    private static let lock = NSLock()
    /// 同时有几个标签页要用密码时排队，第一个验证通过后其他的直接用
    private static let evaluation = NSLock()
    private static var lastSuccess: Date?
    private static var prompts = 0

    static var enabled: Bool {
        TestHooks.requireAuth ?? UserDefaults.standard.bool(forKey: Prefs.requireAuthForSecrets)
    }

    /// 弹过几次验证（测试用）
    static var promptCount: Int {
        lock.lock(); defer { lock.unlock() }
        return prompts
    }

    /// 在后台线程调用，等用户验证完才返回。返回 false 表示不能用保存的密码
    static func authorize(reason: String) -> Bool {
        guard enabled else { return true }
        evaluation.lock()
        defer { evaluation.unlock() }
        lock.lock()
        if let last = lastSuccess, Date().timeIntervalSince(last) < gracePeriod {
            lock.unlock()
            return true
        }
        prompts += 1
        lock.unlock()

        let context = LAContext()
        var policyError: NSError?
        let available = TestHooks.authUnavailable ? false :
            (TestHooks.authAnswer != nil || context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &policyError))
        // 保护开启时，系统不能验证身份也必须拒绝读取保存的密码。
        guard available else { return false }
        let granted: Bool
        if let answer = TestHooks.authAnswer {
            granted = answer
        } else {
            let done = DispatchSemaphore(value: 0)
            var success = false
            context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { ok, _ in
                success = ok
                done.signal()
            }
            done.wait()
            granted = success
        }
        if granted {
            lock.lock()
            lastSuccess = Date()
            lock.unlock()
        }
        return granted
    }
}
