import AppKit
import ConchKit
import Foundation
import UniformTypeIdentifiers

/// 一个正在用本机编辑器编辑的远端文件：下载到本机，编辑器保存后自动传回服务器
final class RemoteEdit: ObservableObject, Identifiable {
    enum State: Equatable {
        case downloading
        /// 和服务器一致；Date 是上一次传回去的时间（刚下载时为 nil）
        case synced(Date?)
        case uploading
        /// 打开编辑之后服务器上的文件又被改过，没有覆盖，等用户决定
        case conflict
        case failed(String)
    }

    let id = UUID()
    let remotePath: String
    let localURL: URL
    @Published var state: State = .downloading
    /// 下载（或上次上传）后服务器上这个文件的修改时间和大小，用来发现别人同时改了它
    var remoteStamp: (modified: Int64?, size: UInt64)?
    /// 上次和服务器同步时，本机副本的修改时间
    var localStamp: Date?
    /// 上传失败后，过一会儿再试
    var retryAfter: Date?
    /// 最近一次上传的传输项（再保存时从传输列表里换掉，免得越积越多）
    weak var lastTransfer: TransferItem?

    init(remotePath: String, localURL: URL) {
        self.remotePath = remotePath
        self.localURL = localURL
    }

    var name: String { localURL.lastPathComponent }

    var remoteDirectory: String {
        let parent = (remotePath as NSString).deletingLastPathComponent
        return parent.isEmpty ? "/" : parent
    }

    var localModified: Date? {
        (try? FileManager.default.attributesOfItem(atPath: localURL.path))?[.modificationDate] as? Date
    }

    /// 本机副本保存过、还没传回服务器
    var hasLocalChanges: Bool {
        guard let localStamp, let current = localModified else { return false }
        return current != localStamp
    }

    var statusText: String {
        switch state {
        case .downloading: "正在下载…"
        case .synced(nil): "已打开，保存后自动上传"
        case .synced(let date?): "已上传 \(date.formatted(date: .omitted, time: .standard))"
        case .uploading: "正在上传…"
        case .conflict: "服务器上的文件被别人改过，没有覆盖"
        case .failed(let message): message
        }
    }
}

extension SftpBrowser {
    /// 用本机的编辑器打开远端文件；编辑器保存后自动传回服务器
    func edit(_ file: RemoteFile) {
        if let existing = edits.first(where: { $0.remotePath == file.path }) {
            if existing.state != .downloading { Self.openInEditor(existing.localURL) }
            return
        }
        guard isReady else { return }
        // 每个文件一个单独的目录，同名文件（不同目录下的 nginx.conf）不会互相覆盖
        let directory = AppPaths.editingDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let edit = RemoteEdit(remotePath: file.path, localURL: directory.appendingPathComponent(file.name))
        edit.remoteStamp = (file.modified, file.size)
        addEdit(edit)
        download(for: edit, reopen: true)
    }

