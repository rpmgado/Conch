import AppKit
import ConchKit
import SwiftUI

// MARK: - 界面主题

/// 界面主题：同一套布局（浮起来的侧边栏、圆角卡片、胶囊工具栏），三套配色
enum UITheme: String, CaseIterable, Identifiable {
    /// 浅色、半透明，和系统界面一致
    case glass
    /// 深色，终端优先，图标的珊瑚色点缀
    case graphite
    /// 浅色界面、深色终端卡片，按分组的环境标签给会话上色
    case environment

    var id: String { rawValue }

    var title: String {
        switch self {
        case .glass: "玻璃"
        case .graphite: "石墨"
        case .environment: "环境色"
        }
    }

    var summary: String {
        switch self {
        case .glass: "浅色、半透明，和系统界面一致"
        case .graphite: "深色，终端优先，珊瑚色点缀"
        case .environment: "按生产、测试、设备给会话上色"
        }
    }

    var isDark: Bool { self == .graphite }

    var palette: Palette {
        switch self {
        case .glass: .glass
        case .graphite: .graphite
        case .environment: .environment
        }
    }
}

/// 一套界面配色。浅色、深色主题各自固定，不随系统变（跟随系统时换的是整套主题）
struct Palette {
    let theme: UITheme
    /// 窗口背景的毛玻璃材质；nil 表示纯色
    let material: NSVisualEffectView.Material?
    /// 盖在毛玻璃上的颜色（纯色主题就是背景色）
    let windowTint: Color
    /// 浮起来的面板：侧边栏、文件、监控、新标签页
    let panel: Color
    let panelBorder: Color
    let panelShadow: Color
    /// 胶囊：标签栏、工具按钮、状态栏、撰写栏
    let capsule: Color
    /// 选中的标签
    let tabSelected: Color
    let tabSelectedBorder: Color
    /// 分段控件里选中的那块、白色小按钮
    let raised: Color
    /// 输入框、图标底、次要按钮的底色
    let field: Color
    let fieldBorder: Color
    /// 大输入框（快速连接、撰写栏）的底色
    let input: Color
    /// 侧边栏选中行
    let selection: Color
    let ink: Color
    let ink2: Color
    let muted: Color
    let hairline: Color
    let accent: Color
    let onAccent: Color
    let ok: Color
    let caution: Color
    let danger: Color
    let recordingText: Color
    /// 终端卡片
    let focusRing: NSColor
    let cardBorder: NSColor
    let cardShadow: NSColor
    let popover: Color

    var isDark: Bool { theme.isDark }
    /// 环境色主题才把环境标签画出来
    var showsEnvironment: Bool { theme == .environment }

    static let glass = Palette(
        theme: .glass,
        material: .underWindowBackground,
        windowTint: Color(hex: 0xF3F5F9, opacity: 0.35),
        panel: Color.white.opacity(0.55),
        panelBorder: Color.white.opacity(0.85),
        panelShadow: Color(hex: 0x1E2A50, opacity: 0.10),
        capsule: Color.white.opacity(0.5),
        tabSelected: .white,
        tabSelectedBorder: Color.black.opacity(0.05),
        raised: .white,
        field: Color(hex: 0x767680, opacity: 0.12),
        fieldBorder: Color.black.opacity(0.10),
        input: Color.white.opacity(0.88),
        selection: Color(hex: 0x0062CC, opacity: 0.12),
        ink: Color(hex: 0x1D1D1F),
        ink2: Color(hex: 0x3A3A3C),
        muted: Color(hex: 0x5E6066),
        hairline: Color.black.opacity(0.08),
        accent: Color(hex: 0x0062CC),
        onAccent: .white,
        ok: Color(hex: 0x1FA34A),
        caution: Color(hex: 0xE09A1A),
        danger: Color(hex: 0xD92D20),
        recordingText: Color(hex: 0xB42318),
        focusRing: NSColor(hex: 0x0062CC, alpha: 0.5),
        cardBorder: NSColor(white: 0, alpha: 0.08),
        cardShadow: NSColor(hex: 0x1E2A50, alpha: 0.12),
        popover: Color.white.opacity(0.9)
    )

