import AppKit
import Combine
import ConchKit
import SwiftTerm
import SwiftUI
import UniformTypeIdentifiers

/// 编辑会话的请求（新建、编辑、把快速连接保存成会话）
struct EditorRequest: Identifiable {
    let id = UUID()
    var profile: SessionProfile
    var isNew: Bool
    /// 保存后让这个标签页改用保存的会话
    weak var adoptingTab: TerminalSession?
}

/// 一个窗口：会话列表 + 一组标签页（每个标签页里可以分屏放几个终端）。
final class WorkspaceModel: NSObject, ObservableObject {
    @Published private(set) var tabs: [WorkspaceTab] = []
    @Published private(set) var selectedTabID: UUID?
    /// 会话列表的选中、搜索、折叠状态（单独一个对象，会话列表不用跟着每个终端的变化重画）
    let sidebar = SidebarState()
    /// 左边的会话列表（⌃⌘S 显示 / 隐藏）
    @Published var showSidebar = true
    /// 工具栏上的外观主题弹窗
    @Published var showThemePicker = false
    @Published var editor: EditorRequest?
    /// 同步输入：在一个终端里敲的键同时发给这个窗口里所有连着的会话
    @Published var broadcastInput = false
    /// 右侧面板：文件（SFTP）或服务器监控
    @Published var sidePanel: SidePanel?
    /// 底部的撰写栏和快捷命令
    @Published var showComposeBar = false
    /// 状态栏上的端口转发面板
    @Published var showForwards = false
    @Published var expandedFiles = false
    /// 文件操作的确认框附着到展开面板，避免排在主窗口现有 sheet 后面。
    var fileDialogWindow: NSWindow? { expandedFiles ? (window?.attachedSheet ?? window) : window }
    /// 文件面板里显示本机那一栏
    @Published var showLocalFiles = TestHooks.isActive ? TestHooks.showLocalFiles : UserDefaults.standard.bool(forKey: Prefs.showLocalFiles) {
        didSet {
            if !TestHooks.isActive, showLocalFiles != oldValue {
                UserDefaults.standard.set(showLocalFiles, forKey: Prefs.showLocalFiles)
            }
        }
    }
    /// 文件面板里本机那一栏（一个窗口一份，切换标签页时位置不变）
    private(set) lazy var localFiles = LocalBrowser()
    let find = FindModel()
    weak var window: NSWindow?
    private var connectedWatcher: AnyCancellable?
    /// 标题栏截走右键时的补救（见 installContextClickFix）
    private var contextClickMonitor: Any?
    private var repostedClick: TimeInterval?

