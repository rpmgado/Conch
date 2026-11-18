import AppKit
import Combine
import ConchKit
import SwiftTerm

/// 一个标签页：持有终端视图，负责把 Rust 内核和 SwiftTerm 接起来，处理断线重连和会话日志。
///
/// 数据通路：
///   远端输出 → Rust 读循环 → CoreBridge.onOutput（内核线程）
///           → TerminalOutput 串行队列：交给 SwiftTerm 解析、写日志 → ack 归还流控额度
///   键盘输入 → TerminalViewDelegate.send → SshSession.write → Rust 写循环
final class TerminalSession: ObservableObject, Identifiable {
    enum Phase: Equatable {
        /// 新标签页，还没选要连哪个会话
        case idle
        case connecting
        case connected
        /// 意外断线，等一会儿自动重连
        case waitingToReconnect(attempt: Int, at: Date, reason: String)
        case failed(String)
        case closed(String)
    }

    static let maxReconnectAttempts = 20

    let id = UUID()
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var profile: SessionProfile?
    @Published private(set) var jumps: [SessionProfile] = []
    @Published private(set) var info: SessionInfo?
    @Published private(set) var terminalTitle = ""
    @Published private(set) var cols = 80
    @Published private(set) var rows = 24
    @Published private(set) var logURL: URL?
    /// 不在前台时有新输出，标签上显示一个小点
    @Published private(set) var hasUnseenOutput = false
    /// 正在进行的 rz / sz
    @Published private(set) var zmodem: ZmodemState?
    /// 这个连接上的端口转发（会话里配的 + 临时加的）
    @Published private(set) var forwards: [ForwardEntry] = []
    /// 远端 Shell 通过 OSC 7 报告的当前目录（不是所有服务器都会报）
    @Published private(set) var remoteDirectory: String?
    /// 文件面板（SFTP），第一次打开时创建
    private(set) lazy var files = SftpBrowser(session: self)
    /// 服务器监控，第一次打开监控面板时创建
    private(set) lazy var monitor = ServerMonitor(session: self)

    let terminalView: ConchTerminalView
    let output: TerminalOutput
    weak var workspace: WorkspaceModel?
    /// 这个标签页记住的密码和口令（自动重连时不用再问）
    private(set) var secrets = SessionSecrets()
    /// 快速连接时临时指定的跳板机（不在会话列表里）
    private var adHocJumps: [SessionProfile] = []
    private let link = SessionLink()
    private var bridge: CoreBridge?
    private var userClosed = false
    private var reconnectAttempt = 0
    private var reconnectTimer: Timer?
    private var appliedAppearance: AppearanceSnapshot?
    private var subscriptions: Set<AnyCancellable> = []
    private var networkObserver: NSObjectProtocol?
    /// 临时加的转发规则（不在会话设置里），重连后也要恢复
    private var extraForwardRules: [ForwardRule] = []

    init(workspace: WorkspaceModel?) {
        let appearance = TerminalAppearance.shared.snapshot
        terminalView = ConchTerminalView(frame: NSRect(x: 0, y: 0, width: 900, height: 560), font: appearance.font)
        output = TerminalOutput(view: terminalView)
        self.workspace = workspace
        terminalView.terminalDelegate = self
        terminalView.onActivate = { [weak self] in
            guard let self else { return }
            self.workspace?.paneActivated(self)
        }
        terminalView.contextMenuProvider = { [weak self] in
            guard let self, let workspace = self.workspace else { return nil }
            return workspace.paneMenu(for: self)
        }
        applyAppearance(appearance)

        TerminalAppearance.shared.$snapshot
            .dropFirst()
            .sink { [weak self] in self?.applyAppearance($0) }
            .store(in: &subscriptions)
        // 标签页的变化（状态、标题）要让整个窗口刷新：标签栏、窗口标题都要变
        objectWillChange
            .sink { [weak self] _ in self?.workspace?.objectWillChange.send() }
            .store(in: &subscriptions)
        output.onUnseenOutput = { [weak self] in self?.hasUnseenOutput = true }
        networkObserver = NotificationCenter.default.addObserver(
            forName: .conchNetworkMayBeBack, object: nil, queue: .main
        ) { [weak self] _ in self?.retryNowIfWaiting() }
    }

    deinit {
        if let networkObserver { NotificationCenter.default.removeObserver(networkObserver) }
        reconnectTimer?.invalidate()
    }

