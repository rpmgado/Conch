import AppKit
import ConchKit
import Foundation

/// 一个标签页的文件面板（SFTP）：当前目录、文件列表、传输队列。
/// SFTP 走的是这个标签页的同一条 SSH 连接（经过跳板机也一样）。
final class SftpBrowser: ObservableObject {
    enum Status: Equatable {
        case idle
        case opening
        case ready
        case failed(String)
        case disconnected
    }

    @Published private(set) var status: Status = .idle
    @Published private(set) var path = ""
    @Published private(set) var entries: [RemoteFile] = [] {
        didSet { updateVisible() }
    }
    /// 目录在前，再按名称排序；默认隐藏点开头的文件（列表每次刷新都要用，算好存着）
    @Published private(set) var visibleEntries: [RemoteFile] = []
    @Published private(set) var loading = false
    @Published var showHidden = false {
        didSet { if showHidden != oldValue { updateVisible() } }
    }
    /// 地址栏里正在编辑的路径
    @Published var pathField = ""
    @Published var selection: Set<String> = []
    @Published private(set) var transfers: [TransferItem] = []
    /// 正在用本机编辑器编辑的远端文件（见 RemoteEditing.swift）
    @Published private(set) var edits: [RemoteEdit] = []
    /// 最近一次操作的错误，显示在面板底部
    @Published var message: String?

    private var client: SftpClient?
    /// 每次建立 / 结束连接都换一个标识，让旧拖放和旧异步请求失效。
    private(set) var transferSourceID = UUID()
    private var loadGeneration = 0

    func filesForDrop(_ items: [RemoteFilesDrag]) -> [RemoteFile]? {
        guard isReady, !items.isEmpty else { return nil }
        var paths: [String] = []
        for item in items {
            guard let valid = item.paths(for: transferSourceID) else {
                message = "文件来自另一个窗口或已经断开的连接，请在来源服务器的文件面板中下载"
                return nil
            }
            paths += valid
        }
        var seen = Set<String>()
        let unique = paths.filter { seen.insert($0).inserted }
        let files = unique.compactMap(entry)
        guard !files.isEmpty, files.count == unique.count else {
            message = "拖动期间目录已变化，请重新选择文件"
            return nil
        }
        return files
    }
    private weak var session: TerminalSession?
    /// 面板打开过：连上（包括重连）后自动打开 SFTP
    private var wanted = false
    /// 打开 SFTP 之后要转到的路径（右键“在文件面板中显示”）
    private var pendingReveal: String?
    /// 每秒检查一次编辑中的文件有没有保存
    var editTimer: Timer?

    init(session: TerminalSession) {
        self.session = session
    }

    deinit {
        editTimer?.invalidate()
    }

    var sftpClient: SftpClient? { client }

    var windowForDialogs: NSWindow? { session?.workspace?.fileDialogWindow }

    func addEdit(_ edit: RemoteEdit) {
        edits.append(edit)
    }

    func removeEdit(_ edit: RemoteEdit) {
        edits.removeAll { $0 === edit }
        if let transfer = edit.lastTransfer, transfer.state != .running {
            transfers.removeAll { $0 === transfer }
        }
        if edits.isEmpty {
            editTimer?.invalidate()
            editTimer = nil
        }
    }

    /// 同一个编辑中的文件再次上传时，传输列表里只留最新的一条
    func replaceTransfer(of edit: RemoteEdit, with item: TransferItem) {
        if let previous = edit.lastTransfer, previous.state != .running {
            transfers.removeAll { $0 === previous }
        }
        edit.lastTransfer = item
    }

    func startTransfer(_ item: TransferItem, policy: ConflictPolicy) {
        start(item, policy: policy)
    }

    var isReady: Bool { status == .ready && client != nil }

