import AppKit
import ConchKit
import SwiftTerm

/// 自动化测试钩子：仅在 CONCH_TESTING 编译的独立测试 App 中生效；正式 App 忽略所有测试开关。
///
///   CONCH_DATA_DIR=/path                 App 数据目录（会话列表、known_hosts、日志）改到这里
///   CONCH_SSH_CONFIG=/path               代替 ~/.ssh/config（快速连接解析别名、导入时用）
///   CONCH_KEYCHAIN_SERVICE=名字          钥匙串条目用这个服务名，不碰真实保存的密码
///   CONCH_IMPORT_SSH_CONFIG=/path        启动时导入这个 ssh_config
///   CONCH_IMPORT_XSH=/path               启动时导入这个 .xsh 文件或文件夹
///   CONCH_QUICK_CONNECT='ssh …'          第一个窗口用快速连接打开
///   CONCH_QUICK_CONNECT_LEGACY=1         快速连接时开启兼容老设备算法
///   CONCH_OPEN_SESSIONS='名称1,名称2'    按名称打开保存的会话，每个一个标签页
///   CONCH_SELECT_TAB=0                   打开后选中第几个标签页
///   CONCH_TRUST_NEW_HOSTS=1              自动信任新主机
///   CONCH_TEST_SECRETS='账户=值;…'       直接提供密码 / 口令（账户形如 password:user@host:port）
///   CONCH_TEST_PROMPT_ANSWER='值[;remember]'  模拟用户在密码框里输入（可选勾上“记住”）
///   CONCH_TEST_OTP=123456                交互式认证的每个问题都答这个
///   CONCH_TEST_KEYCHAIN=1                启动时做一次钥匙串读写自检
///   CONCH_TEST_KEYCHAIN_SEED='账户=值;…' 启动时先往（测试用的）钥匙串里写这些
///   CONCH_AUTOTYPE='命令\n'               每次连上 1 秒后模拟键盘输入（支持 \n \r \t \e）
///   CONCH_SNAPSHOT=/path/out.png         若干秒后把窗口画成 PNG
///   CONCH_DUMP_TEXT=/path/prefix         同时导出每个标签页的屏幕文字：prefix-0.txt、prefix-1.txt…
///   CONCH_DUMP_STATE=/path/state.json    同时导出标签页状态、会话列表等
///   CONCH_SNAPSHOT_DELAY=4               截图前等待的秒数
///   CONCH_QUIT_AFTER_SNAPSHOT=1          截图后退出（会清掉测试用的钥匙串条目）
///   CONCH_NO_METAL=1                     不用 Metal（离屏截图只能截到 CoreGraphics 渲染的内容）
///   CONCH_SHOW_EDITOR=会话名或分组名     打开会话编辑表单（找不到同名会话就新建，放在这个分组）
///   CONCH_SHOW_SETTINGS=1                打开设置窗口（截图时一起截）
///   CONCH_DUMP_VIEWS=/path               导出窗口的 NSView 层级（调试布局用）
///   CONCH_DUMP_MENUS=/path               导出菜单栏和快捷键
///   CONCH_TEST_ZMODEM_DIR=/path          sz 收到的文件放这里（不用设置里的下载目录）
///   CONCH_TEST_RZ_FILES='文件1;文件2'    远端 rz 时直接发这些文件（不弹选择框）
///   CONCH_SHOW_FILES=1                   打开文件面板（SFTP）
///   CONCH_SHOW_COMPOSE=1                 打开撰写栏
///   CONCH_BROADCAST=1                    打开同步输入
///   CONCH_FIND=文字                      截图前在终端里查找
///   CONCH_KEYS='文字\r' CONCH_KEYS_DELAY=3  几秒后像键盘一样在当前标签页输入（会走同步输入）
///   CONCH_SHOW_FORWARDS=1                2 秒后打开状态栏上的端口转发面板
///   CONCH_TEST_SFTP_PATH=/path           2 秒后让文件面板进到这个目录
///   CONCH_TEST_SFTP_UPLOAD=/path/file    3 秒后用文件面板上传这个文件到当前目录
///   CONCH_TEST_LOCAL_PATH=/path          文件面板本机那一栏从这里开始（默认是测试数据目录）；CONCH_SHOW_LOCAL=0 不显示本机那一栏
///   CONCH_TEST_EDIT=/远端/文件            2.5 秒后用“本机编辑器”编辑这个文件（测试时不真的打开编辑器）
///   CONCH_TEST_EDIT_APPEND='文字\n' CONCH_TEST_EDIT_APPEND_DELAY=2  开始编辑几秒后往本机副本追加文字（模拟编辑器保存）
///   CONCH_TEST_EDIT_CONFLICT=keep|overwrite  服务器上的文件被别人改过时怎么选
///   CONCH_TEST_DISCONNECT_AFTER=2        第一次连上几秒后点“断开”
///   CONCH_TEST_ENTER_AFTER_DISCONNECT=1  断开 2 秒后在终端里按回车（应该重新连接）
///   CONCH_SHOW_MONITOR=1                 打开服务器监控面板（导出的状态里有 monitor）
///   CONCH_SYNC_DIR=/path                 会话同步已经打开，同步文件夹是这个
///   CONCH_SYNC_ENABLE=/path              启动后打开会话同步（把本机的会话并进去）
///   CONCH_TEST_ADD_GROUP='名称' CONCH_TEST_ADD_GROUP_DELAY=4  几秒后新建一个分组（测同步时两边同时修改）
///   CONCH_REQUIRE_AUTH=1                 打开“使用保存的密码前验证”（测试时默认关，不读你的设置）
///   CONCH_TEST_AUTH=allow|deny           模拟 Touch ID 验证的结果
///   CONCH_PANE_ACTIONS='h,v,next,close'   2 秒后每隔 1.5 秒做一个分屏操作：h 左右分屏、v 上下分屏、
///                                        open:会话名 在右边分屏打开会话、next / prev 切换分屏、zoom 放大、close 关闭分屏
///   CONCH_TEST_SCRIPT='步骤;…'           按顺序模拟点击、按键等界面操作，见 TestScript.swift
///   导出的状态里 tabs 是所有终端（按标签页、分屏的顺序），tab 是所在标签页的序号，layouts 是每个标签页的分屏结构
enum TestHooks {
    private static let env = ProcessInfo.processInfo.environment
    private static var windowHandled = false
    private static var keychainSelfTest: String?

