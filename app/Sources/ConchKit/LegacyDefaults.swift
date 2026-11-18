import Foundation

/// 换 App 标识（Bundle ID）以后，把旧标识下的设置搬到新标识下。
/// 0.3 及以前的标识是 dev.conch.prototype，0.4 起是 com.conch.gado。
/// 会话、快捷命令和已信任的主机在 ~/Library/Application Support/Conch，
/// 密码在钥匙串里（服务名 Conch），都跟标识无关，不用搬。
public enum LegacyDefaults {
    public static let previousDomain = "dev.conch.prototype"
    /// 搬过以后记一笔，以后不再搬：用户后来改掉、删掉的设置不会又冒出来
    public static let migratedKey = "migratedFromPreviousBundleID"

    /// 0.3 的终端配色默认是“跟随系统”，0.4 起默认跟随界面主题。
    /// 旧设置里存的还是老默认值时不搬，让新的默认生效
    static let previousDefaults: [String: String] = ["themeID": "system"]

    /// 要写进新标识的设置（含“已经搬过”的记号）：新标识下已经有的不覆盖，老默认值不搬。
    /// 没有旧设置（新用户）时只有记号
    public static func valuesToWrite(old: [String: Any]?, existing: [String: Any]) -> [String: Any] {
        var values = (old ?? [:]).filter { key, value in
            guard existing[key] == nil else { return false }
            if let previous = previousDefaults[key], value as? String == previous { return false }
            return true
        }
        values[migratedKey] = true
        return values
    }

    /// 第一次以新标识启动时搬一次。
    /// - Parameters:
    ///   - defaults: 新标识的设置（App 里就是 UserDefaults.standard）
    ///   - current: 新标识；nil（不是从 .app 里运行）或者和旧标识一样时什么都不做
    public static func migrate(_ defaults: UserDefaults, from previous: String = previousDomain, to current: String?) {
        guard let current, current != previous, !defaults.bool(forKey: migratedKey) else { return }
        let values = valuesToWrite(
            old: defaults.persistentDomain(forName: previous),
            existing: defaults.persistentDomain(forName: current) ?? [:]
        )
        for (key, value) in values {
            defaults.set(value, forKey: key)
        }
    }
}
