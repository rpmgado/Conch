import AppKit
import ConchKit
import SwiftTerm

/// 测试脚本：按顺序做一串界面操作（像真的一样往事件队列里放鼠标点击、拖动、滚轮、按键），
/// 每个 state 步骤把当时的焦点、标签页、分屏结构、终端的渲染计数写一行 JSON。只在测试时用，
/// 用来复现“点了终端却不能输入”这类只有真实交互才会出现的问题，也用来测拖动分屏、滚动标签栏。
///
///   CONCH_TEST_SCRIPT='files;click:files;upload:/tmp/a.txt;click:terminal;keys:1234\r;state:done;quit'
///   CONCH_TEST_SCRIPT_LOG=/path/log.jsonl   state 步骤写到这里
///   CONCH_TEST_SCRIPT_DELAY=3                窗口出现几秒后开始（默认 3）
///
/// 点击、拖动、滚轮、按键之前会先确认 Conch 在前台（不在就拿回来），不然事件送不到。
///
/// 步骤（之间默认隔 0.8 秒）：
///   files / monitor / nopanel / local:on|off   打开文件面板、监控面板、关掉右侧面板、显示 / 隐藏本机文件
///   click:位置                        点一下；drag:位置>位置 按住拖过去；wheel:行数@位置 滚轮（正数往下）
///   rclick:位置 / ctrlclick:位置      右键点一下 / 按住 Control 点一下（都应该弹出右键菜单）
///   menupick:标题[>子菜单里的标题]    在弹出的菜单里选这一项；menuclose 关掉弹出的菜单
///   dclick:位置                       双击
///   hidden:local|remote:on|off        本机 / 服务器那一栏显示隐藏文件
///   sheetok / sheetcancel             按弹出的确认框的第一个按钮 / 取消
///   upload:/本机文件                  用文件面板上传到当前目录
///   sheet                             弹出再取消一个“打开”面板（上传按钮会弹的那种）
///   keys:文字                         模拟键盘按键（支持 \r \n \t）
///   send:文字                         直接交给终端（不经过键盘事件）
///   compose:current|all:文字          按撰写栏的选定范围提交命令
///   tab:N / newtab / split:h / split:v / equalize  选标签页、新建标签页、分屏、平均分配分屏大小
///   activate                          把 App 和窗口拿到前台
///   churn:N                           让窗口连着刷新 N 次，量每次多久（看界面卡不卡）
///   state:标记                        记录当前状态
///   wait:秒                           多等一会儿
///   quit                              退出
///
/// 位置：terminal（当前终端中间）、files / local（远端 / 本机文件列表中间）、tabbar[:first|plus]（标签栏中间、第一个标签、+ 按钮）、
///       header:N[:close|zoom]（当前标签页第 N 个分屏的标题栏，或上面的关闭、放大按钮）、pane:N[:left|right|top|bottom]（第 N 个分屏的中间或靠边处）、
///       divider:N（第 N 条分隔缝）、localrow:N / remoterow:N（本机 / 服务器那一栏的第 N 行）、sidebarrow:N（会话列表第 N 行）、above（终端区域上面一点，标签栏那一行）、X,Y（窗口坐标，左上角是原点）
enum TestScript {
    /// 最近一次模拟点击落在哪个视图上（和它的几层父视图）
    private static var lastHit = ""
    /// churn 步骤量到的：窗口每刷新一次平均花的毫秒数
    private static var churnMs: Double?
    /// 正在显示的菜单（右键菜单弹出来时记下，关掉后清空）和最近一次弹出的菜单的内容
    private static var openMenu: NSMenu?
    private static var lastMenu = ""
    private static var menuObservers: [NSObjectProtocol] = []
    private static var hitmap = ""