    static let graphite = Palette(
        theme: .graphite,
        material: .underWindowBackground,
        windowTint: Color(hex: 0x14151A, opacity: 0.62),
        panel: Color(hex: 0x1E2026, opacity: 0.74),
        panelBorder: Color.white.opacity(0.07),
        panelShadow: Color.black.opacity(0.35),
        capsule: Color(hex: 0x1E2026, opacity: 0.74),
        tabSelected: Color(hex: 0x2C2F37),
        tabSelectedBorder: Color.white.opacity(0.08),
        raised: Color(hex: 0x3A3D45),
        field: Color.white.opacity(0.06),
        fieldBorder: Color.white.opacity(0.10),
        input: Color.white.opacity(0.07),
        selection: Color(hex: 0xF26B43, opacity: 0.16),
        ink: Color(hex: 0xECEDEE),
        ink2: Color(hex: 0xC9CCD2),
        muted: Color(hex: 0x9EA3AD),
        hairline: Color.white.opacity(0.07),
        accent: Color(hex: 0xF2845C),
        onAccent: Color(hex: 0x111216),
        ok: Color(hex: 0x4CC38A),
        caution: Color(hex: 0xE8B04B),
        danger: Color(hex: 0xFF6B6B),
        recordingText: Color(hex: 0xFF8F87),
        focusRing: NSColor(hex: 0xF2845C, alpha: 0.5),
        cardBorder: NSColor(white: 1, alpha: 0.08),
        cardShadow: NSColor(white: 0, alpha: 0.35),
        popover: Color(hex: 0x22242A, opacity: 0.96)
    )

    static let environment = Palette(
        theme: .environment,
        material: nil,
        windowTint: Color(hex: 0xEEF0F3),
        panel: .white,
        panelBorder: Color(hex: 0x0F172A, opacity: 0.06),
        panelShadow: Color(hex: 0x0F172A, opacity: 0.07),
        capsule: .white,
        tabSelected: Color(hex: 0xEEF0F3),
        tabSelectedBorder: Color(hex: 0x0F172A, opacity: 0.08),
        raised: .white,
        field: Color(hex: 0xEEF0F3),
        fieldBorder: Color(hex: 0x0F172A, opacity: 0.12),
        input: .white,
        selection: Color(hex: 0xEDEFF2),
        ink: Color(hex: 0x1F2328),
        ink2: Color(hex: 0x2F353D),
        muted: Color(hex: 0x57606A),
        hairline: Color(hex: 0x0F172A, opacity: 0.08),
        accent: Color(hex: 0x1F2328),
        onAccent: .white,
        ok: Color(hex: 0x2DA44E),
        caution: Color(hex: 0xBF8700),
        danger: Color(hex: 0xE5484D),
        recordingText: Color(hex: 0xB4232A),
        // 终端卡片是深色的，焦点框用浅灰才看得见
        focusRing: NSColor(hex: 0x8D939C, alpha: 0.9),
        cardBorder: NSColor(white: 0, alpha: 0),
        cardShadow: NSColor(hex: 0x0F172A, alpha: 0.16),
        popover: .white
    )
}

/// 环境标签的颜色（环境色主题用）。颜色之外总有文字标签，不只靠颜色区分
struct EnvironmentStyle {
    let swatch: Color
    let chipBackground: Color
    let chipText: Color
    let ring: NSColor

    static func of(_ environment: SessionEnvironment) -> EnvironmentStyle {
        switch environment {
        case .production:
            EnvironmentStyle(swatch: Color(hex: 0xE5484D), chipBackground: Color(hex: 0xFFE4E5),
                             chipText: Color(hex: 0xB4232A), ring: NSColor(hex: 0xE5484D, alpha: 0.6))
        case .testing:
            EnvironmentStyle(swatch: Color(hex: 0x12A594), chipBackground: Color(hex: 0xE7F8F6),
                             chipText: Color(hex: 0x0F766E), ring: NSColor(hex: 0x12A594, alpha: 0.6))
        case .device:
            EnvironmentStyle(swatch: Color(hex: 0x7C5CFC), chipBackground: Color(hex: 0xF1EDFF),
                             chipText: Color(hex: 0x6D28D9), ring: NSColor(hex: 0x7C5CFC, alpha: 0.6))
        }
    }

    static func labelColor(_ environment: SessionEnvironment, dark: Bool) -> Color {
        guard dark else { return of(environment).chipText }
        switch environment {
        case .production: return Color(hex: 0xFF9EA2)
        case .testing: return Color(hex: 0x5ED9C5)
        case .device: return Color(hex: 0xB9A3FF)
        }
    }

