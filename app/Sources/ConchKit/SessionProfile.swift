import Foundation

/// 认证方式（对应内核的 AuthMethod）
public enum AuthKind: String, Codable, CaseIterable, Identifiable, Sendable {
    /// 和 OpenSSH 一样依次试 ssh-agent、私钥、密码
    case auto
    case password
    case key
    case agent

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .auto: "自动"
        case .password: "密码"
        case .key: "私钥"
        case .agent: "ssh-agent"
        }
    }
}

/// 连接方式
public enum ConnectionKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case ssh
    /// 明文协议，一般只用于内网的网络设备、老系统
    case telnet
    /// 本机的串口（USB 转串口线接交换机、路由器的 Console 口）
    case serial

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .ssh: "SSH"
        case .telnet: "Telnet"
        case .serial: "串口"
        }
    }
}

/// 串口参数
public struct SerialSettings: Codable, Hashable, Sendable {
    public var path: String
    public var baudRate: Int
    public var dataBits: Int
    /// none / even / odd
    public var parity: String
    public var stopBits: Int
    /// none / hardware（RTS/CTS）/ software（XON/XOFF）
    public var flowControl: String

    public init(path: String = "", baudRate: Int = 9600, dataBits: Int = 8, parity: String = "none",
                stopBits: Int = 1, flowControl: String = "none") {
        self.path = path
        self.baudRate = baudRate
        self.dataBits = dataBits
        self.parity = parity
        self.stopBits = stopBits
        self.flowControl = flowControl
    }

    /// 缺了哪个字段就用默认值（老版本、别的设备同步过来的数据）
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        path = try c.decodeIfPresent(String.self, forKey: .path) ?? ""
        baudRate = try c.decodeIfPresent(Int.self, forKey: .baudRate) ?? 9600
        dataBits = try c.decodeIfPresent(Int.self, forKey: .dataBits) ?? 8
        parity = try c.decodeIfPresent(String.self, forKey: .parity) ?? "none"
        stopBits = try c.decodeIfPresent(Int.self, forKey: .stopBits) ?? 1
        flowControl = try c.decodeIfPresent(String.self, forKey: .flowControl) ?? "none"
    }

    public static let baudRates = [1200, 2400, 4800, 9600, 19200, 38400, 57600, 115200, 230400, 460800, 921600]

    /// 如 “9600 8N1”
    public var summary: String {
        let parityLetter = switch parity {
        case "even": "E"
        case "odd": "O"
        default: "N"
        }
        return "\(baudRate) \(dataBits)\(parityLetter)\(stopBits)"
    }
}

