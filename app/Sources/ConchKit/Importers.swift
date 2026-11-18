import Foundation

/// 导入结果：要加入会话列表的会话，以及给用户看的说明
public struct ImportResult: Sendable {
    public var profiles: [SessionProfile] = []
    /// 跳过的条目和原因（不是 SSH 会话、缺主机地址、文件读不了……）
    public var skipped: [String] = []

    public init(profiles: [SessionProfile] = [], skipped: [String] = []) {
        self.profiles = profiles
        self.skipped = skipped
    }
}

// MARK: - ~/.ssh/config

public enum SSHConfigImporter {
    /// 把 ssh_config 里写明的每个 Host 别名变成一个会话。
    /// ProxyJump（以及 ProxyCommand ssh -W 这种老写法）会变成跳板机设置；
    /// 跳板机如果不是配置里的别名，会额外建一个会话给它。
    public static func importProfiles(
        from config: SSHConfig,
        group: String = "SSH 配置",
        localUser: String = NSUserName(),
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> ImportResult {
        var result = ImportResult()
        var byAlias: [String: SessionProfile] = [:]
        var order: [String] = []
        var extras: [String: SessionProfile] = [:]
        var extraOrder: [String] = []

        func makeProfile(alias: String, name: String, user: String?, port: Int?) -> SessionProfile {
            let entry = config.resolve(alias, localUser: localUser, home: home)
            return SessionProfile(
                name: name,
                group: group,
                host: entry.hostName,
                port: port ?? entry.port ?? 22,
                username: user ?? entry.user ?? localUser,
                auth: .auto,
                keyPaths: entry.identityFiles,
                identitiesOnly: entry.identitiesOnly ?? false,
                identityAgent: entry.identityAgent ?? "",
                forwards: entry.forwards
            )
        }

        for alias in config.aliases {
            let key = alias.lowercased()
            byAlias[key] = makeProfile(alias: alias, name: alias, user: nil, port: nil)
            order.append(key)
        }

        // 跳板机地址 → 会话 ID（是别名就用那个会话，否则新建一个）
        func jumpID(for spec: JumpSpec) -> UUID {
            let key = spec.host.lowercased()
            if spec.user == nil, spec.port == nil, let existing = byAlias[key] {
                return existing.id
            }
            var profile = makeProfile(alias: spec.host, name: spec.host, user: spec.user, port: spec.port)
            profile.name = profile.address
            let extraKey = profile.endpointKey
            if let existing = extras[extraKey] {
                return existing.id
            }
            profile.notes = "从 ssh_config 的跳板机设置自动创建"
            extras[extraKey] = profile
            extraOrder.append(extraKey)
            return profile.id
        }

        func setJump(of id: UUID, to jump: UUID) {
            if let key = byAlias.first(where: { $0.value.id == id })?.key {
                if byAlias[key]?.jumpHostID == nil { byAlias[key]?.jumpHostID = jump }
            } else if let key = extras.first(where: { $0.value.id == id })?.key {
                if extras[key]?.jumpHostID == nil { extras[key]?.jumpHostID = jump }
            }
        }

        for key in order {
            guard let profile = byAlias[key] else { continue }
            let entry = config.resolve(profile.name, localUser: localUser, home: home)
            var specs: [JumpSpec] = []
            if let proxyJump = entry.proxyJump {
                specs = JumpSpec.parseList(proxyJump)
            } else if let command = entry.proxyCommand {
                if let spec = JumpSpec.fromProxyCommand(command) {
                    specs = [spec]
                } else {
                    byAlias[key]?.notes = "ssh_config 里的 ProxyCommand 暂不支持：\(command)"
                }
            }
            guard !specs.isEmpty else { continue }
            // ProxyJump a,b：先连 a，再经 a 连 b，最后经 b 连目标
            var previous: UUID?
            for spec in specs {
                let id = jumpID(for: spec)
                if let previous, id != previous { setJump(of: id, to: previous) }
                previous = id
            }
            if let previous, previous != profile.id {
                byAlias[key]?.jumpHostID = previous
            }
        }

        result.profiles = order.compactMap { byAlias[$0] } + extraOrder.compactMap { extras[$0] }
        return result
    }
}

// MARK: - Xshell .xsh

/// 导入 Xshell 的会话文件（.xsh，INI 格式，一般是带 BOM 的 UTF-16）。
/// 可以选单个文件，也可以选整个 Sessions 文件夹：子文件夹会变成分组。
/// Xshell 保存的密码是加密的，不导入，第一次连接时再输入。
public enum XshellImporter {
    public static func importItems(at urls: [URL], rootGroup: String = "Xshell") -> ImportResult {
        var result = ImportResult()
        let fm = FileManager.default
        for url in urls {
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue {
                // 比较路径前先解析符号链接（/var 实际是 /private/var 这类），否则算不出相对路径
                let root = url.resolvingSymlinksInPath().pathComponents
                let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: nil)
                while let file = enumerator?.nextObject() as? URL {
                    guard file.pathExtension.lowercased() == "xsh" else { continue }
                    let dir = file.resolvingSymlinksInPath().deletingLastPathComponent().pathComponents
                    let relativeDir = dir.starts(with: root) ? dir.dropFirst(root.count).joined(separator: "/") : ""
                    let base = GroupPath.join(rootGroup, url.lastPathComponent)
                    let group = relativeDir.isEmpty ? base : GroupPath.join(base, relativeDir)
                    importFile(file, group: group, into: &result)
                }
            } else {
                importFile(url, group: rootGroup, into: &result)
            }
        }
        return result
    }

