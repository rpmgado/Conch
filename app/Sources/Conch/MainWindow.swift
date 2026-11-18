import AppKit
import ConchKit
import SwiftTerm
import SwiftUI

/// SwiftTerm 也有 Color，这个文件里说的都是 SwiftUI 的
private typealias Color = SwiftUI.Color

/// 一个窗口：左边浮起来的会话列表，右边胶囊标签栏 + 终端卡片 + 状态栏
struct MainWindow: View {
    @StateObject private var workspace = WorkspaceModel()
    @ObservedObject private var themes = ThemeStore.shared
    @Environment(\.openSettings) private var openSettings
    @AppStorage(Prefs.sidebarWidth) private var sidebarWidth = 276.0

    var body: some View {
        let palette = themes.palette
        ZStack(alignment: .top) {
            WindowBackground(palette: palette)
            HStack(spacing: 0) {
                if workspace.showSidebar {
                    SessionSidebar(workspace: workspace, sidebar: workspace.sidebar)
                        .frame(width: sidebarWidth)
                    ResizeHandle(width: $sidebarWidth, range: 200...420, growsRightward: true)
                }
                WorkspaceDetail(workspace: workspace)
            }
            .padding(8)
            EnvironmentBand(workspace: workspace)
        }
        // 标题栏藏起来了，内容一直画到窗口顶上
        .ignoresSafeArea(.container, edges: .top)
        .environment(\.palette, palette)
        .tint(palette.accent)
        .foregroundStyle(palette.ink)
        // 不用 navigationTitle：它一变 SwiftUI 就把标题栏重新显示出来，盖住我们的标签栏
        .onChange(of: workspace.windowTitle) { _, title in
            workspace.window?.title = title
            workspace.configureWindowChrome()
        }
        .focusedSceneObject(workspace)
        .background(WindowReader { workspace.attach($0) })
        .sheet(item: $workspace.editor) { request in
            SessionEditor(request: request, workspace: workspace)
                .environment(\.palette, palette)
                .tint(palette.accent)
        }
        .sheet(isPresented: $workspace.expandedFiles, onDismiss: { workspace.focusTerminalSoon() }) {
            if let tab = workspace.activeSession, tab.isSSH {
                ExpandedFilesView(tab: tab, workspace: workspace)
                    .environment(\.palette, palette).tint(palette.accent)
            }
        }
        .onAppear {
            // 右键菜单（AppKit）里要打开设置窗口，用 SwiftUI 给的这个方法
            workspace.openSettingsAction = { openSettings() }
            TestHooks.windowDidAppear(workspace)
            if TestHooks.showSettingsRequested { openSettings() }
        }
        .onDisappear { workspace.closeAll() }
        .frame(minWidth: 760, minHeight: 460)
    }
}

/// 环境色主题：当前会话属于有环境标签的分组时，窗口顶上一条对应颜色的细线
private struct EnvironmentBand: View {
    @ObservedObject var workspace: WorkspaceModel
    @ObservedObject private var store = SessionStore.shared
    @Environment(\.palette) private var palette

    var body: some View {
        if let session = workspace.activeSession, !session.isLauncher,
           let environment = store.environment(of: session.profile)
        {
            UnevenRoundedRectangle(bottomLeadingRadius: 3, bottomTrailingRadius: 3)
                .fill(EnvironmentStyle.of(environment).swatch)
                .frame(height: 3)
                .padding(.horizontal, 28)
                .help("当前会话属于\(environment.title)环境")
                .allowsHitTesting(false)
        }
    }
}

/// 右边的主体：工具栏、终端（或新标签页）、撰写栏、状态栏
struct WorkspaceDetail: View {
    @ObservedObject var workspace: WorkspaceModel
    @AppStorage(Prefs.useMetal) private var useMetal = true
    @AppStorage(Prefs.sidePanelWidth) private var sidePanelWidth = 340.0
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(spacing: 8) {
            ToolbarRow(workspace: workspace)
            if workspace.broadcastInput {
                BroadcastBanner(workspace: workspace)
            }
            GeometryReader { proxy in
                // 窗口窄的时候右侧面板跟着变窄，终端至少留 280
                let panelWidth = min(sidePanelWidth, max(240, proxy.size.width - 288))
                HStack(spacing: 0) {
                    ZStack(alignment: .topTrailing) {
                        TerminalDeck(
                            tabs: workspace.tabs,
                            selectedTabID: workspace.selectedTabID,
                            signature: TerminalDeck.signature(of: workspace.tabs),
                            focusSelected: workspace.activeSession.map { !$0.isLauncher } ?? false,
                            useMetal: useMetal && !TestHooks.disableMetal,
                            style: DeckStyle(palette: palette)
                        )
                        if let session = workspace.activeSession, session.isLauncher {
                            LauncherView(workspace: workspace, tab: session)
                                .id(session.id)
                        } else {
                            FindOverlay(model: workspace.find, terminal: workspace.activeSession?.terminalView)
                        }
                    }
                    .frame(minWidth: 200, maxWidth: .infinity, maxHeight: .infinity)
                    if let panel = workspace.sidePanel, let tab = workspace.activeSession, tab.isSSH {
                        ResizeHandle(width: $sidePanelWidth, range: 260...640, growsRightward: false)
                        SidePanelView(panel: panel, tab: tab, workspace: workspace)
                            .frame(width: panelWidth)
                            .id(tab.id)
                    }
                }
            }
            if workspace.showComposeBar, let tab = workspace.activeSession, !tab.isLauncher {
                ComposeBar(workspace: workspace)
            }
            if let tab = workspace.activeSession, !tab.isLauncher {
                StatusBar(tab: tab, workspace: workspace)
                    .id(tab.id)
            }
        }
    }
}

// MARK: - 工具栏

/// 最上面一行：标签栏胶囊、可以拖动窗口的空白、右边的工具按钮
private struct ToolbarRow: View {
    @ObservedObject var workspace: WorkspaceModel
    @Environment(\.palette) private var palette
    @StateObject private var metrics = Metrics()