/// 一条保存的会话。只保存非敏感信息；密码和私钥口令在钥匙串里。
public struct SessionProfile: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    /// SSH、Telnet 还是串口
    public var kind: ConnectionKind
    public var serial: SerialSettings
    /// 显示名；为空时显示 user@host
    public var name: String
    /// 所在分组，多级用 "/" 分隔，空字符串表示顶层
    public var group: String
    public var host: String
    public var port: Int
    public var username: String
    public var auth: AuthKind
    /// auth = .key 时用第一个；auth = .auto 时是要试的私钥（为空就用 ~/.ssh/id_* 默认那几个）
    public var keyPaths: [String]
    /// ssh_config 的 IdentitiesOnly：只用 keyPaths 里的密钥
    public var identitiesOnly: Bool
    /// ssh_config 的 IdentityAgent：空字符串用 SSH_AUTH_SOCK，"none" 不用 agent
    public var identityAgent: String
    public var legacyAlgorithms: Bool
    /// 经由哪个会话作为跳板机（它自己也可以再有跳板机）
    public var jumpHostID: UUID?
    /// 意外断线时自动重连
    public var autoReconnect: Bool
    /// 连接后自动记录会话日志
    public var logSession: Bool
    /// 远端终端的字符编码（"UTF-8"、"GBK"、"Big5"……），老服务器、网络设备常用 GBK
    public var encoding: String
    /// 连接后自动开启的端口转发
    public var forwards: [ForwardRule]
    public var notes: String
    public var lastConnected: Date?

    public init(
        id: UUID = UUID(),
        kind: ConnectionKind = .ssh,
        serial: SerialSettings = SerialSettings(),
        name: String = "",
        group: String = "",
        host: String = "",
        port: Int = 22,
        username: String = NSUserName(),
        auth: AuthKind = .auto,
        keyPaths: [String] = [],
        identitiesOnly: Bool = false,
        identityAgent: String = "",
        legacyAlgorithms: Bool = false,
        jumpHostID: UUID? = nil,
        autoReconnect: Bool = true,
        logSession: Bool = false,
        encoding: String = "UTF-8",
        forwards: [ForwardRule] = [],
        notes: String = "",
        lastConnected: Date? = nil
    ) {
        self.id = id
        self.kind = kind
        self.serial = serial
        self.name = name
        self.group = group
        self.host = host
        self.port = port
        self.username = username
        self.auth = auth
        self.keyPaths = keyPaths
        self.identitiesOnly = identitiesOnly
        self.identityAgent = identityAgent
        self.legacyAlgorithms = legacyAlgorithms
        self.jumpHostID = jumpHostID
        self.autoReconnect = autoReconnect
        self.logSession = logSession
        self.encoding = encoding
        self.forwards = forwards
        self.notes = notes
        self.lastConnected = lastConnected
    }

    /// 以后加字段时，老的存档缺这些字段也能正常读出来
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        kind = (try? c.decodeIfPresent(ConnectionKind.self, forKey: .kind)) ?? .ssh
        serial = try c.decodeIfPresent(SerialSettings.self, forKey: .serial) ?? SerialSettings()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        group = try c.decodeIfPresent(String.self, forKey: .group) ?? ""
        host = try c.decodeIfPresent(String.self, forKey: .host) ?? ""
        port = try c.decodeIfPresent(Int.self, forKey: .port) ?? 22
        username = try c.decodeIfPresent(String.self, forKey: .username) ?? NSUserName()
        auth = (try? c.decodeIfPresent(AuthKind.self, forKey: .auth)) ?? .auto
        keyPaths = try c.decodeIfPresent([String].self, forKey: .keyPaths) ?? []
        identitiesOnly = try c.decodeIfPresent(Bool.self, forKey: .identitiesOnly) ?? false
        identityAgent = try c.decodeIfPresent(String.self, forKey: .identityAgent) ?? ""
        legacyAlgorithms = try c.decodeIfPresent(Bool.self, forKey: .legacyAlgorithms) ?? false
        jumpHostID = try c.decodeIfPresent(UUID.self, forKey: .jumpHostID)
        autoReconnect = try c.decodeIfPresent(Bool.self, forKey: .autoReconnect) ?? true
        logSession = try c.decodeIfPresent(Bool.self, forKey: .logSession) ?? false
        encoding = try c.decodeIfPresent(String.self, forKey: .encoding) ?? "UTF-8"
        forwards = try c.decodeIfPresent([ForwardRule].self, forKey: .forwards) ?? []
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
        lastConnected = try c.decodeIfPresent(Date.self, forKey: .lastConnected)
    }

    /// user@host，端口不是 22 时带上端口；Telnet 是“主机:端口（Telnet）”，串口是设备名和参数
    public var address: String {
        let hostPart = host.contains(":") ? "[\(host)]" : host
        switch kind {
        case .ssh:
            return port == 22 ? "\(username)@\(hostPart)" : "\(username)@\(hostPart):\(port)"
        case .telnet:
            return "\(hostPart):\(port)（Telnet）"
        case .serial:
            let device = (serial.path as NSString).lastPathComponent
            return "\(device.isEmpty ? "未选择串口" : device) \(serial.summary)"
        }
    }

    /// 拷到剪贴板用的地址：SSH 是 user@host（端口不是 22 时带上 :端口），Telnet 是 主机:端口，串口是设备路径
    public var copyableAddress: String {
        let hostPart = host.contains(":") ? "[\(host)]" : host
        switch kind {
        case .ssh: return port == 22 ? "\(username)@\(hostPart)" : "\(username)@\(hostPart):\(port)"
        case .telnet: return "\(hostPart):\(port)"
        case .serial: return serial.path
        }
    }

    /// 在别的终端里能直接用的 ssh 命令：端口、指定的私钥、跳板机（ssh -J）都带上。不是 SSH 会话时为 nil
    public func sshCommand(jumps: [SessionProfile] = []) -> String? {
        guard kind == .ssh else { return nil }
        var parts = ["ssh"]
        if port != 22 { parts += ["-p", String(port)] }
        let key = keyPath.trimmingCharacters(in: .whitespaces)
        if auth == .key, !key.isEmpty { parts += ["-i", Self.shellQuoted(key, expandingHome: true)] }
        if !jumps.isEmpty { parts += ["-J", Self.shellQuoted(jumps.map(\.jumpSpec).joined(separator: ","))] }
        let user = username.trimmingCharacters(in: .whitespaces)
        let target = host.trimmingCharacters(in: .whitespaces)
        let destination = user.isEmpty ? target : "\(user)@\(target)"
        if destination.hasPrefix("-") { parts.append("--") }
        parts.append(Self.shellQuoted(destination))
        return parts.joined(separator: " ")
    }

    /// ssh -J 的写法：user@host:port，IPv6 地址加方括号，端口是 22 时省略
    var jumpSpec: String {
        let target = host.trimmingCharacters(in: .whitespaces)
        let hostPart = target.contains(":") ? "[\(target)]" : target
        let user = username.trimmingCharacters(in: .whitespaces)
        return (user.isEmpty ? "" : "\(user)@") + hostPart + (port == 22 ? "" : ":\(port)")
    }

    /// 只让私钥路径展开 ~/；主机参数中的方括号、~ 和命令字符一律作为字面值。
    static func shellQuoted(_ text: String, expandingHome: Bool = false) -> String {
        if expandingHome, text.hasPrefix("~/") { return "~/" + shellQuoted(String(text.dropFirst(2))) }
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_./+-@:%,=")
        if !text.isEmpty, text.unicodeScalars.allSatisfy(safe.contains) { return text }
        return "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    public var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? address : trimmed
    }

    /// 私钥认证用的那把私钥
    public var keyPath: String {
        get { keyPaths.first ?? "" }
        set {
            if keyPaths.isEmpty {
                if !newValue.isEmpty { keyPaths = [newValue] }
            } else if newValue.isEmpty {
                keyPaths.removeFirst()
            } else {
                keyPaths[0] = newValue
            }
        }
    }

    /// 能不能拿去连接
    public var isValid: Bool {
        switch kind {
        case .ssh:
            !host.trimmingCharacters(in: .whitespaces).isEmpty
                && !username.trimmingCharacters(in: .whitespaces).isEmpty
                && (1...65535).contains(port)
                && (auth != .key || !keyPath.trimmingCharacters(in: .whitespaces).isEmpty)
        case .telnet:
            !host.trimmingCharacters(in: .whitespaces).isEmpty && (1...65535).contains(port)
        case .serial:
            !serial.path.isEmpty && serial.baudRate > 0
        }
    }

    /// 只有 SSH 才有的功能：文件面板、端口转发、rz/sz、服务器监控
    public var isSSH: Bool { kind == .ssh }

    /// 同一台服务器、同一个用户（导入时判断重复、钥匙串里共用密码）
    public var endpointKey: String {
        "\(username.lowercased())@\(host.lowercased()):\(port)"
    }

    /// ~/.ssh 下最常见的那把私钥，新建“私钥”认证时预填
    public static var defaultKeyPath: String {
        let ssh = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh")
        for name in ["id_ed25519", "id_ecdsa", "id_rsa"] {
            let path = ssh.appendingPathComponent(name).path
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }
        return ssh.appendingPathComponent("id_ed25519").path
    }
}

