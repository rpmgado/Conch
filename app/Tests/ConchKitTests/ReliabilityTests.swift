import Foundation
import Testing
@testable import ConchKit

@Suite("SSH 命令的 Shell 参数安全")
struct ShellCommandSafetyTests {
    private func arguments(_ command: String) throws -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        // 用函数替身接收参数，绝不建立真实 SSH 连接。
        process.arguments = ["-f", "-c", "ssh() { printf '%s\\0' \"$@\"; }; " + command]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        return data.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
    }

    @Test("IPv6 的方括号不会触发 zsh 通配符")
    func ipv6() throws {
        let target = SessionProfile(host: "example.invalid", username: "ops")
        let jump = SessionProfile(host: "fe80::2", port: 2222, username: "ops")
        #expect(try arguments(target.sshCommand(jumps: [jump])!) == ["-J", "ops@[fe80::2]:2222", "ops@example.invalid"])
    }

    @Test("跳板机参数中的引号、分号和命令替换保持字面值")
    func shellCharacters() throws {
        let text = "ops'; printf INJECTED; # $(printf BAD)"
        let target = SessionProfile(host: "example.invalid", username: "ops")
        let jump = SessionProfile(host: "jump.invalid", username: text)
        #expect(try arguments(target.sshCommand(jumps: [jump])!) == ["-J", text + "@jump.invalid", "ops@example.invalid"])
    }

    @Test("带空格和方括号的私钥路径只展开家目录")
    func keyPath() throws {
        let target = SessionProfile(host: "example.invalid", username: "ops", auth: .key, keyPaths: ["~/My Keys/[key]'id"])
        #expect(try arguments(target.sshCommand()!) == ["-i", NSHomeDirectory() + "/My Keys/[key]'id", "ops@example.invalid"])
    }
}

@Suite("远端拖放的连接归属")
struct RemoteDragSafetyTests {
    @Test("同连接允许，不同窗口和重连后的连接拒绝")
    func connectionScope() throws {
        let origin = UUID()
        let payload = RemoteFilesDrag(sourceID: origin, paths: ["/etc/config"])
        let decoded = try JSONDecoder().decode(RemoteFilesDrag.self, from: JSONEncoder().encode(payload))
        #expect(decoded.paths(for: origin) == ["/etc/config"])
        #expect(decoded.paths(for: UUID()) == nil)
    }
    @Test("没有来源的旧拖放数据不能被误当成当前连接")
    func legacyPayload() {
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(RemoteFilesDrag.self, from: Data(#"{"paths":["/etc/config"]}"#.utf8))
        }
    }
}

private final class SyncFixture {
    let root: URL
    let local: URL
    let shared: URL
    let parked: URL
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("conch-sync-test-" + UUID().uuidString)
        local = root.appendingPathComponent("local/sessions.json")
        shared = root.appendingPathComponent("shared/sessions.json")
        parked = root.appendingPathComponent("offline")
        try FileManager.default.createDirectory(at: local.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: shared.deletingLastPathComponent(), withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: root) }
    func write(_ library: SessionLibrary, to url: URL) throws {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(library).write(to: url, options: .atomic)
    }
    func read(_ url: URL) throws -> SessionLibrary {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(SessionLibrary.self, from: Data(contentsOf: url))
    }
    func disconnect() throws { try FileManager.default.moveItem(at: shared.deletingLastPathComponent(), to: parked) }
    func reconnect() throws { try FileManager.default.moveItem(at: parked, to: shared.deletingLastPathComponent()) }
}

@Suite("会话同步离线恢复")
struct SessionSyncRecoveryTests {
    @Test("离线修改、删除、新增，重启后恢复同步仍然有效")
    func offlineRestart() throws {
        let f = try SyncFixture()
        let original = SessionProfile(name: "before", host: "example.invalid")
        let deleted = SessionProfile(name: "delete", host: "old.invalid")
        let initial = SessionLibrary(sessions: [original, deleted], groups: ["旧分组"])
        try f.write(initial, to: f.shared)
        let first = try SessionRepository(localURL: f.local, syncURL: f.shared)
        try f.disconnect()
        try first.update {
            var edited = original; edited.name = "after"; $0.upsert(edited)
            $0.remove(ids: [deleted.id]); $0.upsert(SessionProfile(name: "new", host: "new.invalid"))
            $0.removeGroup("旧分组"); $0.addGroup("新分组")
        }
        #expect(first.waitingForSyncFolder)
        let restarted = try SessionRepository(localURL: f.local, syncURL: f.shared)
        #expect(restarted.library.session(original.id)?.name == "after")
        try f.reconnect()
        try restarted.refresh()
        let result = try f.read(f.shared)
        #expect(result.session(original.id)?.name == "after")
        #expect(result.session(deleted.id) == nil)
        #expect(result.sessions.contains { $0.name == "new" })
        #expect(result.groups == ["新分组"])
        #expect(!restarted.waitingForSyncFolder)
        let again = try SessionRepository(localURL: f.local, syncURL: f.shared)
        #expect(again.library == result)
    }

    @Test("双方修改不同字段自动合并，远端新增也保留")
    func independentChanges() throws {
        let f = try SyncFixture()
        let original = SessionProfile(name: "before", host: "example.invalid")
        try f.write(SessionLibrary(sessions: [original]), to: f.shared)
        let repository = try SessionRepository(localURL: f.local, syncURL: f.shared)
        try f.disconnect()
        try repository.update { var p = original; p.name = "local"; $0.upsert(p) }
        var remote = original; remote.port = 2222
        let added = SessionProfile(name: "remote-added", host: "remote.invalid")
        try f.write(SessionLibrary(sessions: [remote, added]), to: f.parked.appendingPathComponent("sessions.json"))
        try f.reconnect(); try repository.refresh()
        #expect(repository.library.session(original.id)?.name == "local")
        #expect(repository.library.session(original.id)?.port == 2222)
        #expect(repository.library.session(added.id) != nil)
        #expect(repository.message == nil)
    }