    override init() {
        super.init()
        WorkspaceRegistry.shared.register(self)
        newTab()
        // 窗口里任何一个终端变了（连上、断开、关掉）之后，更新会话列表上的“已连接”绿点；没变就不惊动会话列表
        connectedWatcher = objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.sidebar.setConnected(Set(self.connectedSessions.compactMap { $0.profile?.id }))
            }
    }

    enum SidePanel: String {
        case files
        case monitor
    }

    var showFilesPanel: Bool {
        get { sidePanel == .files }
        set { sidePanel = newValue ? .files : (sidePanel == .files ? nil : sidePanel) }
    }

    var showMonitor: Bool {
        get { sidePanel == .monitor }
        set { sidePanel = newValue ? .monitor : (sidePanel == .monitor ? nil : sidePanel) }
    }

    // MARK: 标签页和分屏

    var currentTab: WorkspaceTab? {
        tabs.first { $0.id == selectedTabID }
    }

    /// 当前标签页里获得焦点的终端（没分屏时就是这个标签页）。菜单、状态栏、文件面板都对它
    var activeSession: TerminalSession? {
        currentTab?.focused
    }

    /// 窗口里所有的终端，按标签页、分屏的顺序
    var allSessions: [TerminalSession] {
        tabs.flatMap(\.sessions)
    }

    func tab(containing session: TerminalSession) -> WorkspaceTab? {
        tabs.first { $0.contains(session) }
    }

    var windowTitle: String {
        guard let session = activeSession, !session.isLauncher else { return "Conch" }
        let title = session.terminalTitle.trimmingCharacters(in: .whitespaces)
        return title.isEmpty ? session.tabTitle : "\(session.tabTitle) — \(title)"
    }

    var connectedSessions: [TerminalSession] {
        allSessions.filter(\.isConnected)
    }

    /// 同步输入：一个终端里敲的键发给其他连着的终端
    func broadcast(_ data: Data, from source: TerminalSession) {
        for session in connectedSessions where session !== source {
            session.receiveBroadcast(data)
        }
    }

    func toggleFind() {
        guard let session = activeSession, !session.isLauncher else { return }
        if find.visible {
            find.close(in: session.terminalView)
            focusTerminalSoon()
        } else {
            find.visible = true
        }
    }

    /// 有连接（或正在连接、等着重连）的终端数
    var activeConnectionCount: Int {
        allSessions.filter(\.isActive).count
    }

    /// 新建标签页，返回里面的终端（还没有连接，显示快速连接页）
    @discardableResult
    func newTab(select: Bool = true) -> TerminalSession {
        let session = TerminalSession(workspace: self)
        let tab = WorkspaceTab(session: session, workspace: self)
        if let current = currentTab, let index = tabs.firstIndex(where: { $0 === current }) {
            tabs.insert(tab, at: index + 1)
        } else {
            tabs.append(tab)
        }
        if select || selectedTabID == nil { self.select(tab) }
        return session
    }

    func select(_ tab: WorkspaceTab) {
        guard tabs.contains(where: { $0 === tab }) else { return }
        selectedTabID = tab.id
        updateVisibility()
    }

    /// 切到这个终端所在的标签页，并把焦点给它
    func select(_ session: TerminalSession) {
        guard let tab = tab(containing: session) else { return }
        if let zoomed = tab.zoomedID, zoomed != session.id { tab.zoomedID = session.id }
        tab.focus(session)
        select(tab)
    }

    func select(index: Int) {
        guard tabs.indices.contains(index) else { return }
        select(tabs[index])
    }

    func selectNext(_ step: Int) {
        guard let current = currentTab, let index = tabs.firstIndex(where: { $0 === current }), !tabs.isEmpty else { return }
        select(tabs[(index + step + tabs.count) % tabs.count])
    }

    /// 只有选中的标签页里、正在显示的终端算“在前台”（后台的有新输出时标签上显示小点）
    private func updateVisibility() {
        for tab in tabs {
            let selected = tab.id == selectedTabID
            for session in tab.sessions {
                session.setVisible(selected && tab.isShowing(session))
            }
        }
    }

    /// 点了某个分屏（鼠标），焦点跟过去
    func paneActivated(_ session: TerminalSession) {
        guard let tab = tab(containing: session), tab.focusedID != session.id else { return }
        tab.focus(session)
    }

    /// 在标签页里连接会话。当前是新标签页就直接用它，否则开一个新的
    func open(_ profile: SessionProfile, adHocJumps: [SessionProfile] = [], secrets: SessionSecrets? = nil, forceNewTab: Bool = false) {
        let session: TerminalSession
        if !forceNewTab, let active = activeSession, active.isLauncher {
            session = active
        } else {
            session = newTab()
        }
        select(session)
        session.open(profile, adHocJumps: adHocJumps, secrets: secrets)
        focusTerminalSoon()
    }

    func openSessions(_ ids: [UUID]) {
        let library = SessionStore.shared.library
        for id in ids {
            if let profile = library.session(id) { open(profile) }
        }
    }

    func duplicate(_ session: TerminalSession) {
        guard let seed = session.duplicationSeed else { return }
        open(seed.profile, adHocJumps: seed.jumps, secrets: seed.secrets, forceNewTab: true)
    }

    /// 能不能拆分：要有连接对象，串口不能同时打开两次
    func canSplit(_ session: TerminalSession?) -> Bool {
        guard let profile = session?.profile else { return false }
        return profile.kind != .serial
    }

    /// 把当前终端一分为二，新的分屏里再连一次同一个会话
    func splitActive(_ axis: PaneAxis) {
        guard let session = activeSession, canSplit(session), let seed = session.duplicationSeed else { return }
        addPane(next: session, axis: axis) { $0.open(seed.profile, adHocJumps: seed.jumps, secrets: seed.secrets) }
    }

    /// 在当前终端旁边分屏打开另一个会话；当前是新标签页时直接在里面打开
    func openInSplit(_ profile: SessionProfile, axis: PaneAxis) {
        guard let session = activeSession, !session.isLauncher else { return open(profile) }
        addPane(next: session, axis: axis) { $0.open(profile) }
    }

    private func addPane(next session: TerminalSession, axis: PaneAxis, open: (TerminalSession) -> Void) {
        guard let tab = tab(containing: session) else { return }
        let pane = TerminalSession(workspace: self)
        // 新终端先用当前终端的尺寸，连上之前就是正确的行列数
        pane.terminalView.frame = session.terminalView.frame
        tab.split(session, axis: axis, with: pane)
        select(pane)
        open(pane)
        focusTerminalSoon()
    }

    /// ⌘] / ⌘[：在当前标签页的分屏之间切换焦点
    func focusNextPane(_ step: Int) {
        guard let tab = currentTab, tab.isSplit else { return }
        let sessions = tab.sessions
        let index = sessions.firstIndex { $0.id == tab.focusedID } ?? 0
        select(sessions[(index + step + sessions.count) % sessions.count])
        focusTerminalSoon()
    }

    /// 放大当前分屏（其他分屏先藏起来），再按一次还原
    func toggleZoom() {
        guard let tab = currentTab, tab.isSplit else { return }
        tab.zoomedID = tab.zoomedID == nil ? tab.focusedID : nil
        updateVisibility()
        focusTerminalSoon()
    }

    func equalizePanes() {
        currentTab?.equalize()
    }

    /// 关闭整个标签页（里面所有分屏）
    func close(_ tab: WorkspaceTab) {
        let active = tab.sessions.filter(\.isActive).count
        let confirm = UserDefaults.standard.bool(forKey: Prefs.confirmClose) && active > 0 && !TestHooks.isActive
        guard confirm else { return remove(tab) }
        select(tab)
        Dialogs.confirm(
            "关闭“\(tab.focused.tabTitle)”？",
            detail: active > 1 ? "这个标签页里的 \(active) 个连接都会断开。" : "关闭标签页会断开这个连接。",
            confirmTitle: "关闭",
            suppressionKey: Prefs.confirmClose,
            window: window
        ) { [weak self] ok in
            if ok { self?.remove(tab) }
        }
    }

    /// 关闭一个分屏；标签页里只有它时关闭整个标签页
    func closePane(_ session: TerminalSession) {
        guard let tab = tab(containing: session) else { return }
        guard tab.isSplit else { return close(tab) }
        let confirm = UserDefaults.standard.bool(forKey: Prefs.confirmClose) && session.isActive && !TestHooks.isActive
        let proceed = { [weak self] in
            guard let self else { return }
            session.close()
            tab.remove(session)
            self.updateVisibility()
            self.focusTerminalSoon()
        }
        guard confirm else { return proceed() }
        select(session)
        Dialogs.confirm(
            "关闭这个分屏？",
            detail: "会断开“\(session.tabTitle)”的连接。",
            confirmTitle: "关闭",
            suppressionKey: Prefs.confirmClose,
            window: window
        ) { ok in
            if ok { proceed() }
        }
    }

    /// 把分屏挪到同一个标签页里另一个分屏的某一边
    func movePane(_ session: TerminalSession, beside target: TerminalSession, edge: PaneEdge) {
        guard let tab = tab(containing: session), tab.contains(target), tab.move(session, beside: target, edge: edge) else { return }
        select(session)
        updateVisibility()
        focusTerminalSoon()
    }

    /// 两个分屏互换位置
    func swapPanes(_ first: TerminalSession, _ second: TerminalSession) {
        guard let tab = tab(containing: first), tab.contains(second) else { return }
        tab.swap(first, second)
        select(first)
        focusTerminalSoon()
    }

    /// 把一个分屏拿出来，放到紧挨着的新标签页里（连接不断）
    func detachPane(_ session: TerminalSession) {
        guard let tab = tab(containing: session), tab.isSplit, let index = tabs.firstIndex(where: { $0 === tab }),
              tab.remove(session)
        else { return }
        let detached = WorkspaceTab(session: session, workspace: self)
        tabs.insert(detached, at: index + 1)
        select(detached)
        focusTerminalSoon()
    }

    /// 终端和分屏标题栏的右键菜单。快捷键和菜单栏里的一致（这里只是显示出来，按键由菜单栏处理）
    func paneMenu(for session: TerminalSession) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let terminal = session.terminalView
        let selection = terminal.selectionActive ? (terminal.getSelection() ?? "") : ""
        let connected = session.isConnected
        let clipboard = NSPasteboard.general.string(forType: .string) ?? ""

        // 拷贝粘贴
        let copy = NSMenuItem(title: "拷贝", action: #selector(TerminalView.copy(_:)), keyEquivalent: "c")
        copy.target = terminal
        copy.isEnabled = !selection.isEmpty
        menu.addItem(copy)
        let paste = NSMenuItem(title: "粘贴", action: #selector(TerminalView.paste(_:)), keyEquivalent: "v")
        paste.target = terminal
        paste.isEnabled = connected && !clipboard.isEmpty
        menu.addItem(paste)
        if !selection.isEmpty {
            menu.addItem(ActionMenuItem("粘贴选中的文字", enabled: connected, help: "把选中的文字当作粘贴发给这个终端") {
                terminal.pasteText(selection)
            })
        }
        menu.addItem(ActionMenuItem("全选", key: "a") { terminal.selectAll() })

        // 选中的是网址、路径时
        menu.addItem(.separator())
        if let url = Self.link(in: selection) {
            menu.addItem(ActionMenuItem("打开链接", help: url.absoluteString) { NSWorkspace.shared.open(url) })
        }
        if session.isSSH, let path = Self.remotePath(in: selection) {
            menu.addItem(ActionMenuItem("在文件面板中显示“\(Self.shortened(path))”", enabled: connected, help: path) { [weak self] in
                self?.revealInFiles(path, from: session)
            })
        }
        menu.addItem(ActionMenuItem(selection.isEmpty ? "查找…" : "查找“\(Self.shortened(selection))”", key: "f") { [weak self] in
            self?.findText(selection, in: session)
        })

        // 快捷命令
        menu.addItem(.separator())
        let commands = QuickCommandStore.shared.commands
        let quick = NSMenuItem(title: "快捷命令", action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: "快捷命令")
        submenu.autoenablesItems = false
        for command in commands {
            submenu.addItem(ActionMenuItem(command.name, enabled: connected, help: command.command) { [weak self] in
                self?.sendQuickCommand(command, from: session)
            })
        }
        if !commands.isEmpty { submenu.addItem(.separator()) }
        submenu.addItem(ActionMenuItem("编辑快捷命令…") { [weak self] in self?.showSettings(.quickCommands) })
        quick.submenu = submenu
        menu.addItem(quick)

        guard !session.isLauncher else { return menu }

        // 分屏
        menu.addItem(.separator())
        let splittable = canSplit(session)
        menu.addItem(ActionMenuItem("左右分屏", key: "d", enabled: splittable) { [weak self] in
            self?.select(session)
            self?.splitActive(.horizontal)
        })
        menu.addItem(ActionMenuItem("上下分屏", key: "d", modifiers: [.command, .shift], enabled: splittable) { [weak self] in
            self?.select(session)
            self?.splitActive(.vertical)
        })
        if let tab = tab(containing: session), tab.isSplit {
            menu.addItem(ActionMenuItem(tab.zoomedID == nil ? "放大这个分屏" : "还原分屏", key: "\r", modifiers: [.command, .shift]) { [weak self] in
                self?.select(session)
                self?.toggleZoom()
            })
            menu.addItem(ActionMenuItem("平均分配分屏大小", enabled: tab.zoomedID == nil) { [weak self] in
                self?.select(session)
                self?.equalizePanes()
            })
            menu.addItem(ActionMenuItem("移到新标签页") { [weak self] in self?.detachPane(session) })
            menu.addItem(ActionMenuItem("关闭这个分屏", key: "w") { [weak self] in self?.closePane(session) })
        }

        // 连接
        menu.addItem(.separator())
        menu.addItem(ActionMenuItem("重新连接", key: "r") { session.reconnect() })
        menu.addItem(ActionMenuItem("断开连接", enabled: session.isActive) { session.disconnect() })
        menu.addItem(ActionMenuItem("复制标签页", help: "在新标签页里再连一次这个会话") { [weak self] in self?.duplicate(session) })
        menu.addItem(ActionMenuItem(session.isSavedSession ? "编辑会话…" : "保存为会话…", key: "i") { [weak self] in
            self?.select(session)
            self?.editSelectedTabSession()
        })
        menu.addItem(ActionMenuItem(session.logURL == nil ? "开始记录日志" : "停止记录日志", key: "l", modifiers: [.command, .option]) {
            session.toggleLogging()
        })

        // 面板和窗口里的开关
        menu.addItem(.separator())
        if session.isSSH {
            menu.addItem(ActionMenuItem("文件面板（SFTP）", key: "f", modifiers: [.command, .option],
                                        checked: sidePanel == .files) { [weak self] in
                self?.select(session)
                self?.showFilesPanel.toggle()
            })
            menu.addItem(ActionMenuItem("服务器监控", key: "u", modifiers: [.command, .option], checked: sidePanel == .monitor) { [weak self] in
                self?.select(session)
                self?.showMonitor.toggle()
            })
            menu.addItem(ActionMenuItem("端口转发…", key: "p", modifiers: [.command, .option], enabled: connected) { [weak self] in
                self?.select(session)
                self?.showForwards = true
            })
        }
        menu.addItem(ActionMenuItem("同步输入到所有会话", key: "i", modifiers: [.command, .option], checked: broadcastInput) { [weak self] in
            self?.broadcastInput.toggle()
        })
        menu.addItem(ActionMenuItem("撰写栏和快捷命令", key: "b", modifiers: [.command, .option], checked: showComposeBar) { [weak self] in
            self?.showComposeBar.toggle()
        })

        // 清理
        menu.addItem(.separator())
        menu.addItem(ActionMenuItem("清除回滚缓冲区", key: "k") { session.clearScrollback() })
        menu.addItem(ActionMenuItem("重置终端", help: "屏幕乱码、鼠标乱跳、光标不见了时用：恢复终端的各种模式，不影响连接") {
            session.resetTerminal()
        })
        return menu
    }

    /// 发快捷命令：开着同步输入时发给所有连着的会话，否则只发给这个
    func sendQuickCommand(_ command: QuickCommand, from session: TerminalSession) {
        let data = Data(command.payload.utf8)
        if broadcastInput {
            for target in connectedSessions { target.receiveBroadcast(data) }
        } else {
            session.receiveBroadcast(data)
        }
        select(session)
        focusTerminalSoon()
    }

    /// 打开文件面板，转到这个路径（是文件就转到它所在的目录并选中它）
    func revealInFiles(_ path: String, from session: TerminalSession) {
        select(session)
        sidePanel = .files
        session.files.reveal(path)
    }

    /// 查找：选中了文字就直接找它
    func findText(_ text: String, in session: TerminalSession) {
        select(session)
        find.visible = true
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, !trimmed.contains("\n") {
            find.text = trimmed
            find.next(in: session.terminalView)
        }
    }

    /// 打开设置窗口（可以指定先显示哪一页）。设置窗口是 SwiftUI 的场景，由 MainWindow 把打开它的方法交过来
    var openSettingsAction: (() -> Void)?

    func showSettings(_ page: SettingsPage? = nil) {
        if let page { SettingsNavigation.shared.page = page }
        openSettingsAction?()
    }

    /// 选中的文字是网址时返回它（http、https，或者 www. 开头的）
    static func link(in text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(where: \.isWhitespace) else { return nil }
        let candidate = trimmed.lowercased().hasPrefix("www.") ? "https://" + trimmed : trimmed
        guard let url = URL(string: candidate), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              url.host?.isEmpty == false
        else { return nil }
        return url
    }

    /// 选中的文字像服务器上的路径（/ 或 ~/ 开头、一行）时返回它
    static func remotePath(in text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 1, trimmed.count < 1024, !trimmed.contains("\n"),
              trimmed.hasPrefix("/") || trimmed.hasPrefix("~/")
        else { return nil }
        return trimmed
    }

    /// 菜单里放不下太长的字：只留开头和结尾
    static func shortened(_ text: String, limit: Int = 28) -> String {
        let flat = text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ")
        guard flat.count > limit else { return flat }
        return String(flat.prefix(limit / 2)) + "…" + String(flat.suffix(limit / 2 - 1))
    }

    // MARK: 标签页的右键菜单用

    /// 关闭这个标签页右边的所有标签页
    func closeTabs(rightOf keep: WorkspaceTab) {
        guard let index = tabs.firstIndex(where: { $0 === keep }), index < tabs.count - 1 else { return }
        let doomed = Array(tabs[(index + 1)...])
        let active = doomed.flatMap(\.sessions).filter(\.isActive).count
        let proceed = { [weak self] in
            for tab in doomed { self?.remove(tab) }
        }
        guard active > 0, UserDefaults.standard.bool(forKey: Prefs.confirmClose), !TestHooks.isActive else { return proceed() }
        Dialogs.confirm("关闭右边的 \(doomed.count) 个标签页？", detail: "其中 \(active) 个连接会被断开。",
                        confirmTitle: "关闭", window: window) { ok in
            if ok { proceed() }
        }
    }

    /// 给标签页起个名字（只改标签栏上显示的，不改会话）
    func renameTab(_ tab: WorkspaceTab) {
        Dialogs.promptText("重命名标签页", detail: "只改标签栏上显示的名字，不改会话。", initial: tab.title,
                           confirmTitle: "重命名", window: window) { name in
            guard let name else { return }
            tab.customTitle = name == tab.focused.tabTitle ? nil : name
        }
    }

    static func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// ⌘W：有分屏时关闭当前分屏，否则关闭当前标签页；只剩一个空白的新标签页时关闭窗口
    func closeSelectedTab() {
        guard let tab = currentTab else { return requestCloseWindow() }
        if tab.isSplit {
            closePane(tab.focused)
        } else if tabs.count == 1, tab.focused.isLauncher {
            requestCloseWindow()
        } else {
            close(tab)
        }
    }

    func closeOthers(_ keep: WorkspaceTab) {
        let others = tabs.filter { $0 !== keep }
        let active = others.flatMap(\.sessions).filter(\.isActive).count
        let proceed = { [weak self] in
            for tab in others { self?.remove(tab) }
        }
        guard active > 0, UserDefaults.standard.bool(forKey: Prefs.confirmClose), !TestHooks.isActive else { return proceed() }
        Dialogs.confirm("关闭其他 \(others.count) 个标签页？", detail: "其中 \(active) 个连接会被断开。",
                        confirmTitle: "关闭", window: window) { ok in
            if ok { proceed() }
        }
    }

    private func remove(_ tab: WorkspaceTab) {
        guard let index = tabs.firstIndex(where: { $0 === tab }) else { return }
        tab.sessions.forEach { $0.close() }
        let wasSelected = tab.id == selectedTabID
        tabs.remove(at: index)
        if tabs.isEmpty {
            // 最后一个标签页关掉后留一个新标签页，窗口不关
            newTab()
        } else if wasSelected {
            select(tabs[min(index, tabs.count - 1)])
        }
    }

    /// 拖动标签页排序：把 id 对应的标签页挪到 target 前面
    func moveTab(_ id: UUID, before target: WorkspaceTab) {
        guard let from = tabs.firstIndex(where: { $0.id == id }), tabs[from] !== target else { return }
        let tab = tabs.remove(at: from)
        let to = tabs.firstIndex(where: { $0 === target }) ?? tabs.count
        tabs.insert(tab, at: to)
    }

    func focusTerminalSoon() {
        DispatchQueue.main.async { [weak self] in
            guard let self, let session = self.activeSession, !session.isLauncher else { return }
            self.window?.makeFirstResponder(session.terminalView)
        }
    }

    // MARK: 窗口

    func attach(_ window: NSWindow) {
        guard self.window !== window else { return }
        self.window = window
        installContextClickFix(for: window)
        // 我们有自己的标签栏，不要系统的窗口标签
        window.tabbingMode = .disallowed
        window.title = windowTitle
        configureWindowChrome()
        // 点红色关闭按钮时先确认（有连接的话）
        if let close = window.standardWindowButton(.closeButton) {
            close.target = self
            close.action = #selector(closeButtonClicked(_:))
        }
    }

    /// 窗口不是当前窗口时，窗口顶上那一条（标签栏、右上角的按钮）的鼠标事件会先被系统的标题栏截走，
    /// 在那里右键（或 Control+点击）就什么都不弹。遇到这种情况先把窗口拿到前面，再把这次点击重新发一遍
    private func installContextClickFix(for window: NSWindow) {
        if let contextClickMonitor { NSEvent.removeMonitor(contextClickMonitor) }
        contextClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .leftMouseDown]) { [weak self, weak window] event in
            guard let self, let window, event.window === window, !window.isKeyWindow,
                  event.type == .rightMouseDown || event.isContextClick,
                  self.repostedClick != event.timestamp,
                  Self.titlebarCovers(event.locationInWindow, in: window)
            else { return event }
            // 同一次点击只重发一次：重发后窗口还没变成当前窗口，就按系统默认的处理
            self.repostedClick = event.timestamp
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
            DispatchQueue.main.async { NSApp.postEvent(event, atStart: true) }
            return nil
        }
    }

    /// 窗口里这个点是不是被系统的标题栏挡着（不算红绿灯按钮）
    static func titlebarCovers(_ point: NSPoint, in window: NSWindow) -> Bool {
        guard let frameView = window.contentView?.superview, let hit = frameView.hitTest(point) else { return false }
        var view: NSView? = hit
        var inTitlebar = false
        while let current = view {
            if current === window.contentView || current is NSButton { return false }
            let name = String(describing: type(of: current))
            if name.hasPrefix("NSTitlebar") || name.hasPrefix("NSToolbar") { inTitlebar = true }
            view = current.superview
        }
        return inTitlebar
    }

    @objc private func closeButtonClicked(_ sender: Any?) {
        requestCloseWindow()
    }

    func requestCloseWindow() {
        let active = activeConnectionCount
        let close = { [weak self] in
            self?.closeAll()
            self?.window?.close()
        }
        guard active > 0, UserDefaults.standard.bool(forKey: Prefs.confirmClose), !TestHooks.isActive else { return close() }
        Dialogs.confirm("关闭这个窗口？", detail: "窗口里的 \(active) 个连接都会被断开。",
                        confirmTitle: "关闭窗口", window: window) { ok in
            if ok { close() }
        }
    }

    func closeAll() {
        for session in allSessions { session.close() }
        if let contextClickMonitor {
            NSEvent.removeMonitor(contextClickMonitor)
            self.contextClickMonitor = nil
        }
    }

    // MARK: 会话列表

    func editNew(group: String = "") {
        var profile = SessionProfile(group: group)
        profile.keyPaths = []
        editor = EditorRequest(profile: profile, isNew: true)
    }

    func edit(_ profile: SessionProfile) {
        editor = EditorRequest(profile: profile, isNew: false)
    }

    func editSelectedTabSession() {
        guard let tab = activeSession, let profile = tab.profile else { return }
        if tab.isSavedSession {
            edit(SessionStore.shared.session(profile.id) ?? profile)
        } else {
            saveAsSession(tab)
        }
    }

    /// 把快速连接的标签页保存成会话。临时指定的跳板机也一起存进会话列表
    func saveAsSession(_ tab: TerminalSession) {
        guard let seed = tab.duplicationSeed else { return }
        var profile = seed.profile
        if !seed.jumps.isEmpty {
            var previous: UUID?
            for var jump in seed.jumps {
                jump.group = "快速连接"
                jump.jumpHostID = previous
                SessionStore.shared.upsert(jump)
                previous = jump.id
            }
            profile.jumpHostID = previous
        }
        if profile.group.isEmpty { profile.group = "快速连接" }
        editor = EditorRequest(profile: profile, isNew: true, adoptingTab: tab)
    }

    func deleteSessions(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        let names = ids.compactMap { SessionStore.shared.session($0)?.displayName }
        let message = ids.count == 1 ? "删除会话“\(names.first ?? "")”？" : "删除 \(ids.count) 个会话？"
        Dialogs.confirm(message, detail: "已经打开的标签页不受影响。钥匙串里保存的密码不会删除。",
                        confirmTitle: "删除", destructive: true, window: window) { [weak self] ok in
            guard ok else { return }
            SessionStore.shared.update { $0.remove(ids: ids) }
            self?.sidebar.selection.subtract(ids.map { "s:\($0.uuidString)" })
        }
    }

    func newGroup(parent: String = "") {
        Dialogs.promptText("新建分组", detail: parent.isEmpty ? "" : "放在“\(parent)”下面。用 / 可以一次建多级。",
                           confirmTitle: "创建", window: window) { name in
            guard let name else { return }
            SessionStore.shared.update { $0.addGroup(GroupPath.join(parent, name)) }
        }
    }

    func renameGroup(_ path: String) {
        Dialogs.promptText("重命名分组", detail: "用 / 分隔可以移到别的分组下面。", initial: path,
                           confirmTitle: "重命名", window: window) { [weak self] name in
            guard let name else { return }
            SessionStore.shared.update { $0.renameGroup(path, to: name) }
            self?.sidebar.collapsedGroups.remove(path)
        }
    }

    func deleteGroup(_ path: String) {
        let parent = GroupPath.parent(of: path)
        Dialogs.confirm("删除分组“\(GroupPath.lastComponent(of: path))”？",
                        detail: "里面的会话不会删除，会挪到\(parent.isEmpty ? "顶层" : "“\(parent)”")。",
                        confirmTitle: "删除分组", window: window) { ok in
            guard ok else { return }
            SessionStore.shared.update { $0.removeGroup(path) }
        }
    }

    func move(_ ids: Set<UUID>, to group: String) {
        SessionStore.shared.update { $0.move(ids: ids, to: group) }
    }

    /// 删除钥匙串里这个会话用到的密码和私钥口令
    func forgetSecrets(_ profile: SessionProfile) {
        Keychain.delete(.password(for: profile))
        for path in profile.keyPaths where !path.isEmpty {
            Keychain.delete(.passphrase(path: path))
        }
        Dialogs.inform("已删除“\(profile.displayName)”保存的密码", detail: "下次连接时会重新询问。", window: window)
    }

    func toggleGroup(_ path: String) {
        if sidebar.collapsedGroups.contains(path) { sidebar.collapsedGroups.remove(path) } else { sidebar.collapsedGroups.insert(path) }
    }

    /// 给分组设环境标签（生产 / 测试 / 设备）；nil 表示跟着上级
    func setEnvironment(_ environment: SessionEnvironment?, forGroup path: String) {
        SessionStore.shared.update { $0.setEnvironment(environment, forGroup: path) }
    }

    /// 标题栏藏起来、内容画满整个窗口；放一个空的工具栏让标题栏变高，红绿灯和我们的工具栏一样高。
    /// SwiftUI 更新窗口时可能改回去，所以标题变了之后再设一遍（没变的属性不动）
    func configureWindowChrome() {
        guard let window else { return }
        if window.titleVisibility != .hidden { window.titleVisibility = .hidden }
        if !window.titlebarAppearsTransparent { window.titlebarAppearsTransparent = true }
        if !window.styleMask.contains(.fullSizeContentView) { window.styleMask.insert(.fullSizeContentView) }
        if window.toolbar == nil {
            let toolbar = NSToolbar(identifier: "conch.main")
            toolbar.showsBaselineSeparator = false
            window.toolbar = toolbar
        }
        if window.toolbarStyle != .unified { window.toolbarStyle = .unified }
        if window.isMovableByWindowBackground { window.isMovableByWindowBackground = false }
    }

    func toggleSidebar() {
        withAnimation(.easeInOut(duration: 0.2)) { showSidebar.toggle() }
    }

    // MARK: 导入

    func importSSHConfig() {
        let url = TestHooks.sshConfigURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            return Dialogs.inform("没有找到 ~/.ssh/config", window: window)
        }
        let result = SSHConfigImporter.importProfiles(from: SSHConfig.load(from: url))
        report(SessionStore.shared.merge(result.profiles), result: result, source: "~/.ssh/config")
    }

    func importXshell() {
        let panel = NSOpenPanel()
        panel.title = "导入 Xshell 会话"
        panel.message = "选择 .xsh 会话文件，或者整个会话文件夹（Windows 上一般在 文档\\NetSarang Computer\\7\\Xshell\\Sessions）"
        panel.prompt = "导入"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        if let xsh = UTType(filenameExtension: "xsh") {
            panel.allowedContentTypes = [xsh, .folder]
        }
        let handle = { [weak self] (response: NSApplication.ModalResponse) in
            guard response == .OK, let self else { return }
            let result = XshellImporter.importItems(at: panel.urls)
            self.report(SessionStore.shared.merge(result.profiles), result: result, source: "Xshell")
        }
        if let window { panel.beginSheetModal(for: window, completionHandler: handle) } else { handle(panel.runModal()) }
    }

    private func report(_ outcome: (added: Int, skipped: Int), result: ImportResult, source: String) {
        var lines: [String] = []
        if outcome.skipped > 0 { lines.append("\(outcome.skipped) 个已经在会话列表里，跳过了。") }
        if !result.skipped.isEmpty {
            lines.append("没有导入：")
            lines.append(contentsOf: result.skipped.prefix(12).map { "· \($0)" })
            if result.skipped.count > 12 { lines.append("……还有 \(result.skipped.count - 12) 个") }
        }
        if source == "Xshell", outcome.added > 0 {
            lines.append("Xshell 保存的密码是加密的，没有导入，第一次连接时会询问。")
        }
        Dialogs.inform(outcome.added > 0 ? "从 \(source) 导入了 \(outcome.added) 个会话" : "没有导入新的会话",
                       detail: lines.joined(separator: "\n"), window: window)
    }
}