    var body: some View {
        // 标签栏最多能占的宽度：整行减去右边的按钮、拖动窗口的空白和（侧边栏藏起来时）左边的按钮
        let leading: CGFloat = workspace.showSidebar ? 0 : 68 + 38 + 16
        let room = max(0, metrics.rowWidth - metrics.actionsWidth - leading - 24 - 16)
        HStack(spacing: 8) {
            if !workspace.showSidebar {
                // 给红绿灯按钮留位置
                WindowDragArea().frame(width: 68)
                ChromeIconButton(systemImage: "sidebar.left", help: "显示侧边栏（⌃⌘S）") { workspace.toggleSidebar() }
                    .padding(4)
                    .capsuleBar(palette)
            }
            TabStrip(workspace: workspace, room: room)
                .layoutPriority(1)
            WindowDragArea()
                .frame(minWidth: 24, maxWidth: .infinity, maxHeight: .infinity)
            ToolbarActions(workspace: workspace)
                .background(GeometryReader { proxy in
                    Color.clear.onAppear { metrics.actionsWidth = proxy.size.width }
                        .onChange(of: proxy.size.width) { _, width in metrics.actionsWidth = width }
                })
        }
        .frame(height: 40)
        .background(GeometryReader { proxy in
            Color.clear.onAppear { metrics.rowWidth = proxy.size.width }
                .onChange(of: proxy.size.width) { _, width in metrics.rowWidth = width }
        })
    }

    /// 这个工程不用 @State（命令行工具链里没有 SwiftUI 的宏插件），小状态都放在这种对象里
    final class Metrics: ObservableObject {
        /// 量到之前先按一个普通窗口的宽度算，标签不会在第一帧挤成最窄
        @Published var rowWidth: CGFloat = 1400
        @Published var actionsWidth: CGFloat = 180
    }
}

/// 右上角的按钮：分屏、文件、监控、外观主题
private struct ToolbarActions: View {
    @ObservedObject var workspace: WorkspaceModel
    @Environment(\.palette) private var palette

    var body: some View {
        let session = workspace.activeSession
        let isSSH = session?.isSSH ?? false
        let canSplit = workspace.canSplit(session)
        HStack(spacing: 2) {
            Menu {
                Button("左右分屏（⌘D）") { workspace.splitActive(.horizontal) }
                Button("上下分屏（⇧⌘D）") { workspace.splitActive(.vertical) }
                if workspace.currentTab?.isSplit == true {
                    Divider()
                    Button(workspace.currentTab?.zoomedID == nil ? "放大当前分屏（⇧⌘↩）" : "还原分屏（⇧⌘↩）") { workspace.toggleZoom() }
                    Button("平均分配分屏大小") { workspace.equalizePanes() }
                }
            } label: {
                Image(systemName: "rectangle.split.2x1")
                    .font(.system(size: 13.5, weight: .medium))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            // 菜单按钮默认用强调色，看起来像“已打开”；和旁边的按钮一样用普通颜色
            .tint(palette.ink2)
            .fixedSize()
            .frame(width: 30, height: 30)
            .disabled(!canSplit)
            .opacity(canSplit ? 1 : 0.4)
            .help("分屏")
            ChromeIconButton(systemImage: "folder", help: "文件面板（SFTP，⌥⌘F）", title: "文件", isOn: workspace.showFilesPanel, enabled: isSSH) {
                workspace.showFilesPanel.toggle()
            }
            ChromeIconButton(systemImage: "gauge.with.dots.needle.33percent", help: "服务器监控（⌥⌘U）", title: "监控", isOn: workspace.showMonitor, enabled: isSSH) {
                workspace.showMonitor.toggle()
            }
            Rectangle().fill(palette.hairline).frame(width: 1, height: 18).padding(.horizontal, 3)
            ChromeIconButton(systemImage: "paintpalette", help: "外观主题", isOn: workspace.showThemePicker) {
                workspace.showThemePicker.toggle()
            }
            .popover(isPresented: $workspace.showThemePicker, arrowEdge: .bottom) {
                ThemePicker().environment(\.palette, palette)
            }
        }
        .padding(4)
        .capsuleBar(palette)
    }
}

/// 右侧面板：上面切换“文件 / 监控”，下面是对应的内容
private struct SidePanelView: View {
    let panel: WorkspaceModel.SidePanel
    let tab: TerminalSession
    @ObservedObject var workspace: WorkspaceModel
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                ThemedSegments(
                    options: [("文件", WorkspaceModel.SidePanel.files), ("监控", .monitor)],
                    selection: Binding(get: { panel }, set: { workspace.sidePanel = $0 })
                )
                if panel == .files {
                    ChromeIconButton(systemImage: "arrow.up.left.and.arrow.down.right", help: "展开文件传输（本地与远端左右对照）") {
                        workspace.expandedFiles = true
                    }
                    Button {
                        workspace.showLocalFiles.toggle()
                    } label: {
                        Image(systemName: "laptopcomputer")
                            .font(.system(size: 12, weight: .medium))
                            .frame(width: 26, height: 26)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(workspace.showLocalFiles ? palette.field : Color.clear)
                            )
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(workspace.showLocalFiles ? palette.accent : palette.muted)
                    .help(workspace.showLocalFiles ? "隐藏本机文件" : "显示本机文件（和服务器上下对照，方便上传下载）")
                    .accessibilityLabel("本机文件")
                }
                Button {
                    workspace.sidePanel = nil
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 26, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(palette.muted)
                .help("关闭面板")
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 4)
            switch panel {
            case .files:
                SftpPanel(browser: tab.files, local: workspace.localFiles, tab: tab, workspace: workspace,
                          showLocal: workspace.showLocalFiles)
            case .monitor:
                MonitorPanel(monitor: tab.monitor, tab: tab)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .panelCard(palette)
    }
}

/// 只在需要时显示查找栏（单独观察 FindModel，输入时不用重画整个窗口）
private struct FindOverlay: View {
    @ObservedObject var model: FindModel
    let terminal: TerminalView?

    var body: some View {
        if model.visible {
            FindBar(model: model, terminal: terminal)
        }
    }
}

/// 同步输入开着时的提醒，免得忘了关
private struct BroadcastBanner: View {
    @ObservedObject var workspace: WorkspaceModel
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "dot.radiowaves.left.and.right")
                .foregroundStyle(palette.caution)
            Text("同步输入已开启：在任一终端里输入的内容，会同时发给这个窗口里的 \(workspace.connectedSessions.count) 个连接")
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer()
            Button("关闭同步输入") { workspace.broadcastInput = false }
                .controlSize(.small)
        }
        .font(.system(size: 12.5))
        .padding(.horizontal, 14)
        .frame(height: 34)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.orange.opacity(palette.isDark ? 0.2 : 0.16))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.orange.opacity(0.35), lineWidth: 0.5))
        )
    }
}

// MARK: - 标签栏