    // MARK: 状态

    var isLauncher: Bool { profile == nil }

    var tabTitle: String { profile?.displayName ?? "新标签页" }

    /// 有连接、正在连接或等着重连：关掉标签页前要确认
    var isActive: Bool {
        switch phase {
        case .connecting, .connected, .waitingToReconnect: true
        default: false
        }
    }

    var isConnected: Bool { phase == .connected }

    /// 状态栏上显示的路线：目标（经由 跳板机1 → 跳板机2）
    var routeDescription: String {
        guard let profile else { return "" }
        guard profile.isSSH else { return profile.address }
        let address = "\(profile.username)@\(profile.host):\(profile.port)"
        guard !jumps.isEmpty else { return address }
        return "\(address)（经由 \(jumps.map(\.displayName).joined(separator: " → "))）"
    }

    /// 是会话列表里保存的会话（不是快速连接）
    var isSavedSession: Bool {
        profile.map { SessionStore.shared.contains($0.id) } ?? false
    }

    /// 当前的 SSH 连接，没连上或者不是 SSH（Telnet、串口）时为 nil
    var connection: SshSession? { link.ssh }

    /// 是 SSH 会话（文件面板、端口转发、监控只对 SSH 有效）
    var isSSH: Bool { profile?.isSSH ?? false }

    func setVisible(_ visible: Bool) {
        output.setVisible(visible)
        if visible, hasUnseenOutput { hasUnseenOutput = false }
    }

    // MARK: 连接

    /// 在这个标签页里连接一个会话（新标签页选好会话、快速连接、复制标签页都走这里）
    func open(_ profile: SessionProfile, adHocJumps: [SessionProfile] = [], secrets: SessionSecrets? = nil) {
        self.profile = profile
        self.adHocJumps = adHocJumps
        if let secrets { self.secrets = secrets }
        userClosed = false
        reconnectAttempt = 0
        startConnection(automatic: false)
    }

    /// 手动重新连接（⌘R、按钮、断开后按回车）
    func reconnect() {
        guard profile != nil else { return }
        userClosed = false
        reconnectAttempt = 0
        startConnection(automatic: false)
    }

    /// 断开连接，标签页保留
    func disconnect() {
        userClosed = true
        cancelReconnectTimer()
        if let connection = link.connection {
            connection.close() // 状态在 on_closed 回来后更新
            return
        }
        switch phase {
        case .connecting:
            bridge = nil // 连接结果回来时会被丢弃
            phase = .closed("已取消连接")
            output.status("[已取消连接，按回车键重新连接]")
        case .waitingToReconnect:
            phase = .closed("已停止自动重连")
            output.status("[已停止自动重连，按回车键重新连接]")
        default:
            break
        }
    }

    /// 标签页要关掉了：断开连接、停止日志
    func close() {
        userClosed = true
        cancelReconnectTimer()
        stopForwards()
        files.connectionEnded()
        monitor.connectionEnded()
        link.connection?.close()
        link.connection = nil
        bridge = nil
        stopLogging()
    }

    /// 保存成会话后，这个标签页改用会话列表里的那一份
    func adopt(_ saved: SessionProfile) {
        profile = saved
        adHocJumps = []
    }

    /// 给“复制标签页”用：会话、临时跳板机、已输入的密码
    var duplicationSeed: (profile: SessionProfile, jumps: [SessionProfile], secrets: SessionSecrets)? {
        profile.map { ($0, adHocJumps, secrets.copy()) }
    }

