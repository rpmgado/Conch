import AppKit
import ConchKit
import SwiftUI

@main
struct ConchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        // 0.3 及以前的 App 标识不一样，先把那边的设置搬过来，再注册默认值
        if !TestHooks.isActive {
            LegacyDefaults.migrate(.standard, to: Bundle.main.bundleIdentifier)
        }
        Prefs.register()
    }

    var body: some Scene {
        WindowGroup("Conch", id: "main") {
            MainWindow()
        }
        .defaultSize(width: 1100, height: 680)
        .commands {
            ConchCommands()
        }

        Settings {
            SettingsView()
        }
    }
}

/// 菜单和快捷键。作用在当前（最前面的）窗口上
struct ConchCommands: Commands {
    @FocusedObject private var workspace: WorkspaceModel?
    @Environment(\.openWindow) private var openWindow
    @AppStorage(Prefs.useMetal) private var useMetal = true
    @AppStorage(Prefs.uiTheme) private var uiTheme = "system"

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("新建窗口") { openWindow(id: "main") }
                .keyboardShortcut("n")
            Button("新建标签页") { workspace?.newTab() }
                .keyboardShortcut("t")
                .disabled(workspace == nil)
            Divider()
            Button("新建会话…") { workspace?.editNew() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(workspace == nil)
            Menu("导入") {
                Button("~/.ssh/config") { workspace?.importSSHConfig() }
                Button("Xshell 会话文件…") { workspace?.importXshell() }
            }
            .disabled(workspace == nil)
        }

        // 替换系统的“关闭”：⌘W 关标签页，⇧⌘W 关窗口
        CommandGroup(replacing: .saveItem) {
            // 设置窗口等其他窗口没有标签页，⌘W 直接关窗口
            Button(workspace == nil ? "关闭" : workspace?.currentTab?.isSplit == true ? "关闭分屏" : "关闭标签页") {
                if let workspace { workspace.closeSelectedTab() } else { NSApp.keyWindow?.performClose(nil) }
            }
            .keyboardShortcut("w")
            Button("关闭窗口") {
                if let workspace { workspace.requestCloseWindow() } else { NSApp.keyWindow?.performClose(nil) }
            }
            .keyboardShortcut("w", modifiers: [.command, .shift])
        }

        CommandGroup(after: .pasteboard) {
            Divider()
            Button("查找…") { workspace?.toggleFind() }
                .keyboardShortcut("f")
                .disabled(workspace?.activeSession?.isLauncher ?? true)
            Button("查找下一个") {
                if let workspace { workspace.find.visible = true; workspace.find.next(in: workspace.activeSession?.terminalView) }
            }
            .keyboardShortcut("g")
            .disabled(workspace?.activeSession?.isLauncher ?? true)
            Button("查找上一个") {
                if let workspace { workspace.find.visible = true; workspace.find.next(in: workspace.activeSession?.terminalView, backwards: true) }
            }
            .keyboardShortcut("g", modifiers: [.command, .shift])
            .disabled(workspace?.activeSession?.isLauncher ?? true)
            Button("清除回滚缓冲区") { workspace?.activeSession?.clearScrollback() }
                .keyboardShortcut("k")
                .disabled(workspace?.activeSession?.isLauncher ?? true)
        }

        CommandMenu("会话") {
            let tab = workspace?.activeSession
            let hasSession = tab.map { !$0.isLauncher } ?? false
            Button("重新连接") { tab?.reconnect() }
                .keyboardShortcut("r")
                .disabled(!hasSession)
            Button("断开连接") { tab?.disconnect() }
                .disabled(!(tab?.isActive ?? false))
            Button("复制标签页") { if let tab { workspace?.duplicate(tab) } }
                .disabled(!hasSession)
            Divider()
            Button("左右分屏") { workspace?.splitActive(.horizontal) }
                .keyboardShortcut("d")
                .disabled(!(workspace?.canSplit(tab) ?? false))
            Button("上下分屏") { workspace?.splitActive(.vertical) }
                .keyboardShortcut("d", modifiers: [.command, .shift])
                .disabled(!(workspace?.canSplit(tab) ?? false))
            let split = workspace?.currentTab?.isSplit ?? false
            Button(workspace?.currentTab?.zoomedID == nil ? "放大当前分屏" : "还原分屏") { workspace?.toggleZoom() }
                .keyboardShortcut(.return, modifiers: [.command, .shift])
                .disabled(!split)
            Button("平均分配分屏大小") { workspace?.equalizePanes() }
                .disabled(!split)
            Divider()
            Button(tab?.logURL == nil ? "开始记录日志" : "停止记录日志") { tab?.toggleLogging() }
                .keyboardShortcut("l", modifiers: [.command, .option])
                .disabled(!hasSession)
            Button("在访达中显示日志") {
                if let url = tab?.logURL {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                } else {
                    let directory = AppPaths.logDirectory
                    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(directory)
                }
            }
            Divider()
            Button(tab?.isSavedSession == false && hasSession ? "保存为会话…" : "编辑会话…") {
                workspace?.editSelectedTabSession()
            }
            .keyboardShortcut("i")
            .disabled(!hasSession)
            Divider()
            Toggle("文件面板（SFTP）", isOn: binding(\.showFilesPanel))
                .keyboardShortcut("f", modifiers: [.command, .option])
                .disabled(!(tab?.isSSH ?? false))
            Toggle("服务器监控", isOn: binding(\.showMonitor))
                .keyboardShortcut("u", modifiers: [.command, .option])
                .disabled(!(tab?.isSSH ?? false))
            Button("端口转发…") { workspace?.showForwards = true }
                .keyboardShortcut("p", modifiers: [.command, .option])
                .disabled(!(tab?.isSSH ?? false) || !(tab?.isConnected ?? false))
            Divider()
            Toggle("同步输入到所有会话", isOn: binding(\.broadcastInput))
                .keyboardShortcut("i", modifiers: [.command, .option])
                .disabled(workspace == nil)
            Toggle("撰写栏和快捷命令", isOn: binding(\.showComposeBar))
                .keyboardShortcut("b", modifiers: [.command, .option])
                .disabled(workspace == nil)
        }

