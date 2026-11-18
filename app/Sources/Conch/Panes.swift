import AppKit
import Combine
import SwiftTerm

/// 分屏方向
enum PaneAxis: String {
    /// 左右并排
    case horizontal
    /// 上下排列
    case vertical
}

/// 把分屏拖到另一个分屏的哪一边
enum PaneEdge {
    case left, right, top, bottom

    var axis: PaneAxis { self == .left || self == .right ? .horizontal : .vertical }
    /// 放在目标的前面（左边、上面）
    var isLeading: Bool { self == .left || self == .top }

    var title: String {
        switch self {
        case .left: "放在左边"
        case .right: "放在右边"
        case .top: "放在上面"
        case .bottom: "放在下面"
        }
    }
}

/// 分屏树里的中间节点：把一块区域按比例分给几个子节点。
/// 是引用类型，拖动分隔线时终端区域直接改比例，不用经过 SwiftUI
final class PaneSplit {
    var axis: PaneAxis
    var children: [PaneItem]
    /// 每个子节点占的比例，加起来是 1
    var fractions: [CGFloat]

    init(axis: PaneAxis, children: [PaneItem], fractions: [CGFloat]? = nil) {
        self.axis = axis
        self.children = children
        self.fractions = fractions ?? Array(repeating: 1 / CGFloat(children.count), count: children.count)
    }
}

/// 分屏树的节点：叶子是一个终端
enum PaneItem {
    case leaf(TerminalSession)
    case split(PaneSplit)

    /// 从左到右、从上到下的顺序
    var sessions: [TerminalSession] {
        switch self {
        case .leaf(let session): [session]
        case .split(let split): split.children.flatMap(\.sessions)
        }
    }

    /// 测试和调试用的文字形式，如 H(0,V(1,2))
    func describe(indexOf: (TerminalSession) -> Int) -> String {
        describe(label: { String(indexOf($0)) })
    }

    /// 分屏树的完整样子：每个分屏是谁、每一层的比例。终端区域靠它判断要不要重新排版
    /// （换位置、平均分配这些操作分屏的个数和顺序编号都不变，只看编号会漏掉）
    var layoutKey: String {
        switch self {
        case .leaf(let session):
            return String(session.id.uuidString.prefix(8))
        case .split(let split):
            let ratios = split.fractions.map { String(format: "%.3f", $0) }.joined(separator: "/")
            return (split.axis == .horizontal ? "H[" : "V[") + ratios + "](" + split.children.map(\.layoutKey).joined(separator: ",") + ")"
        }
    }

    func describe(label: (TerminalSession) -> String) -> String {
        switch self {
        case .leaf(let session):
            return label(session)
        case .split(let split):
            let inner = split.children.map { $0.describe(label: label) }.joined(separator: ",")
            return (split.axis == .horizontal ? "H(" : "V(") + inner + ")"
        }
    }
}

/// 标签栏上的一个标签页：一个终端，或者分屏后的几个终端
final class WorkspaceTab: ObservableObject, Identifiable {
    let id = UUID()
    @Published private(set) var root: PaneItem
    /// 获得焦点的终端（键盘输入、状态栏、文件面板、菜单命令都对它）
    @Published private(set) var focusedID: UUID
    /// 放大显示的分屏，其他分屏暂时藏起来
    @Published var zoomedID: UUID?
    /// 用户给标签页起的名字（右键“重命名标签页”）；nil 时显示会话名
    @Published var customTitle: String?
    private var subscriptions: [AnyCancellable] = []
    private var forward: AnyCancellable?

    init(session: TerminalSession, workspace: WorkspaceModel?) {
        root = .leaf(session)
        focusedID = session.id
        // 标签页和里面任何一个终端的变化都让窗口刷新（标签栏、状态栏）
        forward = objectWillChange.sink { [weak workspace] _ in workspace?.objectWillChange.send() }
        observeSessions()
    }

    var sessions: [TerminalSession] { root.sessions }

    var focused: TerminalSession {
        let all = sessions
        return all.first { $0.id == focusedID } ?? all[0]
    }

    var isSplit: Bool {
        if case .split = root { return true }
        return false
    }

    /// 标签栏上显示的名字
    var title: String { customTitle ?? focused.tabTitle }

    func contains(_ session: TerminalSession) -> Bool {
        sessions.contains { $0 === session }
    }