    /// 按路径编辑（测试用）
    func editPath(_ path: String, attempts: Int = 20) {
        guard isReady, let client = sftpClient else {
            if attempts > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.editPath(path, attempts: attempts - 1) }
            }
            return
        }
        Task { @MainActor [weak self] in
            if let file = try? await client.stat(path: path) { self?.edit(file) }
        }
    }

    /// 放弃本机的修改，重新从服务器下载
    func reloadEdit(_ edit: RemoteEdit) {
        guard isReady, let client = sftpClient else { return }
        edit.state = .downloading
        Task { @MainActor [weak self] in
            if let stat = try? await client.stat(path: edit.remotePath) { edit.remoteStamp = (stat.modified, stat.size) }
            self?.download(for: edit, reopen: false)
        }
    }

    /// 用本机的版本覆盖服务器上的（冲突时用户确认之后）
    func overwriteRemote(_ edit: RemoteEdit) {
        upload(edit, force: true)
    }

    func stopEditing(_ edit: RemoteEdit) {
        removeEdit(edit)
        // 已经同步过的本机副本没用了；还有没传上去的修改就留着，免得丢东西
        if !edit.hasLocalChanges, edit.state != .conflict {
            try? FileManager.default.removeItem(at: edit.localURL.deletingLastPathComponent())
        }
    }

    func revealEditCopy(_ edit: RemoteEdit) {
        NSWorkspace.shared.activateFileViewerSelecting([edit.localURL])
    }

    private func download(for edit: RemoteEdit, reopen: Bool) {
        let directory = edit.localURL.deletingLastPathComponent()
        let item = TransferItem(direction: .download, name: edit.name, source: edit.remotePath,
                                destination: directory.path, browser: self)
        item.onFinished = { [weak self, weak edit] item in
            guard let self, let edit else { return }
            switch item.state {
            case .finished:
                edit.localStamp = edit.localModified
                edit.retryAfter = nil
                edit.state = .synced(nil)
                if reopen { Self.openInEditor(edit.localURL) }
                self.startWatchingEdits()
            case .failed(let message):
                edit.state = .failed("下载失败：\(message)")
            case .cancelled:
                self.removeEdit(edit)
            case .running:
                break
            }
        }
        replaceTransfer(of: edit, with: item)
        startTransfer(item, policy: .overwrite)
    }

    /// 每秒看一眼本机副本有没有被保存过
    fileprivate func checkEdits() {
        let now = Date()
        for edit in edits where edit.hasLocalChanges {
            switch edit.state {
            case .downloading, .uploading, .conflict:
                continue
            case .failed:
                if let retry = edit.retryAfter, retry > now { continue }
            case .synced:
                break
            }
            upload(edit, force: false)
        }
    }

    private func upload(_ edit: RemoteEdit, force: Bool) {
        guard isReady, let client = sftpClient else {
            edit.state = .failed("连接已断开，重新连上后会自动上传")
            edit.retryAfter = Date().addingTimeInterval(5)
            return
        }
        let pending = edit.localModified
        edit.state = .uploading
        Task { @MainActor [weak self] in
            // 上传前先看服务器上的文件是不是在这期间被别人改过
            if !force, let expected = edit.remoteStamp, let current = try? await client.stat(path: edit.remotePath),
               current.modified != expected.modified || current.size != expected.size
            {
                edit.state = .conflict
                self?.askAboutConflict(edit)
                return
            }
            guard let self else { return }
            let item = TransferItem(direction: .upload, name: edit.name, source: edit.localURL.path,
                                    destination: edit.remoteDirectory, browser: self)
            item.onFinished = { [weak edit] item in
                guard let edit else { return }
                switch item.state {
                case .finished:
                    edit.localStamp = pending
                    Task { @MainActor in
                        if let stat = try? await client.stat(path: edit.remotePath) {
                            edit.remoteStamp = (stat.modified, stat.size)
                        }
                        edit.retryAfter = nil
                        edit.state = .synced(Date())
                    }
                case .failed(let message):
                    edit.state = .failed("上传失败：\(message)")
                    edit.retryAfter = Date().addingTimeInterval(10)
                case .cancelled:
                    edit.state = .failed("上传已取消，再保存一次会重新上传")
                    edit.localStamp = pending
                case .running:
                    break
                }
            }
            self.replaceTransfer(of: edit, with: item)
            self.startTransfer(item, policy: .overwrite)
        }
    }

    private func askAboutConflict(_ edit: RemoteEdit) {
        if let answer = TestHooks.editConflictAnswer {
            if answer == "overwrite" { upload(edit, force: true) }
            return
        }
        Dialogs.confirm(
            "“\(edit.name)”在服务器上被改过",
            detail: "你打开编辑之后，服务器上的这个文件又被修改了（可能是别人或者程序改的）。用你的版本覆盖，服务器上的那些修改就没了。\n\n不覆盖的话，可以在文件面板的“正在编辑”里选择“重新下载”，拿到服务器上的最新版本。",
            confirmTitle: "用我的版本覆盖",
            destructive: true,
            window: windowForDialogs
        ) { [weak self] ok in
            if ok { self?.upload(edit, force: true) }
        }
    }

    private func startWatchingEdits() {
        guard editTimer == nil else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.checkEdits() }
        RunLoop.main.add(timer, forMode: .common)
        editTimer = timer
    }

    /// 编辑用的应用：设置里选的；没选就用这个文件的默认应用。
    /// 默认应用是终端、安装器这类“打开就是执行”的，或者没有默认应用时，改用文本编辑
    static func openInEditor(_ url: URL) {
        if TestHooks.isActive { return }
        let custom = UserDefaults.standard.string(forKey: Prefs.editorApp) ?? ""
        let notEditors: Set<String> = [
            "com.apple.Terminal", "com.googlecode.iterm2", "com.apple.installer",
            "com.apple.archiveutility", "com.apple.DiskImageMounter", "com.apple.ScriptMenuApp",
        ]
        var app: URL?
        if !custom.isEmpty, FileManager.default.fileExists(atPath: custom) {
            app = URL(fileURLWithPath: custom)
        } else if let preferred = NSWorkspace.shared.urlForApplication(toOpen: url),
                  !notEditors.contains(Bundle(url: preferred)?.bundleIdentifier ?? "")
        {
            app = preferred
        }
        let editor = app ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.TextEdit")
        guard let editor else { return }
        NSWorkspace.shared.open([url], withApplicationAt: editor, configuration: NSWorkspace.OpenConfiguration())
    }
}
