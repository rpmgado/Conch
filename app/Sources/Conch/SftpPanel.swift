import AppKit
import ConchKit
import SwiftUI
import UniformTypeIdentifiers

/// 右侧的文件面板：上面是服务器（SFTP），下面是本机，中间一条“上传 / 下载”的分隔条（上下拖动调高度），
/// 再下面是编辑中的文件和传输队列。两栏之间可以互相拖文件；从访达拖文件进服务器那一栏也是上传。
/// 同名文件覆盖前先问一声
struct SftpPanel: View {
    @ObservedObject var browser: SftpBrowser
    @ObservedObject var local: LocalBrowser
    let tab: TerminalSession
    let workspace: WorkspaceModel
    /// 显示本机那一栏（面板标题栏上的按钮切换）
    let showLocal: Bool
    var expanded = false
    @StateObject private var split = SplitState()
    @Environment(\.palette) private var palette

    /// 两栏之间那条分隔条的高度
    private static let barHeight: CGFloat = 34

    var body: some View {
        VStack(spacing: 0) {
            if expanded {
                transferActions
                GeometryReader { proxy in
                    let limit = max(320, Double(proxy.size.width) - 330)
                    HStack(spacing: 0) {
                        localSection.frame(width: min(split.expandedLocalWidth, limit), height: proxy.size.height)
                        ResizeHandle(width: $split.expandedLocalWidth, range: 320...limit, growsRightward: true)
                        remoteSection.frame(maxWidth: .infinity).frame(height: proxy.size.height)
                    }
                }
            } else {
            GeometryReader { proxy in
                let available = max(0, proxy.size.height - Self.barHeight)
                VStack(spacing: 0) {
                    remoteSection
                        .frame(height: showLocal ? available * (1 - split.localFraction) : proxy.size.height)
                    if showLocal {
                        transferBar(available: available)
                        localSection
                            .frame(height: available * split.localFraction)
                    }
                }
            }
            }
            if !browser.edits.isEmpty {
                hairline
                EditList(browser: browser)
            }
            if !browser.transfers.isEmpty {
                hairline
                TransferList(browser: browser)
            }
            hairline
            footer
        }
        .onAppear {
            browser.activate()
            if showLocal { local.activate() }
        }
        .onDisappear {
            if showLocal { local.deactivate() }
        }
        .onChange(of: showLocal) { _, shown in
            if shown { local.activate() } else { local.deactivate() }
        }
    }

    private var hairline: some View {
        Rectangle().fill(palette.hairline).frame(height: 0.5).padding(.horizontal, 12)
    }

    /// 两栏的高度比例（拖中间的分隔条调）
    final class SplitState: ObservableObject {
        @Published var localFraction = min(0.8, max(0.2, UserDefaults.standard.double(forKey: Prefs.localFilesFraction)))
        @Published var expandedLocalWidth = 480.0
        var dragStart: Double?
    }

    // MARK: 服务器那一栏

    private var remoteSection: some View {
        VStack(spacing: 0) {
            sectionTitle("远程 · \(tab.tabTitle)", detail: tab.routeDescription, icon: "server.rack", count: browser.selection.count)
            pathBar(icon: "server.rack", iconHelp: "服务器上的文件（\(tab.routeDescription)）", text: $browser.pathField,
                    enabled: browser.isReady, submit: { browser.go(to: browser.pathField) },
                    up: browser.goUp, home: browser.goHome, refresh: browser.refresh,
                    showHidden: $browser.showHidden) {
                if let directory = tab.remoteDirectory {
                    iconButton("terminal", "转到终端当前目录 \(directory)", enabled: browser.isReady) { browser.go(to: directory) }
                }
            }
            remoteContent
        }
    }

