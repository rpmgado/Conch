import AppKit
import ConchKit
import SwiftUI

/// 设置窗口里的各页
enum SettingsPage: String {
    case appearance, terminal, transfer, quickCommands, logs, sync
}

/// 从别处（右键菜单、撰写栏）打开设置时，先切到要用的那一页
final class SettingsNavigation: ObservableObject {
    static let shared = SettingsNavigation()
    @Published var page: SettingsPage = .appearance
}

/// 设置窗口（⌘,）
struct SettingsView: View {
    @ObservedObject private var themes = ThemeStore.shared
    @ObservedObject private var navigation = SettingsNavigation.shared

    var body: some View {
        tabs
            .environment(\.palette, themes.palette)
            .tint(themes.palette.accent)
    }

    private var tabs: some View {
        TabView(selection: $navigation.page) {
            AppearanceSettings()
                .tabItem { Label("外观", systemImage: "paintpalette") }
                .tag(SettingsPage.appearance)
            TerminalSettings()
                .tabItem { Label("终端", systemImage: "terminal") }
                .tag(SettingsPage.terminal)
            TransferSettings()
                .tabItem { Label("传输", systemImage: "arrow.up.arrow.down") }
                .tag(SettingsPage.transfer)
            QuickCommandSettings()
                .tabItem { Label("快捷命令", systemImage: "text.badge.plus") }
                .tag(SettingsPage.quickCommands)
            LogSettings()
                .tabItem { Label("日志", systemImage: "doc.text") }
                .tag(SettingsPage.logs)
            SyncSecuritySettings()
                .tabItem { Label("同步与安全", systemImage: "lock.icloud") }
                .tag(SettingsPage.sync)
        }
        .frame(width: 580, height: 640)
    }
}

private struct SyncSecuritySettings: View {
    @AppStorage(Prefs.syncDirectory) private var syncDirectory = ""
    @AppStorage(Prefs.requireAuthForSecrets) private var requireAuth = false

