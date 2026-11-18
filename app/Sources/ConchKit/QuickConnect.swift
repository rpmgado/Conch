import Foundation

/// 快速连接框里输入的内容。支持这些写法：
///   host、user@host、user@host:port、[::1]:2222、ssh://user@host:port
///   ssh user@host -p 2222 -i ~/.ssh/key -J jump1,jump2 -l user
/// 主机名可以是 ~/.ssh/config 里的别名，由 App 再去解析。
public struct QuickConnectRequest: Equatable, Sendable {
    public var user: String?
    public var host: String
    public var port: Int?
    public var identityFile: String?
    /// -J 后面的跳板机，原样保留，可能是别名或 user@host:port 列表
    public var jump: String?
    /// 输入的是 “telnet 主机 [端口]”
    public var telnet: Bool

    public init(user: String? = nil, host: String, port: Int? = nil, identityFile: String? = nil, jump: String? = nil, telnet: Bool = false) {
        self.user = user
        self.host = host
        self.port = port
        self.identityFile = identityFile
        self.jump = jump
        self.telnet = telnet
    }

    public static func parse(_ input: String) -> QuickConnectRequest? {
        var words = SSHConfig.words(input.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !words.isEmpty else { return nil }
        // telnet 主机 [端口]，也认 telnet://主机:端口
        if words[0] == "telnet" || words[0].hasPrefix("telnet://") {
            if words[0] == "telnet" { words.removeFirst() } else { words[0] = String(words[0].dropFirst("telnet://".count)) }
            guard let first = words.first, var spec = JumpSpec.parse(first) else { return nil }
            if words.count > 1, let port = Int(words[1]) { spec.port = port }
            guard spec.port.map({ (1...65535).contains($0) }) ?? true else { return nil }
            return QuickConnectRequest(host: spec.host, port: spec.port ?? 23, telnet: true)
        }
        if words[0] == "ssh" { words.removeFirst() }

        var user: String?
        var port: Int?
        var identity: String?
        var jump: String?
        var destination: String?
        // 这些选项后面跟一个参数，不认识的也要跳过它的参数，免得把参数当成主机名
        let takesValue: Set<String> = ["-p", "-l", "-i", "-J", "-o", "-F", "-b", "-c", "-m", "-E", "-S", "-L", "-R", "-D", "-W", "-w", "-e", "-Q", "-B", "-O"]
        var index = 0
        while index < words.count {
            let word = words[index]
            let value = index + 1 < words.count ? words[index + 1] : nil
            switch word {
            case "-p": port = value.flatMap { Int($0) }
            case "-l": user = value
            case "-i": identity = value
            case "-J": jump = value
            default:
                if word.hasPrefix("-") {
                    // -p2222 这种连写
                    if word.hasPrefix("-p"), let p = Int(word.dropFirst(2)) { port = p }
                } else if destination == nil {
                    destination = word
                }
            }
            index += takesValue.contains(word) ? 2 : 1
        }

        guard let destination, var spec = JumpSpec.parse(destination) else { return nil }
        // -l 和 -p 优先级低于目标里直接写的
        if spec.user == nil { spec.user = user }
        if spec.port == nil { spec.port = port }
        guard spec.port.map({ (1...65535).contains($0) }) ?? true else { return nil }
        return QuickConnectRequest(user: spec.user, host: spec.host, port: spec.port, identityFile: identity, jump: jump)
    }
}
