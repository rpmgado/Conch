import Foundation

/// 8 位 RGB 颜色。ConchKit 不依赖 AppKit，App 里再转成 NSColor / SwiftTerm.Color。
public struct RGB: Hashable, Sendable {
    public var r: UInt8
    public var g: UInt8
    public var b: UInt8

    public init(_ hex: UInt32) {
        r = UInt8((hex >> 16) & 0xFF)
        g = UInt8((hex >> 8) & 0xFF)
        b = UInt8(hex & 0xFF)
    }
}

/// 终端配色：前景、背景、光标、选区和 16 个 ANSI 颜色（0–7 普通，8–15 高亮）
public struct TerminalTheme: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let isDark: Bool
    public let background: RGB
    public let foreground: RGB
    public let cursor: RGB
    public let selection: RGB
    public let ansi: [RGB]

    init(id: String, name: String, isDark: Bool, background: UInt32, foreground: UInt32,
         cursor: UInt32, selection: UInt32, ansi: [UInt32]) {
        precondition(ansi.count == 16, "ANSI 调色板必须是 16 色")
        self.id = id
        self.name = name
        self.isDark = isDark
        self.background = RGB(background)
        self.foreground = RGB(foreground)
        self.cursor = RGB(cursor)
        self.selection = RGB(selection)
        self.ansi = ansi.map(RGB.init)
    }

    /// “跟随系统”：浅色模式用 conchLight，深色模式用 conchDark
    public static let systemID = "system"
    /// “跟随界面主题”：玻璃、石墨、环境色各配一套（默认）
    public static let followUIID = "ui"

    /// followUIID 由 App 按当前界面主题换成 forUITheme(_:)；这里只处理其他的
    public static func resolve(_ id: String, darkMode: Bool) -> TerminalTheme {
        if id == systemID || id == followUIID { return darkMode ? conchDark : conchLight }
        return all.first { $0.id == id } ?? conchDark
    }

    /// 界面主题配套的终端配色：glass / graphite / environment
    public static func forUITheme(_ uiTheme: String) -> TerminalTheme {
        switch uiTheme {
        case "graphite": conchGraphite
        case "environment": conchEnvironment
        default: conchGlass
        }
    }

    /// 设置里能选的主题（“跟随界面主题”“跟随系统”不在这里，由界面单独加）
    public static let all: [TerminalTheme] = [
        conchGlass, conchGraphite, conchEnvironment,
        conchDark, conchLight, classic, solarizedDark, solarizedLight, tango, dracula, gruvboxDark,
    ]

    /// 玻璃主题：白底，颜色都按白底上至少 4.5:1 的对比度挑
    public static let conchGlass = TerminalTheme(
        id: "conch-glass", name: "玻璃（白底）", isDark: false,
        background: 0xFFFFFF, foreground: 0x1D1D1F, cursor: 0x0062CC, selection: 0xCFE0F7,
        ansi: [0x1D1D1F, 0xC42B1C, 0x1A7F37, 0x946200, 0x0B63CE, 0x8A3FB0, 0x0A7487, 0x6B6E75,
               0x5E6066, 0xD9362B, 0x23883F, 0xA87000, 0x1F75E0, 0xA24BC4, 0x0E8A96, 0x8C8F96]
    )

    /// 石墨主题：和窗口连成一片的深色，光标是图标的珊瑚色
    public static let conchGraphite = TerminalTheme(
        id: "conch-graphite", name: "石墨（深色）", isDark: true,
        background: 0x111216, foreground: 0xD6D9DF, cursor: 0xF26B43, selection: 0x3A3D46,
        ansi: [0x2A2D33, 0xFF8F87, 0x7FD1A0, 0xE8C473, 0x86A8F9, 0xC8A2F5, 0x7CCFD8, 0xC9CCD2,
               0x5C616B, 0xFFADA6, 0x9BE0B6, 0xF2D48F, 0xA5BFFB, 0xD8BCF8, 0x9ADDE4, 0xF2F3F5]
    )

    /// 环境色主题：浅色界面里的深色终端卡片
    public static let conchEnvironment = TerminalTheme(
        id: "conch-environment", name: "环境色（深色卡片）", isDark: true,
        background: 0x1A1D23, foreground: 0xE3E5E8, cursor: 0xFF9EA2, selection: 0x3A3F4A,
        ansi: [0x2B2F37, 0xFF8A80, 0x86D69F, 0xF0C674, 0x8AB4F8, 0xC4B5FD, 0x7FD3DD, 0xC9CDD4,
               0x5F6570, 0xFFA8A0, 0xA2E3B6, 0xF5D696, 0xA8C7FA, 0xD6CCFE, 0x9DE0E8, 0xF4F5F7]
    )

    public static let conchDark = TerminalTheme(
        id: "conch-dark", name: "Conch 深色", isDark: true,
        background: 0x1D1F23, foreground: 0xD5D8DE, cursor: 0xE8E8E8, selection: 0x3A4352,
        ansi: [0x2A2D33, 0xE06C6C, 0x8CC77A, 0xE5C07B, 0x6AA7E8, 0xC68AE0, 0x5DC2C6, 0xC8CCD4,
               0x5C6370, 0xF08A8A, 0xA6DB91, 0xF0D39A, 0x8DBEF2, 0xD7A6EE, 0x7FD8DB, 0xF2F4F8]
    )

    public static let conchLight = TerminalTheme(
        id: "conch-light", name: "Conch 浅色", isDark: false,
        background: 0xFBFBFC, foreground: 0x24292F, cursor: 0x24292F, selection: 0xC8DDF8,
        ansi: [0x24292F, 0xC8383F, 0x3E8E33, 0x9A6700, 0x2F6FC4, 0x9A3FB0, 0x1B7C83, 0x6E7781,
               0x57606A, 0xE0484F, 0x4FA544, 0xB57F00, 0x4185DB, 0xB256C8, 0x2898A0, 0x8C959F]
    )

    /// 黑底灰字，xterm 的标准调色板
    public static let classic = TerminalTheme(
        id: "classic", name: "经典黑", isDark: true,
        background: 0x000000, foreground: 0xE5E5E5, cursor: 0xE5E5E5, selection: 0x4D4D4D,
        ansi: [0x000000, 0xCD0000, 0x00CD00, 0xCDCD00, 0x0000EE, 0xCD00CD, 0x00CDCD, 0xE5E5E5,
               0x7F7F7F, 0xFF0000, 0x00FF00, 0xFFFF00, 0x5C5CFF, 0xFF00FF, 0x00FFFF, 0xFFFFFF]
    )

    public static let solarizedDark = TerminalTheme(
        id: "solarized-dark", name: "Solarized 深色", isDark: true,
        background: 0x002B36, foreground: 0x839496, cursor: 0x93A1A1, selection: 0x174652,
        ansi: [0x073642, 0xDC322F, 0x859900, 0xB58900, 0x268BD2, 0xD33682, 0x2AA198, 0xEEE8D5,
               0x002B36, 0xCB4B16, 0x586E75, 0x657B83, 0x839496, 0x6C71C4, 0x93A1A1, 0xFDF6E3]
    )

    public static let solarizedLight = TerminalTheme(
        id: "solarized-light", name: "Solarized 浅色", isDark: false,
        background: 0xFDF6E3, foreground: 0x657B83, cursor: 0x586E75, selection: 0xEEE8D5,
        ansi: [0x073642, 0xDC322F, 0x859900, 0xB58900, 0x268BD2, 0xD33682, 0x2AA198, 0xEEE8D5,
               0x002B36, 0xCB4B16, 0x586E75, 0x657B83, 0x839496, 0x6C71C4, 0x93A1A1, 0xFDF6E3]
    )

    public static let tango = TerminalTheme(
        id: "tango", name: "Tango", isDark: true,
        background: 0x2E3436, foreground: 0xD3D7CF, cursor: 0xD3D7CF, selection: 0x4A5357,
        ansi: [0x2E3436, 0xCC0000, 0x4E9A06, 0xC4A000, 0x3465A4, 0x75507B, 0x06989A, 0xD3D7CF,
               0x555753, 0xEF2929, 0x8AE234, 0xFCE94F, 0x729FCF, 0xAD7FA8, 0x34E2E2, 0xEEEEEC]
    )

    public static let dracula = TerminalTheme(
        id: "dracula", name: "Dracula", isDark: true,
        background: 0x282A36, foreground: 0xF8F8F2, cursor: 0xF8F8F2, selection: 0x44475A,
        ansi: [0x21222C, 0xFF5555, 0x50FA7B, 0xF1FA8C, 0xBD93F9, 0xFF79C6, 0x8BE9FD, 0xF8F8F2,
               0x6272A4, 0xFF6E6E, 0x69FF94, 0xFFFFA5, 0xD6ACFF, 0xFF92DF, 0xA4FFFF, 0xFFFFFF]
    )

    public static let gruvboxDark = TerminalTheme(
        id: "gruvbox-dark", name: "Gruvbox 深色", isDark: true,
        background: 0x282828, foreground: 0xEBDBB2, cursor: 0xEBDBB2, selection: 0x504945,
        ansi: [0x282828, 0xCC241D, 0x98971A, 0xD79921, 0x458588, 0xB16286, 0x689D6A, 0xA89984,
               0x928374, 0xFB4934, 0xB8BB26, 0xFABD2F, 0x83A598, 0xD3869B, 0x8EC07C, 0xEBDBB2]
    )
}