    var body: some View {
        Form {
            Section {
                LabeledContent("同步文件夹") {
                    HStack {
                        Text(syncDirectory.isEmpty ? "未开启" : (syncDirectory as NSString).abbreviatingWithTildeInPath)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(syncDirectory)
                        if syncDirectory.isEmpty {
                            if let iCloud = SyncSettings.iCloudDriveRoot {
                                Button("用 iCloud 云盘") { enable(iCloud.appendingPathComponent("Conch", isDirectory: true)) }
                            }
                            Button("选择文件夹…", action: chooseFolder)
                        } else {
                            Button("在访达中显示") { NSWorkspace.shared.open(URL(fileURLWithPath: syncDirectory, isDirectory: true)) }
                            Button("停止同步") { SyncSettings.disable() }
                        }
                    }
                }
                Text("会话、分组和快捷命令存放在所选同步文件夹。会话按字段合并；发生冲突时保留本机操作，并在本机保存双方版本。同步延迟取决于你的同步服务，快捷命令仍采用整份文件同步。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("保存的密码在各自 Mac 的钥匙串里，信任过的主机也各自记录，都不会放进同步文件夹。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } header: {
                Text("会话同步")
            }

            Section {
                Toggle("使用保存的密码前，先用 Touch ID 或登录密码验证", isOn: $requireAuth)
                Text("打开后，连接时要用钥匙串里保存的密码或私钥口令，会先要求验证；验证一次，5 分钟内不再问。取消或系统无法验证时改为手动输入密码。断线自动重连不会再问。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } header: {
                Text("密码保护")
            }
        }
        .formStyle(.grouped)
        .padding(.vertical, 8)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "用这个文件夹同步"
        panel.message = "选择同步盘里的一个文件夹，Conch 会在里面建一个 Conch 文件夹存放会话列表"
        if panel.runModal() == .OK, let url = panel.url {
            enable(url.lastPathComponent == "Conch" ? url : url.appendingPathComponent("Conch", isDirectory: true))
        }
    }

    private func enable(_ directory: URL) {
        do {
            try SyncSettings.enable(directory)
        } catch {
            Dialogs.inform("没法使用这个文件夹", detail: error.localizedDescription, window: nil)
        }
    }
}

private struct AppearanceSettings: View {
    @AppStorage(Prefs.compactSidebar) private var compactSidebar = false
    @AppStorage(Prefs.uiTheme) private var uiTheme = "system"
    @AppStorage(Prefs.themeID) private var themeID = TerminalTheme.followUIID
    @AppStorage(Prefs.fontFamily) private var fontFamily = ""
    @AppStorage(Prefs.fontSize) private var fontSize = 13.0
    @ObservedObject private var appearance = TerminalAppearance.shared
    @ObservedObject private var themes = ThemeStore.shared

    var body: some View {
        Form {
            Section {
                HStack(spacing: 10) {
                    ForEach(UITheme.allCases) { theme in
                        ThemeCard(theme: theme, selected: themes.theme == theme) {
                            ThemeStore.select(theme.rawValue)
                        }
                    }
                }
                Toggle("紧凑会话列表", isOn: $compactSidebar)
                    .help("隐藏地址副标题，显示更多会话；关闭后使用更易读的舒适间距")
                Toggle(isOn: Binding(
                    get: { uiTheme == "system" },
                    set: { ThemeStore.select($0 ? "system" : themes.theme.rawValue) }
                )) {
                    Text("跟随系统外观")
                    Text("系统是浅色时用“玻璃”，深色时用“石墨”")
                }
            } header: {
                Text("界面主题")
            } footer: {
                Text("工具栏调色板可随时切换外观。生产环境文字提示在三套主题下都保留；分组右键可设置环境。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Section {
                Picker("配色", selection: $themeID) {
                    Text("跟随界面主题").tag(TerminalTheme.followUIID)
                    Text("跟随系统（浅色 / 深色自动切换）").tag(TerminalTheme.systemID)
                    Divider()
                    ForEach(TerminalTheme.all) { theme in
                        Text(theme.name).tag(theme.id)
                    }
                }
                ThemePreview(theme: appearance.snapshot.theme, font: appearance.snapshot.font)
                    .frame(height: 112)

                Picker("字体", selection: $fontFamily) {
                    Text("系统等宽字体（SF Mono）").tag("")
                    Divider()
                    ForEach(TerminalAppearance.monospacedFamilies, id: \.self) { family in
                        Text(family).tag(family)
                    }
                }
                Stepper(value: $fontSize, in: 8...40, step: 1) {
                    Text("字号：\(Int(fontSize))")
                }
                Text("也可以在终端里用 ⌘+ / ⌘- 调整，⌘0 恢复默认。中文会自动用系统的中文字体显示。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } header: {
                Text("终端")
            }
        }
        .formStyle(.grouped)
        .padding(.vertical, 8)
    }
}

/// 界面主题的卡片：小样、名字、一句话说明，选中的有一圈强调色
private struct ThemeCard: View {
    let theme: UITheme
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 7) {
                ThemeSwatch(theme: theme, width: 150, height: 48)
                HStack(spacing: 4) {
                    Text(theme.title).font(.system(size: 12.5, weight: .semibold))
                    Spacer(minLength: 0)
                    if selected {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor)
                    }
                }
                Text(theme.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .lineLimit(2)
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.04)))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.08), lineWidth: selected ? 2 : 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(theme.title)主题")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// 配色预览：一段模拟的终端内容 + 16 色色块
private struct ThemePreview: View {
    let theme: TerminalTheme
    let font: NSFont

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 0) {
                    Text("deploy@web-01").foregroundStyle(color(theme.ansi[2]))
                    Text(":").foregroundStyle(color(theme.foreground))
                    Text("~/app").foregroundStyle(color(theme.ansi[4]))
                    Text("$ ls --color").foregroundStyle(color(theme.foreground))
                }
                HStack(spacing: 12) {
                    Text("config/").foregroundStyle(color(theme.ansi[12]))
                    Text("run.sh").foregroundStyle(color(theme.ansi[10]))
                    Text("error.log").foregroundStyle(color(theme.ansi[1]))
                    Text("README.md").foregroundStyle(color(theme.foreground))
                }
            }
            .font(.custom(font.fontName, size: 12))
            HStack(spacing: 3) {
                ForEach(0..<16, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(color(theme.ansi[index]))
                        .frame(width: 18, height: 12)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(color(theme.background)))
    }

    private func color(_ rgb: RGB) -> SwiftUI.Color {
        SwiftUI.Color(nsColor: NSColor(rgb))
    }
}