/// 会话列表自己的状态：选中、搜索、折叠的分组、这个窗口里连着哪些会话。
/// 单独放一个对象：会话列表只在这些变了的时候重画，不用跟着终端标题、尺寸的每次变化把整棵树重建一遍
final class SidebarState: ObservableObject {
    @Published var selection: Set<String> = []
    @Published var searchText = ""
    @Published var collapsedGroups: Set<String> = []
    /// 这个窗口里已连接的会话（列表上显示绿点）
    @Published private(set) var connectedIDs: Set<UUID> = []

    func setConnected(_ ids: Set<UUID>) {
        if ids != connectedIDs { connectedIDs = ids }
    }
}

/// 所有窗口，退出前统计连接数、网络事件广播用
final class WorkspaceRegistry {
    static let shared = WorkspaceRegistry()

    private final class WeakBox {
        weak var value: WorkspaceModel?
        init(_ value: WorkspaceModel) { self.value = value }
    }

    private var boxes: [WeakBox] = []

    func register(_ workspace: WorkspaceModel) {
        boxes.removeAll { $0.value == nil }
        boxes.append(WeakBox(workspace))
    }

    var all: [WorkspaceModel] {
        boxes.compactMap(\.value)
    }

    var activeConnectionCount: Int {
        all.reduce(0) { $0 + $1.activeConnectionCount }
    }
}