    private func startConnection(automatic: Bool) {
        guard var target = profile else { return }
        cancelReconnectTimer()
        dropConnection()

        let chain: [SessionProfile]
        if SessionStore.shared.contains(target.id) {
            // 会话可能在别处被编辑过，用最新的
            if let latest = SessionStore.shared.session(target.id) {
                target = latest
                profile = latest
            }
            do {
                chain = try SessionStore.shared.library.jumpChain(for: target)
                // 记下来：会话之后被删掉的话，这个标签页重连时仍然走同样的跳板机
                adHocJumps = chain
            } catch {
                phase = .failed(error.userMessage)
                output.status(error.userMessage, style: .error)
                return
            }
        } else {
            chain = adHocJumps
        }
        jumps = chain
        info = nil
        phase = .connecting

        let bridge = CoreBridge(owner: self, output: output, hops: chain + [target], secrets: secrets)
        self.bridge = bridge
        let open = Self.opener(for: target, jumps: chain, cols: cols, rows: rows, bridge: bridge)

        // 整个任务跑在主线程上；await 期间主线程是空闲的，弹窗等交互不受影响
        Task { @MainActor [weak self] in
            do {
                let connection = try await open()
                guard let self, self.bridge === bridge else {
                    connection.close() // 用户在连接过程中已经取消、重连或者关掉了标签页
                    return
                }
                self.link.connection = connection
                bridge.attach(connection)
                // 连接期间窗口尺寸可能变过，同步一次
                connection.resize(cols: UInt32(max(self.cols, 1)), rows: UInt32(max(self.rows, 1)))
                self.info = connection.info()
                self.phase = .connected
                if target.isSSH {
                    self.startForwards()
                    self.files.connectionEstablished()
                    self.monitor.connectionEstablished()
                }
                self.reconnectAttempt = 0
                bridge.saveRememberedSecrets()
                SessionStore.shared.markConnected(target.id)
                if target.logSession, self.logURL == nil {
                    self.startLogging()
                }
                TestHooks.sessionDidConnect(self)
            } catch {
                guard let self, self.bridge === bridge else { return }
                self.bridge = nil
                bridge.forgetEnteredSecrets()
                self.connectionFailed(error, automatic: automatic)
            }
        }
    }

    /// 按会话的协议准备好“建立连接”这一步
    private static func opener(
        for target: SessionProfile, jumps: [SessionProfile], cols: Int, rows: Int, bridge: CoreBridge
    ) -> () async throws -> TerminalConnection {
        let cols = UInt32(max(cols, 1))
        let rows = UInt32(max(rows, 1))
        switch target.kind {
        case .ssh:
            let config = ConnectConfig(
                jumps: jumps.map(Self.hopConfig),
                target: Self.hopConfig(target),
                cols: cols,
                rows: rows,
                term: "xterm-256color",
                knownHostsPath: AppPaths.knownHosts.path,
                encoding: target.encoding
            )
            return { try await connect(config: config, delegate: bridge) }
        case .telnet:
            let config = TelnetConfig(
                host: target.host.trimmingCharacters(in: .whitespaces),
                port: UInt16(clamping: target.port),
                cols: cols,
                rows: rows,
                term: "xterm-256color",
                encoding: target.encoding
            )
            return { try await connectTelnet(config: config, delegate: bridge) }
        case .serial:
            let serial = target.serial
            let config = SerialConfig(
                path: serial.path,
                baudRate: UInt32(clamping: serial.baudRate),
                dataBits: UInt8(clamping: serial.dataBits),
                parity: serial.parity,
                stopBits: UInt8(clamping: serial.stopBits),
                flowControl: serial.flowControl,
                encoding: target.encoding
            )
            return { try await openSerial(config: config, delegate: bridge) }
        }
    }

    /// 丢掉当前连接（不触发状态变化），准备重连
    private func dropConnection() {
        link.connection?.close()
        link.connection = nil
        bridge = nil
    }

    private func connectionFailed(_ error: Error, automatic: Bool) {
        let message = error.userMessage
        if automatic, error.isRetryable, !userClosed, profile?.autoReconnect == true {
            scheduleReconnect(reason: message)
            return
        }
        phase = .failed(message)
        output.status(message, style: error.isCancellation ? .dim : .error)
        output.status("[按回车键重新连接]")
    }

    // CoreBridge 回调（已切回主线程）
    fileprivate func sessionClosed(by bridge: CoreBridge, info: CloseInfo) {
        guard self.bridge === bridge else { return }
        self.bridge = nil
        link.connection = nil
        self.info = nil
        zmodem = nil
        markForwardsStopped("连接已断开")
        files.connectionEnded()
        monitor.connectionEnded()
        // 远端程序可能把终端留在全屏模式、鼠标上报模式里，断开后恢复正常
        output.resetModes()

        if userClosed {
            phase = .closed("已断开连接")
            output.status("[已断开连接，按回车键重新连接]")
            return
        }
        if info.lost, profile?.autoReconnect == true {
            scheduleReconnect(reason: info.reason ?? "连接已中断")
            return
        }
        let message: String
        if let reason = info.reason {
            message = reason
        } else if let status = info.exitStatus, status != 0 {
            message = "连接已关闭（退出码 \(status)）"
        } else {
            message = "连接已关闭"
        }
        phase = .closed(message)
        output.status("[\(message)，按回车键重新连接]")
    }

