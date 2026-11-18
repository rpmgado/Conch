import AppKit
import Combine
import ConchKit
import SwiftTerm

/// 偏好设置的键。默认值在 Prefs.register() 里集中登记，界面上的 @AppStorage 读到的也是这些值。
enum Prefs {
    static let useMetal = "useMetal"
    /// 界面主题：system（跟随系统：浅色用玻璃，深色用石墨）/ glass / graphite / environment
    static let uiTheme = "uiTheme"
    /// 终端配色；默认跟随界面主题
    static let themeID = "themeID"
    /// 侧边栏、右侧面板的宽度
    static let compactSidebar = "compactSidebar"
    static let sidebarWidth = "sidebarWidth"
    static let sidePanelWidth = "sidePanelWidth"
    /// 字体家族名，空字符串表示系统等宽字体（SF Mono）
    static let fontFamily = "fontFamily"
    static let fontSize = "fontSize"
    /// block / bar / underline
    static let cursorShape = "cursorShape"
    static let cursorBlink = "cursorBlink"
    static let scrollback = "scrollbackLines"
    static let optionAsMeta = "optionAsMeta"
    /// 空字符串表示默认的 ~/Library/Logs/Conch
    static let logDirectory = "logDirectory"
    static let logPlainText = "logPlainText"
    static let logTimestamps = "logTimestamps"
    static let confirmClose = "confirmCloseConnected"
    /// SFTP 下载、sz 接收文件的默认目录，空字符串表示 ~/Downloads
    static let downloadDirectory = "downloadDirectory"
    /// 远程编辑用的应用（.app 的路径），空字符串表示按文件类型用默认应用
    static let editorApp = "editorApp"
    /// 会话同步文件夹，空字符串表示没开同步
    static let syncDirectory = "syncDirectory"
    /// 用钥匙串里保存的密码前，先用 Touch ID 或登录密码验证
    static let requireAuthForSecrets = "requireAuthForSecrets"
    /// 文件面板里显示本机那一栏、本机那一栏上次在哪个文件夹、显示隐藏文件、本机那一栏占的高度比例
    static let showLocalFiles = "showLocalFiles"
    static let localFilesDirectory = "localFilesDirectory"
    static let localShowHidden = "localShowHidden"
    static let localFilesFraction = "localFilesFraction"
    static let highlightEnabled = "highlightEnabled"
    static let highlightRed = "highlightRed"
    static let highlightYellow = "highlightYellow"
    static let highlightGreen = "highlightGreen"

    static func register() {
        UserDefaults.standard.register(defaults: [
            useMetal: true,
            uiTheme: "system",
            themeID: TerminalTheme.followUIID,
            sidebarWidth: 276.0,
            compactSidebar: false,
            sidePanelWidth: 340.0,
            fontFamily: "",
            fontSize: 13.0,
            cursorShape: "block",
            cursorBlink: true,
            scrollback: 10_000,
            optionAsMeta: true,
            logDirectory: "",
            logPlainText: true,
            logTimestamps: false,
            confirmClose: true,
            downloadDirectory: "",
            editorApp: "",
            syncDirectory: "",
            requireAuthForSecrets: false,
            showLocalFiles: true,
            localFilesDirectory: "",
            localShowHidden: false,
            localFilesFraction: 0.45,
            highlightEnabled: true,
            highlightRed: KeywordHighlighter.defaultRed,
            highlightYellow: KeywordHighlighter.defaultYellow,
            highlightGreen: KeywordHighlighter.defaultGreen,
        ])
    }
}