/// 标签栏胶囊：标签少的时候只有内容那么宽；多了先把每个标签变窄，还放不下就横向滚动
/// （鼠标滚轮上下滚也能左右翻），右边多一个按钮列出所有标签页。选中的标签页总会滚到看得见的地方
struct TabStrip: View {
    @ObservedObject var workspace: WorkspaceModel
    /// 标签栏最多能占多宽（ToolbarRow 量好传进来），用来决定每个标签多宽
    let room: CGFloat
    @Environment(\.palette) private var palette
    @StateObject private var metrics = Metrics()

    /// 标签越多越窄，最窄 118（还能看清会话名），最宽 240
    private var tabMaxWidth: CGFloat {
        let count = CGFloat(max(workspace.tabs.count, 1))
        // 胶囊里除了标签还有 + 按钮、列表按钮和边距
        let perTab = (room - 76) / count - 2
        return min(240, max(118, perTab))
    }

    var body: some View {
        let overflowing = metrics.contentWidth > metrics.visibleWidth + 1
        HStack(spacing: 2) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 2) {
                        ForEach(workspace.tabs) { tab in
                            TabItem(tab: tab, workspace: workspace, isSelected: tab.id == workspace.selectedTabID,
                                    maxWidth: tabMaxWidth)
                                .id(tab.id)
                        }
                    }
                    .background(WheelToHorizontalScroll())
                    .background(GeometryReader { geometry in
                        Color.clear.preference(key: ContentWidthKey.self, value: geometry.size.width)
                    })
                }
                .frame(maxWidth: metrics.contentWidth)
                .background(GeometryReader { geometry in
                    Color.clear.preference(key: VisibleWidthKey.self, value: geometry.size.width)
                })
                .onPreferenceChange(ContentWidthKey.self) { metrics.contentWidth = $0 }
                .onPreferenceChange(VisibleWidthKey.self) { metrics.visibleWidth = $0 }
                .onChange(of: workspace.selectedTabID) { _, id in reveal(id, with: proxy) }
                .onChange(of: workspace.tabs.count) { reveal(workspace.selectedTabID, with: proxy) }
                .onChange(of: overflowing) { reveal(workspace.selectedTabID, with: proxy) }
            }
            if overflowing {
                TabListMenu(workspace: workspace)
            }
            Button {
                workspace.newTab()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(palette.ink2)
            .help("新建标签页（⌘T）")
        }
        .padding(4)
        .capsuleBar(palette)
    }

    /// 等新标签排好再滚过去（刚加的标签这一刻可能还没有位置）
    private func reveal(_ id: UUID?, with proxy: ScrollViewProxy) {
        guard let id else { return }
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.18)) { proxy.scrollTo(id) }
        }
    }

    final class Metrics: ObservableObject {
        @Published var contentWidth: CGFloat = 0
        @Published var visibleWidth: CGFloat = 0
    }

    private struct ContentWidthKey: PreferenceKey {
        static let defaultValue: CGFloat = 0
        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
    }

    private struct VisibleWidthKey: PreferenceKey {
        static let defaultValue: CGFloat = 0
        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
    }
}

/// 标签放不下时的下拉按钮：列出所有标签页，点一下切过去
private struct TabListMenu: View {
    @ObservedObject var workspace: WorkspaceModel
    @Environment(\.palette) private var palette

    var body: some View {
        Menu {
            ForEach(Array(workspace.tabs.enumerated()), id: \.element.id) { index, tab in
                Button {
                    workspace.select(tab)
                    workspace.focusTerminalSoon()
                } label: {
                    let title = "\(index + 1). \(tab.title)" + (tab.isSplit ? "（\(tab.sessions.count) 个分屏）" : "")
                    if tab.id == workspace.selectedTabID {
                        Label(title, systemImage: "checkmark")
                    } else {
                        Text(title)
                    }
                }
            }
        } label: {
            Image(systemName: "chevron.down")
                .font(.system(size: 11.5, weight: .semibold))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .tint(palette.ink2)
        .fixedSize()
        .frame(width: 26, height: 30)
        .help("所有标签页（共 \(workspace.tabs.count) 个）")
    }
}

/// 放在横向 ScrollView 里：鼠标滚轮（上下滚）变成左右滚动。触控板左右滑动照常交给 ScrollView
struct WheelToHorizontalScroll: NSViewRepresentable {
    func makeNSView(context: Context) -> BridgeView { BridgeView() }
    func updateNSView(_ view: BridgeView, context: Context) {}

    final class BridgeView: NSView {
        private var monitor: Any?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self, self.handle(event) else { return event }
                return nil
            }
        }

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }

        /// 处理了（滚动了标签栏）就返回 true
        private func handle(_ event: NSEvent) -> Bool {
            guard let scrollView = enclosingScrollView, let window = scrollView.window, !isHiddenOrHasHiddenAncestor else { return false }
            let location: NSPoint
            if let eventWindow = event.window {
                guard eventWindow === window else { return false }
                location = event.locationInWindow
            } else {
                location = window.convertPoint(fromScreen: event.locationInWindow)
            }
            guard scrollView.bounds.contains(scrollView.convert(location, from: nil)) else { return false }
            // 主要是左右方向的（触控板横扫）交给 ScrollView 自己
            guard abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX) else { return false }
            let documentWidth = scrollView.documentView?.frame.width ?? 0
            guard documentWidth > scrollView.contentView.bounds.width + 1 else { return true }
            // 滚轮一格默认只滚 10 点，标签有一两百点宽，翻起来太慢
            if scrollView.horizontalLineScroll < 48 { scrollView.horizontalLineScroll = 48 }
            // 把上下方向的量挪到左右方向，像按住 Shift 滚滚轮一样交给 ScrollView（它自己的滚动状态才不会乱）
            guard let cgEvent = event.cgEvent?.copy() else { return false }
            let lines = cgEvent.getIntegerValueField(.scrollWheelEventDeltaAxis1)
            let points = cgEvent.getDoubleValueField(.scrollWheelEventPointDeltaAxis1)
            let fixed = cgEvent.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1)
            cgEvent.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: lines)
            cgEvent.setDoubleValueField(.scrollWheelEventPointDeltaAxis2, value: points)
            cgEvent.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: fixed)
            cgEvent.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: 0)
            cgEvent.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: 0)
            cgEvent.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: 0)
            guard let horizontal = NSEvent(cgEvent: cgEvent) else { return false }
            scrollView.scrollWheel(with: horizontal)
            return true
        }
    }
}

struct TabItem: View {
    @ObservedObject var tab: WorkspaceTab
    let workspace: WorkspaceModel
    let isSelected: Bool
    var maxWidth: CGFloat = 240
    @ObservedObject private var store = SessionStore.shared
    @Environment(\.palette) private var palette