    // MARK: 自动重连

    private func scheduleReconnect(reason: String) {
        reconnectAttempt += 1
        guard reconnectAttempt <= Self.maxReconnectAttempts else {
            let message = "自动重连 \(Self.maxReconnectAttempts) 次都没有成功：\(reason)"
            phase = .failed(message)
            output.status(message, style: .error)
            return
        }
        // 1、2、4、8、16、30、30……秒
        let delay = min(pow(2, Double(reconnectAttempt - 1)), 30)
        phase = .waitingToReconnect(attempt: reconnectAttempt, at: Date().addingTimeInterval(delay), reason: reason)
        output.status("[\(reason)。\(Int(delay)) 秒后自动重连（第 \(reconnectAttempt) 次）]", style: .warning)
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            self?.startConnection(automatic: true)
        }
        // common 模式：弹着菜单、拖着窗口时也照样触发
        RunLoop.main.add(timer, forMode: .common)
        reconnectTimer = timer
    }

    /// 网络恢复或者电脑醒来：正在等重连的不用再等
    func retryNowIfWaiting() {
        guard case .waitingToReconnect = phase else { return }
        startConnection(automatic: true)
    }

    private func cancelReconnectTimer() {
        reconnectTimer?.invalidate()
        reconnectTimer = nil
    }

    // MARK: 日志

    func startLogging() {
        guard let profile, logURL == nil else { return }
        do {
            let logger = try SessionLogger(profile: profile)
            logURL = logger.url
            output.startLog(logger)
        } catch {
            output.status("无法创建日志文件：\(error.localizedDescription)", style: .error)
        }
    }

    func stopLogging() {
        guard logURL != nil else { return }
        output.stopLog()
        logURL = nil
    }

    func toggleLogging() {
        if logURL == nil { startLogging() } else { stopLogging() }
    }

    // MARK: 端口转发

    /// 连上后把会话里配的、以及临时加的转发都开起来
    private func startForwards() {
        let rules = (profile?.forwards ?? []).filter(\.enabled) + extraForwardRules
        forwards = rules.map { ForwardEntry(rule: $0) }
        for entry in forwards { launch(entry) }
    }

    private func launch(_ entry: ForwardEntry) {
        guard let ssh = link.ssh else { return }
        entry.state = .starting
        let spec = Self.forwardSpec(entry.rule)
        Task { @MainActor [weak self] in
            do {
                let handle = try await ssh.startForward(spec: spec)
                // 期间连接可能已经换了
                guard let self, self.link.ssh === ssh else { handle.stop(); return }
                entry.handle = handle
                entry.state = .running(port: Int(handle.status().boundPort))
            } catch {
                entry.state = .failed(error.userMessage)
                self?.output.status("端口转发 \(entry.rule.summary) 启动失败：\(error.userMessage)", style: .warning)
            }
            self?.objectWillChange.send()
        }
    }

    /// 临时加一条转发（只对这个标签页有效，重连后自动恢复）
    func addForward(_ rule: ForwardRule) {
        extraForwardRules.append(rule)
        let entry = ForwardEntry(rule: rule)
        forwards.append(entry)
        launch(entry)
    }

    func removeForward(_ entry: ForwardEntry) {
        entry.handle?.stop()
        forwards.removeAll { $0 === entry }
        extraForwardRules.removeAll { $0.id == entry.rule.id }
    }

    /// 停了的转发再开一次
    func restartForward(_ entry: ForwardEntry) {
        entry.handle?.stop()
        entry.handle = nil
        launch(entry)
    }

    private func stopForwards() {
        for entry in forwards { entry.handle?.stop() }
        markForwardsStopped("已停止")
    }

    private func markForwardsStopped(_ reason: String) {
        for entry in forwards where entry.state.isActive {
            entry.state = .stopped(reason)
            entry.handle = nil
        }
        objectWillChange.send()
    }

    static func forwardSpec(_ rule: ForwardRule) -> ForwardSpec {
        let kind: ForwardKind = switch rule.kind {
        case .local: .local
        case .remote: .remote
        case .dynamic: .dynamic
        }
        return ForwardSpec(
            kind: kind,
            bindHost: rule.bindHost,
            bindPort: UInt16(clamping: rule.bindPort),
            targetHost: rule.targetHost,
            targetPort: UInt16(clamping: rule.targetPort)
        )
    }

    // MARK: rz / sz

    /// CoreBridge 转来的 ZMODEM 进展（主线程）
    fileprivate func zmodemEvent(_ event: ZmodemEvent) {
        switch event {
        case .started(let upload):
            zmodem = ZmodemState(upload: upload)
        case .fileStarted(let name, let size):
            zmodem?.fileName = name
            zmodem?.done = 0
            zmodem?.total = size
            let verb = zmodem?.upload == true ? "发送" : "接收"
            output.status("[rz/sz] 正在\(verb) \(name)（\(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))）…")
        case .progress(let name, let done, let total):
            zmodem?.fileName = name
            zmodem?.done = done
            zmodem?.total = total
        case .fileFinished(let name, let localPath):
            zmodem?.files += 1
            if localPath.isEmpty {
                output.status("[rz/sz] \(name) 已发送")
            } else {
                output.status("[rz/sz] 已保存到 \((localPath as NSString).abbreviatingWithTildeInPath)")
                zmodem?.lastSaved = URL(fileURLWithPath: localPath)
            }
        case .finished(let files, let error):
            if let error {
                output.status("[rz/sz] \(error)", style: error.contains("取消") ? .dim : .error)
            } else if files == 0 {
                output.status("[rz/sz] 没有传输文件")
            }
            zmodem = nil
        }
    }

    func cancelZmodem() {
        link.ssh?.cancelZmodem()
    }

    // MARK: 其他

    /// 认证过程中要弹窗：先切到这个标签页，把窗口拿到前台
    func prepareForDialog() -> NSWindow? {
        workspace?.select(self)
        let window = workspace?.window ?? terminalView.window
        if let window {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        }
        if !NSApp.isActive {
            NSApp.requestUserAttention(.informationalRequest)
        }
        return window
    }

    /// 让测试钩子模拟键盘输入
    func sendText(_ text: String) {
        link.connection?.write(data: Data(text.utf8))
    }

    func clearScrollback() {
        terminalView.clearScrollback()
    }

    /// 右键“重置终端”：退出全屏程序留下的备用屏幕、关掉鼠标上报和括号粘贴、恢复字符集和光标。连接不受影响
    func resetTerminal() {
        output.resetModes()
    }

    private func applyAppearance(_ appearance: AppearanceSnapshot) {
        if appliedAppearance?.highlightRules != appearance.highlightRules {
            output.setHighlightRules(appearance.highlightRules)
        }
        terminalView.apply(appearance, previous: appliedAppearance)
        appliedAppearance = appearance
    }

    static func hopConfig(_ profile: SessionProfile) -> HopConfig {
        let expand = { (path: String) in (path as NSString).expandingTildeInPath }
        let auth: AuthMethod
        switch profile.auth {
        case .auto:
            auth = .auto(keyPaths: profile.keyPaths.filter { !$0.isEmpty }.map(expand), identitiesOnly: profile.identitiesOnly)
        case .password:
            auth = .password
        case .key:
            auth = .privateKey(path: expand(profile.keyPath))
        case .agent:
            auth = .agent
        }
        return HopConfig(
            host: profile.host.trimmingCharacters(in: .whitespaces),
            port: UInt16(clamping: profile.port),
            username: profile.username.trimmingCharacters(in: .whitespaces),
            auth: auth,
            legacyAlgorithms: profile.legacyAlgorithms,
            identityAgent: profile.identityAgent
        )
    }
}