    @ViewBuilder
    private var remoteContent: some View {
        switch browser.status {
        case .idle, .opening:
            placeholder { ProgressView("正在打开 SFTP…").controlSize(.small) }
        case .failed(let message):
            placeholder {
                VStack(spacing: 8) {
                    Text(message).font(.callout).multilineTextAlignment(.center)
                    Button("重试") { browser.open() }
                }
            }
        case .disconnected:
            placeholder {
                VStack(spacing: 8) {
                    Text("连接已断开").foregroundStyle(.secondary)
                    if tab.isConnected { Button("重新打开") { browser.open() } }
                }
            }
        case .ready:
            remoteList
        }
    }

    private func placeholder<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack { Spacer(); content().padding(); Spacer() }.frame(maxWidth: .infinity)
    }

    private var remoteList: some View {
        List(selection: $browser.selection) {
            ForEach(browser.visibleEntries, id: \.path) { file in
                RemoteFileRow(file: file)
                    .tag(file.path)
                    .draggable(RemoteFilesDrag(sourceID: browser.transferSourceID, paths: dragPaths(for: file.path, selection: browser.selection)))
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .overlay {
            if browser.loading { ProgressView().controlSize(.small) }
        }
        .contextMenu(forSelectionType: String.self) { paths in
            remoteMenu(for: paths.compactMap(browser.entry))
        } primaryAction: { paths in
            guard paths.count == 1, let file = paths.first.flatMap(browser.entry) else { return }
            if file.isDir {
                browser.go(to: file.path)
            } else if showLocal {
                download([file], to: local.directory)
            } else {
                download([file], to: AppPaths.downloadsDirectory, reveal: true)
            }
        }
        .onDrop(of: [.conchLocalFiles, .fileURL], isTargeted: nil) { providers in
            receiveUploads(providers)
        }
    }

    @ViewBuilder
    private func remoteMenu(for files: [RemoteFile]) -> some View {
        if files.isEmpty {
            Button("上传文件到这里…") { chooseUpload(to: nil) }
            Button("新建文件夹…") { newRemoteFolder() }
            Button("在终端中进入这个目录") { browser.changeTerminalDirectory(to: browser.path) }
        } else {
            if files.count == 1, let file = files.first, file.isDir {
                Button("打开") { browser.go(to: file.path) }
                Button("在终端中进入这个目录") { browser.changeTerminalDirectory(to: file.path) }
                Button("上传文件到这个文件夹…") { chooseUpload(to: file.path) }
                Divider()
            }
            if files.count == 1, let file = files.first, !file.isDir {
                Button("用本机编辑器打开") { browser.edit(file) }
                    .help("下载到本机用编辑器打开，保存后自动传回服务器")
                Divider()
            }
            if showLocal {
                Button("下载到本机这一栏的文件夹（\(local.directory.lastPathComponent)）") { download(files, to: local.directory) }
            }
            Button("下载到“下载”文件夹") { download(files, to: AppPaths.downloadsDirectory, reveal: true) }
            Button("下载到…") { chooseDownload(files) }
            Divider()
            if files.count == 1, let file = files.first {
                Button("重命名…") { renameRemote(file) }
                Button("修改权限…") { chmod(file) }
            }
            Button("复制路径") { browser.copyPath(files) }
            Divider()
            Button(files.count == 1 ? "删除" : "删除这 \(files.count) 项", role: .destructive) { deleteRemote(files) }
        }
    }

    // MARK: 中间的分隔条：上传、下载，上下拖动调两栏的高度

    private var transferActions: some View {
        HStack(spacing: 8) {
            Rectangle().fill(palette.hairline).frame(height: 0.5)
            barButton("上传", systemImage: expanded ? "arrow.right" : "arrow.up", enabled: browser.isReady && !local.selection.isEmpty,
                      help: "把本机这一栏选中的文件上传到服务器当前目录（也可以直接拖上去）") {
                upload(local.selection.compactMap(local.entry).map(\.url))
            }
            barButton("下载", systemImage: expanded ? "arrow.left" : "arrow.down", enabled: browser.isReady && !browser.selection.isEmpty,
                      help: "把服务器上选中的文件下载到本机这一栏的文件夹（也可以直接拖下来）") {
                download(browser.selection.compactMap(browser.entry), to: local.directory)
            }
            Rectangle().fill(palette.hairline).frame(height: 0.5)
        }
        .padding(.horizontal, 12)
        .frame(height: Self.barHeight)
        .contentShape(Rectangle())
    }

    private func transferBar(available: CGFloat) -> some View {
        transferActions
        .onHover { inside in
            if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
        }
        .gesture(
            DragGesture(minimumDistance: 2, coordinateSpace: .global)
                .onChanged { value in
                    let start = split.dragStart ?? split.localFraction
                    split.dragStart = start
                    split.localFraction = min(0.8, max(0.2, start - Double(value.translation.height / max(available, 1))))
                }
                .onEnded { _ in
                    split.dragStart = nil
                    if !TestHooks.isActive { UserDefaults.standard.set(split.localFraction, forKey: Prefs.localFilesFraction) }
                }
        )
    }

    private func barButton(_ title: String, systemImage: String, enabled: Bool, help: String,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 12, weight: .medium))
                .labelStyle(.titleAndIcon)
                .padding(.horizontal, 10)
                .frame(height: 24)
                .background(Capsule().fill(palette.field))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? palette.ink : palette.muted)
        .disabled(!enabled)
        .help(help)
    }

    // MARK: 本机那一栏

    private var localSection: some View {
        VStack(spacing: 0) {
            sectionTitle("本地 · 这台 Mac", detail: local.directory.path, icon: "laptopcomputer", count: local.selection.count)
            pathBar(icon: "laptopcomputer", iconHelp: "这台 Mac 上的文件", text: $local.pathField, enabled: true,
                    submit: { local.go(to: local.pathField) },
                    up: local.goUp, home: local.goHome, refresh: local.refresh, showHidden: $local.showHidden) {
                iconButton("folder", "在访达中打开这个文件夹", enabled: true) { local.reveal([]) }
            }
            localList
        }
    }

    private var localList: some View {
        List(selection: $local.selection) {
            ForEach(local.visibleEntries, id: \.path) { file in
                LocalFileRow(file: file)
                    .tag(file.path)
                    .draggable(LocalFilesDrag(paths: dragPaths(for: file.path, selection: local.selection)))
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .overlay {
            if local.visibleEntries.isEmpty, !local.loading {
                Text(local.entries.isEmpty ? "空文件夹" : "只有隐藏文件")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .contextMenu(forSelectionType: String.self) { paths in
            localMenu(for: paths.compactMap(local.entry))
        } primaryAction: { paths in
            guard paths.count == 1, let file = paths.first.flatMap(local.entry) else { return }
            if file.isDir { local.go(to: file.path) } else { upload([file.url]) }
        }
        .dropDestination(for: RemoteFilesDrag.self) { items, _ in
            guard let files = browser.filesForDrop(items) else { return false }
            download(files, to: local.directory)
            return true
        }
    }

    @ViewBuilder
    private func localMenu(for files: [LocalFile]) -> some View {
        if files.isEmpty {
            Button("新建文件夹…") { newLocalFolder() }
            Button("在访达中打开") { local.reveal([]) }
        } else {
            Button("上传到服务器（\(browser.path.isEmpty ? "当前目录" : browser.path)）") { upload(files.map(\.url)) }
                .disabled(!browser.isReady)
            Divider()
            if files.count == 1, let file = files.first {
                if file.isDir {
                    Button("打开") { local.go(to: file.path) }
                } else {
                    Button("用默认应用打开") { local.openInDefaultApp(file) }
                }
            }
            Button("在访达中显示") { local.reveal(files) }
            Divider()
            if files.count == 1, let file = files.first {
                Button("重命名…") { renameLocal(file) }
            }
            Button("复制路径") { local.copyPath(files) }
            Divider()
            Button(files.count == 1 ? "移到废纸篓" : "把这 \(files.count) 项移到废纸篓", role: .destructive) { trashLocal(files) }
        }
    }

    private func sectionTitle(_ title: String, detail: String, icon: String, count: Int) -> some View {
        HStack(spacing: 6) {
            Label(title, systemImage: icon).font(.system(size: 12, weight: .semibold)).lineLimit(1)
            Spacer(minLength: 4)
            if count > 0 { Text("已选 \(count) 项").font(.caption).foregroundStyle(palette.muted) }
        }
        .foregroundStyle(palette.ink)
        .padding(.horizontal, 12).padding(.top, 8)
        .help(detail)
    }

    // MARK: 地址栏

    private func pathBar<Extra: View>(icon: String, iconHelp: String, text: Binding<String>, enabled: Bool,
                                      submit: @escaping () -> Void, up: @escaping () -> Void, home: @escaping () -> Void,
                                      refresh: @escaping () -> Void, showHidden: Binding<Bool>,
                                      @ViewBuilder extra: () -> Extra) -> some View {
        HStack(spacing: 4) {
            iconButton("arrow.turn.left.up", "上一级", enabled: enabled, action: up)
            iconButton("house", "家目录", enabled: enabled, action: home)
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(palette.muted)
                    .help(iconHelp)
                TextField("路径", text: text)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12).monospaced())
                    .onSubmit(submit)
                    .help(text.wrappedValue)
                    .accessibilityLabel(icon == "server.rack" ? "远程路径" : "本地路径")
            }
            .disabled(!enabled)
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(palette.input)
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(palette.fieldBorder, lineWidth: 0.5))
            )
            iconButton("arrow.clockwise", "刷新", enabled: enabled, action: refresh)
            iconButton(showHidden.wrappedValue ? "eye" : "eye.slash",
                       showHidden.wrappedValue ? "隐藏点开头的文件（现在显示着）" : "显示隐藏文件（点开头的文件）",
                       enabled: enabled, isOn: showHidden.wrappedValue) {
                showHidden.wrappedValue.toggle()
            }
            extra()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private func iconButton(_ symbol: String, _ help: String, enabled: Bool, isOn: Bool = false,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12.5, weight: .medium))
                .frame(width: 26, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isOn ? palette.accent : palette.ink2)
        .help(help)
        .accessibilityLabel(help)
        .disabled(!enabled)
    }

    // MARK: 底部

    private var footer: some View {
        HStack(spacing: 10) {
            Button { chooseUpload(to: nil) } label: { Label("上传", systemImage: "square.and.arrow.up") }
                .help("选择文件或文件夹上传到服务器当前目录（也可以直接从访达拖进来）")
            Button { newRemoteFolder() } label: { Label("新建文件夹", systemImage: "folder.badge.plus") }
                .help("在服务器当前目录新建文件夹")
            Spacer()
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .disabled(!browser.isReady)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .overlay(alignment: .top) {
            if let message = browser.message ?? local.message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(palette.popover))
                    .offset(y: -32)
                    .onTapGesture {
                        browser.message = nil
                        local.message = nil
                    }
            }
        }
    }

    // MARK: 传输（覆盖同名文件前先问）

    /// 拖动选中的某一行时，把选中的都带上；拖没选中的就只带它
    private func dragPaths(for path: String, selection: Set<String>) -> [String] {
        selection.contains(path) ? Array(selection) : [path]
    }

    func upload(_ urls: [URL], to directory: String? = nil) {
        guard !urls.isEmpty, browser.isReady else { return }
        let target = directory ?? browser.path
        let existing = target == browser.path ? Set(browser.entries.map(\.name)) : []
        let clashes = urls.map(\.lastPathComponent).filter(existing.contains)
        let connectionID = browser.transferSourceID
        confirmOverwrite(clashes, place: "服务器上的 \(target)") {
            guard browser.isReady, browser.transferSourceID == connectionID else {
                browser.message = "确认期间连接已变化，请重新选择文件"
                return
            }
            browser.upload(urls, to: target)
        }
    }

    private func download(_ files: [RemoteFile], to directory: URL, reveal: Bool = false) {
        guard !files.isEmpty else { return }
        let clashes = files.map(\.name).filter { FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path) }
        let connectionID = browser.transferSourceID
        confirmOverwrite(clashes, place: LocalBrowser.display(directory)) {
            guard browser.isReady, browser.transferSourceID == connectionID else {
                browser.message = "确认期间连接已变化，请重新选择文件"
                return
            }
            browser.download(files, to: directory, reveal: reveal)
        }
    }

    private func confirmOverwrite(_ names: [String], place: String, then proceed: @escaping () -> Void) {
        guard !names.isEmpty else { return proceed() }
        let list = names.prefix(3).map { "“\($0)”" }.joined(separator: "、") + (names.count > 3 ? " 等 \(names.count) 项" : "")
        Dialogs.confirm("\(place) 里已经有 \(list)，要覆盖吗？", detail: "覆盖后原来的内容找不回来。",
                        confirmTitle: "覆盖", destructive: true, window: workspace.fileDialogWindow) { ok in
            if ok { proceed() }
        }
    }

    /// 拖到服务器那一栏的：本机那一栏的文件，或者从访达拖来的文件
    private func receiveUploads(_ providers: [NSItemProvider]) -> Bool {
        guard browser.isReady else { return false }
        let group = DispatchGroup()
        let lock = NSLock()
        var urls: [URL] = []
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.conchLocalFiles.identifier) {
                group.enter()
                provider.loadDataRepresentation(forTypeIdentifier: UTType.conchLocalFiles.identifier) { data, _ in
                    if let data, let drag = try? JSONDecoder().decode(LocalFilesDrag.self, from: data) {
                        lock.lock()
                        urls += drag.paths.map { URL(fileURLWithPath: $0) }
                        lock.unlock()
                    }
                    group.leave()
                }
            } else if provider.canLoadObject(ofClass: URL.self) {
                group.enter()
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    if let url, url.isFileURL {
                        lock.lock()
                        urls.append(url)
                        lock.unlock()
                    }
                    group.leave()
                }
            }
        }
        group.notify(queue: .main) {
            upload(urls)
        }
        return true
    }

    // MARK: 弹窗

    private func chooseUpload(to directory: String?) {
        let panel = NSOpenPanel()
        panel.title = "上传到 \(directory ?? browser.path)"
        panel.prompt = "上传"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        if showLocal { panel.directoryURL = local.directory }
        let handle = { (response: NSApplication.ModalResponse) in
            if response == .OK { upload(panel.urls, to: directory) }
        }
        if let window = workspace.fileDialogWindow { panel.beginSheetModal(for: window, completionHandler: handle) } else { handle(panel.runModal()) }
    }

    private func chooseDownload(_ files: [RemoteFile]) {
        let panel = NSOpenPanel()
        panel.title = "下载到"
        panel.prompt = "下载到这里"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = showLocal ? local.directory : AppPaths.downloadsDirectory
        let handle = { (response: NSApplication.ModalResponse) in
            if response == .OK, let url = panel.url { download(files, to: url, reveal: true) }
        }
        if let window = workspace.fileDialogWindow { panel.beginSheetModal(for: window, completionHandler: handle) } else { handle(panel.runModal()) }
    }

    private func newRemoteFolder() {
        Dialogs.promptText("新建文件夹", detail: "建在服务器的 \(browser.path)", confirmTitle: "新建", window: workspace.fileDialogWindow) { name in
            if let name { browser.makeDirectory(named: name) }
        }
    }

    private func newLocalFolder() {
        Dialogs.promptText("新建文件夹", detail: "建在本机的 \(local.displayPath)", confirmTitle: "新建", window: workspace.fileDialogWindow) { name in
            if let name { local.makeDirectory(named: name) }
        }
    }

    private func renameRemote(_ file: RemoteFile) {
        Dialogs.promptText("重命名", initial: file.name, confirmTitle: "重命名", window: workspace.fileDialogWindow) { name in
            if let name, name != file.name { browser.rename(file, to: name) }
        }
    }

    private func renameLocal(_ file: LocalFile) {
        Dialogs.promptText("重命名", initial: file.name, confirmTitle: "重命名", window: workspace.fileDialogWindow) { name in
            if let name, name != file.name { local.rename(file, to: name) }
        }
    }

    private func chmod(_ file: RemoteFile) {
        let current = String(file.permissions & 0o7777, radix: 8)
        Dialogs.promptText("修改“\(file.name)”的权限", detail: "八进制，例如 644、755、600", initial: current,
                           confirmTitle: "修改", window: workspace.fileDialogWindow) { text in
            guard let text, let mode = UInt32(text, radix: 8), mode <= 0o7777 else { return }
            browser.chmod(file, mode: mode)
        }
    }

    private func deleteRemote(_ files: [RemoteFile]) {
        let names = files.prefix(5).map(\.name).joined(separator: "、") + (files.count > 5 ? " 等" : "")
        let hasFolder = files.contains(where: \.isDir)
        Dialogs.confirm("删除服务器上的 \(names)？", detail: hasFolder ? "文件夹会连同里面的内容一起删除，无法恢复。" : "删除后无法恢复。",
                        confirmTitle: "删除", destructive: true, window: workspace.fileDialogWindow) { ok in
            if ok { browser.delete(files) }
        }
    }

    private func trashLocal(_ files: [LocalFile]) {
        let names = files.prefix(5).map(\.name).joined(separator: "、") + (files.count > 5 ? " 等" : "")
        Dialogs.confirm("把本机的 \(names) 移到废纸篓？", detail: "可以在废纸篓里找回来。",
                        confirmTitle: "移到废纸篓", window: workspace.fileDialogWindow) { ok in
            if ok { local.moveToTrash(files) }
        }
    }
}

