import Foundation

/// 把终端输出流转成适合存日志的纯文本。
///
/// 按“单行终端”来模拟：回车回到行首、后面的字覆盖前面的，退格左移，
/// 处理常见的行内光标移动和擦除（ESC[K、ESC[C、ESC[D…），中文按两格宽算；
/// 颜色、标题等其他控制序列直接去掉。这样 zsh 的提示符、进度条、命令行编辑在日志里看起来和屏幕上一致。
/// 全屏程序（vim、top）靠整屏光标定位画界面，日志里只能得到大致的文字。
///
/// 流式处理：控制序列、UTF-8 字符被截断在两次输出之间也没关系。没换行的半行等换行或 finish() 时再输出。
public struct PlainTextFilter: Sendable {
    private enum State: Sendable {
        case text
        case escape        // 刚收到 ESC
        case csi           // ESC [ 参数 … 终止字节
        case string        // OSC / DCS / APC / PM / SOS，到 BEL 或 ST 结束
        case stringEscape  // 字符串里收到 ESC，看下一个是不是 '\'
        case charset       // ESC ( B 这类，再吃掉一个字节
    }

    /// 宽字符（中文等）占两格，第二格放这个占位
    private static let continuation: UInt32 = 0
    private static let space: UInt32 = 0x20
    /// 防止一直不换行的输出把内存吃光
    private static let maxLine = 16 * 1024

    private var state = State.text
    private var cells: [UInt32] = []
    private var column = 0
    private var params: [UInt8] = []
    // 正在拼的 UTF-8 字符
    private var scalar: UInt32 = 0
    private var scalarRemaining = 0

    private let timestamps: Bool
    private let clock: @Sendable () -> Date

    public init(timestamps: Bool, clock: @escaping @Sendable () -> Date = { Date() }) {
        self.timestamps = timestamps
        self.clock = clock
    }