    /// 没有环境标签时的头像颜色
    static let neutral = EnvironmentStyle(swatch: Color(hex: 0x8B949E), chipBackground: Color(hex: 0xEEF0F3),
                                          chipText: Color(hex: 0x2F353D), ring: NSColor(hex: 0x1F2328, alpha: 0.45))

    /// 头像上的两个字：web-01 → W1，db-master → DM，staging → ST，核心交换机 → 核心
    static func initials(for name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard let first = trimmed.first else { return "?" }
        if !first.isASCII { return String(trimmed.prefix(2)) }
        if let last = trimmed.last, last.isNumber, trimmed.count > 1 {
            return (String(first) + String(last)).uppercased()
        }
        let words = trimmed.split { !$0.isLetter && !$0.isNumber }
        if words.count >= 2, let second = words[1].first {
            return (String(first) + String(second)).uppercased()
        }
        return String(trimmed.prefix(2)).uppercased()
    }
}

extension SessionStore {
    /// 会话所在分组的环境标签；快速连接（没保存的会话）没有
    func environment(of profile: SessionProfile?) -> SessionEnvironment? {
        guard let profile, session(profile.id) != nil else { return nil }
        return library.environment(of: profile)
    }
}

// MARK: - 当前主题

/// 设置里的选择（跟随系统或固定一套）解析成当前用的主题；固定主题时让整个 App 用对应的浅色、深色外观
final class ThemeStore: ObservableObject {
    static let shared = ThemeStore()

    @Published private(set) var theme: UITheme
    private var defaultsObserver: NSObjectProtocol?
    private var appearanceObserver: NSKeyValueObservation?

    private init() {
        theme = Self.resolve()
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.refresh() }
        appearanceObserver = NSApplication.shared.observe(\.effectiveAppearance) { [weak self] _, _ in
            DispatchQueue.main.async { self?.refresh() }
        }
        applyAppearance()
    }

    var palette: Palette { theme.palette }

    /// system / glass / graphite / environment
    static var choice: String {
        TestHooks.uiTheme ?? UserDefaults.standard.string(forKey: Prefs.uiTheme) ?? "system"
    }

    static func select(_ choice: String) {
        UserDefaults.standard.set(choice, forKey: Prefs.uiTheme)
    }

    static func resolve() -> UITheme {
        UITheme(rawValue: choice) ?? (systemIsDark ? .graphite : .glass)
    }

    /// 系统现在是不是深色模式（App 自己固定了外观时，effectiveAppearance 就不是系统的了）
    static var systemIsDark: Bool {
        if NSApp.appearance == nil {
            return NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        }
        return UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"
    }

    func refresh() {
        applyAppearance()
        let latest = Self.resolve()
        if latest != theme { theme = latest }
        // 终端配色“跟随界面主题”时跟着换（放在外观改好之后，免得读到旧的深浅色）
        TerminalAppearance.shared.refresh()
    }

    private func applyAppearance() {
        let wanted: NSAppearance.Name? = UITheme(rawValue: Self.choice).map { $0.isDark ? .darkAqua : .aqua }
        if NSApp.appearance?.name != wanted {
            NSApp.appearance = wanted.flatMap(NSAppearance.init(named:))
        }
    }
}

private struct PaletteKey: EnvironmentKey {
    static let defaultValue = Palette.glass
}

extension EnvironmentValues {
    var palette: Palette {
        get { self[PaletteKey.self] }
        set { self[PaletteKey.self] = newValue }
    }
}

// MARK: - 颜色

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: opacity)
    }
}

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: alpha)
    }
}

// MARK: - 通用的外观部件

extension View {
    /// 浮起来的面板：圆角、细边、柔和的影子
    func panelCard(_ palette: Palette, radius: CGFloat = 16) -> some View {
        background(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(palette.panel)
                .overlay(
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .strokeBorder(palette.panelBorder, lineWidth: 0.5)
                )
                .shadow(color: palette.panelShadow, radius: 14, y: 6)
        )
    }

    /// 胶囊：标签栏、工具按钮组、状态栏
    func capsuleBar(_ palette: Palette, radius: CGFloat = 14) -> some View {
        background(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(palette.capsule)
                .overlay(
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .strokeBorder(palette.panelBorder, lineWidth: 0.5)
                )
                .shadow(color: palette.panelShadow.opacity(0.6), radius: 2, y: 1)
        )
    }

