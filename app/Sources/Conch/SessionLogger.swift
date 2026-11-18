import ConchKit
import Foundation

/// 把一个标签页的终端输出写到日志文件。只在终端的串行喂数据队列上调用，不需要加锁。
final class SessionLogger {
    let url: URL
    private let handle: FileHandle
    private var filter: PlainTextFilter?

    init(profile: SessionProfile) throws {
        let directory = AppPaths.logDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let stamp = formatter.string(from: Date())
        let base = Self.sanitize(profile.displayName)
        var candidate = directory.appendingPathComponent("\(base)_\(stamp).log")
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(base)_\(stamp)_\(counter).log")
            counter += 1
        }
        url = candidate
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: url.path])
        }
        handle = try FileHandle(forWritingTo: url)

        let defaults = UserDefaults.standard
        if defaults.bool(forKey: Prefs.logPlainText) {
            filter = PlainTextFilter(timestamps: defaults.bool(forKey: Prefs.logTimestamps))
        }
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let header = "# Conch 会话日志：\(profile.address)，开始于 \(formatter.string(from: Date()))\n"
        try? handle.write(contentsOf: Data(header.utf8))
    }

    func write(_ data: Data) {
        let output = filter?.feed(data) ?? data
        if !output.isEmpty {
            try? handle.write(contentsOf: output)
        }
    }

    func close() {
        if var filter {
            let rest = filter.finish()
            if !rest.isEmpty { try? handle.write(contentsOf: rest) }
            self.filter = nil
        }
        try? handle.close()
    }

    /// 文件名里不能有 / 和 :，其他字符（包括中文）都保留
    private static func sanitize(_ name: String) -> String {
        let cleaned = name.map { "/:\\".contains($0) ? "_" : $0 }
        let result = String(cleaned).trimmingCharacters(in: .whitespaces)
        return result.isEmpty ? "session" : String(result.prefix(80))
    }
}