    /// 喂一批原始输出，返回已经完整的行（UTF-8）
    public mutating func feed(_ bytes: some Sequence<UInt8>) -> Data {
        var out = Data()
        for byte in bytes {
            switch state {
            case .text:
                text(byte, into: &out)
            case .escape:
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
                    state = .text // 两字节的序列（ESC 7、ESC = 等）到此结束
                }
            case .csi:
                if byte == 0x1B {
                    state = .escape
                } else if (0x40...0x7E).contains(byte) {
                    csi(final: byte)
                    state = .text
                } else {
                    params.append(byte)
                }
            case .string:
                if byte == 0x07 {
                    state = .text
                } else if byte == 0x1B {
                    state = .stringEscape
                }
            case .stringEscape:
                state = byte == UInt8(ascii: "\\") ? .text : (byte == 0x1B ? .stringEscape : .string)
            case .charset:
                state = .text
            }
        }
        return out
    }

    /// 结束时把还没换行的半行也输出
    public mutating func finish() -> Data {
        var out = Data()
        if !cells.isEmpty { flushLine(into: &out) }
        return out
    }

    // MARK: 普通字符和 C0 控制字符

    private mutating func text(_ byte: UInt8, into out: inout Data) {
        // 拼 UTF-8 多字节字符
        if scalarRemaining > 0 {
            if byte & 0xC0 == 0x80 {
                scalar = (scalar << 6) | UInt32(byte & 0x3F)
                scalarRemaining -= 1
                if scalarRemaining == 0 { put(scalar, into: &out) }
                return
            }
            // 序列断了，前面那半个字符作废
            scalarRemaining = 0
            put(0xFFFD, into: &out)
        }
        switch byte {
        case 0x1B: state = .escape
        case 0x0A: flushLine(into: &out)
        case 0x0D: column = 0
        case 0x08: column = max(0, column - 1)
        case 0x09: column = (column / 8 + 1) * 8
        case 0x00..<0x20, 0x7F: break // 响铃等其他控制字符丢掉
        case 0x80..<0xC0: break // 落单的后续字节
        case 0xC0..<0xE0: start(byte & 0x1F, remaining: 1)
        case 0xE0..<0xF0: start(byte & 0x0F, remaining: 2)
        case 0xF0..<0xF8: start(byte & 0x07, remaining: 3)
        case 0xF8...: break
        default: put(UInt32(byte), into: &out)
        }
    }

    private mutating func start(_ bits: UInt8, remaining: Int) {
        scalar = UInt32(bits)
        scalarRemaining = remaining
    }

    /// 在光标处写一个字符（覆盖原来的），光标右移
    private mutating func put(_ value: UInt32, into out: inout Data) {
        let width = Self.isWide(value) ? 2 : 1
        while cells.count < column { cells.append(Self.space) }
        erase(at: column)
        if width == 2 { erase(at: column + 1) }
        set(column, value)
        if width == 2 { set(column + 1, Self.continuation) }
        column += width
        if cells.count >= Self.maxLine { flushLine(into: &out) }
    }

    private mutating func set(_ index: Int, _ value: UInt32) {
        if index < cells.count { cells[index] = value } else { cells.append(value) }
    }

    /// 要覆盖某一格时，如果它是宽字符的一半，把另一半变成空格
    private mutating func erase(at index: Int) {
        guard index < cells.count else { return }
        if cells[index] == Self.continuation, index > 0 {
            cells[index - 1] = Self.space
        } else if index + 1 < cells.count, cells[index + 1] == Self.continuation {
            cells[index + 1] = Self.space
        }
    }

    // MARK: CSI

    private mutating func csi(final: UInt8) {
        // ESC[? 开头的是模式设置，和文字无关
        if params.first == UInt8(ascii: "?") || params.first == UInt8(ascii: ">") { return }
        let numbers = String(decoding: params, as: UTF8.self).split(separator: ";").map { Int($0) ?? 0 }
        let first = numbers.first ?? 0
        let count = max(first, 1)
        switch final {
        case UInt8(ascii: "K"): // 擦除行
            switch first {
            case 1:
                for index in 0..<min(column + 1, cells.count) { cells[index] = Self.space }
            case 2:
                cells.removeAll(keepingCapacity: true)
            default:
                if column < cells.count {
                    erase(at: column)
                    cells.removeSubrange(column...)
                }
            }
        case UInt8(ascii: "C"): column += count                // 右移
        case UInt8(ascii: "D"): column = max(0, column - count) // 左移
        case UInt8(ascii: "G"), UInt8(ascii: "`"): column = count - 1 // 移到第 n 列
        case UInt8(ascii: "H"), UInt8(ascii: "f"):               // 定位：只取列
            column = numbers.count > 1 ? max(numbers[1], 1) - 1 : 0
        case UInt8(ascii: "P"): // 删除 n 个字符
            if column < cells.count {
                erase(at: column)
                cells.removeSubrange(column..<min(column + count, cells.count))
            }
        case UInt8(ascii: "@"): // 插入 n 个空格
            if column < cells.count {
                cells.insert(contentsOf: repeatElement(Self.space, count: count), at: column)
            }
        case UInt8(ascii: "X"): // 把 n 个字符擦成空格
            for index in column..<min(column + count, cells.count) { cells[index] = Self.space }
        default:
            break
        }
    }

    // MARK: 输出

    private mutating func flushLine(into out: inout Data) {
        var text = String()
        text.unicodeScalars.reserveCapacity(cells.count)
        for value in cells where value != Self.continuation {
            text.unicodeScalars.append(Unicode.Scalar(value) ?? "\u{FFFD}")
        }
        while text.last == " " { text.removeLast() }
        if timestamps {
            out.append(Data("[\(Self.format(clock()))] ".utf8))
        }
        out.append(Data(text.utf8))
        out.append(0x0A)
        cells.removeAll(keepingCapacity: true)
        column = 0
    }

    /// 东亚宽字符和大部分 emoji 占两格（和终端里的显示一致）
    static func isWide(_ value: UInt32) -> Bool {
        switch value {
        case 0x1100...0x115F, 0x2E80...0x303E, 0x3041...0x33FF, 0x3400...0x4DBF, 0x4E00...0x9FFF,
             0xA000...0xA4CF, 0xAC00...0xD7A3, 0xF900...0xFAFF, 0xFE30...0xFE4F, 0xFF00...0xFF60,
             0xFFE0...0xFFE6, 0x1F300...0x1F64F, 0x1F900...0x1F9FF, 0x20000...0x2FFFD, 0x30000...0x3FFFD:
            true
        default:
            false
        }
    }

    private static func format(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(
            format: "%04d-%02d-%02d %02d:%02d:%02d",
            c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0, c.second ?? 0
        )
    }
}