    /// 这个终端现在是否显示（放大别的分屏时不显示）
    func isShowing(_ session: TerminalSession) -> Bool {
        zoomedID == nil || zoomedID == session.id
    }

    var hasUnseenOutput: Bool {
        sessions.contains(where: \.hasUnseenOutput)
    }

    func focus(_ session: TerminalSession) {
        guard focusedID != session.id, contains(session) else { return }
        focusedID = session.id
    }

    /// 把 target 一分为二，新终端放在右边（左右分屏）或下面（上下分屏）
    func split(_ target: TerminalSession, axis: PaneAxis, with newSession: TerminalSession) {
        objectWillChange.send()
        zoomedID = nil
        root = Self.inserting(newSession, beside: target, axis: axis, before: false, in: root)
        observeSessions()
    }

    /// 把一个分屏挪到 target 的某一边（target 原来那块对半分）
    @discardableResult
    func move(_ session: TerminalSession, beside target: TerminalSession, edge: PaneEdge) -> Bool {
        guard session !== target, contains(session), contains(target),
              let remaining = Self.removing(session, from: root)
        else { return false }
        objectWillChange.send()
        zoomedID = nil
        root = Self.inserting(session, beside: target, axis: edge.axis, before: edge.isLeading, in: remaining)
        observeSessions()
        return true
    }

    /// 两个分屏互换位置（各自的大小不变）
    func swap(_ first: TerminalSession, _ second: TerminalSession) {
        guard first !== second, contains(first), contains(second) else { return }
        objectWillChange.send()
        root = Self.mapLeaves(root) { $0 === first ? second : $0 === second ? first : $0 }
    }

    /// 拿掉一个分屏。标签页里只剩它一个时不处理，返回 false
    @discardableResult
    func remove(_ target: TerminalSession) -> Bool {
        let before = sessions
        guard before.count > 1, let index = before.firstIndex(where: { $0 === target }),
              let newRoot = Self.removing(target, from: root)
        else { return false }
        objectWillChange.send()
        root = newRoot
        if zoomedID == target.id { zoomedID = nil }
        if focusedID == target.id {
            // 焦点给排在它前面的那个（它是第一个时给后面的）
            let after = sessions
            focusedID = after[max(0, min(index - 1, after.count - 1))].id
        }
        observeSessions()
        return true
    }

    /// 所有分屏一样大
    func equalize() {
        objectWillChange.send()
        Self.equalize(root)
    }

    private static func equalize(_ item: PaneItem) {
        guard case .split(let split) = item else { return }
        split.fractions = Array(repeating: 1 / CGFloat(split.children.count), count: split.children.count)
        split.children.forEach(equalize)
    }

    /// 在 target 旁边放 newSession：before 为 true 时放在左边（上面），否则放在右边（下面）
    private static func inserting(_ newSession: TerminalSession, beside target: TerminalSession, axis: PaneAxis,
                                  before: Bool, in item: PaneItem) -> PaneItem {
        switch item {
        case .leaf(let session):
            guard session === target else { return item }
            let pair: [PaneItem] = before ? [.leaf(newSession), .leaf(session)] : [.leaf(session), .leaf(newSession)]
            return .split(PaneSplit(axis: axis, children: pair))
        case .split(let split):
            // 同方向拆分：在它旁边插一个，把它原来那块对半分
            if split.axis == axis, let index = split.children.firstIndex(where: {
                if case .leaf(let session) = $0 { return session === target }
                return false
            }) {
                let half = split.fractions[index] / 2
                split.fractions[index] = half
                let position = before ? index : index + 1
                split.children.insert(.leaf(newSession), at: position)
                split.fractions.insert(half, at: position)
                return item
            }
            split.children = split.children.map { inserting(newSession, beside: target, axis: axis, before: before, in: $0) }
            return item
        }
    }

    private static func mapLeaves(_ item: PaneItem, _ transform: (TerminalSession) -> TerminalSession) -> PaneItem {
        switch item {
        case .leaf(let session):
            return .leaf(transform(session))
        case .split(let split):
            split.children = split.children.map { mapLeaves($0, transform) }
            return item
        }
    }