private struct TerminalSettings: View {
    @AppStorage(Prefs.cursorShape) private var cursorShape = "block"
    @AppStorage(Prefs.cursorBlink) private var cursorBlink = true
    @AppStorage(Prefs.scrollback) private var scrollback = 10_000
    @AppStorage(Prefs.optionAsMeta) private var optionAsMeta = true
    @AppStorage(Prefs.useMetal) private var useMetal = true
    @AppStorage(Prefs.confirmClose) private var confirmClose = true
    @AppStorage(Prefs.highlightEnabled) private var highlight = true
    @AppStorage(Prefs.highlightRed) private var red = KeywordHighlighter.defaultRed
    @AppStorage(Prefs.highlightYellow) private var yellow = KeywordHighlighter.defaultYellow
    @AppStorage(Prefs.highlightGreen) private var green = KeywordHighlighter.defaultGreen

    var body: some View {
        Form {
            Section("关键字高亮") {
                Toggle("给输出里的关键字加颜色", isOn: $highlight)
                TextField("红色", text: $red, prompt: Text(KeywordHighlighter.defaultRed))
                    .disabled(!highlight)
                TextField("黄色", text: $yellow, prompt: Text(KeywordHighlighter.defaultYellow))
                    .disabled(!highlight)
                TextField("绿色", text: $green, prompt: Text(KeywordHighlighter.defaultGreen))
                    .disabled(!highlight)
                Text("用逗号分隔，整词匹配、不分大小写。vim、top 这类全屏程序里不会加颜色；日志文件里保存的是原始内容。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Picker("光标", selection: $cursorShape) {
                Text("方块").tag("block")
                Text("竖线").tag("bar")
                Text("下划线").tag("underline")
            }
            .pickerStyle(.segmented)
            Toggle("光标闪烁", isOn: $cursorBlink)
            Picker("回滚行数", selection: $scrollback) {
                Text("1,000").tag(1_000)
                Text("5,000").tag(5_000)
                Text("10,000").tag(10_000)
                Text("50,000").tag(50_000)
                Text("100,000").tag(100_000)
            }
            Toggle("把 Option 键当作 Meta 键", isOn: $optionAsMeta)
                .help("打开后 Option+B / Option+F 等能在 bash、emacs 里按词移动；关掉后 Option 用来输入特殊字符")
            Toggle("使用 GPU 渲染（Metal）", isOn: $useMetal)
            Toggle("关闭有连接的标签页或窗口前确认", isOn: $confirmClose)
        }
        .formStyle(.grouped)
        .padding(.vertical, 8)
    }
}

private struct TransferSettings: View {
    @AppStorage(Prefs.downloadDirectory) private var downloadDirectory = ""
    @AppStorage(Prefs.editorApp) private var editorApp = ""