    /// 输入框、下拉按钮的底
    func fieldBackground(_ palette: Palette, radius: CGFloat = 8) -> some View {
        background(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(palette.field)
        )
    }
}

/// 工具栏、面板上的图标按钮：30×30，选中时有底色
struct ChromeIconButton: View {
    let systemImage: String
    let help: String
    var title: String? = nil
    var isOn = false
    var enabled = true
    let action: () -> Void
    @Environment(\.palette) private var palette

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: systemImage)
                if let title { Text(title).font(.system(size: 12, weight: .medium)) }
            }
                .font(.system(size: 13.5, weight: .medium))
                .padding(.horizontal, title == nil ? 0 : 8)
                .frame(minWidth: 30, minHeight: 30)
                .foregroundStyle(isOn ? palette.accent : palette.ink2)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(isOn ? palette.tabSelected : Color.clear)
                        .shadow(color: isOn ? palette.panelShadow : .clear, radius: 1, y: 0.5)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// 自己画的分段控件（系统的在三套主题里不好统一）
struct ThemedSegments<Value: Hashable>: View {
    let options: [(title: String, value: Value)]
    @Binding var selection: Value
    var height: CGFloat = 26
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                let selected = option.value == selection
                Button {
                    selection = option.value
                } label: {
                    Text(option.title)
                        .font(.system(size: 12, weight: selected ? .semibold : .medium))
                        .foregroundStyle(selected ? palette.ink : palette.ink2)
                        .frame(maxWidth: .infinity)
                        .frame(height: height)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(selected ? palette.raised : Color.clear)
                                .shadow(color: selected ? Color.black.opacity(palette.isDark ? 0.4 : 0.12) : .clear, radius: 1, y: 0.5)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(option.title)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(palette.field))
    }
}

/// 环境标签的小字块（生产 / 测试 / 设备）
struct EnvironmentChip: View {
    let environment: SessionEnvironment
    @Environment(\.palette) private var palette

    var body: some View {
        let style = EnvironmentStyle.of(environment)
        Text(environment.title)
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(EnvironmentStyle.labelColor(environment, dark: palette.isDark))
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(palette.isDark ? style.swatch.opacity(0.16) : style.chipBackground)
            )
            .help("环境由分组决定，在分组的右键菜单里修改")
    }
}

/// 会话的字母头像（环境色主题里代替协议图标）
struct SessionAvatar: View {
    let name: String
    let environment: SessionEnvironment?
    var size: CGFloat = 30
    /// 右下角的连接状态点（nil 不画）
    var status: Color?
    var ringColor: Color = .white

    var body: some View {
        let style = environment.map(EnvironmentStyle.of) ?? .neutral
        Text(EnvironmentStyle.initials(for: name))
            .font(.system(size: size * 0.37, weight: .bold))
            .foregroundStyle(style.chipText)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.3, style: .continuous).fill(style.chipBackground))
            .overlay(alignment: .bottomTrailing) {
                if let status {
                    Circle()
                        .fill(status)
                        .frame(width: size * 0.27, height: size * 0.27)
                        .overlay(Circle().stroke(ringColor, lineWidth: 2))
                        .offset(x: 2, y: 2)
                }
            }
    }
}

// MARK: - 窗口

/// 窗口背景：毛玻璃（透出桌面）或纯色
struct WindowBackground: View {
    let palette: Palette

    var body: some View {
        ZStack {
            if let material = palette.material {
                VisualEffect(material: material)
            }
            palette.windowTint
        }
    }
}

private struct VisualEffect: NSViewRepresentable {
    let material: NSVisualEffectView.Material

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        view.material = material
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
    }
}

/// 可以拖着移动窗口的空白处（标题栏藏起来了，工具栏的空白处代替它）；双击按系统设置缩放或最小化
struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ view: DragView, context: Context) {}

    final class DragView: NSView {
        override func mouseDown(with event: NSEvent) {
            guard let window else { return }
            if event.clickCount == 2 {
                switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
                case "Minimize": window.performMiniaturize(nil)
                case "None": break
                default: window.performZoom(nil)
                }
            } else {
                window.performDrag(with: event)
            }
        }
    }
}