    private static func removing(_ target: TerminalSession, from item: PaneItem) -> PaneItem? {
        switch item {
        case .leaf(let session):
            return session === target ? nil : item
        case .split(let split):
            var children: [PaneItem] = []
            var fractions: [CGFloat] = []
            for (child, fraction) in zip(split.children, split.fractions) {
                guard let kept = removing(target, from: child) else { continue }
                // 只剩一个孩子的同方向分屏并进来，免得嵌套越来越深
                if case .split(let inner) = kept, inner.axis == split.axis {
                    children.append(contentsOf: inner.children)
                    fractions.append(contentsOf: inner.fractions.map { $0 * fraction })
                } else {
                    children.append(kept)
                    fractions.append(fraction)
                }
            }
            if children.isEmpty { return nil }
            if children.count == 1 { return children[0] }
            let total = fractions.reduce(0, +)
            split.children = children
            split.fractions = fractions.map { $0 / max(total, 0.0001) }
            return .split(split)
        }
    }

    private func observeSessions() {
        subscriptions = sessions.map { session in
            session.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        }
    }
}

/// 一个标签页里各个分屏的位置，和分屏之间的分隔线
struct PaneLayout {
    struct Divider {
        let split: PaneSplit
        /// 第 index 个和第 index + 1 个子节点之间
        let index: Int
        let rect: NSRect
        /// 这个分屏节点占的整块区域
        let container: NSRect
    }

    /// 分屏卡片之间的缝（可以拖动）
    static let gap: CGFloat = 8
    /// 拖分隔线时，每个分屏至少留这么大
    static let minimumSize: CGFloat = 80

    private(set) var frames: [(session: TerminalSession, frame: NSRect)] = []
    private(set) var dividers: [Divider] = []

    init(_ root: PaneItem, in rect: NSRect) {
        place(root, in: rect)
    }

    private mutating func place(_ item: PaneItem, in rect: NSRect) {
        switch item {
        case .leaf(let session):
            frames.append((session, rect))
        case .split(let split):
            let horizontal = split.axis == .horizontal
            let count = split.children.count
            let length = horizontal ? rect.width : rect.height
            let available = max(0, length - Self.gap * CGFloat(count - 1))
            var offset = horizontal ? rect.minX : rect.minY
            let end = horizontal ? rect.maxX : rect.maxY
            for (index, child) in split.children.enumerated() {
                let isLast = index == count - 1
                // 最后一个拿剩下的，免得四舍五入累积出缝
                let size = isLast ? max(0, end - offset) : (available * split.fractions[index]).rounded()
                let childRect = horizontal
                    ? NSRect(x: offset, y: rect.minY, width: size, height: rect.height)
                    : NSRect(x: rect.minX, y: offset, width: rect.width, height: size)
                place(child, in: childRect)
                offset += size
                if !isLast {
                    let dividerRect = horizontal
                        ? NSRect(x: offset, y: rect.minY, width: Self.gap, height: rect.height)
                        : NSRect(x: rect.minX, y: offset, width: rect.width, height: Self.gap)
                    dividers.append(Divider(split: split, index: index, rect: dividerRect, container: rect))
                    offset += Self.gap
                }
            }
        }
    }

    /// 把分隔线拖到 position（沿分屏方向的坐标）后，更新两边的比例
    static func drag(_ divider: Divider, to position: CGFloat) {
        let split = divider.split
        let horizontal = split.axis == .horizontal
        let count = split.children.count
        let length = horizontal ? divider.container.width : divider.container.height
        let available = max(1, length - gap * CGFloat(count - 1))
        let start = (horizontal ? divider.container.minX : divider.container.minY)
            + available * split.fractions[..<divider.index].reduce(0, +) + gap * CGFloat(divider.index)
        let pair = split.fractions[divider.index] + split.fractions[divider.index + 1]
        let pairSize = pair * available
        let minimum = min(minimumSize, pairSize / 2)
        let size = min(max(position - start - gap / 2, minimum), pairSize - minimum)
        split.fractions[divider.index] = size / available
        split.fractions[divider.index + 1] = pair - size / available
    }
}

/// 终端视图：点一下就把焦点（键盘输入、状态栏）切到这个分屏
final class ConchTerminalView: TerminalView {
    var onActivate: (() -> Void)?
    /// 右键菜单（拷贝粘贴、分屏操作），由 TerminalSession 提供
    var contextMenuProvider: (() -> NSMenu?)?