extension TerminalSession: TerminalViewDelegate {
    // 这些回调可能来自主线程（键盘、布局），也可能来自解析线程（终端应答、标题）

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        // 键盘输入在主线程；终端自己生成的应答（光标位置报告等）在解析线程，不能同步给别的会话
        if Thread.isMainThread, let workspace, workspace.broadcastInput {
            workspace.broadcast(Data(data), from: self)
        }
        if let connection = link.connection {
            // write 是线程安全的（只是往 Rust 的通道里塞消息）
            connection.write(data: Data(data))
            return
        }
        // 没有连接时按回车重新连接
        if data.contains(13) {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                switch self.phase {
                case .closed, .failed: self.reconnect()
                default: break
                }
            }
        }
    }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        onMain {
            self.cols = max(newCols, 1)
            self.rows = max(newRows, 1)
            self.link.connection?.resize(cols: UInt32(self.cols), rows: UInt32(self.rows))
        }
    }

    func setTerminalTitle(source: TerminalView, title: String) {
        onMain { self.terminalTitle = title }
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        // OSC 7 报的是 file://主机/路径
        let path = directory.flatMap { URL(string: $0)?.path } ?? directory
        onMain { self.remoteDirectory = path }
    }

    /// 同步输入：把别的标签页里敲的键原样发过来
    func receiveBroadcast(_ data: Data) {
        link.connection?.write(data: data)
    }

    func scrolled(source: TerminalView, position: Double) {}

    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}

    func clipboardCopy(source: TerminalView, content: Data) {
        // OSC 52：远端程序（如 tmux、vim）请求写剪贴板
        guard let text = String(data: content, encoding: .utf8) else { return }
        onMain {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
    }

    private func onMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
    }
}

