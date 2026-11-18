import Foundation

/// 关键字高亮：在终端输出里给 error、warning 这类词加上颜色，看日志时一眼就能找到。
///
/// - 只改普通文本，控制序列原样通过；
/// - 全屏程序（vim、top、less 用的备用屏幕）里不处理，免得打乱它们的界面；
/// - 自己记着当前的颜色和样式（SGR），高亮完恢复成原来的样子；
/// - 一批输出结束时，末尾没结束的单词照常交出去，绝不扣着字节（否则敲键盘时回显会慢一拍）。
///   代价是一个关键字恰好被拆在两批输出之间时不会高亮。
public struct KeywordHighlighter: Sendable {
    public struct Rule: Sendable, Equatable {
        public var words: [String]
        /// SGR 参数，如 "1;31"（红色加粗）
        public var sgr: String

        public init(words: [String], sgr: String) {
            self.words = words
            self.sgr = sgr
        }
    }

    public static let defaultRed = "error, errors, failed, failure, fatal, panic, denied, refused, exception, critical"
    public static let defaultYellow = "warn, warning, warnings, deprecated"
    public static let defaultGreen = "success, successful, succeeded, ok, passed"

    /// 设置里逗号分隔的关键字 → 规则
    public static func rules(red: String, yellow: String, green: String) -> [Rule] {
        func words(_ text: String) -> [String] {
            text.split(whereSeparator: { $0 == "," || $0 == "，" || $0.isWhitespace })
                .map { $0.lowercased() }
                .filter { !$0.isEmpty }
        }
        return [Rule(words: words(red), sgr: "1;31"), Rule(words: words(yellow), sgr: "1;33"), Rule(words: words(green), sgr: "1;32")]
            .filter { !$0.words.isEmpty }
    }

    private enum State: Sendable {
        case text
        case escape
        case csi
        case string
        case stringEscape
        case charset
    }

    private let lookup: [String: String]
    private var state = State.text
    private var word: [UInt8] = []
    private var params: [UInt8] = []
    /// 上次 SGR 重置以来设置过的参数，高亮后用它恢复
    private var currentSGR: [String] = []
    private var alternateScreen = false

    public init(rules: [Rule]) {
        var lookup: [String: String] = [:]
        for rule in rules {
            for word in rule.words where lookup[word] == nil {
                lookup[word] = rule.sgr
            }
        }
        self.lookup = lookup
    }

    public var isEmpty: Bool { lookup.isEmpty }

    public mutating func process(_ input: some Sequence<UInt8>) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(input.underestimatedCount + 32)
        for byte in input {
            switch state {
            case .text:
                if Self.isWordByte(byte) {
                    word.append(byte)
                    continue
                }
                flushWord(into: &out)
                out.append(byte)
                if byte == 0x1B { state = .escape }
            case .escape:
                out.append(byte)
                switch byte {
                case UInt8(ascii: "["):
                    params.removeAll(keepingCapacity: true)
                    state = .csi
                case UInt8(ascii: "]"), UInt8(ascii: "P"), UInt8(ascii: "X"), UInt8(ascii: "^"), UInt8(ascii: "_"):
                    state = .string
                case UInt8(ascii: "("), UInt8(ascii: ")"), UInt8(ascii: "*"), UInt8(ascii: "+"),
                     UInt8(ascii: "-"), UInt8(ascii: "."), UInt8(ascii: "/"), UInt8(ascii: "#"), UInt8(ascii: "%"):
                    state = .charset
                case 0x1B:
                    state = .escape
                default:
                    state = .text
                }
            case .csi:
                out.append(byte)
                if byte == 0x1B {
                    state = .escape
                } else if (0x40...0x7E).contains(byte) {
                    finishCSI(final: byte)
                    state = .text
                } else {
                    params.append(byte)
                }
            case .string:
                out.append(byte)
                if byte == 0x07 {
                    state = .text
                } else if byte == 0x1B {
                    state = .stringEscape
                }
            case .stringEscape:
                out.append(byte)
                state = byte == UInt8(ascii: "\\") ? .text : (byte == 0x1B ? .stringEscape : .string)
            case .charset:
                out.append(byte)
                state = .text
            }
        }
        // 这批输出结束：没结束的单词照常交出去
        if !word.isEmpty {
            out.append(contentsOf: word)
            word.removeAll(keepingCapacity: true)
        }
        return out
    }

    private static func isWordByte(_ byte: UInt8) -> Bool {
        (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A) || (byte >= 0x30 && byte <= 0x39) || byte == 0x5F
    }

    private mutating func flushWord(into out: inout [UInt8]) {
        guard !word.isEmpty else { return }
        defer { word.removeAll(keepingCapacity: true) }
        guard !alternateScreen, word.count <= 32,
              let sgr = lookup[String(decoding: word, as: UTF8.self).lowercased()]
        else {
            out.append(contentsOf: word)
            return
        }
        out.append(contentsOf: Array("\u{1b}[\(sgr)m".utf8))
        out.append(contentsOf: word)
        // 先全部重置，再把原来的样式加回去
        let restore = currentSGR.isEmpty ? "\u{1b}[0m" : "\u{1b}[0;\(currentSGR.joined(separator: ";"))m"
        out.append(contentsOf: Array(restore.utf8))
    }

    private mutating func finishCSI(final: UInt8) {
        let text = String(decoding: params, as: UTF8.self)
        switch final {
        case UInt8(ascii: "m") where !text.hasPrefix("?") && !text.hasPrefix(">"):
            trackSGR(text)
        case UInt8(ascii: "h"), UInt8(ascii: "l"):
            // 进出备用屏幕：?1049、?1047、?47
            if text.hasPrefix("?") {
                let modes = text.dropFirst().split(separator: ";")
                if modes.contains(where: { $0 == "1049" || $0 == "1047" || $0 == "47" }) {
                    alternateScreen = final == UInt8(ascii: "h")
                }
            }
        default:
            break
        }
    }

    /// 记录 SGR 状态。“38;5;n”“38;2;r;g;b” 这类扩展颜色里的 0 不能当成重置
    private mutating func trackSGR(_ text: String) {
        let tokens = text.split(separator: ";", omittingEmptySubsequences: false).map(String.init)
        if tokens.isEmpty || (tokens.count == 1 && tokens[0].isEmpty) {
            currentSGR.removeAll()
            return
        }
        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            if token == "38" || token == "48" || token == "58" {
                let mode = index + 1 < tokens.count ? tokens[index + 1] : ""
                let length = mode == "5" ? 3 : (mode == "2" ? 5 : 1)
                let end = min(index + length, tokens.count)
                currentSGR.append(tokens[index..<end].joined(separator: ";"))
                index = end
                continue
            }
            if token.isEmpty || token == "0" || token == "00" {
                currentSGR.removeAll()
            } else {
                currentSGR.append(token)
            }
            index += 1
        }
        // 防止只增不减（程序一直叠加样式却从不重置）
        if currentSGR.count > 16 { currentSGR.removeFirst(currentSGR.count - 16) }
    }
}