private struct RemoteFileRow: View {
    let file: RemoteFile

    var body: some View {
        FileListRow(name: file.name, icon: icon, isDir: file.isDir, size: Int64(file.size),
                    modified: file.modified.map { Date(timeIntervalSince1970: TimeInterval($0)) },
                    dimmed: file.name.hasPrefix("."))
            .help("\(file.path)\n权限 \(Self.permissions(file))  所有者 \(file.owner):\(file.group)")
    }

    private var icon: String {
        if file.isSymlink { return file.isDir ? "folder.badge.questionmark" : "arrowshape.turn.up.right" }
        return file.isDir ? "folder.fill" : "doc"
    }

    private static func permissions(_ file: RemoteFile) -> String {
        let bits = Int(file.permissions)
        let chars = Array("rwxrwxrwx")
        let text = (0..<9).map { bits & (1 << (8 - $0)) != 0 ? chars[$0] : "-" }
        return (file.isDir ? "d" : "-") + String(text)
    }
}

/// 正在用本机编辑器编辑的文件：保存后自动上传，状态一目了然
private struct EditList: View {
    @ObservedObject var browser: SftpBrowser

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("正在编辑（保存后自动上传）").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(browser.edits) { edit in
                EditRow(edit: edit, browser: browser)
            }
        }
        .padding(8)
    }
}

