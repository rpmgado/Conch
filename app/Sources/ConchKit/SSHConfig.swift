import Foundation

/// 解析 OpenSSH 客户端配置（~/.ssh/config），用来导入会话、解析快速连接里的别名。
///
/// 支持 Host 块（通配符、取反）、Include、Key Value / Key=Value 两种写法、引号；
/// 取值规则和 OpenSSH 一样“第一个出现的值生效”，所以 Host * 里的默认值放在后面也能正确兜底。
/// Match 块条件太多，统一当作不匹配。
public struct SSHConfig: Sendable {
    struct Block: Sendable {
        /// nil 表示文件开头、第一个 Host 之前的全局部分
        var patterns: [String]?
        var isMatch = false
        var options: [(key: String, value: String)] = []
    }

    var blocks: [Block] = []

    /// 配置里写明的具体主机别名（不含通配符），按出现顺序
    public private(set) var aliases: [String] = []

    public init() {}

    public static func load(from url: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> SSHConfig {
        var config = SSHConfig()
        config.blocks = [Block(patterns: nil)]
        config.read(url: url, home: home, depth: 0)
        config.collectAliases()
        return config
    }

    public static func parse(_ text: String, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> SSHConfig {
        var config = SSHConfig()
        config.blocks = [Block(patterns: nil)]
        config.read(text: text, home: home, depth: 0)
        config.collectAliases()
        return config
    }

    private mutating func read(url: URL, home: URL, depth: Int) {
        guard depth < 16,
              let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8)
        else { return }
        read(text: text, home: home, depth: depth)
    }

    private mutating func read(text: String, home: URL, depth: Int) {
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard let (key, value) = Self.splitKeyValue(line) else { continue }
            switch key {
            case "host":
                blocks.append(Block(patterns: Self.words(value)))
            case "match":
                blocks.append(Block(patterns: [], isMatch: true))
            case "include":
                // 相对路径相对于 ~/.ssh；被包含的文件就地展开（和 OpenSSH 一样）
                for pattern in Self.words(value) {
                    let expanded = Self.expandTilde(pattern, home: home)
                    let absolute = expanded.hasPrefix("/") ? expanded : home.appendingPathComponent(".ssh/\(expanded)").path
                    for path in Self.glob(absolute) {
                        read(url: URL(fileURLWithPath: path), home: home, depth: depth + 1)
                    }
                }
            default:
                blocks[blocks.count - 1].options.append((key, value))
            }
        }
    }

    private mutating func collectAliases() {
        var seen = Set<String>()
        for block in blocks where !block.isMatch {
            for pattern in block.patterns ?? [] {
                let concrete = !pattern.contains("*") && !pattern.contains("?") && !pattern.hasPrefix("!")
                if concrete, seen.insert(pattern.lowercased()).inserted {
                    aliases.append(pattern)
                }
            }
        }
    }

    // MARK: 取值