/// 分组路径的小工具。路径用 "/" 分隔，比如 "生产/数据库"。
public enum GroupPath {
    public static func normalize(_ path: String) -> String {
        path.split(separator: "/")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: "/")
    }

    public static func parent(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return "" }
        return String(path[..<slash])
    }

    public static func lastComponent(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return path }
        return String(path[path.index(after: slash)...])
    }

    public static func join(_ parent: String, _ child: String) -> String {
        normalize(parent.isEmpty ? child : "\(parent)/\(child)")
    }

    /// path 是否等于 ancestor 或在它下面
    public static func isWithin(_ path: String, _ ancestor: String) -> Bool {
        ancestor.isEmpty || path == ancestor || path.hasPrefix(ancestor + "/")
    }

    /// "a/b/c" → ["a", "a/b", "a/b/c"]
    public static func ancestors(of path: String) -> [String] {
        var result: [String] = []
        var current = ""
        for component in path.split(separator: "/") {
            current = current.isEmpty ? String(component) : "\(current)/\(component)"
            result.append(current)
        }
        return result
    }
}

/// 端口转发规则（存在会话里，连接后自动开启）
public struct ForwardRule: Codable, Hashable, Identifiable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        /// 本机端口 → 经服务器 → 目标（ssh -L）
        case local
        /// 服务器端口 → 经本机 → 目标（ssh -R）
        case remote
        /// 本机 SOCKS 代理（ssh -D）
        case dynamic

        public var title: String {
            switch self {
            case .local: "本地"
            case .remote: "远程"
            case .dynamic: "动态（SOCKS）"
            }
        }
    }

    public var id: UUID
    public var kind: Kind
    public var bindHost: String
    public var bindPort: Int
    public var targetHost: String
    public var targetPort: Int
    public var enabled: Bool

    public init(id: UUID = UUID(), kind: Kind, bindHost: String = "127.0.0.1", bindPort: Int,
                targetHost: String = "", targetPort: Int = 0, enabled: Bool = true) {
        self.id = id
        self.kind = kind
        self.bindHost = bindHost
        self.bindPort = bindPort
        self.targetHost = targetHost
        self.targetPort = targetPort
        self.enabled = enabled
    }

    public var isValid: Bool {
        guard (0...65535).contains(bindPort), !bindHost.isEmpty else { return false }
        if kind == .dynamic { return true }
        return !targetHost.trimmingCharacters(in: .whitespaces).isEmpty && (1...65535).contains(targetPort)
    }

    /// 一行说明，如“本地 127.0.0.1:8080 → db:3306”
    public var summary: String {
        let bind = "\(bindHost):\(bindPort == 0 ? "自动" : String(bindPort))"
        switch kind {
        case .dynamic: return "SOCKS 代理 \(bind)"
        case .local: return "本地 \(bind) → \(targetHost):\(targetPort)"
        case .remote: return "服务器 \(bind) → 本机 \(targetHost):\(targetPort)"
        }
    }

    /// 解析 ssh_config 的 LocalForward / RemoteForward / DynamicForward 的值，也认 ssh -L 的写法：
    ///   “[绑定地址:]端口 目标主机:目标端口”、“端口:目标主机:目标端口”、“绑定地址:端口:目标主机:目标端口”
    public static func parse(kind: Kind, value: String) -> ForwardRule? {
        let words = value.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let first = words.first else { return nil }
        if kind == .dynamic {
            guard let (host, port) = splitBind(first) else { return nil }
            return ForwardRule(kind: .dynamic, bindHost: host, bindPort: port)
        }
        if words.count == 1 {
            let parts = first.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
            switch parts.count {
            case 3:
                guard let bindPort = Int(parts[0]), let targetPort = Int(parts[2]) else { return nil }
                return ForwardRule(kind: kind, bindPort: bindPort, targetHost: parts[1], targetPort: targetPort)
            case 4:
                guard let bindPort = Int(parts[1]), let targetPort = Int(parts[3]) else { return nil }
                return ForwardRule(kind: kind, bindHost: normalizedBindHost(parts[0]), bindPort: bindPort,
                                   targetHost: parts[2], targetPort: targetPort)
            default:
                return nil
            }
        }
        guard let (bindHost, bindPort) = splitBind(first),
              let colon = words[1].lastIndex(of: ":"),
              let targetPort = Int(words[1][words[1].index(after: colon)...])
        else { return nil }
        var targetHost = String(words[1][..<colon])
        if targetHost.hasPrefix("["), targetHost.hasSuffix("]") {
            targetHost = String(targetHost.dropFirst().dropLast())
        }
        return ForwardRule(kind: kind, bindHost: bindHost, bindPort: bindPort, targetHost: targetHost, targetPort: targetPort)
    }

    /// 监听地址：“端口”“主机:端口”“[IPv6]:端口”“*:端口”
    static func splitBind(_ text: String) -> (String, Int)? {
        if let port = Int(text) { return ("127.0.0.1", port) }
        if text.hasPrefix("["), let close = text.firstIndex(of: "]") {
            let host = String(text[text.index(after: text.startIndex)..<close])
            let rest = text[text.index(after: close)...]
            guard rest.hasPrefix(":"), let port = Int(rest.dropFirst()) else { return nil }
            return (host, port)
        }
        guard let colon = text.lastIndex(of: ":"), let port = Int(text[text.index(after: colon)...]) else { return nil }
        return (normalizedBindHost(String(text[..<colon])), port)
    }

    static func normalizedBindHost(_ host: String) -> String {
        switch host {
        case "", "*": "0.0.0.0"
        case "localhost": "127.0.0.1"
        default: host
        }
    }
}

/// 快捷命令（撰写栏上的按钮）
public struct QuickCommand: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var command: String
    /// 发送后自动回车
    public var pressEnter: Bool

    public init(id: UUID = UUID(), name: String, command: String, pressEnter: Bool = true) {
        self.id = id
        self.name = name
        self.command = command
        self.pressEnter = pressEnter
    }

    /// 要发给终端的内容。多行命令逐行回车
    public var payload: String {
        let lines = command.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "\r")
        return pressEnter ? lines + "\r" : lines
    }
}

/// 设置里能选的字符编码（显示名, 编码标签）
public enum TerminalEncoding {
    public static let all: [(title: String, label: String)] = [
        ("UTF-8", "UTF-8"),
        ("简体中文 GBK / GB18030", "GB18030"),
        ("繁体中文 Big5", "Big5"),
        ("日文 Shift_JIS", "Shift_JIS"),
        ("日文 EUC-JP", "EUC-JP"),
        ("韩文 EUC-KR", "EUC-KR"),
        ("西欧 ISO-8859-1", "windows-1252"),
    ]

    public static func title(for label: String) -> String {
        all.first { $0.label.caseInsensitiveCompare(label) == .orderedSame }?.title ?? label
    }
}