    override func mouseDown(with event: NSEvent) {
        activate()
        // Control + 点击和右键一样弹出菜单（Mac 的习惯），不交给终端
        if event.isContextClick, let menu = menu(for: event) {
            NSMenu.popUpContextMenu(menu, with: event, for: self)
            return
        }
        super.mouseDown(with: event)
    }

    /// 右键：先拿到焦点；远端程序开了鼠标模式（vim、tmux）时右键交给它，按住 Shift 右键才弹菜单
    override func rightMouseDown(with event: NSEvent) {
        activate()
        super.rightMouseDown(with: event)
    }

    override func otherMouseDown(with event: NSEvent) {
        activate()
        super.otherMouseDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        contextMenuProvider?() ?? super.menu(for: event)
    }

    /// 用 GPU 绘制时，鼠标点到的是盖在终端上面的绘图视图，它不接收键盘焦点，
    /// 窗口也就不会把焦点从别处（文件列表、会话列表、输入框）交给终端。这里自己要回来
    private func activate() {
        onActivate?()
        if let window, window.firstResponder !== self {
            window.makeFirstResponder(self)
        }
    }
}

extension NSEvent {
    /// Control + 左键点击：Mac 上和右键一样，用来弹出右键菜单
    var isContextClick: Bool {
        type == .leftMouseDown && modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting(.capsLock) == .control
    }
}

/// 带闭包的菜单项（右键菜单用）
final class ActionMenuItem: NSMenuItem {
    private let handler: @MainActor () -> Void

    init(_ title: String, key: String = "", modifiers: NSEvent.ModifierFlags = .command, enabled: Bool = true,
         checked: Bool = false, help: String? = nil, handler: @escaping @MainActor () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: key)
        keyEquivalentModifierMask = modifiers
        target = self
        isEnabled = enabled
        state = checked ? .on : .off
        toolTip = help
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError() }

    @MainActor @objc private func run() { handler() }
}

/// 分屏时每个终端上面的小标题栏：状态点、会话名、放大、关闭。按住标题拖动可以换位置、拖到标签栏变成新标签页。
/// 鼠标事件交给 DeckView 处理
final class PaneHeaderView: NSView {
    static let height: CGFloat = 24

    weak var session: TerminalSession?
    weak var deck: DeckView?
    private let dot = NSView()
    private let label = NSTextField(labelWithString: "")
    private let zoomButton = NSButton()
    private let closeButton = NSButton()
    private var zoomed = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 3.5
        label.font = .systemFont(ofSize: 11.5, weight: .medium)
        label.lineBreakMode = .byTruncatingMiddle
        label.maximumNumberOfLines = 1
        label.cell?.usesSingleLineMode = true
        for button in [zoomButton, closeButton] {
            button.isBordered = false
            button.imagePosition = .imageOnly
            button.target = self
        }
        setImage(closeButton, "xmark", tip: "关闭这个分屏")
        closeButton.action = #selector(closeClicked)
        zoomButton.action = #selector(zoomClicked)
        setZoomed(false)
        [dot, label, zoomButton, closeButton].forEach(addSubview)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    var title: String { label.stringValue }

    func update(title: String, dotColor: NSColor, textColor: NSColor, focused: Bool, zoomed: Bool) {
        if label.stringValue != title {
            label.stringValue = title
            needsLayout = true
        }
        label.textColor = textColor.withAlphaComponent(focused ? 0.92 : 0.55)
        dot.layer?.backgroundColor = dotColor.cgColor
        for button in [zoomButton, closeButton] {
            button.contentTintColor = textColor.withAlphaComponent(focused ? 0.75 : 0.45)
        }
        if zoomed != self.zoomed { setZoomed(zoomed) }
    }

    private func setZoomed(_ value: Bool) {
        zoomed = value
        setImage(zoomButton, value ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                 tip: value ? "还原分屏（⇧⌘↩）" : "放大这个分屏（⇧⌘↩）")
    }