    /// 某个别名最终生效的配置
    public func resolve(_ alias: String, localUser: String = NSUserName(),
                        home: URL = FileManager.default.homeDirectoryForCurrentUser) -> SSHConfigEntry {
        var first: [String: String] = [:]
        var identityFiles: [String] = []
        var forwards: [ForwardRule] = []
        for block in blocks where matches(block, alias) {
            for (key, value) in block.options {
                if key == "identityfile" {
                    // IdentityFile 可以写多次，全部累加
                    identityFiles.append(value)
                } else if let kind = Self.forwardKinds[key] {
                    // 端口转发也可以写多条
                    if let rule = ForwardRule.parse(kind: kind, value: value) { forwards.append(rule) }
                } else if first[key] == nil {
                    first[key] = value
                }
            }
        }

        var entry = SSHConfigEntry(alias: alias)
        entry.hostName = first["hostname"].map { $0.replacingOccurrences(of: "%h", with: alias) } ?? alias
        entry.port = first["port"].flatMap { Int($0) }
        entry.user = first["user"]
        entry.identitiesOnly = first["identitiesonly"].map { $0.lowercased() == "yes" }
        entry.proxyJump = first["proxyjump"].flatMap { $0.lowercased() == "none" ? nil : $0 }
        entry.proxyCommand = first["proxycommand"].flatMap { $0.lowercased() == "none" ? nil : $0 }
        entry.forwards = forwards

        let tokens: [Character: String] = [
            "d": home.path,
            "u": localUser,
            "h": entry.hostName,
            "n": alias,
            "r": entry.user ?? localUser,
            "p": String(entry.port ?? 22),
        ]
        entry.identityFiles = identityFiles
            .filter { $0.lowercased() != "none" }
            .map { Self.expandTokens(Self.expandTilde($0, home: home), tokens) }
        if let agent = first["identityagent"] {
            if agent.lowercased() == "none" || agent == "SSH_AUTH_SOCK" {
                entry.identityAgent = agent.lowercased() == "none" ? "none" : ""
            } else if agent.hasPrefix("$") {
                // IdentityAgent $SOME_ENV：读环境变量
                entry.identityAgent = ProcessInfo.processInfo.environment[String(agent.dropFirst())] ?? ""
            } else {
                entry.identityAgent = Self.expandTokens(Self.expandTilde(agent, home: home), tokens)
            }
        }
        return entry
    }

    private static let forwardKinds: [String: ForwardRule.Kind] = [
        "localforward": .local,
        "remoteforward": .remote,
        "dynamicforward": .dynamic,
    ]

    /// 别名有没有在配置里出现（包括被某个 Host 块的具体名字列出来）
    public func knows(_ alias: String) -> Bool {
        aliases.contains { $0.caseInsensitiveCompare(alias) == .orderedSame }
    }

    private func matches(_ block: Block, _ alias: String) -> Bool {
        if block.isMatch { return false }
        guard let patterns = block.patterns else { return true }
        var positive = false
        for pattern in patterns {
            if pattern.hasPrefix("!") {
                if Self.wildcard(String(pattern.dropFirst()), alias) { return false }
            } else if Self.wildcard(pattern, alias) {
                positive = true
            }
        }
        return positive
    }

    // MARK: 文本处理