    private func updateVisible() {
        visibleEntries = entries
            .filter { showHidden || !$0.name.hasPrefix(".") }
            .sorted { a, b in
                if a.isDir != b.isDir { return a.isDir }
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
    }

    func entry(_ path: String) -> RemoteFile? {
        entries.first { $0.path == path }
    }

    // MARK: 连接

    /// 面板显示出来了
    func activate() {
        wanted = true
        if client == nil, status != .opening { open() }
    }

    func connectionEstablished() {
        if wanted { open() }
    }

    func connectionEnded() {
        transferSourceID = UUID()
        loadGeneration += 1
        loading = false
        client = nil
        if status != .idle { status = .disconnected }
    }

    func open() {
        guard let ssh = session?.connection else {
            status = .disconnected
            return
        }
        transferSourceID = UUID()
        let generation = transferSourceID
        loadGeneration += 1
        client = nil
        status = .opening
        Task { @MainActor [weak self] in
            do {
                let client = try await ssh.openSftp()
                guard let self, self.transferSourceID == generation else { return }
                self.client = client
                self.status = .ready
                if let pending = self.pendingReveal {
                    // 右键“在文件面板中显示”时面板还没连上：连上后直接转到那里
                    self.pendingReveal = nil
                    await self.revealNow(pending, client: client)
                } else {
                    let start = self.path.isEmpty ? try await client.home() : self.path
                    guard self.transferSourceID == generation else { return }
                    await self.load(start)
                }
            } catch {
                guard let self, self.transferSourceID == generation else { return }
                self.status = .failed(error.userMessage)
            }
        }
    }

    /// 转到这个路径：是目录就进去；是文件就进到它所在的目录并选中它。SFTP 还没打开时，打开后再转
    func reveal(_ target: String) {
        var target = target.trimmingCharacters(in: .whitespaces)
        guard !target.isEmpty else { return }
        // ~ 开头的交给服务器展开（相对家目录）
        if target == "~" { target = "." } else if target.hasPrefix("~/") { target = String(target.dropFirst(2)) }
        guard let client, status == .ready else {
            pendingReveal = target
            activate()
            return
        }
        Task { @MainActor [weak self] in await self?.revealNow(target, client: client) }
    }

    @MainActor
    private func revealNow(_ target: String, client: SftpClient) async {
        let generation = transferSourceID
        do {
            let resolved = target.hasPrefix("/") ? target : try await client.resolve(path: target)
            let info = try await client.stat(path: resolved)
            guard generation == transferSourceID else { return }
            if info.isDir {
                await load(resolved)
            } else {
                let parent = (resolved as NSString).deletingLastPathComponent
                await load(parent.isEmpty ? "/" : parent)
                if entries.contains(where: { $0.path == resolved }) { selection = [resolved] }
            }
        } catch {
            guard generation == transferSourceID else { return }
            message = "找不到 \(target)：\(error.userMessage)"
            if path.isEmpty, let home = try? await client.home(), generation == transferSourceID { await load(home) }
        }
    }

    // MARK: 浏览

    @MainActor
    func load(_ target: String) async {
        guard let client else { return }
        let connectionID = transferSourceID
        loadGeneration += 1
        let requestID = loadGeneration
        loading = true
        defer { if requestID == loadGeneration { loading = false } }
        do {
            let resolved = target.hasPrefix("/") ? target : try await client.resolve(path: target)
            let list = try await client.list(path: resolved)
            guard connectionID == transferSourceID, requestID == loadGeneration else { return }
            path = resolved
            pathField = resolved
            entries = list
            selection = selection.filter { selected in list.contains { $0.path == selected } }
            message = nil
        } catch {
            guard connectionID == transferSourceID, requestID == loadGeneration else { return }
            pathField = path
            message = error.userMessage
        }
    }

    func go(to target: String) {
        var target = target.trimmingCharacters(in: .whitespaces)
        guard !target.isEmpty else { return }
        // ~ 开头的路径交给服务器展开（相对家目录）
        if target == "~" { target = "." } else if target.hasPrefix("~/") { target = String(target.dropFirst(2)) }
        Task { await load(target) }
    }

    func goUp() {
        guard path != "/" else { return }
        let parent = (path as NSString).deletingLastPathComponent
        go(to: parent.isEmpty ? "/" : parent)
    }

    func goHome() {
        go(to: ".")
    }

    func refresh() {
        guard !path.isEmpty else { return open() }
        go(to: path)
    }

    /// 双击：目录进入，文件下载
    func open(_ file: RemoteFile) {
        if file.isDir {
            go(to: file.path)
        } else {
            download([file], to: AppPaths.downloadsDirectory, reveal: true)
        }
    }

    // MARK: 文件操作

    func makeDirectory(named name: String) {
        perform("新建文件夹") { client in
            try await client.mkdir(path: Self.join(self.path, name))
        }
    }

    func rename(_ file: RemoteFile, to name: String) {
        perform("重命名") { client in
            try await client.rename(from: file.path, to: Self.join((file.path as NSString).deletingLastPathComponent, name))
        }
    }

    func delete(_ files: [RemoteFile]) {
        perform("删除") { client in
            for file in files { try await client.remove(path: file.path) }
        }
    }

    func chmod(_ file: RemoteFile, mode: UInt32) {
        perform("修改权限") { client in
            try await client.chmod(path: file.path, mode: mode)
        }
    }

    func copyPath(_ files: [RemoteFile]) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(files.map(\.path).joined(separator: "\n"), forType: .string)
    }

    /// 在终端里 cd 到这个目录
    func changeTerminalDirectory(to path: String) {
        let quoted = "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        session?.sendText("cd \(quoted)\r")
    }