/// SSH、Telnet、串口连接共同的接口（UniFFI 生成的两个类型方法签名一样，直接遵循）
protocol TerminalConnection: AnyObject {
    func write(data: Data)
    func resize(cols: UInt32, rows: UInt32)
    func ack(bytes: UInt64)
    func close()
    func info() -> SessionInfo
}

extension SshSession: TerminalConnection {}
extension StreamSession: TerminalConnection {}

/// 当前连接的引用。键盘输入在主线程，终端应答在解析线程，所以要加锁。
final class SessionLink: @unchecked Sendable {
    private let lock = NSLock()
    private var current: TerminalConnection?

    var connection: TerminalConnection? {
        get { lock.lock(); defer { lock.unlock() }; return current }
        set { lock.lock(); current = newValue; lock.unlock() }
    }

    /// SSH 才有的功能（SFTP、端口转发、rz/sz、监控）用这个
    var ssh: SshSession? { connection as? SshSession }
}

/// 一个标签页的输出队列：远端输出、连接进度提示、日志都在这里按顺序处理。
final class TerminalOutput: @unchecked Sendable {
    enum Style {
        case dim, warning, error
    }

    let queue = DispatchQueue(label: "conch.terminal-output", qos: .userInteractive)
    private let feeder: TerminalFeedSender
    /// 只用它线程安全的状态快照接口（光标位置、是不是在备用屏幕）
    private weak var view: TerminalView?
    /// 只在 queue 上访问
    private var logger: SessionLogger?
    private var highlighter: KeywordHighlighter?
    private let lock = NSLock()
    private var visible = true
    private var unseenReported = false
    /// 后台标签页有新输出时调用（主线程）
    var onUnseenOutput: (() -> Void)?

    init(view: TerminalView) {
        self.feeder = view.feedSender
        self.view = view
    }

    func data(_ data: Data, completion: @escaping () -> Void) {
        queue.async { [self] in
            // 在这里同步解析；渲染由 SwiftTerm 按显示器刷新率合并。日志里存原始输出（不含高亮加的颜色）
            if highlighter != nil {
                feeder.feed(byteArray: highlighter!.process(data)[...])
            } else {
                feeder.feed(byteArray: [UInt8](data)[...])
            }
            logger?.write(data)
            completion()
        }
        noteActivity()
    }