/// App 自己的数据目录：~/Library/Application Support/Conch
enum AppPaths {
    static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = TestHooks.dataDirectory ?? base.appendingPathComponent("Conch", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 新信任的主机记在这里；~/.ssh/known_hosts 只读不写
    static var knownHosts: URL { supportDirectory.appendingPathComponent("known_hosts") }

    /// 会话列表：打开同步时在同步文件夹里，否则在本机
    static var sessionsFile: URL {
        SyncSettings.directory?.appendingPathComponent(SyncSettings.sessionsFileName) ?? localSessionsFile
    }

    static var localSessionsFile: URL { supportDirectory.appendingPathComponent("sessions.json") }

    static var defaultLogDirectory: URL {
        if let test = TestHooks.dataDirectory { return test.appendingPathComponent("Logs", isDirectory: true) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Conch", isDirectory: true)
    }

    /// SFTP 下载和 sz 接收的文件放这里
    static var downloadsDirectory: URL {
        if let test = TestHooks.dataDirectory { return test.appendingPathComponent("Downloads", isDirectory: true) }
        let custom = UserDefaults.standard.string(forKey: Prefs.downloadDirectory) ?? ""
        if !custom.isEmpty { return URL(fileURLWithPath: (custom as NSString).expandingTildeInPath, isDirectory: true) }
        return FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads", isDirectory: true)
    }

    static var zmodemDirectory: URL { downloadsDirectory }

    /// 远程编辑时下载到本机的副本
    static var editingDirectory: URL {
        if let test = TestHooks.dataDirectory { return test.appendingPathComponent("Editing", isDirectory: true) }
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return caches.appendingPathComponent("Conch/Editing", isDirectory: true)
    }

    static var logDirectory: URL {
        let custom = UserDefaults.standard.string(forKey: Prefs.logDirectory) ?? ""
        return custom.isEmpty ? defaultLogDirectory : URL(fileURLWithPath: (custom as NSString).expandingTildeInPath, isDirectory: true)
    }
}

/// 终端的外观设置（主题、字体、光标、回滚行数）。偏好或系统深浅色变化时重新计算，各个终端订阅后自动更新。
struct AppearanceSnapshot: Equatable {
    var theme: TerminalTheme
    var font: NSFont
    var cursor: CursorStyle
    var scrollback: Int
    var optionAsMeta: Bool
    /// 关键字高亮规则；关掉时为空
    var highlightRules: [KeywordHighlighter.Rule]
}

final class TerminalAppearance: ObservableObject {
    static let shared = TerminalAppearance()

    @Published private(set) var snapshot: AppearanceSnapshot
    private var defaultsObserver: NSObjectProtocol?
    private var appearanceObserver: NSKeyValueObservation?

    private init() {
        snapshot = Self.current()
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.refresh() }
        // “跟随系统”主题要跟着深浅色模式切换
        appearanceObserver = NSApplication.shared.observe(\.effectiveAppearance) { [weak self] _, _ in
            DispatchQueue.main.async { self?.refresh() }
        }
    }

    func refresh() {
        let latest = Self.current()
        if latest != snapshot { snapshot = latest }
    }

    static var isDarkMode: Bool {
        NSApplication.shared.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    static func current() -> AppearanceSnapshot {
        let defaults = UserDefaults.standard
        let themeID = defaults.string(forKey: Prefs.themeID) ?? TerminalTheme.followUIID
        let theme = themeID == TerminalTheme.followUIID
            ? TerminalTheme.forUITheme(ThemeStore.resolve().rawValue)
            : TerminalTheme.resolve(themeID, darkMode: isDarkMode)
        let size = CGFloat(min(max(defaults.double(forKey: Prefs.fontSize), 8), 40))
        let family = defaults.string(forKey: Prefs.fontFamily) ?? ""
        let font = family.isEmpty
            ? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
            : NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: size)
                ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        let blink = defaults.bool(forKey: Prefs.cursorBlink)
        let cursor: CursorStyle = switch defaults.string(forKey: Prefs.cursorShape) {
        case "bar": blink ? .blinkBar : .steadyBar
        case "underline": blink ? .blinkUnderline : .steadyUnderline
        default: blink ? .blinkBlock : .steadyBlock
        }
        return AppearanceSnapshot(
            theme: theme,
            font: font,
            cursor: cursor,
            scrollback: min(max(defaults.integer(forKey: Prefs.scrollback), 1000), 200_000),
            optionAsMeta: defaults.bool(forKey: Prefs.optionAsMeta),
            highlightRules: defaults.bool(forKey: Prefs.highlightEnabled)
                ? KeywordHighlighter.rules(
                    red: defaults.string(forKey: Prefs.highlightRed) ?? "",
                    yellow: defaults.string(forKey: Prefs.highlightYellow) ?? "",
                    green: defaults.string(forKey: Prefs.highlightGreen) ?? ""
                )
                : []
        )
    }

    /// 等宽字体家族，给设置里的字体菜单用
    static var monospacedFamilies: [String] {
        let names = NSFontManager.shared.availableFontNames(with: .fixedPitchFontMask) ?? []
        let families = Set(names.compactMap { NSFont(name: $0, size: 12)?.familyName })
        return families.filter { !$0.hasPrefix(".") }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    static func adjustFontSize(by delta: Double) {
        let defaults = UserDefaults.standard
        if delta == 0 {
            defaults.removeObject(forKey: Prefs.fontSize)
        } else {
            defaults.set(min(max(defaults.double(forKey: Prefs.fontSize) + delta, 8), 40), forKey: Prefs.fontSize)
        }
    }
}

extension TerminalView {
    /// 把外观设置应用到终端视图
    func apply(_ appearance: AppearanceSnapshot, previous: AppearanceSnapshot?) {
        let theme = appearance.theme
        if previous?.theme != theme {
            installColors(theme.ansi.map { SwiftTerm.Color(red8: UInt16($0.r), green8: UInt16($0.g), blue8: UInt16($0.b)) })
            nativeForegroundColor = NSColor(theme.foreground)
            nativeBackgroundColor = NSColor(theme.background)
            caretColor = NSColor(theme.cursor)
            selectedTextBackgroundColor = NSColor(theme.selection)
            // 终端下面卡片的底色也跟着变
            (superview as? DeckView)?.terminalColorsChanged()
        }
        if previous?.font != appearance.font {
            font = appearance.font
        }
        if previous?.cursor != appearance.cursor {
            setCursorStyle(appearance.cursor)
        }
        if previous?.scrollback != appearance.scrollback {
            changeScrollback(appearance.scrollback)
        }
        optionAsMetaKey = appearance.optionAsMeta
    }
}

extension NSColor {
    convenience init(_ rgb: RGB) {
        self.init(srgbRed: CGFloat(rgb.r) / 255, green: CGFloat(rgb.g) / 255, blue: CGFloat(rgb.b) / 255, alpha: 1)
    }
}