    private func setImage(_ button: NSButton, _ symbol: String, tip: String) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .semibold))
        button.toolTip = tip
        button.setAccessibilityLabel(tip)
    }

    override func layout() {
        super.layout()
        let height = bounds.height
        dot.frame = NSRect(x: 4, y: (height - 7) / 2, width: 7, height: 7)
        closeButton.frame = NSRect(x: bounds.width - 22, y: (height - 20) / 2, width: 20, height: 20)
        zoomButton.frame = NSRect(x: bounds.width - 44, y: (height - 20) / 2, width: 20, height: 20)
        let labelHeight = ceil(label.intrinsicContentSize.height)
        label.frame = NSRect(x: 17, y: (height - labelHeight) / 2, width: max(0, bounds.width - 17 - 50), height: labelHeight)
    }

    /// 按钮以外的地方都算标题栏自己（文字标签不吃鼠标）
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard bounds.contains(local), !isHidden else { return nil }
        for button in [zoomButton, closeButton] where button.frame.contains(local) {
            return button
        }
        return self
    }

    override func resetCursorRects() {
        addCursorRect(NSRect(x: 0, y: 0, width: max(0, bounds.width - 48), height: bounds.height), cursor: .openHand)
    }

    override func mouseDown(with event: NSEvent) {
        if event.isContextClick { return rightMouseDown(with: event) }
        deck?.headerMouseDown(self, event: event)
    }
    override func mouseDragged(with event: NSEvent) { deck?.headerMouseDragged(self, event: event) }
    override func mouseUp(with event: NSEvent) { deck?.headerMouseUp(self, event: event) }

    override func rightMouseDown(with event: NSEvent) {
        guard let session, let menu = session.workspace?.paneMenu(for: session) else { return }
        session.workspace?.select(session)
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func zoomClicked() {
        guard let session, let workspace = session.workspace else { return }
        workspace.select(session)
        workspace.toggleZoom()
    }

    @objc private func closeClicked() {
        guard let session else { return }
        session.workspace?.closePane(session)
    }
}

/// 拖分屏时的落点提示：半透明的强调色块，可以带一句说明
final class DropIndicatorView: NSView {
    var color: NSColor = .controlAccentColor {
        didSet { needsDisplay = true }
    }
    var text: String? {
        didSet { if text != oldValue { needsDisplay = true } }
    }

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1.5, dy: 1.5), xRadius: 12, yRadius: 12)
        color.withAlphaComponent(0.18).setFill()
        path.fill()
        color.withAlphaComponent(0.9).setStroke()
        path.lineWidth = 2
        path.stroke()
        guard let text else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: color,
        ]
        let size = (text as NSString).size(withAttributes: attributes)
        let badge = NSRect(x: bounds.midX - size.width / 2 - 12, y: bounds.midY - size.height / 2 - 6,
                           width: size.width + 24, height: size.height + 12)
        NSColor.windowBackgroundColor.withAlphaComponent(0.92).setFill()
        NSBezierPath(roundedRect: badge, xRadius: badge.height / 2, yRadius: badge.height / 2).fill()
        (text as NSString).draw(at: NSPoint(x: badge.minX + 12, y: badge.minY + 6), withAttributes: attributes)
    }
}

/// 鼠标停在分屏之间的缝上时，缝中间显示一个小把手，提示可以拖动
final class DividerGripView: NSView {
    var color: NSColor = .controlAccentColor {
        didSet { needsDisplay = true }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let radius = min(bounds.width, bounds.height) / 2
        color.withAlphaComponent(0.75).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
    }
}

/// 终端下面垫的圆角卡片：底色和终端一样，分屏时有焦点的那张带一圈强调色；不拦鼠标。
/// 用 draw 画（不用图层属性），离屏截图时也画得出来
final class PaneCardView: NSView {
    static let radius: CGFloat = 14

    private var fill: NSColor = .clear
    private var ring: NSColor?
    private var border: NSColor = .clear

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
        layer?.shadowOpacity = 1
        layer?.shadowRadius = 10
        layer?.shadowOffset = CGSize(width: 0, height: -3)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    func update(fill: NSColor, ring: NSColor?, border: NSColor, shadow: NSColor) {
        if fill != self.fill || ring != self.ring || border != self.border {
            self.fill = fill
            self.ring = ring
            self.border = border
            needsDisplay = true
        }
        layer?.shadowColor = shadow.cgColor
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: Self.radius, cornerHeight: Self.radius, transform: nil)
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.75, dy: 0.75), xRadius: Self.radius, yRadius: Self.radius)
        fill.setFill()
        path.fill()
        if let ring {
            ring.setStroke()
            path.lineWidth = 1.5
            path.stroke()
        } else if border.alphaComponent > 0 {
            border.setStroke()
            path.lineWidth = 0.5
            path.stroke()
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
