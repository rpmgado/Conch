import ConchKit
import SwiftTerm
import SwiftUI

/// 快捷命令，存在 UserDefaults；打开会话同步后存在同步文件夹里的 quick-commands.json
final class QuickCommandStore: ObservableObject {
    static let shared = QuickCommandStore()
    private static let key = "quickCommands"

    @Published var commands: [QuickCommand] {
        didSet { if !reloading { save() } }
    }

    /// nil 表示存在 UserDefaults 里
    private var file: WatchedJSONFile?
    private var reloading = false
    private var watcher: Timer?

    private init() {
        let file = SyncSettings.directory.map { WatchedJSONFile(url: $0.appendingPathComponent(SyncSettings.quickCommandsFileName)) }
        self.file = file
        if let file, let list = try? file.read([QuickCommand].self) {
            commands = list
        } else if let data = UserDefaults.standard.data(forKey: Self.key),
                  let list = try? JSONDecoder().decode([QuickCommand].self, from: data)
        {
            commands = list
        } else {
            // 第一次用给几个例子，可以在设置里改
            commands = [
                QuickCommand(name: "磁盘", command: "df -h"),
                QuickCommand(name: "内存", command: "free -h"),
                QuickCommand(name: "负载", command: "uptime"),
                QuickCommand(name: "最近日志", command: "tail -n 50 /var/log/syslog"),
            ]
        }
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.reloadIfChanged() }
        RunLoop.main.add(timer, forMode: .common)
        watcher = timer
    }

    private func reloadIfChanged() {
        guard let file, file.changedOnDisk, let list = try? file.read([QuickCommand].self), list != commands else { return }
        reloading = true
        commands = list
        reloading = false
    }

    /// 打开同步时存到同步文件夹（那边已有的命令保留，本机多出来的加进去）；关闭同步时 url 为 nil，存回本机
    func relocate(to url: URL?, mergeCurrent: Bool) {
        let current = commands
        file = url.map(WatchedJSONFile.init(url:))
        var merged = current
        if mergeCurrent, let file, let existing = try? file.read([QuickCommand].self) {
            merged = existing
            for command in current where !merged.contains(where: { $0.id == command.id || $0.command == command.command }) {
                merged.append(command)
            }
        }
        reloading = true
        commands = merged
        reloading = false
        save()
    }

    private func save() {
        try? file?.write(commands)
        // 开着同步时本机也留一份：同步文件夹暂时打不开时用
        if !TestHooks.isActive, let data = try? JSONEncoder().encode(commands) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }
}

/// 撰写栏：先写好命令再发送，可以发给当前会话或这个窗口里的所有会话；右边是快捷命令按钮
struct ComposeBar: View {
    @ObservedObject var workspace: WorkspaceModel
    @ObservedObject private var store = QuickCommandStore.shared
    @StateObject private var model = ComposeModel()
    @FocusState private var focused: Bool
    @Environment(\.openSettings) private var openSettings
    @Environment(\.palette) private var palette

    var body: some View {
        let hasRecipients = !model.recipients(in: workspace).isEmpty
        let canSend = !model.text.isEmpty && hasRecipients
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                TextField("", text: $model.text, prompt: Text("先写好命令再回车发送，适合长命令和发给多个会话"))
                    .textFieldStyle(.plain)
                    .font(.system(size: 13).monospaced())
                    .focused($focused)
                    .onSubmit { sendDraft() }
                    .padding(.horizontal, 12)
                    .frame(height: 34)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(palette.input)
                            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(palette.fieldBorder, lineWidth: 0.5))
                    )
                Picker("发送范围", selection: $model.toAll) {
                    Text("当前会话").tag(false)
                    Text("全部会话（\(workspace.connectedSessions.count)）").tag(true)
                }
                .labelsHidden()
                .fixedSize()
                .help("撰写栏和栏内快捷命令按这里选定的范围发送")
                Button {
                    sendDraft()
                } label: {
                    HStack(spacing: 6) {
                        Text("发送")
                        Image(systemName: "return")
                    }
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(palette.onAccent)
                    .padding(.horizontal, 14)
                    .frame(height: 34)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(palette.accent))
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressableStyle())
                .disabled(!canSend)
                .opacity(canSend ? 1 : 0.45)
            }
            if !store.commands.isEmpty {
                HStack(spacing: 6) {
                    Text("快捷命令")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(palette.muted)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(store.commands) { command in
                                Button {
                                    model.send(command.payload, in: workspace)
                                } label: {
                                    Text(command.name)
                                        .font(.system(size: 12))
                                        .foregroundStyle(palette.ink)
                                        .padding(.horizontal, 10)
                                        .frame(height: 24)
                                        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(palette.field))
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(PressableStyle())
                                .disabled(!hasRecipients)
                                .help(command.command)
                            }
                        }
                    }
                    Button {
                        openSettings()
                    } label: {
                        Image(systemName: "pencil")
                            .font(.system(size: 12, weight: .medium))
                            .frame(width: 24, height: 24)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(palette.muted)
                    .help("在设置里编辑快捷命令")
                }
                .padding(.horizontal, 2)
            }
        }
        .padding(10)
        .panelCard(palette)
        .onAppear { focused = true }
    }

    private func sendDraft() {
        guard !model.text.isEmpty, model.send(model.text + "\r", in: workspace) else { return }
        model.text = ""
    }
}