    /// 在终端里显示一行提示（连接进度、断开原因等）。光标不在行首时先换行，不会接在提示符后面
    func status(_ text: String, style: Style = .dim) {
        let sgr = switch style {
        case .dim: "2"
        case .warning: "33"
        case .error: "31"
        }
        let body = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "\r\n")
        queue.async { [self] in
            // 输出都在这个队列上同步解析，此时拿到的光标位置是准的
            let column = view?.terminalStateSnapshot().cursor.col ?? 0
            let line = (column > 0 ? "\r\n" : "") + "\u{1b}[\(sgr)m\(body)\u{1b}[0m\r\n"
            feeder.feed(text: line)
            logger?.write(Data(line.utf8))
        }
    }

    /// 断线后让终端回到正常状态：退出全屏程序的备用屏幕、关掉鼠标上报和括号粘贴、软复位
    func resetModes() {
        queue.async { [self] in
            // 只在真的处于备用屏幕时才发 1049l：不在的时候它会把光标恢复到左上角，后面的提示就盖住屏幕了
            let alternate = view?.terminalInputStateSnapshot()?.isAlternateBuffer ?? false
            let sequence = (alternate ? "\u{1b}[?1049l" : "")
                + "\u{1b}[!p\u{1b}[?7h\u{1b}[?1000l\u{1b}[?1002l\u{1b}[?1003l\u{1b}[?1006l\u{1b}[?2004l\u{1b}[?25h"
            feeder.feed(text: sequence)
        }
    }

    func setHighlightRules(_ rules: [KeywordHighlighter.Rule]) {
        queue.async { [self] in
            highlighter = rules.isEmpty ? nil : KeywordHighlighter(rules: rules)
        }
    }

    func startLog(_ logger: SessionLogger) {
        queue.async { [self] in
            self.logger?.close()
            self.logger = logger
        }
    }

    func stopLog() {
        queue.async { [self] in
            logger?.close()
            logger = nil
        }
    }

    func setVisible(_ value: Bool) {
        lock.lock()
        visible = value
        if value { unseenReported = false }
        lock.unlock()
    }

    private func noteActivity() {
        lock.lock()
        let report = !visible && !unseenReported
        if report { unseenReported = true }
        lock.unlock()
        if report {
            DispatchQueue.main.async { [weak self] in self?.onUnseenOutput?() }
        }
    }
}

/// 实现 Rust 侧的 SessionDelegate。所有回调都在内核线程上执行。
final class CoreBridge: SessionDelegate, @unchecked Sendable {
    private weak var owner: TerminalSession?
    private let output: TerminalOutput
    /// 跳板机在前，目标主机最后，和内核的 hop 编号一致
    private let hops: [SessionProfile]
    private let secrets: SessionSecrets
    private let lock = NSLock()
    private var session: TerminalConnection?
    private var unacked: UInt64 = 0
    /// 用户勾选了“记住”的密码，连接成功后才写进钥匙串
    private var toRemember: [SecretKey: String] = [:]
    /// 这次连接中用户输入过的，连接失败时从内存里清掉
    private var entered: Set<SecretKey> = []

    init(owner: TerminalSession, output: TerminalOutput, hops: [SessionProfile], secrets: SessionSecrets) {
        self.owner = owner
        self.output = output
        self.hops = hops
        self.secrets = secrets
    }

    /// connect 返回之前就可能有输出（横幅、提示符），那部分的 ack 先记着
    func attach(_ session: TerminalConnection) {
        lock.lock()
        self.session = session
        let pending = unacked
        unacked = 0
        lock.unlock()
        if pending > 0 { session.ack(bytes: pending) }
    }

    func saveRememberedSecrets() {
        lock.lock()
        let items = toRemember
        toRemember.removeAll()
        lock.unlock()
        guard !items.isEmpty else { return }
        DispatchQueue.global(qos: .utility).async {
            for (key, value) in items {
                Keychain.save(value, for: key)
            }
        }
    }

    func forgetEnteredSecrets() {
        lock.lock()
        let keys = entered
        entered.removeAll()
        toRemember.removeAll()
        lock.unlock()
        for key in keys { secrets.remove(key) }
    }

    // MARK: SessionDelegate

    func onOutput(data: Data) {
        output.data(data) { [self] in ack(UInt64(data.count)) }
    }

    func onProgress(message: String) {
        output.status(message)
    }

    func onClosed(info: CloseInfo) {
        // 排在已收到的输出之后，保证最后一屏先显示出来
        output.queue.async { [self] in
            DispatchQueue.main.async { [self] in
                owner?.sessionClosed(by: self, info: info)
            }
        }
    }

    // 下面几个回调在 Rust 的阻塞线程上执行，可以放心等待用户操作、读钥匙串

    func verifyHostKey(info: HostKeyInfo) -> Bool {
        if TestHooks.trustNewHosts { return true }
        return Dialogs.ask { [weak self] done in
            let window = self?.owner?.prepareForDialog()
            Dialogs.confirmHostKey(info, window: window, completion: done)
        }
    }