    var body: some View {
        Form {
            LabeledContent("下载目录") {
                HStack {
                    Text((AppPaths.downloadsDirectory.path as NSString).abbreviatingWithTildeInPath)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button("选择…", action: choose)
                    if !downloadDirectory.isEmpty {
                        Button("恢复默认") { downloadDirectory = "" }
                    }
                }
            }
            Text("文件面板里双击下载的文件、远端执行 sz 发过来的文件都放在这里；同名文件不会被覆盖，会改名保存。")
                .font(.caption)
                .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            LabeledContent("远程编辑用") {
                HStack {
                    Text(editorApp.isEmpty ? "按文件类型用默认应用" : FileManager.default.displayName(atPath: editorApp))
                        .lineLimit(1)
                    Button("选择应用…", action: chooseEditor)
                    if !editorApp.isEmpty {
                        Button("恢复默认") { editorApp = "" }
                    }
                }
            }
            Text("文件面板里右键“用本机编辑器打开”：文件下载到本机，用这个应用打开，保存后自动传回服务器。默认应用是终端这类会直接执行文件的，会改用文本编辑。")
                .font(.caption)
                .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            Text("rz / sz：在远端执行 sz 文件名 下载，执行 rz 会弹出窗口选择要上传的文件。单个文件不能超过 4 GB，大文件建议用文件面板（SFTP），可以断点续传。")
                .font(.caption)
                .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
        }
        .formStyle(.grouped)
        .padding(.vertical, 8)
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "选择"
        if panel.runModal() == .OK, let url = panel.url {
            downloadDirectory = url.path
        }
    }

    private func chooseEditor() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "选择"
        if panel.runModal() == .OK, let url = panel.url {
            editorApp = url.path
        }
    }
}

private struct QuickCommandSettings: View {
    @ObservedObject private var store = QuickCommandStore.shared

    var body: some View {
        Form {
            Section {
                ForEach($store.commands) { $command in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 4) {
                            TextField("名称", text: $command.name)
                            TextField("命令", text: $command.command, axis: .vertical)
                                .font(.body.monospaced())
                                .lineLimit(1...4)
                            Toggle("发送后自动回车", isOn: $command.pressEnter)
                                .font(.caption)
                        }
                        Button {
                            store.commands.removeAll { $0.id == command.id }
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                    }
                    .padding(.vertical, 2)
                }
                Button {
                    store.commands.append(QuickCommand(name: "新命令", command: ""))
                } label: {
                    Label("添加快捷命令", systemImage: "plus")
                }
            } footer: {
                Text("快捷命令显示在撰写栏上（菜单“会话 → 撰写栏和快捷命令”，⌥⌘B），点一下就发给当前会话；打开同步输入时发给所有会话。多行命令会逐行发送。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .formStyle(.grouped)
        .padding(.vertical, 8)
    }
}

private struct LogSettings: View {
    @AppStorage(Prefs.logDirectory) private var logDirectory = ""
    @AppStorage(Prefs.logPlainText) private var plainText = true
    @AppStorage(Prefs.logTimestamps) private var timestamps = false

    var body: some View {
        Form {
            LabeledContent("日志目录") {
                HStack {
                    Text((AppPaths.logDirectory.path as NSString).abbreviatingWithTildeInPath)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    Button("选择…", action: chooseDirectory)
                    if !logDirectory.isEmpty {
                        Button("恢复默认") { logDirectory = "" }
                    }
                }
            }
            Picker("格式", selection: $plainText) {
                Text("纯文本（去掉颜色和控制字符）").tag(true)
                Text("原始输出（可以用 cat 回放颜色）").tag(false)
            }
            Toggle("每行前面加时间戳", isOn: $timestamps)
                .disabled(!plainText)
            Button("在访达中打开日志目录") {
                let url = AppPaths.logDirectory
                try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                NSWorkspace.shared.open(url)
            }
            Text("可以在会话设置里打开“连接后自动记录会话日志”，也可以随时用菜单“会话 → 开始记录日志”（⌥⌘L）。新设置对之后开始的日志生效。")
                .font(.caption)
                .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
        }
        .formStyle(.grouped)
        .padding(.vertical, 8)
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "选择"
        if panel.runModal() == .OK, let url = panel.url {
            logDirectory = url.path
        }
    }
}