    var body: some View {
        let session = tab.focused
        let environment = store.environment(of: session.profile)
        HStack(spacing: 7) {
            leadingMark(session, environment: environment)
            Text(tab.title)
                .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
                .foregroundStyle(isSelected ? palette.ink : palette.ink2)
                .lineLimit(1)
                .truncationMode(.middle)
            badges(session, environment: environment)
            closeButton
        }
        .padding(.leading, palette.showsEnvironment && !session.isLauncher ? 6 : 11)
        .padding(.trailing, 5)
        .frame(height: 30)
        .frame(maxWidth: maxWidth)
        .background(background(environment))
        .contentShape(Rectangle())
        .onTapGesture { workspace.select(tab); workspace.focusTerminalSoon() }
        .help(session.isLauncher ? "新标签页" : tab.sessions.map(\.routeDescription).joined(separator: "\n"))
        .draggable(tab.id.uuidString)
        .dropDestination(for: String.self) { items, _ in
            guard let id = items.first.flatMap(UUID.init(uuidString:)) else { return false }
            workspace.moveTab(id, before: tab)
            return true
        }
        .contextMenu {
            if let profile = session.profile {
                Button("重新连接") { session.reconnect() }
                Button("断开连接") { session.disconnect() }.disabled(!session.isActive)
                Button("复制标签页") { workspace.duplicate(session) }
                Divider()
                Button("左右分屏") { workspace.select(session); workspace.splitActive(.horizontal) }
                    .disabled(!workspace.canSplit(session))
                Button("上下分屏") { workspace.select(session); workspace.splitActive(.vertical) }
                    .disabled(!workspace.canSplit(session))
                Divider()
                Button("重命名标签页…") { workspace.select(tab); workspace.renameTab(tab) }
                if tab.customTitle != nil {
                    Button("恢复成会话名") { tab.customTitle = nil }
                }
                Button("拷贝地址") { WorkspaceModel.copyToPasteboard(profile.copyableAddress) }
                if let command = profile.sshCommand(jumps: session.jumps) {
                    Button("拷贝 ssh 命令") { WorkspaceModel.copyToPasteboard(command) }
                }
                Divider()
                Button(session.logURL == nil ? "开始记录日志" : "停止记录日志") { session.toggleLogging() }
                Button(session.isSavedSession ? "编辑会话…" : "保存为会话…") {
                    workspace.select(session)
                    workspace.editSelectedTabSession()
                }
                Divider()
            }
            Button(tab.isSplit ? "关闭标签页（\(tab.sessions.count) 个分屏）" : "关闭标签页") { workspace.close(tab) }
            Button("关闭其他标签页") { workspace.closeOthers(tab) }.disabled(workspace.tabs.count < 2)
            Button("关闭右侧的标签页") { workspace.closeTabs(rightOf: tab) }
                .disabled(workspace.tabs.last === tab)
        }
    }

    /// 标题前面的小标记：连接状态点；环境色主题里是字母头像；新标签页是终端图标
    @ViewBuilder
    private func leadingMark(_ session: TerminalSession, environment: SessionEnvironment?) -> some View {
        if session.isLauncher {
            Image(systemName: "terminal")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(palette.muted)
        } else if palette.showsEnvironment {
            SessionAvatar(name: session.tabTitle, environment: environment, size: 20,
                          status: PhaseDot.color(for: session.phase, palette: palette),
                          ringColor: isSelected ? .white : palette.capsule)
        } else {
            PhaseDot(phase: session.phase, isLauncher: false)
        }
    }

    /// 标题后面的：环境、分屏数、有新输出、正在记录日志
    @ViewBuilder
    private func badges(_ session: TerminalSession, environment: SessionEnvironment?) -> some View {
        if let environment, isSelected || environment == .production {
            EnvironmentChip(environment: environment)
        }
        if tab.isSplit {
            HStack(spacing: 3) {
                Image(systemName: "rectangle.split.2x1")
                Text("\(tab.sessions.count)")
            }
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(palette.ink2)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(palette.field))
            .help("这个标签页分成了 \(tab.sessions.count) 个屏")
        }
        if tab.hasUnseenOutput && !isSelected {
            Circle().fill(palette.accent).frame(width: 5, height: 5)
                .help("有新的输出")
        }
        if session.logURL != nil {
            Image(systemName: "record.circle").foregroundStyle(palette.danger).font(.system(size: 9))
                .help("正在记录日志")
        }
    }

    private var closeButton: some View {
        Button {
            workspace.close(tab)
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .bold))
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(palette.muted)
        .opacity(isSelected ? 1 : 0.6)
        .help(tab.isSplit ? "关闭标签页（里面的分屏都会关掉）" : "关闭标签页（⌘W）")
    }

    private func background(_ environment: SessionEnvironment?) -> some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        let fill: Color = isSelected ? selectedFill(environment) : .clear
        let border: Color = isSelected ? selectedBorder(environment) : .clear
        let shadow: Color = isSelected && !palette.showsEnvironment ? palette.panelShadow : .clear
        return shape
            .fill(fill)
            .overlay(shape.strokeBorder(border, lineWidth: palette.showsEnvironment ? 1 : 0.5))
            .shadow(color: shadow, radius: 1.5, y: 0.5)
    }

    /// 环境色主题里，选中的生产环境标签页整块染上环境色
    private func selectedFill(_ environment: SessionEnvironment?) -> Color {
        if palette.showsEnvironment, let environment {
            return EnvironmentStyle.of(environment).chipBackground.opacity(0.55)
        }
        return palette.tabSelected
    }

    private func selectedBorder(_ environment: SessionEnvironment?) -> Color {
        if palette.showsEnvironment, let environment {
            return EnvironmentStyle.of(environment).swatch.opacity(0.35)
        }
        return palette.tabSelectedBorder
    }
}

/// 连接状态的小圆点
struct PhaseDot: View {
    let phase: TerminalSession.Phase
    let isLauncher: Bool
    @Environment(\.palette) private var palette

    var body: some View {
        Circle()
            .fill(Self.color(for: phase, palette: palette))
            .frame(width: 7, height: 7)
            .opacity(isLauncher ? 0 : 1)
    }

    static func color(for phase: TerminalSession.Phase, palette: Palette) -> SwiftUI.Color {
        switch phase {
        case .connected: palette.ok
        case .connecting, .waitingToReconnect: palette.caution
        case .failed: palette.danger
        case .closed, .idle: palette.muted.opacity(0.6)
        }
    }
}