    private struct Line: Encodable {
        var step: String
        var firstResponder: String
        var terminalIsFirstResponder: Bool
        var keyWindow: Bool
        var appActive: Bool
        var metal: Bool
        var renderLoop: Bool
        var ticks: Int
        var frames: Int
        var renders: Int
        var tabs: Int
        var selectedTab: Int?
        /// 当前标签页的分屏结构，叶子是分屏 id 的前 4 位，如 H(ab12,V(cd34,ef56))
        var layout: String
        var focusedPane: Int?
        var zoomed: Bool
        var headers: [String]
        /// 当前标签页每个分屏终端的大小（宽×高）和左上角在终端区域里的位置（x,y），按分屏树的顺序
        var paneSizes: [String]
        var paneOrigins: [String]
        var tabStripOffset: Double?
        var tabStripOverflow: Bool?
        var bufferTail: [String]
        var extra: [String: String]
    }

    static func run(_ script: String, in workspace: WorkspaceModel, log: URL?, delay: Double) {
        let steps = script.components(separatedBy: ";").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if let log { try? Data().write(to: log) }
        // 记下弹出来的菜单：右键菜单是一个阻塞的跟踪循环，脚本的下一步会在它开着的时候执行
        let center = NotificationCenter.default
        menuObservers.append(center.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { note in
            guard let menu = note.object as? NSMenu, menu !== NSApp.mainMenu, menu.supermenu == nil else { return }
            openMenu = menu
            lastMenu = describe(menu)
        })
        menuObservers.append(center.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { note in
            if let menu = note.object as? NSMenu, menu === openMenu { openMenu = nil }
        })
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            perform(steps[...], workspace: workspace, log: log)
        }
    }

    /// 为了把 App 拿回前台已经等了几次
    private static var frontRetries = 0
    private static var auditResults: [String: String] = [:]

    private static func perform(_ steps: ArraySlice<String>, workspace: WorkspaceModel, log: URL?) {
        guard let step = steps.first else { return }
        var pause = 0.8
        let (name, argument) = split(step)
        let window = workspace.window
        // 鼠标、键盘事件只有窗口在前台才会照常送到：测试中途别的 App 跑到前面了，先拿回来再做这一步
        if ["click", "dclick", "rclick", "ctrlclick", "drag", "wheel", "keys"].contains(name), let window,
           !(NSApp.isActive && window.isKeyWindow), frontRetries < 10 {
            frontRetries += 1
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                perform(steps, workspace: workspace, log: log)
            }
            return
        }
        frontRetries = 0
        switch name {
        case "files": workspace.showFilesPanel = true
        case "monitor": workspace.showMonitor = true
        case "nopanel": workspace.sidePanel = nil
        case "local": workspace.showLocalFiles = argument != "off"
        case "activate":
            NSApp.activate(ignoringOtherApps: true)
            window?.makeKeyAndOrderFront(nil)
        case "click", "dclick":
            if let window, let point = locate(argument, in: workspace, window: window) {
                noteHit(at: point, in: window)
                post([(.leftMouseDown, point), (.leftMouseUp, point)], in: window)
                if name == "dclick" { post([(.leftMouseDown, point), (.leftMouseUp, point)], in: window, clickCount: 2) }
            }
        case "rclick", "ctrlclick":
            if let window, let point = locate(argument, in: workspace, window: window) {
                noteHit(at: point, in: window)
                lastMenu = ""
                if name == "rclick" {
                    post([(.rightMouseDown, point), (.rightMouseUp, point)], in: window)
                } else {
                    post([(.leftMouseDown, point), (.leftMouseUp, point)], in: window, modifiers: .control)
                }
                pause = 1
            }
        case "menupick":
            // 先关掉菜单（结束跟踪循环），再像用户选中那一项一样执行它
            let path = argument.components(separatedBy: ">")
            if let menu = openMenu, let item = findItem(path, in: menu), let owner = item.menu {
                let index = owner.index(of: item)
                menu.cancelTracking()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    if item.isEnabled { owner.performActionForItem(at: index) }
                }
                pause = 1
            } else {
                NSLog("Conch 测试脚本：菜单里没有 \(argument)（\(lastMenu)）")
                openMenu?.cancelTracking()
            }
        case "menuclose":
            openMenu?.cancelTracking()
        case "deactivate":
            NSApp.deactivate()
        case "hitmap":
            // 调试用：窗口顶上那一行（离顶边 4～52 点）每隔 30 点点到的是哪个视图，写进下一个 state 的 hitmap
            if let window, let root = window.contentView?.superview {
                let height = window.contentView?.bounds.height ?? 0
                var rows: [String] = []
                for top in stride(from: 4.0, through: 52.0, by: 8.0) {
                    var row = "y\(Int(top)):"
                    for x in stride(from: 0.0, to: Double(window.frame.width), by: 30.0) {
                        let name = root.hitTest(NSPoint(x: x, y: height - top)).map { String(describing: Swift.type(of: $0)) } ?? "nil"
                        row += name.hasPrefix("NSToolbar") || name.hasPrefix("NSTitlebar") || name.hasPrefix("_NSTitlebar") ? "T"
                            : name.hasPrefix("NSButton") || name.contains("Button") ? "B" : "."
                    }
                    rows.append(row)
                }
                hitmap = rows.joined(separator: "\n")
            }
        case "hidden":
            // hidden:local:on / hidden:remote:off
            let parts = argument.components(separatedBy: ":")
            let on = parts.last == "on"
            if parts.first == "local" { workspace.localFiles.showHidden = on } else { workspace.activeSession?.files.showHidden = on }
        case "sheetcancel":
            if let window = workspace.fileDialogWindow, let sheet = window.attachedSheet { window.endSheet(sheet, returnCode: .alertSecondButtonReturn) }
        case "sheetok":
            if let window = workspace.fileDialogWindow, let sheet = window.attachedSheet { window.endSheet(sheet, returnCode: .alertFirstButtonReturn) }
        case "drag":
            let ends = argument.components(separatedBy: ">")
            if let window, ends.count == 2,
               let from = locate(ends[0], in: workspace, window: window),
               let to = locate(ends[1], in: workspace, window: window) {
                noteHit(at: from, in: window)
                var events: [(NSEvent.EventType, NSPoint)] = [(.leftMouseDown, from)]
                for step in 1...8 {
                    let t = CGFloat(step) / 8
                    events.append((.leftMouseDragged, NSPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t)))
                }
                events.append((.leftMouseUp, to))
                post(events, in: window)
                pause = 1.2
            }
        case "wheel":
            let parts = argument.components(separatedBy: "@")
            if let window, let lines = Int32(parts[0]), parts.count == 2,
               let point = locate(parts[1], in: workspace, window: window) {
                wheel(lines: lines, at: point, in: window)
            }
        case "uploadconfirm":
            if let tab = workspace.activeSession {
                SftpPanel(browser: tab.files, local: workspace.localFiles, tab: tab, workspace: workspace,
                          showLocal: true, expanded: workspace.expandedFiles).upload([URL(fileURLWithPath: argument)])
            }
        case "expandfiles": workspace.expandedFiles = true
        case "collapsefiles": workspace.expandedFiles = false
        case "uploadto":
            let parts = argument.components(separatedBy: ">")
            if parts.count == 2 { workspace.activeSession?.files.upload([URL(fileURLWithPath: parts[0])], to: parts[1]) }
        case "downloadto":
            let parts = argument.components(separatedBy: ">")
            if parts.count == 2, let browser = workspace.activeSession?.files, let file = browser.entry(parts[0]) {
                browser.download([file], to: URL(fileURLWithPath: parts[1]))
            }
        case "dropcheck":
            if let browser = workspace.activeSession?.files, let file = browser.entries.first(where: { !$0.isDir }) {
                let payload = RemoteFilesDrag(sourceID: browser.transferSourceID, paths: [file.path])
                auditResults["sameConnectionDrop"] = String(browser.filesForDrop([payload])?.count == 1)
                let foreign = RemoteFilesDrag(sourceID: UUID(), paths: [file.path])
                auditResults["foreignDropRejected"] = String(browser.filesForDrop([foreign]) == nil)
                auditResults["dropMessage"] = browser.message ?? ""
                browser.connectionEnded()
                auditResults["staleDropRejected"] = String(browser.filesForDrop([payload]) == nil && browser.transferSourceID != payload.sourceID)
                browser.open()
            }
        case "upload":
            workspace.activeSession?.files.upload([URL(fileURLWithPath: argument)])
        case "sheet":
            if let window {
                let panel = NSOpenPanel()
                panel.beginSheetModal(for: window) { _ in }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { window.endSheet(panel, returnCode: .cancel) }
                pause = 2
            }
        case "keys":
            if let window { type(TestHooks.unescape(argument), in: window) }
        case "send":
            workspace.activeSession?.terminalView.send(txt: TestHooks.unescape(argument))
        case "compose":
            let (scope, command) = split(argument)
            if ["current", "all"].contains(scope), !command.isEmpty {
                let model = ComposeModel()
                model.toAll = scope == "all"
                model.send(TestHooks.unescape(command) + "\r", in: workspace)
            }
        case "tab":
            workspace.select(index: Int(argument) ?? 0)
            workspace.focusTerminalSoon()
        case "newtab": workspace.newTab()
        case "split": workspace.splitActive(argument == "v" ? .vertical : .horizontal)
        case "equalize": workspace.equalizePanes()
        case "churn":
            // 模拟终端频繁变化（标题、状态）：让窗口连着刷新 N 次，量平均每次花多久（下一个 state 里看 churnMs）
            let count = Int(argument) ?? 200
            var fired = 0
            let start = CFAbsoluteTimeGetCurrent()
            let timer = Timer(timeInterval: 0.001, repeats: true) { timer in
                fired += 1
                workspace.objectWillChange.send()
                if fired >= count {
                    timer.invalidate()
                    churnMs = (CFAbsoluteTimeGetCurrent() - start) * 1000 / Double(count)
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            pause = 0.5 + Double(count) * 0.02
        case "state": record(argument, workspace: workspace, log: log)
        case "wait": pause = Double(argument) ?? 1
        case "quit":
            DispatchQueue.main.async { NSApp.terminate(nil) }
            return
        default:
            NSLog("Conch 测试脚本：不认识的步骤 \(step)")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + pause) {
            perform(steps.dropFirst(), workspace: workspace, log: log)
        }
    }

    private static func split(_ step: String) -> (String, String) {
        guard let colon = step.firstIndex(of: ":") else { return (step, "") }
        return (String(step[..<colon]), String(step[step.index(after: colon)...]))
    }

    // MARK: 位置

    /// 把位置名换成窗口坐标（左下角是原点，和 NSEvent 一样）
    private static func locate(_ target: String, in workspace: WorkspaceModel, window: NSWindow) -> NSPoint? {
        guard let root = window.contentView?.superview ?? window.contentView else { return nil }
        let center = { (view: NSView) in view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil) }
        let deck = views(in: root) { $0 is DeckView }.first as? DeckView
        let parts = target.components(separatedBy: ":")
        let sessions = workspace.currentTab?.sessions ?? []
        switch parts[0] {
        case "terminal":
            return workspace.activeSession.map { center($0.terminalView) }
        case "files", "local":
            // 右侧面板里的文件列表：远端在上面，本机在下面（窗口坐标 y 大的在上面）
            let tables = views(in: root) { $0 is NSTableView && !$0.isHiddenOrHasHiddenAncestor }
                .filter { $0.convert($0.bounds, to: nil).minX > window.frame.width / 2 }
                .sorted { $0.convert($0.bounds, to: nil).minY > $1.convert($1.bounds, to: nil).minY }
            let table = parts[0] == "files" ? tables.first : (tables.count > 1 ? tables.last : nil)
            return table.flatMap { $0.enclosingScrollView ?? $0 }.map(center)
        case "localrow", "remoterow":
            // 本机 / 服务器那一栏的第 N 行
            let tables = views(in: root) { $0 is NSTableView && !$0.isHiddenOrHasHiddenAncestor }
                .filter { $0.convert($0.bounds, to: nil).minX > window.frame.width / 2 }
                .sorted { $0.convert($0.bounds, to: nil).minY > $1.convert($1.bounds, to: nil).minY }
            guard let table = (parts[0] == "remoterow" ? tables.first : (tables.count > 1 ? tables.last : nil)) as? NSTableView,
                  let row = parts.count > 1 ? Int(parts[1]) : nil, row < table.numberOfRows else { return nil }
            let rect = table.rect(ofRow: row)
            return table.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
        case "sidebarrow":
            // 会话列表（窗口左边那个列表）的第 N 行
            let tables = views(in: root) { $0 is NSTableView && !$0.isHiddenOrHasHiddenAncestor }
                .filter { $0.convert($0.bounds, to: nil).maxX < window.frame.width / 3 }
            guard let table = tables.first as? NSTableView, let row = parts.count > 1 ? Int(parts[1]) : nil,
                  row < table.numberOfRows else { return nil }
            let rect = table.rect(ofRow: row)
            return table.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
        case "tabbar":
            // tabbar：标签栏中间；tabbar:first 第一个标签上；tabbar:plus 右边的 + 按钮
            guard let strip = tabStrip(in: root) else { return nil }
            let frame = strip.convert(strip.bounds, to: nil)
            switch parts.count > 1 ? parts[1] : "" {
            case "first": return NSPoint(x: frame.minX + 30, y: frame.midY)
            case "plus": return NSPoint(x: frame.maxX + 20, y: frame.midY)
            default: return NSPoint(x: frame.midX, y: frame.midY)
            }
        case "above":
            guard let deck else { return nil }
            return deck.convert(NSPoint(x: deck.bounds.midX, y: -24), to: nil)
        case "header":
            guard let index = parts.count > 1 ? Int(parts[1]) : nil, sessions.indices.contains(index) else { return nil }
            let header = views(in: root) { ($0 as? PaneHeaderView)?.session === sessions[index] && !$0.isHidden }.first
            guard let header else { return nil }
            // 默认点标题文字那一块（避开右边的按钮）；close / zoom 点右边的关闭、放大按钮
            let x: CGFloat = switch parts.count > 2 ? parts[2] : "" {
            case "close": header.bounds.maxX - 12
            case "zoom": header.bounds.maxX - 34
            default: header.bounds.midX - 30
            }
            return header.convert(NSPoint(x: x, y: header.bounds.midY), to: nil)
        case "pane":
            guard let index = parts.count > 1 ? Int(parts[1]) : nil, sessions.indices.contains(index) else { return nil }
            let view = sessions[index].terminalView
            let b = view.bounds
            let local: NSPoint = switch parts.count > 2 ? parts[2] : "" {
            case "left": NSPoint(x: b.minX + b.width * 0.1, y: b.midY)
            case "right": NSPoint(x: b.maxX - b.width * 0.1, y: b.midY)
            case "top": NSPoint(x: b.midX, y: view.isFlipped ? b.minY + b.height * 0.1 : b.maxY - b.height * 0.1)
            case "bottom": NSPoint(x: b.midX, y: view.isFlipped ? b.maxY - b.height * 0.1 : b.minY + b.height * 0.1)
            default: NSPoint(x: b.midX, y: b.midY)
            }
            return view.convert(local, to: nil)
        case "divider":
            guard let deck, let index = parts.count > 1 ? Int(parts[1]) : nil,
                  deck.dividerRectsForTesting.indices.contains(index) else { return nil }
            let rect = deck.dividerRectsForTesting[index]
            return deck.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
        default:
            let numbers = target.split(separator: ",").compactMap { Double($0) }
            guard numbers.count == 2 else { return nil }
            return NSPoint(x: numbers[0], y: (window.contentView?.bounds.height ?? 0) - numbers[1])
        }
    }

    private static func tabStrip(in root: NSView) -> NSScrollView? {
        views(in: root) { $0 is NSScrollView && $0.frame.height <= 40 && !$0.isHiddenOrHasHiddenAncestor }.first as? NSScrollView
    }

    private static func noteHit(at point: NSPoint, in window: NSWindow) {
        guard let root = window.contentView?.superview, let hit = root.hitTest(point) else { return }
        var chain: [String] = []
        var current: NSView? = hit
        while let view = current, chain.count < 4 {
            chain.append(String(describing: Swift.type(of: view)))
            current = view.superview
        }
        lastHit = chain.joined(separator: " < ")
    }

    // MARK: 鼠标和键盘事件

    private static func post(_ events: [(NSEvent.EventType, NSPoint)], in window: NSWindow, clickCount: Int = 1,
                             modifiers: NSEvent.ModifierFlags = []) {
        var time = ProcessInfo.processInfo.systemUptime
        for (type, point) in events {
            let pressure: Float = type == .leftMouseUp || type == .rightMouseUp ? 0 : 1
            if let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: modifiers, timestamp: time,
                                              windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                              clickCount: clickCount, pressure: pressure) {
                NSApp.postEvent(event, atStart: false)
            }
            time += 0.016
        }
    }

    private static func wheel(lines: Int32, at point: NSPoint, in window: NSWindow) {
        // CGEvent 的坐标是全局的、左上角为原点
        let screenPoint = window.convertPoint(toScreen: point)
        let height = NSScreen.screens.first?.frame.height ?? 0
        guard let cgEvent = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: -lines, wheel2: 0, wheel3: 0)
        else { return }
        cgEvent.location = CGPoint(x: screenPoint.x, y: height - screenPoint.y)
        if let event = NSEvent(cgEvent: cgEvent) {
            NSApp.postEvent(event, atStart: false)
        }
    }

    /// 美式键盘上字符对应的按键编号（输入法要看按键编号）
    private static let keyCodes: [Character: UInt16] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12,
        "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23,
        "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34,
        "p": 35, "\r": 36, "\n": 36, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44,
        "n": 45, "m": 46, ".": 47, "\t": 48, " ": 49, "`": 50,
    ]

    private static func type(_ text: String, in window: NSWindow) {
        var time = ProcessInfo.processInfo.systemUptime
        for character in text {
            let lower = Character(character.lowercased())
            let code = keyCodes[lower] ?? 0
            let chars = character == "\n" ? "\r" : String(character)
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                if let event = NSEvent.keyEvent(with: type, location: .zero,
                                                modifierFlags: character.isUppercase ? .shift : [],
                                                timestamp: time, windowNumber: window.windowNumber, context: nil,
                                                characters: chars, charactersIgnoringModifiers: String(lower),
                                                isARepeat: false, keyCode: code) {
                    NSApp.postEvent(event, atStart: false)
                }
                time += 0.01
            }
        }
    }

    // MARK: 记录

    private static func record(_ label: String, workspace: WorkspaceModel, log: URL?) {
        guard let log else { return }
        let window = workspace.window
        let root = window?.contentView?.superview
        let terminal = workspace.activeSession?.terminalView
        let diagnostics = terminal?.diagnostics
        let text = terminal.flatMap { String(data: $0.getBufferAsData(), encoding: .utf8) } ?? ""
        let tail = text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.suffix(3)
        var extra = auditResults
        if let source = NSTextInputContext.current?.selectedKeyboardInputSource { extra["inputSource"] = source }
        if !lastHit.isEmpty { extra["hit"] = lastHit }
        if let churnMs { extra["churnMs"] = String(format: "%.2f", churnMs) }
        if !lastMenu.isEmpty { extra["menu"] = lastMenu }
        if !hitmap.isEmpty { extra["hitmap"] = hitmap }
        extra["menuOpen"] = openMenu == nil ? "no" : "yes"
        if let terminal { extra["selection"] = terminal.getSelection() ?? "" }
        extra["broadcast"] = workspace.broadcastInput ? "on" : "off"
        extra["sidePanel"] = workspace.sidePanel?.rawValue ?? "none"
        extra["compose"] = workspace.showComposeBar ? "on" : "off"
        extra["find"] = workspace.find.visible ? "on" : "off"
        if let session = workspace.activeSession {
            extra["phase"] = "\(session.phase)"
            extra["logging"] = session.logURL == nil ? "off" : "on"
        }
        extra["pasteboard"] = NSPasteboard.general.string(forType: .string) ?? ""
        if let sheet = window?.attachedSheet, let content = sheet.contentView {
            let texts = views(in: content) { ($0 as? NSTextField)?.isEditable == false }.compactMap { ($0 as? NSTextField)?.stringValue }
            extra["sheet"] = texts.filter { !$0.isEmpty }.joined(separator: " | ")
        }
        if let sheet = window?.attachedSheet?.attachedSheet, let content = sheet.contentView {
            extra["nestedSheet"] = views(in: content) { ($0 as? NSTextField)?.isEditable == false }
                .compactMap { ($0 as? NSTextField)?.stringValue }.joined(separator: " | ")
        }
        if let session = workspace.activeSession, session.isSSH, workspace.showFilesPanel {
            let files = session.files
            extra["remote"] = "\(files.status) \(files.path) [\(files.visibleEntries.map(\.name).joined(separator: ","))]"
            extra["transfers"] = files.transfers.map { "\($0.name):\($0.state)" }.joined(separator: ",")
            let local = workspace.localFiles
            extra["local"] = "\(local.directory.path) hidden=\(local.showHidden) [\(local.visibleEntries.map(\.name).joined(separator: ","))]"
        }
        let tab = workspace.currentTab
        let sessions = tab?.sessions ?? []
        let strip = root.flatMap(tabStrip(in:))
        let line = Line(
            step: label,
            firstResponder: window?.firstResponder.map { String(describing: Swift.type(of: $0)) } ?? "nil",
            terminalIsFirstResponder: terminal != nil && window?.firstResponder === terminal,
            keyWindow: window?.isKeyWindow ?? false,
            appActive: NSApp.isActive,
            metal: terminal?.isUsingMetalRenderer ?? false,
            renderLoop: terminal?.isUsingRenderLoop ?? false,
            ticks: diagnostics?.ticks ?? 0,
            frames: diagnostics?.frames ?? 0,
            renders: diagnostics?.renders ?? 0,
            tabs: workspace.tabs.count,
            selectedTab: workspace.tabs.firstIndex { $0.id == workspace.selectedTabID },
            layout: tab?.root.describe(label: { String($0.id.uuidString.prefix(4)) }) ?? "",
            focusedPane: sessions.firstIndex { $0.id == tab?.focusedID },
            zoomed: tab?.zoomedID != nil,
            headers: root.map { views(in: $0) { $0 is PaneHeaderView && !$0.isHidden }.compactMap { ($0 as? PaneHeaderView)?.title } } ?? [],
            paneSizes: sessions.map { $0.terminalView.isHidden ? "hidden" : "\(Int($0.terminalView.frame.width))x\(Int($0.terminalView.frame.height))" },
            paneOrigins: sessions.map { $0.terminalView.isHidden ? "hidden" : "\(Int($0.terminalView.frame.minX)),\(Int($0.terminalView.frame.minY))" },
            tabStripOffset: strip.map { Double($0.contentView.bounds.minX) },
            tabStripOverflow: strip.map { ($0.documentView?.frame.width ?? 0) > $0.contentView.bounds.width + 1 },
            bufferTail: Array(tail),
            extra: extra
        )
        guard var data = try? JSONEncoder().encode(line) else { return }
        data.append(0x0A)
        if let handle = try? FileHandle(forWritingTo: log) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        }
    }

    /// 菜单的内容：每项一个标题，灰掉的加 (×)，有子菜单的列出子菜单，分隔线写成 —
    private static func describe(_ menu: NSMenu) -> String {
        menu.items.map { item in
            if item.isSeparatorItem { return "—" }
            var text = item.title + (item.isEnabled ? "" : "(×)") + (item.state == .on ? "(✓)" : "")
            if let submenu = item.submenu { text += "{" + describe(submenu) + "}" }
            return text
        }.joined(separator: "|")
    }

    private static func findItem(_ path: [String], in menu: NSMenu) -> NSMenuItem? {
        guard let first = path.first, let item = menu.items.first(where: { $0.title == first }) else { return nil }
        if path.count == 1 { return item }
        return item.submenu.flatMap { findItem(Array(path.dropFirst()), in: $0) }
    }

    private static func views(in view: NSView, where match: (NSView) -> Bool) -> [NSView] {
        (match(view) ? [view] : []) + view.subviews.flatMap { views(in: $0, where: match) }
    }
}