/// 解析快速连接框里的输入：先按 ssh 的写法拆开，主机名是 ~/.ssh/config 里的别名时用配置补全
enum QuickConnectResolver {
    struct Resolved {
        var profile: SessionProfile
        var jumps: [SessionProfile]
    }

    static func resolve(_ text: String) -> Resolved? {
        guard let request = QuickConnectRequest.parse(text) else { return nil }
        if request.telnet {
            return Resolved(profile: SessionProfile(kind: .telnet, host: request.host, port: request.port ?? 23), jumps: [])
        }
        let config = SSHConfig.load(from: TestHooks.sshConfigURL)

        var profile = profileFor(host: request.host, user: request.user, port: request.port, config: config)
        if let identity = request.identityFile {
            profile.keyPaths.insert((identity as NSString).expandingTildeInPath, at: 0)
        }
        let entry = config.resolve(request.host)
        let jumpText = request.jump ?? entry.proxyJump
        let jumps = (jumpText.map(JumpSpec.parseList) ?? []).map {
            profileFor(host: $0.host, user: $0.user, port: $0.port, config: config)
        }
        return Resolved(profile: profile, jumps: jumps)
    }

    private static func profileFor(host: String, user: String?, port: Int?, config: SSHConfig) -> SessionProfile {
        let entry = config.resolve(host)
        var profile = SessionProfile(
            host: entry.hostName,
            port: port ?? entry.port ?? 22,
            username: user ?? entry.user ?? NSUserName(),
            auth: .auto,
            keyPaths: entry.identityFiles,
            identitiesOnly: entry.identitiesOnly ?? false,
            identityAgent: entry.identityAgent ?? ""
        )
        // 用的是 ssh_config 里的别名时，标签页就显示别名
        if config.knows(host) { profile.name = host }
        return profile
    }
}