    /// "Key value"、"Key=value"、"Key = value"
    static func splitKeyValue(_ line: String) -> (String, String)? {
        guard let separator = line.firstIndex(where: { $0 == " " || $0 == "\t" || $0 == "=" }) else {
            return nil
        }
        let key = line[..<separator].lowercased()
        var rest = line[separator...].drop { $0 == " " || $0 == "\t" }
        if rest.first == "=" {
            rest = rest.dropFirst().drop { $0 == " " || $0 == "\t" }
        }
        var value = String(rest).trimmingCharacters(in: .whitespaces)
        // 整个值用引号括起来时去掉引号（路径里有空格时常见）
        if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\""), !key.isEmpty, key != "host" {
            value = String(value.dropFirst().dropLast())
        }
        return key.isEmpty ? nil : (key, value)
    }

    /// 按空白拆分，支持双引号
    static func words(_ text: String) -> [String] {
        var result: [String] = []
        var current = ""
        var quoted = false
        for ch in text {
            if ch == "\"" {
                quoted.toggle()
            } else if (ch == " " || ch == "\t") && !quoted {
                if !current.isEmpty { result.append(current); current = "" }
            } else {
                current.append(ch)
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    static func wildcard(_ pattern: String, _ text: String) -> Bool {
        fnmatch(pattern.lowercased(), text.lowercased(), 0) == 0
    }

    static func expandTilde(_ path: String, home: URL) -> String {
        if path == "~" { return home.path }
        if path.hasPrefix("~/") { return home.path + path.dropFirst(1) }
        return path
    }

    static func expandTokens(_ text: String, _ tokens: [Character: String]) -> String {
        var result = ""
        var iterator = text.makeIterator()
        while let ch = iterator.next() {
            guard ch == "%" else { result.append(ch); continue }
            guard let next = iterator.next() else { result.append("%"); break }
            if next == "%" {
                result.append("%")
            } else if let value = tokens[next] {
                result += value
            } else {
                result += "%\(next)"
            }
        }
        return result
    }

    static func glob(_ pattern: String) -> [String] {
        var g = glob_t()
        defer { globfree(&g) }
        guard Darwin.glob(pattern, 0, nil, &g) == 0 else { return [] }
        return (0..<Int(g.gl_pathc)).compactMap { index in
            g.gl_pathv[index].map { String(cString: $0) }
        }.sorted()
    }
}

/// 某个别名解析出来的配置
public struct SSHConfigEntry: Equatable, Sendable {
    public var alias: String
    public var hostName: String = ""
    public var port: Int?
    public var user: String?
    public var identityFiles: [String] = []
    public var identitiesOnly: Bool?
    /// nil 表示没设置；"" 表示用 SSH_AUTH_SOCK；"none" 表示不用 agent
    public var identityAgent: String?
    public var proxyJump: String?
    public var proxyCommand: String?
    /// LocalForward / RemoteForward / DynamicForward
    public var forwards: [ForwardRule] = []

    public init(alias: String) {
        self.alias = alias
        self.hostName = alias
    }
}

/// 跳板机地址 "user@host:port" 或别名，ProxyJump 里用逗号分隔多个
public struct JumpSpec: Equatable, Sendable {
    public var user: String?
    public var host: String
    public var port: Int?

    public init(user: String? = nil, host: String, port: Int? = nil) {
        self.user = user
        self.host = host
        self.port = port
    }

    /// "user@host:port"、"host"、"user@[::1]:22"、"ssh://user@host:port"
    public static func parse(_ text: String) -> JumpSpec? {
        var rest = text.trimmingCharacters(in: .whitespaces)
        if rest.hasPrefix("ssh://") { rest.removeFirst(6) }
        guard !rest.isEmpty else { return nil }
        var user: String?
        if let at = rest.lastIndex(of: "@") {
            user = String(rest[..<at])
            rest = String(rest[rest.index(after: at)...])
        }
        var port: Int?
        if rest.hasPrefix("["), let close = rest.firstIndex(of: "]") {
            let host = String(rest[rest.index(after: rest.startIndex)..<close])
            let after = rest[rest.index(after: close)...]
            if after.hasPrefix(":") { port = Int(after.dropFirst()) }
            rest = host
        } else if rest.filter({ $0 == ":" }).count == 1, let colon = rest.firstIndex(of: ":") {
            port = Int(rest[rest.index(after: colon)...])
            rest = String(rest[..<colon])
        }
        guard !rest.isEmpty else { return nil }
        return JumpSpec(user: user?.isEmpty == true ? nil : user, host: rest, port: port)
    }

    public static func parseList(_ text: String) -> [JumpSpec] {
        text.split(separator: ",").compactMap { parse(String($0)) }
    }

    /// 老式写法 ProxyCommand ssh -W %h:%p jump 等价于 ProxyJump jump
    public static func fromProxyCommand(_ command: String) -> JumpSpec? {
        let words = SSHConfig.words(command)
        guard let program = words.first, program == "ssh" || program.hasSuffix("/ssh"),
              words.contains("-W")
        else { return nil }
        var user: String?
        var port: Int?
        var host: String?
        var index = 1
        let takesValue: Set<String> = ["-W", "-p", "-l", "-i", "-o", "-F", "-J", "-b", "-c", "-m", "-E", "-S"]
        while index < words.count {
            let word = words[index]
            if word == "-p", index + 1 < words.count {
                port = Int(words[index + 1])
            } else if word == "-l", index + 1 < words.count {
                user = words[index + 1]
            }
            if takesValue.contains(word) {
                index += 2
                continue
            }
            if !word.hasPrefix("-") { host = word }
            index += 1
        }
        guard let host, var spec = parse(host) else { return nil }
        if spec.user == nil { spec.user = user }
        if spec.port == nil { spec.port = port }
        return spec
    }
}
