import ConchKit
import SwiftUI

/// 新标签页：快速连接、最近连接过的会话、快速连接记录、新建和导入
struct LauncherView: View {
    @ObservedObject var workspace: WorkspaceModel
    let tab: TerminalSession
    @ObservedObject private var store = SessionStore.shared
    @StateObject private var model = LauncherModel()
    @FocusState private var fieldFocused: Bool
    @Environment(\.palette) private var palette

    /// 点一下填进输入框的例子（verbatim：不让里面的 user@host 变成邮件链接）
    private static let examples = [
        "root@10.0.0.5", "deploy@web.example.com:2222", "ssh -J ops@跳板机 app@10.0.1.8", "telnet 192.168.1.1",
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                quickConnect
                if !recents.isEmpty {
                    section("最近连接", note: "右键可以编辑") {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 10)], spacing: 10) {
                            ForEach(recents) { profile in
                                recentCard(profile)
                            }
                        }
                    }
                }
                if !model.history.isEmpty {
                    section("快速连接记录", note: "右键可以从记录中删除") {
                        FlowLayout(spacing: 6) {
                            ForEach(model.history, id: \.self) { text in
                                chip(text, systemImage: "clock.arrow.circlepath") {
                                    model.text = text
                                    connect()
                                }
                                .contextMenu {
                                    Button("连接") { model.text = text; connect() }
                                    Button("从记录中删除") { model.forget(text) }
                                }
                            }
                        }
                    }
                }
                actions
            }
            .padding(.horizontal, 40)
            .padding(.top, 52)
            .padding(.bottom, 32)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .panelCard(palette)
        .onAppear {
            model.history = QuickConnectHistory.load()
            DispatchQueue.main.async { fieldFocused = true }
        }
    }

    private var recents: [SessionProfile] {
        store.library.recent(limit: 8)
    }

    private var quickConnect: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("快速连接")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(palette.ink)
                Text("输入地址、ssh 或 telnet 命令，回车就连；也可以写 ~/.ssh/config 里的别名。")
                    .font(.system(size: 13))
                    .foregroundStyle(palette.muted)
            }
            HStack(spacing: 10) {
                Image(systemName: "terminal")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(palette.muted)
                TextField("", text: $model.text, prompt: Text("user@host:端口、ssh / telnet 命令，或 ~/.ssh/config 里的别名"))
                    .textFieldStyle(.plain)
                    .font(.system(size: 14).monospaced())
                    .focused($fieldFocused)
                    .onSubmit(connect)
                Button(action: connect) {
                    Text("连接")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(palette.onAccent)
                        .padding(.horizontal, 18)
                        .frame(height: 36)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(palette.accent))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
                .disabled(model.text.trimmingCharacters(in: .whitespaces).isEmpty)
                .opacity(model.text.trimmingCharacters(in: .whitespaces).isEmpty ? 0.45 : 1)
            }
            .padding(.leading, 16)
            .padding(.trailing, 8)
            .frame(height: 52)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(palette.input)
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(palette.fieldBorder, lineWidth: 0.5))
                    .shadow(color: palette.panelShadow, radius: 12, y: 6)
            )
            if let error = model.error {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.system(size: 12.5))
                    .foregroundStyle(palette.danger)
            }
            FlowLayout(spacing: 6) {
                Text("例如")
                    .font(.system(size: 12))
                    .foregroundStyle(palette.muted)
                ForEach(Self.examples, id: \.self) { example in
                    chip(example, systemImage: nil) {
                        model.text = example
                        fieldFocused = true
                    }
                    .help("填进输入框")
                }
            }
        }
    }

    private func recentCard(_ profile: SessionProfile) -> some View {
        Button {
            workspace.open(profile)
        } label: {
            HStack(spacing: 12) {
                if palette.showsEnvironment {
                    SessionAvatar(name: profile.displayName, environment: store.library.environment(of: profile), size: 34)
                } else {
                    Image(systemName: Self.icon(for: profile))
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(palette.ink2)
                        .frame(width: 34, height: 34)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(palette.field))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(profile.displayName)
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(palette.ink)
                        .lineLimit(1)
                    Text(profile.address)
                        .font(.system(size: 11).monospaced())
                        .foregroundStyle(palette.muted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 4)
                Text(profile.lastConnected.map(Self.relative) ?? "")
                    .font(.system(size: 11))
                    .foregroundStyle(palette.muted)
                    .lineLimit(1)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(palette.field))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .contextMenu {
            Button("连接") { workspace.open(profile) }
            Button("编辑…") { workspace.edit(profile) }
        }
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Button {
                workspace.editNew()
            } label: {
                Label("新建会话…", systemImage: "plus")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(palette.ink)
                    .padding(.horizontal, 12)
                    .frame(height: 32)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(palette.field))
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressableStyle())
            Button {
                workspace.importSSHConfig()
            } label: {
                Label("导入 ~/.ssh/config", systemImage: "square.and.arrow.down")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(palette.ink2)
                    .padding(.horizontal, 10)
                    .frame(height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressableStyle())
            Button {
                workspace.importXshell()
            } label: {
                Label("导入 Xshell 会话…", systemImage: "square.and.arrow.down")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(palette.ink2)
                    .padding(.horizontal, 10)
                    .frame(height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressableStyle())
        }
        .padding(.top, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) {
            Rectangle().fill(palette.hairline).frame(height: 0.5)
        }
    }

    private func chip(_ text: String, systemImage: String?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let systemImage {
                    Image(systemName: systemImage).font(.system(size: 10.5, weight: .semibold))
                }
                Text(verbatim: text)
                    .font(.system(size: 11.5).monospaced())
                    .lineLimit(1)
            }
            .foregroundStyle(palette.ink2)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(palette.field))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
    }

    private func connect() {
        let text = model.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard let resolved = QuickConnectResolver.resolve(text) else {
            model.error = "没看懂这个地址。可以写 user@host、user@host:端口、ssh 命令，或者 telnet 主机 端口"
            return
        }
        model.error = nil
        QuickConnectHistory.remember(text)
        workspace.select(tab)
        tab.open(resolved.profile, adHocJumps: resolved.jumps)
        workspace.focusTerminalSoon()
    }

    private func section<Content: View>(_ title: String, note: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(palette.ink)
                Spacer()
                Text(note).font(.system(size: 11.5)).foregroundStyle(palette.muted)
            }
            content()
        }
    }

    private static func icon(for profile: SessionProfile) -> String {
        switch profile.kind {
        case .ssh: "server.rack"
        case .telnet: "network"
        case .serial: "cable.connector"
        }
    }

    private static func relative(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

final class LauncherModel: ObservableObject {
    @Published var text = ""
    @Published var error: String?
    @Published var history: [String] = []

    func forget(_ text: String) {
        QuickConnectHistory.remove(text)
        history = QuickConnectHistory.load()
    }
}

/// 按下时稍微变淡的按钮
struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.65 : 1)
    }
}

/// 一行放不下就换行的排列（例子、快捷命令、记录的小块）
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: min(width, proposal.width ?? width), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if needed > width, !current.indices.isEmpty {
                rows.append(current)
                current = Row()
            }
            current.width = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            current.height = max(current.height, size.height)
            current.indices.append(index)
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}