// MARK: - 状态栏

/// 底部的状态栏胶囊：连接、加密方式、编码、日志、转发、尺寸、断开
struct StatusBar: View {
    @ObservedObject var tab: TerminalSession
    @ObservedObject var workspace: WorkspaceModel
    @ObservedObject private var store = SessionStore.shared
    @Environment(\.palette) private var palette

    var body: some View {
        let environment = store.environment(of: tab.profile)
        HStack(spacing: 12) {
            if let environment {
                Label(environment == .production ? "生产环境" : "\(environment.title)环境", systemImage: environment == .production ? "exclamationmark.triangle" : "tag")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(EnvironmentStyle.labelColor(environment, dark: palette.isDark))
            }
            PhaseDot(phase: tab.phase, isLauncher: false)
            if let zmodem = tab.zmodem {
                ZmodemProgress(state: zmodem) { tab.cancelZmodem() }
            } else {
                content
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(palette.muted)
        .controlSize(.small)
        .lineLimit(1)
        .padding(.leading, 14)
        .padding(.trailing, 6)
        .frame(height: 34)
        .background(
            RoundedRectangle(cornerRadius: 17, style: .continuous)
                .fill(palette.capsule)
                .overlay(
                    RoundedRectangle(cornerRadius: 17, style: .continuous)
                        .strokeBorder(environment.map { EnvironmentStyle.of($0).swatch.opacity(0.3) } ?? palette.panelBorder, lineWidth: 0.5)
                )
                .shadow(color: palette.panelShadow.opacity(0.6), radius: 2, y: 1)
        )
    }

    @ViewBuilder
    private var content: some View {
        switch tab.phase {
        case .idle:
            Spacer()
        case .connecting:
            Text("正在连接 \(tab.routeDescription) …")
            Spacer()
            pillButton("取消") { tab.disconnect() }
        case .connected:
            Text(tab.routeDescription)
                .font(.system(size: 12, weight: .medium).monospaced())
                .foregroundStyle(palette.ink)
                .truncationMode(.middle)
            connectionDetail
            Spacer()
            if let encoding = tab.profile?.encoding, encoding.uppercased() != "UTF-8" {
                Text(TerminalEncoding.title(for: encoding))
                    .help("终端字符编码，在会话设置里修改")
            }
            if let url = tab.logURL {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                } label: {
                    HStack(spacing: 5) {
                        Circle().fill(palette.danger).frame(width: 7, height: 7)
                        Text("记录中")
                    }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(palette.recordingText)
                }
                .buttonStyle(.plain)
                .help("日志写到 \(url.path)，点一下在访达中显示")
            }
            if tab.isSSH {
                forwardsButton
            }
            Text("\(tab.cols)×\(tab.rows)")
                .font(.system(size: 12).monospacedDigit())
                .help("终端尺寸（列×行）")
            pillButton("断开") { tab.disconnect() }
        case .waitingToReconnect(let attempt, let at, let reason):
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let seconds = max(0, Int(at.timeIntervalSince(context.date).rounded(.up)))
                Text("\(reason) · \(seconds) 秒后第 \(attempt) 次重连")
                    .truncationMode(.middle)
            }
            Spacer()
            pillButton("立即重连") { tab.retryNowIfWaiting() }
            pillButton("停止") { tab.disconnect() }
        case .failed(let message):
            Text(message)
                .foregroundStyle(palette.ink)
                .truncationMode(.tail)
                .help(message)
            Spacer()
            pillButton(tab.isSavedSession ? "编辑会话…" : "保存为会话…") { workspace.editSelectedTabSession() }
            pillButton("重新连接", prominent: true) { tab.reconnect() }
        case .closed(let message):
            Text(message)
            Spacer()
            pillButton("重新连接", prominent: true) { tab.reconnect() }
        }
    }

    /// 连接方式的补充说明：SSH 显示认证和加密算法，Telnet 提醒不加密，串口显示流控
    @ViewBuilder
    private var connectionDetail: some View {
        switch tab.profile?.kind ?? .ssh {
        case .ssh:
            if let info = tab.info {
                Label("\(info.auth) · \(info.cipher)", systemImage: "lock")
                    .labelStyle(.titleAndIcon)
                    .help("密钥交换 \(info.kex)\n主机密钥 \(info.hostKey)\n加密 \(info.cipher)\n校验 \(info.mac)\n认证 \(info.auth)")
            }
        case .telnet:
            Label("不加密", systemImage: "lock.open")
                .foregroundStyle(palette.caution)
                .help("Telnet 传输的内容（包括密码）都是明文，只建议在可信的内网里使用")
        case .serial:
            if let flow = tab.profile?.serial.flowControl, flow != "none" {
                Text(flow == "hardware" ? "硬件流控" : "软件流控")
            }
        }
    }

    private var forwardsButton: some View {
        let running = tab.forwards.filter { if case .running = $0.state { return true } else { return false } }.count
        return Button {
            workspace.showForwards.toggle()
        } label: {
            Label(tab.forwards.isEmpty ? "转发" : "转发 \(running)/\(tab.forwards.count)", systemImage: "arrow.left.arrow.right")
                .foregroundStyle(palette.muted)
        }
        .buttonStyle(.plain)
        .help("端口转发（⌥⌘P）")
        .popover(isPresented: $workspace.showForwards, arrowEdge: .top) {
            ForwardsPopover(tab: tab)
        }
    }