final class ComposeModel: ObservableObject {
    @Published var text = ""
    @Published var toAll = false

    /// 撰写栏发送范围由选择器决定，和终端键盘的同步输入各自独立。
    func recipients(in workspace: WorkspaceModel) -> [TerminalSession] {
        if toAll { return workspace.connectedSessions }
        guard let session = workspace.activeSession, session.isConnected else { return [] }
        return [session]
    }

    @discardableResult
    func send(_ text: String, in workspace: WorkspaceModel) -> Bool {
        let targets = recipients(in: workspace)
        guard !text.isEmpty, !targets.isEmpty else { return false }
        let data = Data(text.utf8)
        for session in targets { session.receiveBroadcast(data) }
        return true
    }
}

/// 终端里查找（⌘F）
final class FindModel: ObservableObject {
    @Published var visible = false
    @Published var text = ""
    @Published var caseSensitive = false
    @Published var regex = false
    @Published private(set) var summary: (index: Int, total: Int) = (0, 0)
    @Published private(set) var notFound = false

    var options: SearchOptions {
        SearchOptions(caseSensitive: caseSensitive, regex: regex, wholeWord: false)
    }

    func next(in terminal: TerminalView?, backwards: Bool = false) {
        guard let terminal, !text.isEmpty else { return }
        let found = backwards ? terminal.findPrevious(text, options: options) : terminal.findNext(text, options: options)
        notFound = !found
        let result = terminal.searchMatchSummary(text, options: options)
        summary = (result.index, result.total)
    }

    func close(in terminal: TerminalView?) {
        visible = false
        terminal?.clearSearch()
        summary = (0, 0)
        notFound = false
    }
}

struct FindBar: View {
    @ObservedObject var model: FindModel
    let terminal: TerminalView?
    @FocusState private var focused: Bool
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(palette.muted)
            TextField("在终端中查找", text: $model.text)
                .textFieldStyle(.plain)
                .frame(width: 180)
                .focused($focused)
                .onSubmit { model.next(in: terminal) }
                .onChange(of: model.text) { _, _ in model.next(in: terminal) }
            if !model.text.isEmpty {
                Text(model.notFound ? "没有找到" : "\(model.summary.index)/\(model.summary.total)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(model.notFound ? .red : .secondary)
            }
            Toggle("Aa", isOn: $model.caseSensitive).toggleStyle(.button).help("区分大小写")
            Toggle(".*", isOn: $model.regex).toggleStyle(.button).help("正则表达式")
            Button { model.next(in: terminal, backwards: true) } label: { Image(systemName: "chevron.up") }
                .help("上一个（⇧⌘G）")
            Button { model.next(in: terminal) } label: { Image(systemName: "chevron.down") }
                .help("下一个（⌘G）")
            Button { model.close(in: terminal) } label: { Image(systemName: "xmark") }
                .keyboardShortcut(.cancelAction)
                .help("关闭（Esc）")
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .padding(.horizontal, 12)
        .frame(height: 36)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(palette.popover)
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(palette.panelBorder, lineWidth: 0.5))
                .shadow(color: palette.panelShadow, radius: 10, y: 4)
        )
        .padding(12)
        .onAppear { focused = true }
    }
}