    @Test("同一字段冲突时备份双方，并且不会删除本机修改")
    func conflictBackup() throws {
        let f = try SyncFixture()
        let original = SessionProfile(name: "before", host: "example.invalid")
        try f.write(SessionLibrary(sessions: [original]), to: f.shared)
        let repository = try SessionRepository(localURL: f.local, syncURL: f.shared)
        try f.disconnect()
        try repository.update { var p = original; p.name = "local"; $0.upsert(p) }
        var remote = original; remote.name = "remote"
        try f.write(SessionLibrary(sessions: [remote]), to: f.parked.appendingPathComponent("sessions.json"))
        try f.reconnect(); try repository.refresh()
        #expect(repository.library.session(original.id)?.name == "local")
        #expect(repository.message?.contains("冲突") == true)
        let files = try FileManager.default.contentsOfDirectory(at: f.local.deletingLastPathComponent().appendingPathComponent("Sync Conflicts"), includingPropertiesForKeys: nil)
        #expect(files.count == 1)
        let backup = try #require(files.first)
        let json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: backup)) as? [String: Any])
        let remoteCopy = try #require(json["remote"] as? [String: Any])
        let profiles = try #require(remoteCopy["sessions"] as? [[String: Any]])
        #expect(profiles.first?["name"] as? String == "remote")
    }

    @Test("同步文件暂时损坏时保留本机修改，不用空库覆盖远端")
    func corruptRemote() throws {
        let f = try SyncFixture()
        let original = SessionProfile(name: "before", host: "example.invalid")
        let initial = SessionLibrary(sessions: [original])
        try f.write(initial, to: f.shared)
        let repository = try SessionRepository(localURL: f.local, syncURL: f.shared)
        try Data("incomplete json".utf8).write(to: f.shared)
        try repository.update { var p = original; p.name = "kept"; $0.upsert(p) }
        #expect(try String(contentsOf: f.shared, encoding: .utf8) == "incomplete json")
        try f.write(initial, to: f.shared); try repository.refresh()
        #expect(repository.library.session(original.id)?.name == "kept")
    }

    @Test("iCloud 占位文件不会被当成空会话库覆盖")
    func placeholder() throws {
        let f = try SyncFixture()
        try Data().write(to: f.shared.deletingLastPathComponent().appendingPathComponent(".sessions.json.icloud"))
        let repository = try SessionRepository(localURL: f.local, syncURL: f.shared)
        try repository.update { $0.addGroup("pending") }
        #expect(repository.waitingForSyncFolder)
        #expect(!FileManager.default.fileExists(atPath: f.shared.path))
    }

    @Test("本机写盘失败后刷新不会用旧数据覆盖内存修改")
    func localWriteFailure() throws {
        let f = try SyncFixture()
        let original = SessionProfile(name: "before", host: "example.invalid")
        try f.write(SessionLibrary(sessions: [original]), to: f.local)
        let repository = try SessionRepository(localURL: f.local)
        #expect(throws: (any Error).self) {
            try repository.update { library in
                var edited = original; edited.name = "pending"; library.upsert(edited)
                try! FileManager.default.removeItem(at: f.local)
                try! FileManager.default.createDirectory(at: f.local, withIntermediateDirectories: false)
            }
        }
        #expect(throws: (any Error).self) { try repository.refresh() }
        #expect(repository.library.session(original.id)?.name == "pending")
        try FileManager.default.removeItem(at: f.local)
        try repository.refresh()
        #expect(try f.read(f.local).session(original.id)?.name == "pending")
    }

    @Test("启用同步合并本机记录，停用同步保留当前版本")
    func enableDisable() throws {
        let f = try SyncFixture()
        let ours = SessionProfile(name: "ours", host: "local.invalid")
        let theirs = SessionProfile(name: "theirs", host: "remote.invalid")
        try f.write(SessionLibrary(sessions: [ours]), to: f.local)
        try f.write(SessionLibrary(sessions: [theirs]), to: f.shared)
        let repository = try SessionRepository(localURL: f.local)
        try repository.relocate(to: f.shared, mergeCurrent: true)
        #expect(Set(repository.library.sessions.map(\.id)) == [ours.id, theirs.id])
        try repository.relocate(to: nil, mergeCurrent: false)
        #expect(repository.fileURL == f.local)
        #expect(try f.read(f.local) == repository.library)
        #expect(!FileManager.default.fileExists(atPath: f.local.deletingLastPathComponent().appendingPathComponent("sessions-sync-state.json").path))
    }

    @Test("删除跳板机会清理引用，环境标签的离线删除不会恢复")
    func relatedState() {
        let jump = SessionProfile(host: "jump.invalid")
        let child = SessionProfile(host: "host.invalid", jumpHostID: jump.id)
        let base = SessionLibrary(sessions: [jump, child], groups: ["env"], environments: ["env": .production])
        var local = base; local.remove(ids: [jump.id]); local.setEnvironment(nil, forGroup: "env")
        let result = SessionSyncMerge(base: base, local: local, remote: base)
        #expect(result.library.session(jump.id) == nil)
        #expect(result.library.session(child.id)?.jumpHostID == nil)
        #expect(result.library.environments["env"] == nil)
    }
}
