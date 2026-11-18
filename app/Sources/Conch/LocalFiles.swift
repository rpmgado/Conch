import AppKit
import CoreTransferable
import ConchKit
import SwiftUI
import UniformTypeIdentifiers

/// 本机的一个文件或文件夹（文件面板里本机那一栏）
struct LocalFile: Hashable {
    let url: URL
    let name: String
    /// 能进去的文件夹。.app 这类“包”当成文件
    let isDir: Bool
    let isPackage: Bool
    let isSymlink: Bool
    /// 点开头的文件，或者在访达里被设成隐藏的（比如 ~/Library）
    let isHidden: Bool
    let size: Int64
    let modified: Date?

    var path: String { url.path }
}

/// 文件面板里本机那一栏：当前文件夹和里面的文件。一个窗口一份（切换标签页时不变），记住上次在哪个文件夹。
/// 显示的时候留意文件夹的变化，下载完的文件会自己出现
final class LocalBrowser: ObservableObject {
    @Published private(set) var directory: URL
    @Published private(set) var entries: [LocalFile] = []
    /// 按“显示隐藏文件”过滤后的，文件夹在前
    @Published private(set) var visibleEntries: [LocalFile] = []
    @Published private(set) var loading = false
    @Published var showHidden: Bool {
        didSet {
            guard showHidden != oldValue else { return }
            if !TestHooks.isActive { UserDefaults.standard.set(showHidden, forKey: Prefs.localShowHidden) }
            updateVisible()
        }
    }
    /// 地址栏里正在编辑的路径
    @Published var pathField: String
    @Published var selection: Set<String> = []
    /// 最近一次操作的错误，显示在面板底部
    @Published var message: String?

    private var watcher: DispatchSourceFileSystemObject?
    /// 有几处正在显示本机这一栏（切换标签页时新面板可能先出现、旧的后消失）
    private var activeCount = 0
    private var generation = 0
    private var pendingRefresh: DispatchWorkItem?

    init() {
        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser
        var start = home
        if let test = TestHooks.localDirectory {
            start = test
        } else if let saved = UserDefaults.standard.string(forKey: Prefs.localFilesDirectory), !saved.isEmpty {
            start = URL(fileURLWithPath: saved, isDirectory: true)
        }
        var isDirectory: ObjCBool = false
        if !fileManager.fileExists(atPath: start.path, isDirectory: &isDirectory) || !isDirectory.boolValue {
            start = home
        }
        directory = start
        pathField = Self.display(start)
        showHidden = TestHooks.isActive ? false : UserDefaults.standard.bool(forKey: Prefs.localShowHidden)
    }

    deinit {
        watcher?.cancel()
    }

    /// 本机这一栏显示出来了：读一遍文件夹，开始留意变化
    func activate() {
        activeCount += 1
        load(directory)
    }

    func deactivate() {
        activeCount = max(0, activeCount - 1)
        guard activeCount == 0 else { return }
        watcher?.cancel()
        watcher = nil
    }

    var displayPath: String { Self.display(directory) }

    static func display(_ url: URL) -> String {
        (url.path as NSString).abbreviatingWithTildeInPath
    }

    func entry(_ path: String) -> LocalFile? {
        entries.first { $0.path == path }
    }

    // MARK: 浏览