    private func perform(_ what: String, _ work: @escaping (SftpClient) async throws -> Void) {
        guard let client else { return }
        Task { @MainActor [weak self] in
            do {
                try await work(client)
                await self?.load(self?.path ?? "/")
            } catch {
                self?.message = "\(what)失败：\(error.userMessage)"
            }
        }
    }

    // MARK: 传输

    func download(_ files: [RemoteFile], to directory: URL, reveal: Bool = false) {
        for file in files {
            let item = TransferItem(direction: .download, name: file.name, source: file.path,
                                    destination: directory.path, browser: self)
            item.revealWhenDone = reveal
            start(item, policy: .overwrite)
        }
    }

    func upload(_ urls: [URL], to directory: String? = nil) {
        let target = directory ?? path
        guard !target.isEmpty else { return }
        for url in urls {
            let item = TransferItem(direction: .upload, name: url.lastPathComponent, source: url.path,
                                    destination: target, browser: self)
            start(item, policy: .overwrite)
        }
    }

    /// 失败或取消的传输重新开始：从断开的地方续传
    func retry(_ item: TransferItem) {
        item.reset()
        start(item, policy: .resume)
    }

    func clearFinished() {
        transfers.removeAll { $0.state != .running }
    }

    private func start(_ item: TransferItem, policy: ConflictPolicy) {
        guard let client else {
            if !transfers.contains(where: { $0 === item }) { transfers.append(item) }
            item.onFinished(error: "连接已断开")
            return
        }
        if !transfers.contains(where: { $0 === item }) { transfers.append(item) }
        if item.direction == .download {
            do {
                try FileManager.default.createDirectory(atPath: item.destination, withIntermediateDirectories: true)
            } catch {
                item.onFinished(error: "无法创建下载目录：\(error.localizedDescription)")
                return
            }
        }
        item.handle = switch item.direction {
        case .download:
            client.download(remotePath: item.source, localDir: item.destination, policy: policy, observer: item)
        case .upload:
            client.upload(localPath: item.source, remoteDir: item.destination, policy: policy, observer: item)
        }
    }

    /// 传输完成（主线程）
    fileprivate func transferFinished(_ item: TransferItem) {
        if item.direction == .upload, item.destination == path, isReady {
            refresh()
        }
        if item.direction == .download, item.state == .finished, item.revealWhenDone {
            let url = URL(fileURLWithPath: item.destination).appendingPathComponent(item.name)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    static func join(_ directory: String, _ name: String) -> String {
        directory.hasSuffix("/") ? directory + name : directory + "/" + name
    }
}

/// 一次上传或下载（文件或整个文件夹）
final class TransferItem: ObservableObject, Identifiable, TransferObserver, @unchecked Sendable {
    enum Direction {
        case upload, download
    }

    enum State: Equatable {
        case running
        case finished
        case failed(String)
        case cancelled
    }

    let id = UUID()
    let direction: Direction
    let name: String
    /// 下载时是远端路径，上传时是本地路径
    let source: String
    /// 下载时是本地目录，上传时是远端目录
    let destination: String
    @Published var state: State = .running
    @Published private(set) var progress: TransferProgress?
    @Published private(set) var bytesPerSecond: Double = 0
    var handle: Transfer?
    var revealWhenDone = false
    /// 完成（成功、失败、取消）后在主线程调用
    var onFinished: ((TransferItem) -> Void)?
    private weak var browser: SftpBrowser?
    private var lastSample: (date: Date, bytes: UInt64)?

    init(direction: Direction, name: String, source: String, destination: String, browser: SftpBrowser) {
        self.direction = direction
        self.name = name
        self.source = source
        self.destination = destination
        self.browser = browser
    }

    var fraction: Double {
        guard let progress, progress.bytesTotal > 0 else { return 0 }
        return min(Double(progress.bytesDone) / Double(progress.bytesTotal), 1)
    }

    func cancel() {
        handle?.cancel()
    }

    func reset() {
        state = .running
        progress = nil
        bytesPerSecond = 0
        lastSample = nil
    }

    // TransferObserver（内核线程）

    func onProgress(progress: TransferProgress) {
        DispatchQueue.main.async { [self] in
            let now = Date()
            if let last = lastSample, now.timeIntervalSince(last.date) >= 0.5 {
                let delta = Double(progress.bytesDone &- last.bytes)
                bytesPerSecond = max(0, delta / now.timeIntervalSince(last.date))
                lastSample = (now, progress.bytesDone)
            } else if lastSample == nil {
                lastSample = (now, progress.bytesDone)
            }
            self.progress = progress
        }
    }

    func onFinished(error: String?) {
        DispatchQueue.main.async { [self] in
            if let error {
                state = error.hasSuffix("已取消") ? .cancelled : .failed(error)
            } else {
                state = .finished
            }
            handle = nil
            browser?.transferFinished(self)
            onFinished?(self)
            onFinished = nil
        }
    }
}