    static var dataDirectory: URL? {
        #if CONCH_TESTING
        return env["CONCH_DATA_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("ConchTests-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        #else
        return nil
        #endif
    }

    static var isActive: Bool { dataDirectory != nil }
    static var trustNewHosts: Bool { isActive && env["CONCH_TRUST_NEW_HOSTS"] == "1" }
    static var disableMetal: Bool { isActive && env["CONCH_NO_METAL"] == "1" }
    /// CONCH_UI_THEME=glass|graphite|environment|system：界面主题（截图对比用，不写进偏好设置）
    static var uiTheme: String? { isActive ? env["CONCH_UI_THEME"] : nil }
    static var keychainService: String? {
        guard isActive else { return nil }
        let service = env["CONCH_KEYCHAIN_SERVICE"] ?? "Conch-Tests"
        return service.hasPrefix("Conch-") ? service : "Conch-Tests"
    }
    static var showSettingsRequested: Bool { isActive && env["CONCH_SHOW_SETTINGS"] == "1" }
    static var zmodemDirectory: String? { isActive ? env["CONCH_TEST_ZMODEM_DIR"] : nil }
    static var editConflictAnswer: String? { isActive ? env["CONCH_TEST_EDIT_CONFLICT"] : nil }

    /// 测试时的同步文件夹（不读写你的偏好设置）
    static var syncDirectory: URL? = isActive ? env["CONCH_SYNC_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) } : nil

    /// 测试时是否要求验证；nil 表示不是测试，读偏好设置
    static var requireAuth: Bool? { isActive ? env["CONCH_REQUIRE_AUTH"] == "1" : nil }

    static var authUnavailable: Bool { isActive && env["CONCH_TEST_AUTH"] == "unavailable" }

    static var authAnswer: Bool? {
        guard isActive, let answer = env["CONCH_TEST_AUTH"] else { return nil }
        return answer == "allow"
    }

    /// 测试时文件面板本机那一栏从这个文件夹开始：CONCH_TEST_LOCAL_PATH，没给就用测试数据目录
    /// （不读写你上次的位置，也不去列你真实的主目录）
    static var localDirectory: URL? {
        guard isActive else { return nil }
        if let path = env["CONCH_TEST_LOCAL_PATH"] { return URL(fileURLWithPath: path, isDirectory: true) }
        return dataDirectory
    }

    /// 测试时默认显示本机那一栏，CONCH_SHOW_LOCAL=0 时不显示
    static var showLocalFiles: Bool { env["CONCH_SHOW_LOCAL"] != "0" }

    static var zmodemUploadFiles: [String]? {
        guard isActive, let list = env["CONCH_TEST_RZ_FILES"] else { return nil }
        return list.components(separatedBy: ";").filter { !$0.isEmpty }
    }

    static var sshConfigURL: URL {
        if isActive, let path = env["CONCH_SSH_CONFIG"] { return URL(fileURLWithPath: path) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh/config")
    }

    // MARK: 启动

    static func appDidLaunch() {
        guard isActive else { return }
        if let path = env["CONCH_TEST_PID_FILE"] {
            try? String(ProcessInfo.processInfo.processIdentifier).write(toFile: path, atomically: true, encoding: .utf8)
        }
        if let seed = env["CONCH_TEST_KEYCHAIN_SEED"], keychainService != nil {
            for (account, value) in parsePairs(seed) {
                if let key = secretKey(account: account) { Keychain.save(value, for: key) }
            }
        }
        if let path = env["CONCH_IMPORT_SSH_CONFIG"] {
            let result = SSHConfigImporter.importProfiles(from: SSHConfig.load(from: URL(fileURLWithPath: path)))
            SessionStore.shared.merge(result.profiles)
        }
        if let path = env["CONCH_IMPORT_XSH"] {
            let result = XshellImporter.importItems(at: [URL(fileURLWithPath: path)])
            SessionStore.shared.merge(result.profiles)
        }
        if env["CONCH_TEST_KEYCHAIN"] == "1" {
            keychainSelfTest = runKeychainSelfTest()
        }
        if let path = env["CONCH_SYNC_ENABLE"] {
            try? SyncSettings.enable(URL(fileURLWithPath: path, isDirectory: true))
        }
    }

    static func windowDidAppear(_ workspace: WorkspaceModel) {
        guard isActive, !windowHandled else { return }
        windowHandled = true
        let captureKeys = ["CONCH_SNAPSHOT", "CONCH_DUMP_TEXT", "CONCH_DUMP_STATE", "CONCH_DUMP_VIEWS", "CONCH_DUMP_MENUS"]
        if captureKeys.contains(where: { env[$0] != nil }) || env["CONCH_QUIT_AFTER_SNAPSHOT"] == "1" {
            let delay = Double(env["CONCH_SNAPSHOT_DELAY"] ?? "") ?? 4
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                capture(workspace)
            }
        }
        DispatchQueue.main.async {
            if let text = env["CONCH_QUICK_CONNECT"], let resolved = QuickConnectResolver.resolve(text) {
                var profile = resolved.profile
                profile.legacyAlgorithms = env["CONCH_QUICK_CONNECT_LEGACY"] == "1"
                workspace.open(profile, adHocJumps: resolved.jumps)
            }
            if let names = env["CONCH_OPEN_SESSIONS"] {
                let library = SessionStore.shared.library
                for name in names.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) {
                    if let profile = library.sessions.first(where: { $0.displayName == name }) {
                        workspace.open(profile)
                    }
                }
            }
            if let index = env["CONCH_SELECT_TAB"].flatMap({ Int($0) }) {
                workspace.select(index: index)
            }
            workspace.showFilesPanel = env["CONCH_SHOW_FILES"] == "1"
            if env["CONCH_SHOW_MONITOR"] == "1" { workspace.showMonitor = true }
            if env["CONCH_EXPAND_FILES"] == "1" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { workspace.expandedFiles = true }
            }
            workspace.showComposeBar = env["CONCH_SHOW_COMPOSE"] == "1"
            workspace.broadcastInput = env["CONCH_BROADCAST"] == "1"
            if let text = env["CONCH_FIND"] {
                workspace.find.visible = true
                workspace.find.text = text
            }
            // 文件面板：先进到测试目录，再上传一个文件（都只用于自动化测试）
            if let path = env["CONCH_TEST_SFTP_PATH"] {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    workspace.activeSession?.files.go(to: path)
                }
            }
            if let path = env["CONCH_TEST_EDIT"] {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                    guard let browser = workspace.activeSession?.files else { return }
                    browser.editPath(path)
                    if let text = env["CONCH_TEST_EDIT_APPEND"] {
                        let delay = Double(env["CONCH_TEST_EDIT_APPEND_DELAY"] ?? "") ?? 2
                        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                            guard let edit = browser.edits.first(where: { $0.remotePath == path }),
                                  let handle = try? FileHandle(forWritingTo: edit.localURL) else { return }
                            handle.seekToEndOfFile()
                            handle.write(Data(unescape(text).utf8))
                            try? handle.close()
                        }
                    }
                }
            }
            if let file = env["CONCH_TEST_SFTP_UPLOAD"] {
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    workspace.activeSession?.files.upload([URL(fileURLWithPath: file)])
                }
            }
            if env["CONCH_SHOW_FORWARDS"] == "1" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { workspace.showForwards = true }
            }
            if let group = env["CONCH_TEST_ADD_GROUP"] {
                let delay = Double(env["CONCH_TEST_ADD_GROUP_DELAY"] ?? "") ?? 3
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    SessionStore.shared.update { $0.addGroup(group) }
                }
            }
            if let actions = env["CONCH_PANE_ACTIONS"] {
                for (index, action) in actions.split(separator: ",").enumerated() {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2 + 1.5 * Double(index)) {
                        paneAction(String(action), in: workspace)
                    }
                }
            }
            if let keys = env["CONCH_KEYS"] {
                let delay = Double(env["CONCH_KEYS_DELAY"] ?? "") ?? 3
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    // 走 TerminalView 的键盘输入路径，和用户敲键盘一样（同步输入也会生效）
                    workspace.activeSession?.terminalView.send(txt: unescape(keys))
                }
            }
            if let script = env["CONCH_TEST_SCRIPT"] {
                TestScript.run(script, in: workspace, log: env["CONCH_TEST_SCRIPT_LOG"].map { URL(fileURLWithPath: $0) },
                               delay: Double(env["CONCH_TEST_SCRIPT_DELAY"] ?? "") ?? 3)
            }
            if let name = env["CONCH_SHOW_EDITOR"] {
                if let profile = SessionStore.shared.library.sessions.first(where: { $0.displayName == name }) {
                    workspace.edit(profile)
                } else {
                    workspace.editNew(group: name)
                }
            }
        }
    }

    private static var disconnectTested = false

    static func sessionDidConnect(_ session: TerminalSession) {
        guard isActive else { return }
        if let text = env["CONCH_AUTOTYPE"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                session.sendText(unescape(text))
            }
        }
        // 测“断开”按钮和“断开后按回车重新连接”：只在第一次连上时做
        if let seconds = env["CONCH_TEST_DISCONNECT_AFTER"].flatMap(Double.init), !disconnectTested {
            disconnectTested = true
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
                session.disconnect()
                if env["CONCH_TEST_ENTER_AFTER_DISCONNECT"] == "1" {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        // 和用户在终端里按回车走同一条路
                        session.terminalView.send(txt: "\r")
                    }
                }
            }
        }
    }

    private static func paneAction(_ action: String, in workspace: WorkspaceModel) {
        switch action {
        case "h": workspace.splitActive(.horizontal)
        case "v": workspace.splitActive(.vertical)
        case "next": workspace.focusNextPane(1)
        case "prev": workspace.focusNextPane(-1)
        case "zoom": workspace.toggleZoom()
        case "close": workspace.closeSelectedTab()
        default:
            if action.hasPrefix("open:"),
               let profile = SessionStore.shared.library.sessions.first(where: { $0.displayName == String(action.dropFirst(5)) })
            {
                workspace.openInSplit(profile, axis: .horizontal)
            }
        }
    }

    // MARK: 认证

    static func secret(for key: SecretKey) -> String? {
        guard isActive, let text = env["CONCH_TEST_SECRETS"] else { return nil }
        return parsePairs(text).first { $0.0 == key.account }?.1
    }

    static var promptAnswer: SecretResponse? {
        guard isActive, let text = env["CONCH_TEST_PROMPT_ANSWER"] else { return nil }
        let parts = text.components(separatedBy: ";")
        return SecretResponse(value: parts[0], remember: parts.dropFirst().contains("remember"))
    }

    static func keyboardInteractiveAnswers(_ request: KeyboardInteractiveRequest) -> [String]? {
        guard isActive, let otp = env["CONCH_TEST_OTP"] else { return nil }
        return request.prompts.map { _ in otp }
    }

    // MARK: 截图和导出

    private static func capture(_ workspace: WorkspaceModel) {
        if workspace.find.visible {
            workspace.find.next(in: workspace.activeSession?.terminalView)
        }
        if let prefix = env["CONCH_DUMP_TEXT"] {
            for (index, session) in workspace.allSessions.enumerated() {
                try? session.terminalView.getBufferAsData().write(to: URL(fileURLWithPath: "\(prefix)-\(index).txt"))
            }
        }
        if let path = env["CONCH_DUMP_STATE"] {
            writeState(workspace, to: URL(fileURLWithPath: path))
        }
        if let path = env["CONCH_DUMP_MENUS"], let menu = NSApp.mainMenu {
            var lines: [String] = []
            for top in menu.items {
                lines.append(top.title)
                for item in top.submenu?.items ?? [] where !item.isSeparatorItem {
                    let modifiers = item.keyEquivalentModifierMask
                    var keys = ""
                    if modifiers.contains(.control) { keys += "⌃" }
                    if modifiers.contains(.option) { keys += "⌥" }
                    if modifiers.contains(.shift) { keys += "⇧" }
                    if modifiers.contains(.command) { keys += "⌘" }
                    lines.append("  \(item.title)" + (item.keyEquivalent.isEmpty ? "" : "\t\(keys)\(item.keyEquivalent)")
                                 + (item.isHidden ? "\t(隐藏)" : ""))
                }
            }
            try? lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
        }
        if let path = env["CONCH_DUMP_VIEWS"], let root = workspace.window?.contentView?.superview {
            var lines: [String] = []
            dumpViews(root, depth: 0, into: &lines)
            try? lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
        }
        let window = workspace.window
        if let path = env["CONCH_SNAPSHOT"], let window,
           let frameView = window.contentView?.superview ?? window.contentView,
           let png = renderPNG(frameView)
        {
            try? png.write(to: URL(fileURLWithPath: path))
            // 整窗离屏截图画不出标签栏（横向 ScrollView）里的内容，单独画一张
            if let strip = findViews(in: frameView, where: { $0 is NSScrollView && $0.frame.height <= 40 }).first,
               let document = (strip as? NSScrollView)?.documentView,
               let stripPNG = renderPNG(document)
            {
                try? stripPNG.write(to: URL(fileURLWithPath: (path as NSString).deletingPathExtension + "-tabs.png"))
            }
            // 其他窗口（比如设置窗口）各截一张
            let others = NSApp.windows.filter { $0 !== window && $0.isVisible && !$0.isSheet && $0.contentView != nil }
            for (index, other) in others.enumerated() {
                if let view = other.contentView?.superview ?? other.contentView, let png = renderPNG(view) {
                    try? png.write(to: URL(fileURLWithPath: (path as NSString).deletingPathExtension + "-window\(index).png"))
                }
            }
            // 有弹出的 sheet（主机密钥确认、二次验证）时另存一张
            if let sheet = window.attachedSheet,
               let sheetView = sheet.contentView?.superview ?? sheet.contentView,
               let sheetPNG = renderPNG(sheetView)
            {
                let sheetPath = (path as NSString).deletingPathExtension + "-sheet.png"
                try? sheetPNG.write(to: URL(fileURLWithPath: sheetPath))
            }
        }
        if env["CONCH_QUIT_AFTER_SNAPSHOT"] == "1" {
            // SwiftUI sheet 必须先清除绑定，直接 endSheet 会留下展示状态。
            let isSwiftUISheet = workspace.expandedFiles || workspace.editor != nil
            workspace.expandedFiles = false
            workspace.editor = nil
            if !isSwiftUISheet, let window, let sheet = window.attachedSheet {
                window.endSheet(sheet, returnCode: .alertSecondButtonReturn)
            }
            if keychainService != nil { Keychain.deleteAllForTests() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { NSApp.terminate(nil) }
        }
    }

    private struct TabState: Encodable {
        var title: String
        var tab: Int
        var focused: Bool
        var kind: String?
        var phase: String
        var route: String
        var auth: String?
        var cols: Int
        var rows: Int
        var log: String?
        var savedPassword: Bool
        var encoding: String?
        var forwards: [String]
        var files: FilesState?
        var monitor: MonitorState?
        var remoteDirectory: String?
    }

    private struct MonitorState: Encodable {
        var status: String
        var hostname: String?
        var cores: Int?
        var cpu: Double?
        var cpuPoints: Int
        var memoryPercent: Double?
        var received: Double?
        var disks: [String]
        var processes: [String]
    }

    private static func monitorState(_ monitor: ServerMonitor) -> MonitorState {
        let status: String = switch monitor.status {
        case .idle: "idle"
        case .loading: "loading"
        case .running: "running"
        case .unsupported(let message): "unsupported: \(message)"
        case .failed(let message): "failed: \(message)"
        case .disconnected: "disconnected"
        }
        return MonitorState(
            status: status,
            hostname: monitor.sample?.hostname,
            cores: monitor.sample?.cores,
            cpu: monitor.rates?.cpuPercent,
            cpuPoints: monitor.cpu.count,
            memoryPercent: monitor.memory.last?.value,
            received: monitor.rates?.receivedPerSecond,
            disks: monitor.sample?.disks.map { "\($0.mount) \($0.percent)%" } ?? [],
            processes: monitor.sample?.processes.map(\.command) ?? []
        )
    }

    private struct FilesState: Encodable {
        var status: String
        var path: String
        var entries: [String]
        var transfers: [String]
        var edits: [String]
        /// 本机那一栏（显示时才有）
        var localPath: String?
        var localEntries: [String]?
    }

    private struct State: Encodable {
        var tabs: [TabState]
        var selected: Int?
        var layouts: [String]
        var broadcast: Bool
        var find: String?
        var theme: String
        /// 界面主题（glass / graphite / environment）和分组的环境标签
        var uiTheme: String
        var environments: [String: String]
        var font: String
        var terminalBackground: String?
        var sessions: [String: String]
        var groups: [String]
        var keychainSelfTest: String?
        var sessionsFile: String
        var filesExpanded: Bool
        var fileSheetVisible: Bool
        var waitingForSyncFolder: Bool
        var quickCommands: [String]
        var authPrompts: Int
    }

    private static func writeState(_ workspace: WorkspaceModel, to url: URL) {
        let owners: [(Int, WorkspaceTab)] = workspace.tabs.enumerated().flatMap { item in
            item.element.sessions.map { _ in (item.offset, item.element) }
        }
        let tabs = zip(workspace.allSessions, owners).map { tab, owner in
            TabState(
                title: tab.tabTitle,
                tab: owner.0,
                focused: owner.1.focusedID == tab.id,
                kind: tab.profile?.kind.rawValue,
                phase: describe(tab.phase),
                route: tab.routeDescription,
                auth: tab.info?.auth,
                cols: tab.cols,
                rows: tab.rows,
                log: tab.logURL?.path,
                savedPassword: tab.profile.map { Keychain.exists(.password(for: $0)) } ?? false,
                encoding: tab.profile?.encoding,
                forwards: tab.forwards.map { "\($0.rule.summary) | \(describe($0.state))" },
                files: workspace.showFilesPanel && tab === workspace.activeSession && tab.isSSH
                    ? filesState(tab.files, local: workspace.showLocalFiles ? workspace.localFiles : nil) : nil,
                monitor: workspace.showMonitor && tab === workspace.activeSession && tab.isSSH ? monitorState(tab.monitor) : nil,
                remoteDirectory: tab.remoteDirectory
            )
        }
        let library = SessionStore.shared.library
        var sessions: [String: String] = [:]
        for profile in library.sessions {
            var text = "\(profile.group)|\(profile.address)|\(profile.auth.rawValue)"
            if let jump = library.session(profile.jumpHostID) { text += "|jump=\(jump.displayName)" }
            if !profile.keyPaths.isEmpty { text += "|keys=\(profile.keyPaths.joined(separator: ","))" }
            sessions[profile.displayName] = text
        }
        let snapshot = TerminalAppearance.shared.snapshot
        let state = State(
            tabs: tabs,
            selected: workspace.allSessions.firstIndex { $0 === workspace.activeSession },
            layouts: workspace.tabs.map { tab in
                let all = workspace.allSessions
                return tab.root.describe { session in all.firstIndex { $0 === session } ?? -1 }
                    + (tab.zoomedID.flatMap { id in all.firstIndex { $0.id == id } }.map { " zoom=\($0)" } ?? "")
            },
            broadcast: workspace.broadcastInput,
            find: workspace.find.visible
                ? "\(workspace.find.summary.index)/\(workspace.find.summary.total)\(workspace.find.notFound ? " 没有找到" : "")"
                : nil,
            theme: snapshot.theme.id,
            uiTheme: ThemeStore.shared.theme.rawValue,
            environments: library.environments.mapValues(\.rawValue),
            font: "\(snapshot.font.fontName) \(Int(snapshot.font.pointSize))",
            terminalBackground: workspace.activeSession.flatMap { hex($0.terminalView.nativeBackgroundColor) },
            sessions: sessions,
            groups: library.allGroups,
            keychainSelfTest: keychainSelfTest,
            sessionsFile: SessionStore.shared.fileURL.path,
            filesExpanded: workspace.expandedFiles,
            fileSheetVisible: workspace.expandedFiles && workspace.window?.attachedSheet != nil,
            waitingForSyncFolder: SessionStore.shared.waitingForSyncFolder,
            quickCommands: QuickCommandStore.shared.commands.map(\.name),
            authPrompts: SecretGate.promptCount
        )
        if let data = try? JSONEncoder.conch.encode(state) {
            try? data.write(to: url)
        }
    }

    private static func hex(_ color: NSColor) -> String? {
        guard let rgb = color.usingColorSpace(.sRGB) else { return nil }
        return String(format: "#%02X%02X%02X", Int(round(rgb.redComponent * 255)),
                      Int(round(rgb.greenComponent * 255)), Int(round(rgb.blueComponent * 255)))
    }

    private static func describe(_ state: ForwardEntry.State) -> String {
        switch state {
        case .starting: "starting"
        case .running(let port): "running:\(port)"
        case .failed(let message): "failed: \(message)"
        case .stopped(let reason): "stopped: \(reason)"
        }
    }

    private static func filesState(_ files: SftpBrowser, local: LocalBrowser?) -> FilesState {
        let status = switch files.status {
        case .idle: "idle"
        case .opening: "opening"
        case .ready: "ready"
        case .failed(let message): "failed: \(message)"
        case .disconnected: "disconnected"
        }
        return FilesState(
            status: status,
            path: files.path,
            entries: files.visibleEntries.map { $0.isDir ? $0.name + "/" : $0.name },
            transfers: files.transfers.map { item in
                switch item.state {
                case .running: "\(item.name): running"
                case .finished: "\(item.name): finished"
                case .cancelled: "\(item.name): cancelled"
                case .failed(let message): "\(item.name): failed \(message)"
                }
            },
            edits: files.edits.map { edit in
                let state = switch edit.state {
                case .downloading: "downloading"
                case .synced(nil): "opened"
                case .synced: "synced"
                case .uploading: "uploading"
                case .conflict: "conflict"
                case .failed(let message): "failed \(message)"
                }
                return "\(edit.name): \(state)"
            },
            localPath: local?.directory.path,
            localEntries: local?.visibleEntries.map { $0.isDir ? $0.name + "/" : $0.name }
        )
    }

    private static func describe(_ phase: TerminalSession.Phase) -> String {
        switch phase {
        case .idle: "idle"
        case .connecting: "connecting"
        case .connected: "connected"
        case .waitingToReconnect(let attempt, _, let reason): "waiting(\(attempt)): \(reason)"
        case .failed(let message): "failed: \(message)"
        case .closed(let message): "closed: \(message)"
        }
    }

    private static func findViews(in view: NSView, where match: (NSView) -> Bool) -> [NSView] {
        (match(view) ? [view] : []) + view.subviews.flatMap { findViews(in: $0, where: match) }
    }

    /// 调试界面布局用：列出窗口里所有 NSView 的类型、在窗口里的位置、是否隐藏
    private static func dumpViews(_ view: NSView, depth: Int, into lines: inout [String]) {
        let frame = view.convert(view.bounds, to: nil)
        let flags = (view.isHidden ? " hidden" : "") + (view.alphaValue < 1 ? " alpha=\(view.alphaValue)" : "")
        lines.append(String(repeating: "  ", count: depth)
            + "\(type(of: view)) (\(Int(frame.minX)),\(Int(frame.minY)) \(Int(frame.width))x\(Int(frame.height)))\(flags)")
        for subview in view.subviews {
            dumpViews(subview, depth: depth + 1, into: &lines)
        }
    }

    /// 离屏截图，不需要屏幕录制权限。终端内容（CoreGraphics 渲染）能稳定截到；
    /// SwiftUI 的部分有时截不到，会显示成透明/黑色，那是截图手段的限制。
    private static func renderPNG(_ view: NSView) -> Data? {
        view.window?.displayIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        repaintTerminals(in: view, onto: rep)
        return rep.representation(using: .png, properties: [:])
    }

    /// 终端的背景色画在图层上，离屏绘制画不出来（截图里是白底）。这里先填背景色再把文字叠上去，
    /// 分屏的暗化层也重新盖一遍，截图才和屏幕上看到的一样
    private static func repaintTerminals(in view: NSView, onto rep: NSBitmapImageRep) {
        let terminals = findViews(in: view) { $0 is TerminalView && !$0.isHiddenOrHasHiddenAncestor }.compactMap { $0 as? TerminalView }
        guard !terminals.isEmpty, let context = NSGraphicsContext(bitmapImageRep: rep) else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        defer { NSGraphicsContext.restoreGraphicsState() }
        // 位图的坐标原点在左下角
        func rectInRep(_ subview: NSView) -> NSRect {
            var rect = subview.convert(subview.bounds, to: view)
            if view.isFlipped { rect.origin.y = view.bounds.height - rect.maxY }
            return rect
        }
        for terminal in terminals {
            guard let content = terminal.bitmapImageRepForCachingDisplay(in: terminal.bounds) else { continue }
            terminal.cacheDisplay(in: terminal.bounds, to: content)
            let rect = rectInRep(terminal)
            terminal.nativeBackgroundColor.setFill()
            rect.fill()
            content.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
    }

    // MARK: 钥匙串自检

    private static func runKeychainSelfTest() -> String {
        guard keychainService != nil else { return "需要设置 CONCH_KEYCHAIN_SERVICE" }
        let key = SecretKey.password(user: "conch-selftest", host: "keychain.test", port: 22)
        let first = "selftest-\(UUID().uuidString)"
        guard Keychain.save(first, for: key) else { return "写入失败" }
        defer { Keychain.delete(key) }
        guard Keychain.exists(key) else { return "写入后查不到" }
        guard Keychain.load(key) == first else { return "读出来的内容不对" }
        let second = first + "-updated"
        guard Keychain.save(second, for: key), Keychain.load(key) == second else { return "更新失败" }
        Keychain.delete(key)
        guard !Keychain.exists(key) else { return "删除失败" }
        return "ok"
    }

    // MARK: 小工具

    /// "a=1;b=2" → [(a, 1), (b, 2)]。值里可以有 =，第一个 = 之前是键
    private static func parsePairs(_ text: String) -> [(String, String)] {
        text.components(separatedBy: ";").compactMap { item in
            guard let equals = item.firstIndex(of: "=") else { return nil }
            return (String(item[..<equals]).trimmingCharacters(in: .whitespaces), String(item[item.index(after: equals)...]))
        }
    }

    private static func secretKey(account: String) -> SecretKey? {
        if account.hasPrefix("password:") { return .password(endpoint: String(account.dropFirst(9))) }
        if account.hasPrefix("passphrase:") { return .passphrase(keyPath: String(account.dropFirst(11))) }
        return nil
    }

    static func unescape(_ text: String) -> String {
        text.replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\r", with: "\r")
            .replacingOccurrences(of: "\\t", with: "\t")
            .replacingOccurrences(of: "\\e", with: "\u{1b}")
    }
}