    private func pillButton(_ title: String, prominent: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(prominent ? palette.onAccent : palette.ink)
                .padding(.horizontal, 12)
                .frame(height: 24)
                .background(Capsule().fill(prominent ? palette.accent : palette.field))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// rz / sz 进行中：文件名、进度条、取消
private struct ZmodemProgress: View {
    let state: ZmodemState
    let cancel: () -> Void

    var body: some View {
        Image(systemName: state.upload ? "arrow.up.doc" : "arrow.down.doc")
        Text(state.upload ? "rz 发送" : "sz 接收")
        Text(state.fileName.isEmpty ? "等待对方…" : state.fileName)
            .truncationMode(.middle)
        ProgressView(value: state.fraction)
            .frame(width: 160)
        Text(sizeText)
            .font(.caption.monospacedDigit())
        Spacer()
        Button("取消传输", action: cancel)
    }

    private var sizeText: String {
        let done = ByteCountFormatter.string(fromByteCount: Int64(state.done), countStyle: .file)
        let total = ByteCountFormatter.string(fromByteCount: Int64(state.total), countStyle: .file)
        return "\(done) / \(total)"
    }
}

// MARK: - 终端区域

/// 终端卡片的样子（跟着界面主题）
struct DeckStyle: Equatable {
    var ring: NSColor
    var border: NSColor
    var shadow: NSColor
    /// 环境色主题：焦点框用会话的环境颜色，单屏也画
    var environmentRings: Bool
    /// 拖分屏时的落点提示、分隔缝上的把手
    var accent: NSColor
    /// 分屏标题栏上的连接状态点
    var ok: NSColor
    var caution: NSColor
    var danger: NSColor
    var idle: NSColor

    init(palette: Palette) {
        ring = palette.focusRing
        border = palette.cardBorder
        shadow = palette.cardShadow
        environmentRings = palette.showsEnvironment
        accent = NSColor(palette.accent)
        ok = NSColor(palette.ok)
        caution = NSColor(palette.caution)
        danger = NSColor(palette.danger)
        idle = NSColor(palette.muted).withAlphaComponent(0.6)
    }

    func color(for phase: TerminalSession.Phase) -> NSColor {
        switch phase {
        case .connected: ok
        case .connecting, .waitingToReconnect: caution
        case .failed: danger
        case .closed, .idle: idle
        }
    }
}

/// 所有标签页的终端视图都挂在这里，只显示选中的标签页（分屏时按分屏树排好）。
/// 后台标签页的终端照样接收输出、跟着窗口调整尺寸，切回来时不用重新排版。
struct TerminalDeck: NSViewRepresentable {
    let tabs: [WorkspaceTab]
    let selectedTabID: UUID?
    /// 分屏结构、焦点、分屏标题栏上的内容变了它就变，保证 SwiftUI 会调用 updateNSView
    let signature: String
    let focusSelected: Bool
    let useMetal: Bool
    let style: DeckStyle

    static func signature(of tabs: [WorkspaceTab]) -> String {
        tabs.map { tab in
            let sessions = tab.sessions
            var text = "\(tab.id.uuidString.prefix(8)):\(tab.root.layoutKey):\(tab.focusedID.uuidString.prefix(8)):\(tab.zoomedID?.uuidString.prefix(8) ?? "-")"
            if tab.isSplit {
                // 分屏标题栏显示会话名和连接状态
                text += ":" + sessions.map { "\(DeckView.headerTitle(for: $0))\u{1}\(phaseKey($0.phase))" }.joined(separator: "\u{2}")
            }
            return text
        }.joined(separator: "|")
    }

    private static func phaseKey(_ phase: TerminalSession.Phase) -> String {
        switch phase {
        case .connected: "c"
        case .connecting, .waitingToReconnect: "w"
        case .failed: "f"
        case .closed, .idle: "x"
        }
    }

    func makeNSView(context: Context) -> DeckView {
        DeckView()
    }

    func updateNSView(_ deck: DeckView, context: Context) {
        deck.sync(tabs: tabs, selectedTabID: selectedTabID, focus: focusSelected, useMetal: useMetal, style: style)
    }
}

final class DeckView: NSView {
    private var tabs: [WorkspaceTab] = []
    private var selectedTabID: UUID?
    private var terminals: [ConchTerminalView] = []
    /// 每个终端下面垫一张圆角卡片
    private var cards: [ObjectIdentifier: PaneCardView] = [:]
    /// 分屏时每个终端上面的标题栏
    private var headers: [ObjectIdentifier: PaneHeaderView] = [:]
    private weak var focused: ConchTerminalView?
    /// 选中的标签页里的分隔缝（可以拖动）
    private var dividers: [PaneLayout.Divider] = []
    private var dragging: PaneLayout.Divider?
    /// 鼠标停在哪条缝上（缝中间画个小把手）
    private var hoveredDivider: Int?
    private let grip = DividerGripView()
    private var dividerAreas: [NSTrackingArea] = []
    /// 选中的标签页里看得见的分屏卡片：拖分屏换位置时找落点
    private var visibleCards: [(session: TerminalSession, frame: NSRect)] = []
    private var paneDrag: PaneDrag?
    private let dropIndicator = DropIndicatorView()
    private var wantsMetal = false
    private var style: DeckStyle?

    /// 拖着分屏标题栏换位置
    private struct PaneDrag {
        let session: TerminalSession
        let start: NSPoint
        var active = false
        var target: DropTarget?
    }

    enum DropTarget {
        /// 放到另一个分屏的某一边
        case beside(TerminalSession, PaneEdge)
        /// 和另一个分屏互换位置
        case swap(TerminalSession)
        /// 拖到标签栏：变成单独的标签页
        case newTab
    }

    /// 测试脚本用：看得见的分隔缝在哪
    var dividerRectsForTesting: [NSRect] { dividers.map(\.rect) }

    /// 终端离卡片边缘的距离
    static let padding = NSSize(width: 14, height: 10)
    /// 分屏标题栏离卡片顶边的距离
    static let headerInset: CGFloat = 4

    override init(frame: NSRect) {
        super.init(frame: frame)
        grip.isHidden = true
        dropIndicator.isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    func sync(tabs newTabs: [WorkspaceTab], selectedTabID newSelected: UUID?, focus: Bool, useMetal: Bool, style newStyle: DeckStyle) {
        let views = newTabs.flatMap(\.sessions).map(\.terminalView)
        for terminal in terminals where !views.contains(where: { $0 === terminal }) {
            terminal.removeFromSuperview()
            cards.removeValue(forKey: ObjectIdentifier(terminal))?.removeFromSuperview()
            headers.removeValue(forKey: ObjectIdentifier(terminal))?.removeFromSuperview()
        }
        for terminal in views where terminal.superview !== self {
            addSubview(terminal)
            applyMetal(to: terminal)
        }
        terminals = views
        tabs = newTabs
        selectedTabID = newSelected
        style = newStyle
        if wantsMetal != useMetal {
            wantsMetal = useMetal
            terminals.forEach(applyMetal)
        }
        let newFocused = newTabs.first { $0.id == newSelected }?.focused.terminalView
        let focusChanged = focused !== newFocused
        focused = newFocused
        layoutPanes()
        if focusChanged, focus, let newFocused, let window {
            DispatchQueue.main.async { window.makeFirstResponder(newFocused) }
        }
    }

    override func layout() {
        super.layout()
        layoutPanes()
    }

    /// 终端的配色变了：卡片的底色、标题栏的文字颜色跟着变
    func terminalColorsChanged() {
        layoutPanes()
    }

    /// 按分屏树排好每张卡片和里面的终端；没选中的标签页也排（尺寸保持一致），只是藏起来
    private func layoutPanes() {
        let area = bounds
        var visibleDividers: [PaneLayout.Divider] = []
        var shown: [(session: TerminalSession, frame: NSRect)] = []
        for tab in tabs {
            let selected = tab.id == selectedTabID
            let layout = PaneLayout(tab.root, in: area)
            // 分屏后每个终端上面有标题栏，终端往下挪
            let headed = tab.isSplit
            for (session, frame) in layout.frames {
                let view = session.terminalView
                let cardFrame = tab.zoomedID == session.id ? area : frame
                var target = cardFrame.insetBy(dx: Self.padding.width, dy: Self.padding.height)
                if headed {
                    let top = cardFrame.minY + Self.headerInset + PaneHeaderView.height + 2
                    target.size.height = max(0, target.maxY - top)
                    target.origin.y = top
                }
                if view.frame != target { view.frame = target }
                // 新标签页的终端在快速连接页下面，不显示
                let visible = selected && tab.isShowing(session) && !session.isLauncher
                view.isHidden = !visible
                updateCard(for: session, in: tab, frame: cardFrame, visible: visible)
                updateHeader(for: session, in: tab, cardFrame: cardFrame, visible: visible && headed)
                if visible { shown.append((session, cardFrame)) }
            }
            if selected, tab.zoomedID == nil { visibleDividers = layout.dividers }
        }
        visibleCards = shown
        let dividersMoved = dividers.map(\.rect) != visibleDividers.map(\.rect)
        dividers = visibleDividers
        if dividersMoved {
            updateDividerAreas()
            if dragging == nil { setHoveredDivider(nil) }
        }
        if let index = hoveredDivider ?? dragging.flatMap({ drag in dividers.firstIndex { $0.split === drag.split && $0.index == drag.index } }) {
            placeGrip(on: index)
        }
        window?.invalidateCursorRects(for: self)
    }

    private func updateCard(for session: TerminalSession, in tab: WorkspaceTab, frame: NSRect, visible: Bool) {
        let view = session.terminalView
        let key = ObjectIdentifier(view)
        let card = cards[key] ?? {
            let card = PaneCardView()
            cards[key] = card
            return card
        }()
        if card.superview !== self || subviews.firstIndex(of: card)! > subviews.firstIndex(of: view)! {
            addSubview(card, positioned: .below, relativeTo: view)
        }
        if card.frame != frame { card.frame = frame }
        card.isHidden = !visible
        guard visible, let style else { return }
        var ring: NSColor?
        if session.id == tab.focusedID {
            if style.environmentRings, let environment = SessionStore.shared.environment(of: session.profile) {
                ring = EnvironmentStyle.of(environment).ring
            } else if tab.isSplit, tab.zoomedID == nil {
                ring = style.ring
            }
        }
        card.update(fill: view.nativeBackgroundColor, ring: ring, border: style.border, shadow: style.shadow)
    }

    private func updateHeader(for session: TerminalSession, in tab: WorkspaceTab, cardFrame: NSRect, visible: Bool) {
        let key = ObjectIdentifier(session.terminalView)
        guard visible, let style else {
            headers[key]?.isHidden = true
            return
        }
        let header = headers[key] ?? {
            let header = PaneHeaderView()
            header.deck = self
            headers[key] = header
            return header
        }()
        if header.superview !== self { addSubview(header) }
        header.session = session
        let frame = NSRect(x: cardFrame.minX + 10, y: cardFrame.minY + Self.headerInset,
                           width: max(0, cardFrame.width - 16), height: PaneHeaderView.height)
        if header.frame != frame {
            header.frame = frame
            window?.invalidateCursorRects(for: header)
        }
        header.isHidden = false
        header.update(title: Self.headerTitle(for: session), dotColor: style.color(for: session.phase),
                      textColor: session.terminalView.nativeForegroundColor,
                      focused: session.id == tab.focusedID, zoomed: tab.zoomedID == session.id)
    }

    /// 分屏标题栏上的字：会话名，远端设了终端标题（常见的是 用户@主机:目录）就接在后面，同一台服务器开几个分屏也分得清
    static func headerTitle(for session: TerminalSession) -> String {
        let title = session.terminalTitle.trimmingCharacters(in: .whitespaces)
        return title.isEmpty || title == session.tabTitle ? session.tabTitle : "\(session.tabTitle) — \(title)"
    }

    // MARK: 拖动分隔缝；点卡片的边距也能切换焦点

    override func resetCursorRects() {
        for divider in dividers {
            addCursorRect(divider.rect, cursor: divider.split.axis == .horizontal ? .resizeLeftRight : .resizeUpDown)
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let index = dividers.firstIndex(where: { $0.rect.insetBy(dx: -2, dy: -2).contains(point) }) {
            let divider = dividers[index]
            if event.clickCount == 2 {
                // 双击分隔缝：这一组分屏平均分
                let count = divider.split.children.count
                divider.split.fractions = Array(repeating: 1 / CGFloat(count), count: count)
                layoutPanes()
                return
            }
            dragging = divider
            setHoveredDivider(index)
            return
        }
        if let terminal = terminals.first(where: { !$0.isHidden && $0.frame.insetBy(dx: -Self.padding.width, dy: -Self.padding.height).contains(point) }) {
            terminal.onActivate?()
            window?.makeFirstResponder(terminal)
            return
        }
        super.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let divider = dragging else { return super.mouseDragged(with: event) }
        let point = convert(event.locationInWindow, from: nil)
        PaneLayout.drag(divider, to: divider.split.axis == .horizontal ? point.x : point.y)
        layoutPanes()
    }

    override func mouseUp(with event: NSEvent) {
        guard dragging != nil else { return super.mouseUp(with: event) }
        dragging = nil
        let point = convert(event.locationInWindow, from: nil)
        setHoveredDivider(dividers.firstIndex { $0.rect.insetBy(dx: -2, dy: -2).contains(point) })
        if let focused { window?.makeFirstResponder(focused) }
    }

    // MARK: 分隔缝上的把手

    private func updateDividerAreas() {
        dividerAreas.forEach(removeTrackingArea)
        dividerAreas = dividers.enumerated().map { index, divider in
            let area = NSTrackingArea(rect: divider.rect.insetBy(dx: -2, dy: -2),
                                      options: [.mouseEnteredAndExited, .activeInKeyWindow],
                                      owner: self, userInfo: ["divider": index])
            addTrackingArea(area)
            return area
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        updateDividerAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        guard let index = event.trackingArea?.userInfo?["divider"] as? Int, dividers.indices.contains(index) else {
            return super.mouseEntered(with: event)
        }
        setHoveredDivider(index)
    }

    override func mouseExited(with event: NSEvent) {
        guard event.trackingArea?.userInfo?["divider"] != nil else { return super.mouseExited(with: event) }
        if dragging == nil { setHoveredDivider(nil) }
    }

    private func setHoveredDivider(_ index: Int?) {
        hoveredDivider = index
        if let index { placeGrip(on: index) } else { grip.isHidden = true }
    }

    private func placeGrip(on index: Int) {
        guard dividers.indices.contains(index) else { grip.isHidden = true; return }
        let rect = dividers[index].rect
        let horizontal = dividers[index].split.axis == .horizontal
        let length = min(44, (horizontal ? rect.height : rect.width) * 0.4)
        grip.frame = horizontal
            ? NSRect(x: rect.midX - 2, y: rect.midY - length / 2, width: 4, height: length)
            : NSRect(x: rect.midX - length / 2, y: rect.midY - 2, width: length, height: 4)
        grip.color = style?.accent ?? .controlAccentColor
        if grip.superview !== self || subviews.last !== grip { addSubview(grip, positioned: .above, relativeTo: nil) }
        grip.isHidden = false
    }

    // MARK: 拖分屏标题栏：换位置、移到新标签页

    func headerMouseDown(_ header: PaneHeaderView, event: NSEvent) {
        guard let session = header.session, let workspace = session.workspace else { return }
        workspace.select(session)
        window?.makeFirstResponder(session.terminalView)
        if event.clickCount == 2 {
            workspace.toggleZoom()
            return
        }
        paneDrag = PaneDrag(session: session, start: convert(event.locationInWindow, from: nil))
    }

    func headerMouseDragged(_ header: PaneHeaderView, event: NSEvent) {
        guard var drag = paneDrag else { return }
        let point = convert(event.locationInWindow, from: nil)
        if !drag.active {
            guard hypot(point.x - drag.start.x, point.y - drag.start.y) > 4 else { return }
            drag.active = true
            NSCursor.closedHand.push()
        }
        drag.target = dropTarget(at: point, dragging: drag.session)
        paneDrag = drag
        showDropIndicator(for: drag.target)
    }

    func headerMouseUp(_ header: PaneHeaderView, event: NSEvent) {
        guard let drag = paneDrag else { return }
        paneDrag = nil
        dropIndicator.isHidden = true
        guard drag.active else { return }
        NSCursor.pop()
        guard let target = drag.target, let workspace = drag.session.workspace else { return }
        perform(target, moving: drag.session, in: workspace)
    }

    /// 把 session 放到 target（测试脚本也走这里）
    func perform(_ target: DropTarget, moving session: TerminalSession, in workspace: WorkspaceModel) {
        switch target {
        case .beside(let other, let edge): workspace.movePane(session, beside: other, edge: edge)
        case .swap(let other): workspace.swapPanes(session, other)
        case .newTab: workspace.detachPane(session)
        }
    }

    /// 鼠标在 point 松开时，分屏会放到哪里
    func dropTarget(at point: NSPoint, dragging session: TerminalSession) -> DropTarget? {
        // 拖到终端区域上面（标签栏那一行）：移到新标签页
        if point.y < 0, point.y > -90, point.x >= bounds.minX, point.x <= bounds.maxX {
            return .newTab
        }
        guard let (other, frame) = visibleCards.first(where: { $0.frame.contains(point) }), other !== session,
              frame.width > 0, frame.height > 0
        else { return nil }
        let u = (point.x - frame.minX) / frame.width
        let v = (point.y - frame.minY) / frame.height
        if (0.3...0.7).contains(u), (0.3...0.7).contains(v) { return .swap(other) }
        let edges: [(PaneEdge, CGFloat)] = [(.left, u), (.right, 1 - u), (.top, v), (.bottom, 1 - v)]
        return .beside(other, edges.min { $0.1 < $1.1 }!.0)
    }

    private func showDropIndicator(for target: DropTarget?) {
        guard let target else {
            dropIndicator.isHidden = true
            return
        }
        let frame: NSRect
        switch target {
        case .newTab:
            frame = NSRect(x: bounds.minX + 40, y: bounds.minY + 6, width: max(0, bounds.width - 80), height: 46)
            dropIndicator.text = "松开鼠标，移到新标签页"
        case .swap(let other):
            frame = (visibleCards.first { $0.session === other }?.frame ?? .zero).insetBy(dx: 6, dy: 6)
            dropIndicator.text = "互换位置"
        case .beside(let other, let edge):
            let card = visibleCards.first { $0.session === other }?.frame ?? .zero
            switch edge {
            case .left: frame = NSRect(x: card.minX, y: card.minY, width: card.width / 2, height: card.height)
            case .right: frame = NSRect(x: card.midX, y: card.minY, width: card.width / 2, height: card.height)
            case .top: frame = NSRect(x: card.minX, y: card.minY, width: card.width, height: card.height / 2)
            case .bottom: frame = NSRect(x: card.minX, y: card.midY, width: card.width, height: card.height / 2)
            }
            dropIndicator.text = edge.title
        }
        dropIndicator.color = style?.accent ?? .controlAccentColor
        dropIndicator.frame = frame
        if dropIndicator.superview !== self || subviews.last !== dropIndicator {
            addSubview(dropIndicator, positioned: .above, relativeTo: nil)
        }
        dropIndicator.isHidden = false
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        terminals.forEach(applyMetal)
        if let focused, !focused.isHidden {
            DispatchQueue.main.async { window.makeFirstResponder(focused) }
        }
    }

    /// Metal 必须在视图进入窗口之后才能开；失败就留在 CoreGraphics 渲染
    private func applyMetal(to terminal: TerminalView) {
        guard window != nil else { return }
        do {
            try terminal.setUseMetal(wantsMetal)
        } catch {
            NSLog("Conch：Metal 渲染不可用，改用 CoreGraphics：\(error)")
        }
    }
}

/// 拿到 SwiftUI 视图所在的 NSWindow
struct WindowReader: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.onWindow = onWindow
        return view
    }

    func updateNSView(_ view: ReaderView, context: Context) {}

    final class ReaderView: NSView {
        var onWindow: ((NSWindow) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            DispatchQueue.main.async { [weak self] in self?.onWindow?(window) }
        }
    }
}