private struct EditRow: View {
    @ObservedObject var edit: RemoteEdit
    let browser: SftpBrowser

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon).foregroundStyle(iconColor)
            VStack(alignment: .leading, spacing: 1) {
                Text(edit.name).font(.caption).lineLimit(1).truncationMode(.middle)
                Text(edit.statusText).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            if edit.state == .conflict {
                Menu("处理") {
                    Button("用我的版本覆盖服务器") { browser.overwriteRemote(edit) }
                    Button("重新下载（放弃我的修改）") { browser.reloadEdit(edit) }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .font(.caption)
            }
            Button {
                SftpBrowser.openInEditor(edit.localURL)
            } label: {
                Image(systemName: "square.and.pencil")
            }
            .buttonStyle(.borderless)
            .help("再次在编辑器里打开")
            .disabled(edit.state == .downloading)
            Menu {
                Button("在访达中显示本机副本") { browser.revealEditCopy(edit) }
                Button("重新下载（放弃我的修改）") { browser.reloadEdit(edit) }
                Divider()
                Button("停止编辑") { browser.stopEditing(edit) }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .help("\(edit.remotePath)\n本机副本：\(edit.localURL.path)")
    }

    private var icon: String {
        switch edit.state {
        case .downloading, .uploading: "arrow.triangle.2.circlepath"
        case .synced: "checkmark.circle"
        case .conflict, .failed: "exclamationmark.triangle.fill"
        }
    }

    private var iconColor: SwiftUI.Color {
        switch edit.state {
        case .conflict, .failed: .orange
        case .synced: .green
        default: .secondary
        }
    }
}

private struct TransferList: View {
    @ObservedObject var browser: SftpBrowser

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("传输").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Button("清除已完成") { browser.clearFinished() }
                    .buttonStyle(.borderless)
                    .font(.caption)
            }
            ScrollView {
                VStack(spacing: 6) {
                    ForEach(browser.transfers) { item in
                        TransferRow(item: item, browser: browser)
                    }
                }
            }
            .frame(maxHeight: 150)
        }
        .padding(8)
    }
}