    static func importFile(_ url: URL, group: String, into result: inout ImportResult) {
        let name = url.deletingPathExtension().lastPathComponent
        guard let data = try? Data(contentsOf: url) else {
            result.skipped.append("\(name)：读不了文件")
            return
        }
        switch parse(data: data, name: name, group: group) {
        case .success(let profile): result.profiles.append(profile)
        case .failure(let reason): result.skipped.append("\(name)：\(reason.message)")
        }
    }

    public struct SkipReason: Error, Sendable {
        public var message: String
    }

    public static func parse(data: Data, name: String, group: String) -> Result<SessionProfile, SkipReason> {
        guard let text = decode(data) else {
            return .failure(SkipReason(message: "无法识别文件编码"))
        }
        let ini = INI(text)
        let proto = (ini["CONNECTION", "Protocol"] ?? "SSH").uppercased()
        guard proto == "SSH" || proto == "TELNET" else {
            let why = proto == "SERIAL" ? "是串口会话，Windows 的 COM 口设置在 Mac 上用不了，请在 Conch 里新建串口会话" : "是 \(proto) 会话，目前只导入 SSH 和 Telnet"
            return .failure(SkipReason(message: why))
        }
        let host = (ini["CONNECTION", "Host"] ?? "").trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty else {
            return .failure(SkipReason(message: "没有主机地址"))
        }
        var profile = SessionProfile(name: name, group: group, host: host)
        if proto == "TELNET" {
            profile.kind = .telnet
            profile.port = 23
        }
        if let port = ini["CONNECTION", "Port"].flatMap({ Int($0) }), (1...65535).contains(port) {
            profile.port = port
        }
        if let user = ini["CONNECTION:AUTHENTICATION", "UserName"], !user.isEmpty {
            profile.username = user
        }
        var notes: [String] = []
        let userKey = ini["CONNECTION:AUTHENTICATION", "UserKey"] ?? ""
        let method = ini["CONNECTION:AUTHENTICATION", "Method"] ?? ""
        if !userKey.isEmpty {
            // Xshell 的用户密钥存在它自己的密钥库里，需要先导出成 OpenSSH 格式的私钥文件
            profile.auth = .auto
            notes.append("Xshell 里用的是用户密钥“\(userKey)”，请在 Xshell 里导出成私钥文件后，在会话里选择它")
        } else if method == "0" {
            profile.auth = .password
        }
        if let description = ini["SessionInfo", "Description"], !description.isEmpty,
           description != "Xshell session file"
        {
            notes.append(description)
        }
        profile.notes = notes.joined(separator: "\n")
        return .success(profile)
    }

    /// .xsh 常见的编码：带 BOM 的 UTF-16LE（Xshell 5 以后）、UTF-8、老版本的 GBK
    static func decode(_ data: Data) -> String? {
        let bytes = [UInt8](data.prefix(3))
        if bytes.starts(with: [0xFF, 0xFE]) { return String(data: data.dropFirst(2), encoding: .utf16LittleEndian) }
        if bytes.starts(with: [0xFE, 0xFF]) { return String(data: data.dropFirst(2), encoding: .utf16BigEndian) }
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { return String(data: data.dropFirst(3), encoding: .utf8) }
        // 没有 BOM 的 UTF-16LE：ASCII 字符后面跟着 0
        if data.count >= 4, data[data.startIndex + 1] == 0, data[data.startIndex + 3] == 0 {
            return String(data: data, encoding: .utf16LittleEndian)
        }
        if let utf8 = String(data: data, encoding: .utf8) { return utf8 }
        let gb18030 = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
        return String(data: data, encoding: String.Encoding(rawValue: gb18030))
    }
}

/// 最简单的 INI 解析：[节]、键=值，节名和键名不区分大小写
struct INI {
    private var values: [String: [String: String]] = [:]

    init(_ text: String) {
        var section = ""
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix(";") || line.hasPrefix("#") { continue }
            if line.hasPrefix("["), line.hasSuffix("]") {
                section = String(line.dropFirst().dropLast()).lowercased()
                continue
            }
            guard let equals = line.firstIndex(of: "=") else { continue }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            values[section, default: [:]][key] = value
        }
    }

    subscript(section: String, key: String) -> String? {
        values[section.lowercased()]?[key.lowercased()]
    }
}