    func requestSecret(request: SecretRequest) -> String? {
        let key: SecretKey = switch request.kind {
        case .password: .password(user: request.username, host: request.host, port: Int(request.port))
        case .passphrase: .passphrase(path: request.keyPath)
        }
        if let injected = TestHooks.secret(for: key) {
            return injected
        }
        if request.retry {
            secrets.remove(key)
        } else {
            if let cached = secrets.get(key) { return cached }
            // 打开了“使用保存的密码前验证”：先验证；用户取消就当没保存过，改为询问
            if Keychain.exists(key) {
                if SecretGate.authorize(reason: Self.authReason(for: request)), let stored = Keychain.load(key) {
                    secrets.set(key, stored)
                    return stored
                }
                output.status("身份验证未通过或不可用，未读取保存的密码，请手动输入。")
            }
        }

        let index = Int(request.hop)
        let hop = index < hops.count ? hops[index] : nil
        let isJump = index < hops.count - 1
        let response: SecretResponse? = TestHooks.promptAnswer ?? Dialogs.ask { [weak self] done in
            let window = self?.owner?.prepareForDialog()
            let saved = hop.map { SessionStore.shared.contains($0.id) } ?? false
            Dialogs.promptSecret(
                request: request,
                hopName: hop?.displayName,
                isJump: isJump,
                rememberByDefault: saved,
                window: window,
                completion: done
            )
        }
        guard let response else { return nil }
        secrets.set(key, response.value)
        lock.lock()
        entered.insert(key)
        toRemember[key] = response.remember ? response.value : nil
        lock.unlock()
        return response.value
    }

    /// Touch ID 弹窗上的说明（系统会显示成“Conch 正在尝试……”）
    private static func authReason(for request: SecretRequest) -> String {
        switch request.kind {
        case .password: "使用保存的 \(request.username)@\(request.host) 的密码"
        case .passphrase: "使用保存的私钥 \((request.keyPath as NSString).lastPathComponent) 的口令"
        }
    }

    func keyboardInteractive(request: KeyboardInteractiveRequest) -> [String]? {
        if let answers = TestHooks.keyboardInteractiveAnswers(request) {
            return answers
        }
        let index = Int(request.hop)
        let hopName = index < hops.count ? hops[index].displayName : request.host
        return Dialogs.ask { [weak self] done in
            let window = self?.owner?.prepareForDialog()
            Dialogs.keyboardInteractive(request, hopName: hopName, window: window, completion: done)
        }
    }

    // rz / sz

    func zmodemDownloadDir() -> String? {
        if let directory = TestHooks.zmodemDirectory { return directory }
        let directory = AppPaths.zmodemDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.path
    }

    func zmodemChooseFiles() -> [String]? {
        if let files = TestHooks.zmodemUploadFiles { return files }
        return Dialogs.ask { [weak self] done in
            let window = self?.owner?.prepareForDialog()
            Dialogs.chooseFilesToSend(window: window, completion: done)
        }
    }

    func onZmodemEvent(event: ZmodemEvent) {
        // 排在已收到的输出后面，提示的顺序才对
        output.queue.async { [weak self] in
            DispatchQueue.main.async { self?.owner?.zmodemEvent(event) }
        }
    }

    private func ack(_ bytes: UInt64) {
        lock.lock()
        guard let session else {
            unacked += bytes
            lock.unlock()
            return
        }
        lock.unlock()
        session.ack(bytes: bytes)
    }
}

/// 正在进行的 rz / sz（状态栏上显示进度）
struct ZmodemState: Equatable {
    var upload: Bool
    var fileName = ""
    var done: UInt64 = 0
    var total: UInt64 = 0
    var files = 0
    var lastSaved: URL?

    var fraction: Double {
        total > 0 ? min(Double(done) / Double(total), 1) : 0
    }
}

/// 一条端口转发及其运行状态
final class ForwardEntry: ObservableObject, Identifiable {
    enum State: Equatable {
        case starting
        case running(port: Int)
        case failed(String)
        case stopped(String)

        var isActive: Bool {
            switch self {
            case .starting, .running: true
            default: false
            }
        }
    }

    let rule: ForwardRule
    @Published var state: State = .starting
    var handle: PortForward?

    var id: UUID { rule.id }

    init(rule: ForwardRule) {
        self.rule = rule
    }

    /// 实际监听的地址（端口填 0 时由系统分配）
    var listenAddress: String {
        if case .running(let port) = state { return "\(rule.bindHost):\(port)" }
        return "\(rule.bindHost):\(rule.bindPort)"
    }
}