private struct TransferRow: View {
    @ObservedObject var item: TransferItem
    let browser: SftpBrowser

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: item.direction == .upload ? "arrow.up.circle" : "arrow.down.circle")
                    .foregroundStyle(.secondary)
                Text(item.name).font(.caption).lineLimit(1).truncationMode(.middle)
                Spacer()
                switch item.state {
                case .running:
                    Button { item.cancel() } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless).foregroundStyle(.secondary).help("取消")
                case .failed, .cancelled:
                    Button("续传") { browser.retry(item) }
                        .buttonStyle(.borderless).font(.caption).help("从中断的地方接着传")
                case .finished:
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                }
            }
            if item.state == .running {
                ProgressView(value: item.fraction).controlSize(.small)
            }
            Text(detail).font(.caption2).foregroundStyle(detailColor).lineLimit(2)
        }
        .help(item.direction == .upload ? "上传 \(item.source) → \(item.destination)" : "下载 \(item.source) → \(item.destination)")
    }

    private var detail: String {
        let done = ByteCountFormatter.string(fromByteCount: Int64(item.progress?.bytesDone ?? 0), countStyle: .file)
        let total = ByteCountFormatter.string(fromByteCount: Int64(item.progress?.bytesTotal ?? 0), countStyle: .file)
        switch item.state {
        case .running:
            let speed = ByteCountFormatter.string(fromByteCount: Int64(item.bytesPerSecond), countStyle: .file)
            let files = (item.progress?.filesTotal ?? 0) > 1 ? " · \(item.progress!.filesDone)/\(item.progress!.filesTotal) 个文件" : ""
            return "\(done) / \(total) · \(speed)/s\(files)"
        case .finished:
            return "完成，\(total)"
        case .failed(let message):
            return message
        case .cancelled:
            return "已取消（\(done)），可以续传"
        }
    }

    private var detailColor: SwiftUI.Color {
        if case .failed = item.state { return .red }
        return .secondary
    }
}

/// 展开后的左右对照模式，复用同一个连接、文件列表和传输队列。
struct ExpandedFilesView: View {
    @ObservedObject private var store = SessionStore.shared
    @ObservedObject var tab: TerminalSession
    @ObservedObject var workspace: WorkspaceModel
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("文件传输 · \(tab.tabTitle)").font(.headline)
                if let environment = store.environment(of: tab.profile) {
                    EnvironmentChip(environment: environment)
                }
                Spacer()
                Button("返回终端") { workspace.expandedFiles = false }
                    .keyboardShortcut(.cancelAction)
            }.padding(16)
            Divider()
            SftpPanel(browser: tab.files, local: workspace.localFiles, tab: tab, workspace: workspace,
                      showLocal: true, expanded: true)
        }
        .frame(width: min(1000, (NSScreen.main?.visibleFrame.width ?? 1100) - 80), height: 640)
    }
}
