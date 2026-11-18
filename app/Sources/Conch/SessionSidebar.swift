import ConchKit
import SwiftUI

/// 左边浮起来的会话列表：搜索、分组树、右键菜单，双击（或回车）连接
struct SessionSidebar: View {
    /// 只用来执行操作；不观察它（窗口里任何终端一变它就变，会话列表不必跟着重画）
    let workspace: WorkspaceModel
    @ObservedObject var sidebar: SidebarState
    @ObservedObject private var store = SessionStore.shared
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(spacing: 6) {
            header
            searchField
                .padding(.horizontal, 10)
            List(selection: $sidebar.selection) {
                if isSearching {
                    let results = store.library.search(sidebar.searchText)
                    if results.isEmpty {
                        Text("没有找到匹配的会话").foregroundStyle(.secondary)
                    }
                    ForEach(results) { profile in
                        SessionRow(profile: profile, showGroup: true, workspace: workspace, sidebar: sidebar)
                            .tag("s:\(profile.id.uuidString)")
                    }
                } else {
                    let tree = store.library.tree()
                    if tree.isEmpty {
                        emptyHint
                    }
                    ForEach(tree) { node in
                        NodeView(node: node, workspace: workspace, sidebar: sidebar)
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .contextMenu(forSelectionType: String.self) { ids in
                menu(for: ids)
            } primaryAction: { ids in
                connect(ids)
            }
            bottomBar
        }
        .padding(.bottom, 8)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .panelCard(palette)
    }

    /// 最上面一行：左边给红绿灯按钮留位置，可以拖动窗口；右边是收起侧边栏
    private var header: some View {
        HStack(spacing: 0) {
            WindowDragArea()
            ChromeIconButton(systemImage: "sidebar.left", help: "隐藏侧边栏（⌃⌘S）") { workspace.toggleSidebar() }
                .padding(.trailing, 6)
        }
        .frame(height: 40)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(palette.muted)
            TextField("搜索会话", text: $sidebar.searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
            if !sidebar.searchText.isEmpty {
                Button {
                    sidebar.searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(palette.muted)
                }
                .buttonStyle(.plain)
                .help("清除搜索")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .fieldBackground(palette, radius: 10)
    }

    private var isSearching: Bool {
        !sidebar.searchText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var emptyHint: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("还没有保存的会话").foregroundStyle(.secondary)
            Text("点下面的“新建会话”，或者从 ~/.ssh/config、Xshell 导入。")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
    }

    private var bottomBar: some View {
        HStack(spacing: 8) {
            Menu {
                Button("新建会话…") { workspace.editNew(group: selectedGroup ?? "") }
                Button("新建分组…") { workspace.newGroup(parent: selectedGroup ?? "") }
                Divider()
                Button("导入 ~/.ssh/config") { workspace.importSSHConfig() }
                Button("导入 Xshell 会话…") { workspace.importXshell() }
            } label: {
                Label("新建会话", systemImage: "plus")
                    .font(.system(size: 12.5, weight: .medium))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("新建会话、分组，或导入")
            Spacer()
            syncStatus
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .overlay(alignment: .top) {
            Rectangle().fill(palette.hairline).frame(height: 0.5).padding(.horizontal, 10)
        }
    }

    @ViewBuilder
    private var syncStatus: some View {
        let count = "\(store.library.sessions.count) 个会话"
        if let message = store.persistenceMessage {
            Label("同步 / 保存提示", systemImage: "exclamationmark.icloud")
                .foregroundStyle(palette.caution)
                .help(message)
        } else if store.waitingForSyncFolder {
            Label(count, systemImage: "exclamationmark.icloud")
                .foregroundStyle(palette.caution)
                .help("同步文件夹现在打不开（移动硬盘或网络盘没连上？）。修改先存在本机，等它回来会自动合并")
        } else if SyncSettings.directory != nil {
            Label("已同步 · \(count)", systemImage: "checkmark.icloud")
                .foregroundStyle(palette.muted)
                .help("会话列表放在同步文件夹里，几台 Mac 共用")
        } else {
            Text(count).foregroundStyle(palette.muted)
        }
    }

    /// 选中的分组（选中会话时取它所在的分组），新建会话、分组时放在这里
    private var selectedGroup: String? {
        guard let id = sidebar.selection.first else { return nil }
        if let path = SessionNode.groupPath(from: id) { return path }
        return SessionNode.sessionID(from: id).flatMap { store.session($0)?.group }
    }

    private func sessionIDs(_ ids: Set<String>) -> [UUID] {
        // 按列表里的顺序打开
        let wanted = Set(ids.compactMap(SessionNode.sessionID(from:)))
        return store.library.search("").map(\.id).filter(wanted.contains)
    }

    private func connect(_ ids: Set<String>) {
        let sessions = sessionIDs(ids)
        if !sessions.isEmpty {
            workspace.openSessions(sessions)
        } else if ids.count == 1, let path = ids.first.flatMap(SessionNode.groupPath(from:)) {
            workspace.toggleGroup(path)
        }
    }

    @ViewBuilder
    private func menu(for ids: Set<String>) -> some View {
        let sessions = sessionIDs(ids)
        let groups = ids.compactMap(SessionNode.groupPath(from:))
        if !sessions.isEmpty {
            Button(sessions.count == 1 ? "连接" : "连接这 \(sessions.count) 个会话") { workspace.openSessions(sessions) }
            if sessions.count == 1, let profile = store.session(sessions[0]) {
                let canSplit = workspace.activeSession.map { !$0.isLauncher } ?? false
                Button("在右侧分屏打开") { workspace.openInSplit(profile, axis: .horizontal) }
                    .disabled(!canSplit)
                Button("在下方分屏打开") { workspace.openInSplit(profile, axis: .vertical) }
                    .disabled(!canSplit)
                Divider()
                Button("编辑…") { workspace.edit(profile) }
                Button("复制一份") {
                    var copy = profile
                    copy.id = UUID()
                    copy.name = profile.displayName + " 副本"
                    copy.lastConnected = nil
                    store.upsert(copy)
                }
                Button("忘记保存的密码") { workspace.forgetSecrets(profile) }
            }
            Menu("移动到分组") {
                Button("顶层") { workspace.move(Set(sessions), to: "") }
                let allGroups = store.library.allGroups
                if !allGroups.isEmpty { Divider() }
                ForEach(allGroups, id: \.self) { group in
                    Button(group) { workspace.move(Set(sessions), to: group) }
                }
                Divider()
                Button("新分组…") {
                    Dialogs.promptText("移动到新分组", confirmTitle: "移动", window: workspace.window) { name in
                        if let name { workspace.move(Set(sessions), to: name) }
                    }
                }
            }
            Divider()
            Button(sessions.count == 1 ? "删除" : "删除这 \(sessions.count) 个会话", role: .destructive) {
                workspace.deleteSessions(Set(sessions))
            }
        } else if groups.count == 1, let path = groups.first {
            Button("在这个分组里新建会话…") { workspace.editNew(group: path) }
            Button("新建子分组…") { workspace.newGroup(parent: path) }
            Button("重命名分组…") { workspace.renameGroup(path) }
            environmentMenu(for: path)
            Divider()
            Button("删除分组…", role: .destructive) { workspace.deleteGroup(path) }
        } else {
            Button("新建会话…") { workspace.editNew() }
            Button("新建分组…") { workspace.newGroup() }
        }
    }

    /// 分组的环境标签：生产、测试、设备；没设时跟着上级
    private func environmentMenu(for path: String) -> some View {
        let own = store.library.environments[GroupPath.normalize(path)]
        let inherited = store.library.environment(ofGroup: GroupPath.parent(of: path))
        return Menu("环境") {
            Toggle(inherited.map { "跟随上级（\($0.title)）" } ?? "无", isOn: Binding(
                get: { own == nil },
                set: { if $0 { workspace.setEnvironment(nil, forGroup: path) } }
            ))
            Divider()
            ForEach(SessionEnvironment.allCases, id: \.self) { environment in
                Toggle(environment.title, isOn: Binding(
                    get: { own == environment },
                    set: { if $0 { workspace.setEnvironment(environment, forGroup: path) } }
                ))
            }
            Divider()
            Text("“环境色”主题按这个给会话上色，连到生产环境时窗口顶上有红线提示")
        }
    }
}

/// 树里的一个节点：分组可以折叠，会话是叶子
private struct NodeView: View {
    let node: SessionNode
    let workspace: WorkspaceModel
    @ObservedObject var sidebar: SidebarState
    @ObservedObject private var store = SessionStore.shared
    @Environment(\.palette) private var palette

    var body: some View {
        switch node.kind {
        case .group(let path):
            DisclosureGroup(isExpanded: Binding(
                get: { !sidebar.collapsedGroups.contains(path) },
                set: { expanded in
                    if expanded { sidebar.collapsedGroups.remove(path) } else { sidebar.collapsedGroups.insert(path) }
                }
            )) {
                ForEach(node.children ?? []) { child in
                    NodeView(node: child, workspace: workspace, sidebar: sidebar)
                }
            } label: {
                HStack(spacing: 6) {
                    if palette.showsEnvironment, let environment = store.library.environment(ofGroup: path) {
                        RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                            .fill(EnvironmentStyle.of(environment).swatch)
                            .frame(width: 8, height: 8)
                            .help("\(environment.title)环境")
                    } else {
                        Image(systemName: "folder")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    Text(node.title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text("\(Self.sessionCount(node))")
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
            .tag(node.id)
        case .session(let profile):
            SessionRow(profile: profile, showGroup: false, workspace: workspace, sidebar: sidebar)
                .tag(node.id)
        }
    }

    private static func sessionCount(_ node: SessionNode) -> Int {
        switch node.kind {
        case .session: 1
        case .group: (node.children ?? []).reduce(0) { $0 + sessionCount($1) }
        }
    }
}

private struct SessionRow: View {
    @AppStorage(Prefs.compactSidebar) private var compact = false
    let profile: SessionProfile
    let showGroup: Bool
    let workspace: WorkspaceModel
    @ObservedObject var sidebar: SidebarState
    @ObservedObject private var store = SessionStore.shared
    @Environment(\.palette) private var palette

    var body: some View {
        let connected = sidebar.connectedIDs.contains(profile.id)
        HStack(spacing: 10) {
            if palette.showsEnvironment {
                SessionAvatar(name: profile.displayName, environment: store.library.environment(of: profile), size: 28,
                              status: connected ? palette.ok : nil, ringColor: palette.isDark ? .black : .white)
            } else {
                Image(systemName: icon)
                    .font(.system(size: 12.5, weight: .medium))
                    .frame(width: 26, height: 26)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(palette.field))
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(profile.displayName)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                if !compact, subtitle != profile.displayName {
                    Text(subtitle)
                        .font(.system(size: 12).monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 0)
            if connected && !palette.showsEnvironment {
                Circle().fill(palette.ok).frame(width: 7, height: 7)
                    .help("已连接")
            }
        }
        .padding(.vertical, compact ? 1 : 4)
        .help(help)
    }

    private var icon: String {
        switch profile.kind {
        case .ssh: profile.jumpHostID == nil ? "server.rack" : "arrow.triangle.branch"
        case .telnet: "network"
        case .serial: "cable.connector"
        }
    }

    private var subtitle: String {
        showGroup && !profile.group.isEmpty ? "\(profile.group) · \(profile.address)" : profile.address
    }

    private var help: String {
        var lines = [profile.address]
        switch profile.kind {
        case .ssh:
            lines.append("认证：\(profile.auth.title)")
            if let jump = SessionStore.shared.session(profile.jumpHostID) {
                lines.append("经由跳板机：\(jump.displayName)")
            }
        case .telnet:
            lines.append("Telnet（不加密）")
        case .serial:
            lines.append("串口 \(profile.serial.path)")
        }
        if let environment = store.library.environment(of: profile) {
            lines.append("环境：\(environment.title)")
        }
        if !profile.notes.isEmpty { lines.append(profile.notes) }
        return lines.joined(separator: "\n")
    }
}