/// 两个区域之间可以拖动的缝（调侧边栏、右侧面板的宽度）
struct ResizeHandle: View {
    @Binding var width: Double
    let range: ClosedRange<Double>
    /// 拖动的那条边在被调整区域的右边（侧边栏）还是左边（右侧面板）
    let growsRightward: Bool
    @StateObject private var drag = DragOrigin()

    var body: some View {
        Color.clear
            .frame(width: 8)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        let start = drag.start ?? width
                        drag.start = start
                        let delta = Double(value.translation.width) * (growsRightward ? 1 : -1)
                        width = min(max(start + delta, range.lowerBound), range.upperBound)
                    }
                    .onEnded { _ in drag.start = nil }
            )
    }

    final class DragOrigin: ObservableObject {
        var start: Double?
    }
}

// MARK: - 主题选择

/// 主题的小样：背景、侧边栏、终端卡片、强调色
struct ThemeSwatch: View {
    let theme: UITheme
    var width: CGFloat = 48
    var height: CGFloat = 34

    var body: some View {
        let colors = Self.colors(theme)
        RoundedRectangle(cornerRadius: height * 0.24, style: .continuous)
            .fill(colors.background)
            .overlay(alignment: .topLeading) {
                HStack(spacing: width * 0.06) {
                    RoundedRectangle(cornerRadius: 3).fill(colors.side).frame(width: width * 0.23)
                    RoundedRectangle(cornerRadius: 3).fill(colors.card)
                        .overlay(alignment: .topLeading) {
                            Circle().fill(colors.accent).frame(width: height * 0.18).padding(height * 0.12)
                        }
                }
                .padding(height * 0.15)
            }
            .overlay(alignment: .top) {
                if theme == .environment {
                    Rectangle().fill(Color(hex: 0xE5484D)).frame(height: 2.5)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: height * 0.24, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: height * 0.24, style: .continuous).strokeBorder(Color.gray.opacity(0.35), lineWidth: 0.5))
            .frame(width: width, height: height)
            .accessibilityHidden(true)
    }

    private static func colors(_ theme: UITheme) -> (background: AnyShapeStyle, side: Color, card: Color, accent: Color) {
        switch theme {
        case .glass:
            (AnyShapeStyle(LinearGradient(colors: [Color(hex: 0xCFE0FF), Color(hex: 0xFFE1D1)], startPoint: .topLeading, endPoint: .bottomTrailing)),
             Color.white.opacity(0.85), .white, Color(hex: 0x0062CC))
        case .graphite:
            (AnyShapeStyle(Color(hex: 0x0F1013)), Color(hex: 0x2A2D33), Color(hex: 0x16171B), Color(hex: 0xF26B43))
        case .environment:
            (AnyShapeStyle(Color(hex: 0xE3E6EB)), .white, Color(hex: 0x1A1D23), Color(hex: 0xFF9EA2))
        }
    }
}

/// 工具栏调色板按钮弹出的主题选择
struct ThemePicker: View {
    @ObservedObject private var store = ThemeStore.shared
    @AppStorage(Prefs.uiTheme) private var choice = "system"
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("外观主题")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(palette.muted)
                .padding(.horizontal, 8)
                .padding(.top, 4)
                .padding(.bottom, 6)
            ForEach(UITheme.allCases) { theme in
                let current = store.theme == theme
                Button {
                    ThemeStore.select(theme.rawValue)
                } label: {
                    HStack(spacing: 12) {
                        ThemeSwatch(theme: theme)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(theme.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(palette.ink)
                            Text(theme.summary).font(.system(size: 11.5)).foregroundStyle(palette.muted)
                        }
                        Spacer(minLength: 4)
                        if current {
                            Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)).foregroundStyle(palette.accent)
                        }
                    }
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(current ? palette.selection : Color.clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(current ? .isSelected : [])
            }
            Divider().padding(.horizontal, 8).padding(.vertical, 4)
            Toggle(isOn: Binding(
                get: { choice == "system" },
                set: { ThemeStore.select($0 ? "system" : store.theme.rawValue) }
            )) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("跟随系统外观").font(.system(size: 12.5)).foregroundStyle(palette.ink)
                    Text("系统是浅色时用玻璃，深色时用石墨").font(.system(size: 11)).foregroundStyle(palette.muted)
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .padding(.horizontal, 8)
            .padding(.bottom, 4)
        }
        .padding(8)
        .frame(width: 300)
    }
}