        CommandGroup(after: .toolbar) {
            Button(workspace?.showSidebar == false ? "显示侧边栏" : "隐藏侧边栏") { workspace?.toggleSidebar() }
                .keyboardShortcut("s", modifiers: [.command, .control])
                .disabled(workspace == nil)
            Menu("外观主题") {
                ForEach(UITheme.allCases) { theme in
                    Toggle(theme.title, isOn: Binding(
                        get: { uiTheme == theme.rawValue },
                        set: { if $0 { ThemeStore.select(theme.rawValue) } }
                    ))
                }
                Divider()
                Toggle("跟随系统外观", isOn: Binding(
                    get: { uiTheme == "system" },
                    set: { ThemeStore.select($0 ? "system" : ThemeStore.shared.theme.rawValue) }
                ))
            }
            Divider()
            Button("放大字体") { TerminalAppearance.adjustFontSize(by: 1) }
                .keyboardShortcut("=")
            Button("缩小字体") { TerminalAppearance.adjustFontSize(by: -1) }
                .keyboardShortcut("-")
            Button("默认字号") { TerminalAppearance.adjustFontSize(by: 0) }
                .keyboardShortcut("0")
            Toggle("使用 GPU 渲染（Metal）", isOn: $useMetal)
            Divider()
            Button("下一个标签页") { workspace?.selectNext(1) }
                .keyboardShortcut("]", modifiers: [.command, .shift])
                .disabled(workspace == nil)
            Button("上一个标签页") { workspace?.selectNext(-1) }
                .keyboardShortcut("[", modifiers: [.command, .shift])
                .disabled(workspace == nil)
            Button("下一个分屏") { workspace?.focusNextPane(1) }
                .keyboardShortcut("]")
                .disabled(!(workspace?.currentTab?.isSplit ?? false))
            Button("上一个分屏") { workspace?.focusNextPane(-1) }
                .keyboardShortcut("[")
                .disabled(!(workspace?.currentTab?.isSplit ?? false))
            Menu("切换到标签页") {
                ForEach(1..<10) { number in
                    Button("第 \(number) 个") { workspace?.select(index: number - 1) }
                        .keyboardShortcut(KeyEquivalent(Character("\(number)")))
                }
            }
            .disabled(workspace == nil)
            Divider()
        }
    }
}

extension ConchCommands {
    /// 菜单里的开关绑到当前窗口的状态上
    private func binding(_ keyPath: ReferenceWritableKeyPath<WorkspaceModel, Bool>) -> Binding<Bool> {
        Binding(
            get: { workspace?[keyPath: keyPath] ?? false },
            set: { workspace?[keyPath: keyPath] = $0 }
        )
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        // 我们有自己的标签栏，不要系统的窗口标签（也就没有“显示标签页栏”菜单）
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 直接运行可执行文件（没有 .app 包）时，也要有 Dock 图标并能接收键盘输入
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        // 先定好界面主题（固定主题时 App 的浅色、深色外观），窗口一出来就是对的
        _ = ThemeStore.shared
        NetworkMonitor.shared.start()
        TestHooks.appDidLaunch()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let active = WorkspaceRegistry.shared.activeConnectionCount
        guard active > 0, UserDefaults.standard.bool(forKey: Prefs.confirmClose), !TestHooks.isActive else {
            return .terminateNow
        }
        let alert = NSAlert()
        alert.messageText = "退出 Conch？"
        alert.informativeText = "还有 \(active) 个连接，退出会全部断开。"
        alert.addButton(withTitle: "退出")
        alert.addButton(withTitle: "取消")
        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        for workspace in WorkspaceRegistry.shared.all {
            workspace.closeAll()
        }
    }
}