    func load(_ url: URL) {
        generation += 1
        let current = generation
        loading = true
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try Self.list(url) }
            DispatchQueue.main.async { [weak self] in
                guard let self, current == self.generation else { return }
                self.loading = false
                switch result {
                case .success(let files):
                    let moved = url.standardizedFileURL.path != self.directory.standardizedFileURL.path
                    self.directory = url
                    self.pathField = Self.display(url)
                    self.entries = files
                    self.updateVisible()
                    self.selection = moved ? [] : self.selection.filter { path in files.contains { $0.path == path } }
                    self.message = nil
                    if moved, !TestHooks.isActive {
                        UserDefaults.standard.set(url.path, forKey: Prefs.localFilesDirectory)
                    }
                    if self.activeCount > 0, moved || self.watcher == nil { self.watch(url) }
                case .failure(let error):
                    self.pathField = Self.display(self.directory)
                    self.message = Self.describe(error, url: url)
                }
            }
        }
    }

    /// 地址栏里输入的路径（可以用 ~）
    func go(to text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let url = URL(fileURLWithPath: (trimmed as NSString).expandingTildeInPath, isDirectory: true).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            pathField = displayPath
            message = "找不到文件夹 \(trimmed)"
            return
        }
        load(url)
    }

    func goUp() {
        let parent = directory.deletingLastPathComponent()
        guard parent.path != directory.path else { return }
        load(parent)
    }

    func goHome() {
        load(FileManager.default.homeDirectoryForCurrentUser)
    }

    func refresh() {
        load(directory)
    }

    // MARK: 文件操作

    func makeDirectory(named name: String) {
        perform("新建文件夹") {
            try FileManager.default.createDirectory(at: self.directory.appendingPathComponent(name, isDirectory: true),
                                                    withIntermediateDirectories: false)
        }
    }

    func rename(_ file: LocalFile, to name: String) {
        perform("重命名") {
            try FileManager.default.moveItem(at: file.url, to: file.url.deletingLastPathComponent().appendingPathComponent(name))
        }
    }

    func moveToTrash(_ files: [LocalFile]) {
        perform("移到废纸篓") {
            for file in files { try FileManager.default.trashItem(at: file.url, resultingItemURL: nil) }
        }
    }

    func reveal(_ files: [LocalFile]) {
        NSWorkspace.shared.activateFileViewerSelecting(files.isEmpty ? [directory] : files.map(\.url))
    }

    func openInDefaultApp(_ file: LocalFile) {
        NSWorkspace.shared.open(file.url)
    }

    func copyPath(_ files: [LocalFile]) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(files.map(\.path).joined(separator: "\n"), forType: .string)
    }

    private func perform(_ what: String, _ work: () throws -> Void) {
        do {
            try work()
        } catch {
            message = "\(what)失败：\(error.localizedDescription)"
        }
        refresh()
    }

    private func updateVisible() {
        visibleEntries = showHidden ? entries : entries.filter { !$0.isHidden }
    }

    // MARK: 留意文件夹的变化

    private func watch(_ url: URL) {
        watcher?.cancel()
        watcher = nil
        let descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor,
                                                               eventMask: [.write, .delete, .rename, .link], queue: .main)
        source.setEventHandler { [weak self] in self?.scheduleRefresh() }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        watcher = source
    }

    /// 文件夹连着变好几次（比如下载时）只刷新一次
    private func scheduleRefresh() {
        pendingRefresh?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.activeCount > 0 else { return }
            self.load(self.directory)
        }
        pendingRefresh = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    // MARK: 读文件夹

    static func list(_ url: URL) throws -> [LocalFile] {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey, .isHiddenKey,
                                         .fileSizeKey, .contentModificationDateKey]
        let items = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: Array(keys))
        return items.map { item in
            let values = try? item.resourceValues(forKeys: keys)
            let isSymlink = values?.isSymbolicLink ?? false
            var isDirectory = values?.isDirectory ?? false
            if isSymlink {
                var flag: ObjCBool = false
                isDirectory = FileManager.default.fileExists(atPath: item.path, isDirectory: &flag) && flag.boolValue
            }
            let isPackage = values?.isPackage ?? false
            return LocalFile(
                url: item,
                name: item.lastPathComponent,
                isDir: isDirectory && !isPackage,
                isPackage: isPackage,
                isSymlink: isSymlink,
                isHidden: values?.isHidden ?? item.lastPathComponent.hasPrefix("."),
                size: Int64(values?.fileSize ?? 0),
                modified: values?.contentModificationDate
            )
        }
        .sorted { a, b in
            if a.isDir != b.isDir { return a.isDir }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    private static func describe(_ error: Error, url: URL) -> String {
        let error = error as NSError
        if error.domain == NSCocoaErrorDomain, error.code == NSFileReadNoPermissionError {
            return "没有权限打开 \(display(url))。可以在“系统设置 → 隐私与安全性 → 文件与文件夹”里允许 Conch 访问"
        }
        return "打不开 \(display(url))：\(error.localizedDescription)"
    }
}

// MARK: - 两栏之间拖文件

extension UTType {
    /// 从服务器那一栏拖出来的文件（只在这个 App 里用）
    static let conchRemoteFiles = UTType(exportedAs: "com.conch.gado.remote-files")
    /// 从本机那一栏拖出来的文件（只在这个 App 里用，拖到访达不会搬动文件）
    static let conchLocalFiles = UTType(exportedAs: "com.conch.gado.local-files")
}

extension RemoteFilesDrag: Transferable {
    public static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .conchRemoteFiles)
    }
}

struct LocalFilesDrag: Codable, Transferable {
    let paths: [String]

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .conchLocalFiles)
    }
}

// MARK: - 文件列表的一行

/// 两栏共用的格式：大小、修改时间
enum FileListFormat {
    private static let recent: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter
    }()

    private static let older: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    static func date(_ date: Date?) -> String {
        guard let date else { return "" }
        let sameYear = Calendar.current.isDate(date, equalTo: Date(), toGranularity: .year)
        return (sameYear ? recent : older).string(from: date)
    }

    static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

/// 文件列表里的一行：图标、名字、大小、修改时间
struct FileListRow: View {
    let name: String
    let icon: String
    let isDir: Bool
    let size: Int64?
    let modified: Date?
    var dimmed = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .foregroundStyle(isDir ? Color.accentColor : .secondary)
                .frame(width: 16)
            Text(name)
                .lineLimit(1)
                .truncationMode(.middle)
                .opacity(dimmed ? 0.6 : 1)
            Spacer(minLength: 6)
            if let size, !isDir {
                Text(FileListFormat.size(size))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Text(FileListFormat.date(modified))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(width: 74, alignment: .trailing)
        }
    }
}

struct LocalFileRow: View {
    let file: LocalFile

    var body: some View {
        FileListRow(name: file.name, icon: icon, isDir: file.isDir, size: file.size, modified: file.modified, dimmed: file.isHidden)
            .help(file.path)
    }

    private var icon: String {
        if file.isPackage { return "shippingbox" }
        if file.isSymlink { return file.isDir ? "folder.badge.questionmark" : "arrowshape.turn.up.right" }
        return file.isDir ? "folder.fill" : "doc"
    }
}
