import ConchKit
import Foundation
import Security

/// 钥匙串里一条秘密信息对应的键。
/// 密码按“用户@主机:端口”存，同一台服务器的不同会话共用；
/// 私钥口令按私钥文件存，因为口令属于那把私钥，在哪个会话里用都一样。
enum SecretKey: Hashable {
    case password(endpoint: String)
    case passphrase(keyPath: String)

    static func password(user: String, host: String, port: Int) -> SecretKey {
        .password(endpoint: "\(user.lowercased())@\(host.lowercased()):\(port)")
    }

    static func password(for profile: SessionProfile) -> SecretKey {
        password(user: profile.username, host: profile.host, port: profile.port)
    }

    static func passphrase(path: String) -> SecretKey {
        .passphrase(keyPath: (path as NSString).expandingTildeInPath)
    }

    var account: String {
        switch self {
        case .password(let endpoint): "password:\(endpoint)"
        case .passphrase(let path): "passphrase:\(path)"
        }
    }

    /// 钥匙串访问.app 里看到的名字
    var label: String {
        switch self {
        case .password(let endpoint): "Conch：\(endpoint) 的密码"
        case .passphrase(let path): "Conch：私钥 \((path as NSString).abbreviatingWithTildeInPath) 的口令"
        }
    }
}

/// 读写登录钥匙串。这些调用可能阻塞（钥匙串上锁时系统会弹窗要密码），尽量在后台线程调用。
enum Keychain {
    static var service: String { TestHooks.keychainService ?? "Conch" }

    private static func baseQuery(_ key: SecretKey) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.account,
        ]
    }

    static func load(_ key: SecretKey) -> String? {
        var query = baseQuery(key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// 只查有没有，不读内容（不会触发钥匙串授权弹窗）
    static func exists(_ key: SecretKey) -> Bool {
        var query = baseQuery(key)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        return SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess
    }

    @discardableResult
    static func save(_ value: String, for key: SecretKey) -> Bool {
        let data = Data(value.utf8)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrLabel as String: key.label,
        ]
        var status = SecItemUpdate(baseQuery(key) as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = baseQuery(key)
            item.merge(attributes) { $1 }
            item[kSecAttrDescription as String] = "Conch SSH"
            status = SecItemAdd(item as CFDictionary, nil)
        }
        if status != errSecSuccess {
            NSLog("Conch：保存到钥匙串失败（\(status)）：\(key.label)")
        }
        return status == errSecSuccess
    }

    static func delete(_ key: SecretKey) {
        SecItemDelete(baseQuery(key) as CFDictionary)
    }

    /// 自动化测试结束时清掉测试服务名下的所有条目（正常使用时不会调用）
    static func deleteAllForTests() {
        guard let service = TestHooks.keychainService else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        while SecItemDelete(query as CFDictionary) == errSecSuccess {}
    }
}

/// 一个标签页在内存里记住的密码和口令：自动重连时不用再问。
/// 用户没勾选“记住”的密码只放在这里，标签页关掉就没了。
final class SessionSecrets: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [SecretKey: String] = [:]

    func get(_ key: SecretKey) -> String? {
        lock.lock(); defer { lock.unlock() }
        return values[key]
    }

    func set(_ key: SecretKey, _ value: String) {
        lock.lock(); defer { lock.unlock() }
        values[key] = value
    }

    func remove(_ key: SecretKey) {
        lock.lock(); defer { lock.unlock() }
        values.removeValue(forKey: key)
    }

    func copy() -> SessionSecrets {
        lock.lock(); defer { lock.unlock() }
        let other = SessionSecrets()
        other.values = values
        return other
    }
}
