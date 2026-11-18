import AppKit

/// 用户在密码框里输入的内容
struct SecretResponse {
    var value: String
    /// 勾选了“在钥匙串中记住”
    var remember: Bool
}

/// 需要用户参与的弹窗：主机指纹确认、密码 / 口令、交互式认证、各种确认框。
///
/// 都以窗口内 sheet 的形式弹出，不阻塞主线程；结果通过 completion 回传。
/// Rust 侧在阻塞线程上用 `Dialogs.ask` 同步等待用户操作。
enum Dialogs {
    /// 在后台线程调用：切到主线程弹窗，等用户操作完再返回结果。
    /// 不能在主线程上调用（会死锁）。
    static func ask<T>(_ present: @escaping (@escaping (T) -> Void) -> Void) -> T {
        precondition(!Thread.isMainThread, "Dialogs.ask 只能在后台线程调用")
        let semaphore = DispatchSemaphore(value: 0)
        let box = ResultBox<T>()
        DispatchQueue.main.async {
            present { value in
                box.value = value
                semaphore.signal()
            }
        }
        semaphore.wait()
        return box.value!
    }

    // MARK: 认证

    static func confirmHostKey(_ info: HostKeyInfo, window: NSWindow?, completion: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "第一次连接 \(info.host):\(info.port)"
        alert.informativeText = """
        无法确认这台主机的身份。它的主机密钥指纹（\(info.algorithm)）是：

        \(info.fingerprint)

        请和服务器管理员核对指纹后再继续。信任后 Conch 会记住这台主机；以后如果密钥变了，会拒绝连接并提醒你。
        """
        alert.addButton(withTitle: "信任并连接")
        alert.addButton(withTitle: "取消")
        present(alert, in: window) { completion($0 == .alertFirstButtonReturn) }
    }

    /// 要密码或私钥口令
    static func promptSecret(
        request: SecretRequest,
        hopName: String?,
        isJump: Bool,
        rememberByDefault: Bool,
        window: NSWindow?,
        completion: @escaping (SecretResponse?) -> Void
    ) {
        let alert = NSAlert()
        let target = "\(request.username)@\(request.host)" + (request.port == 22 ? "" : ":\(request.port)")
        let prefix = isJump ? "跳板机 " : ""
        switch request.kind {
        case .password:
            alert.messageText = request.retry ? "密码不正确，请重新输入" : "输入 \(prefix)\(target) 的密码"
            if let hopName, hopName != target {
                alert.informativeText = "会话：\(hopName)"
            }
        case .passphrase:
            let path = (request.keyPath as NSString).abbreviatingWithTildeInPath
            alert.messageText = request.retry ? "私钥口令不正确，请重新输入" : "输入私钥的口令"
            alert.informativeText = "\(path)\n用于登录 \(prefix)\(target)"
        }

        let field = NSSecureTextField()
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: 280).isActive = true
        let remember = NSButton(checkboxWithTitle: "在钥匙串中记住", target: nil, action: nil)
        remember.state = rememberByDefault ? .on : .off
        let stack = NSStackView(views: [field, remember])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.setFrameSize(stack.fittingSize)
        alert.accessoryView = stack
        alert.addButton(withTitle: "登录")
        alert.addButton(withTitle: "取消")
        alert.window.initialFirstResponder = field

        present(alert, in: window) { response in
            guard response == .alertFirstButtonReturn else { return completion(nil) }
            completion(SecretResponse(value: field.stringValue, remember: remember.state == .on))
        }
    }

    /// 交互式认证：堡垒机的动态口令、二次验证等。用户取消时回传 nil。
    static func keyboardInteractive(
        _ request: KeyboardInteractiveRequest,
        hopName: String,
        window: NSWindow?,
        completion: @escaping ([String]?) -> Void
    ) {
        let alert = NSAlert()
        alert.messageText = request.name.isEmpty ? "\(hopName) 需要进一步验证" : "\(hopName)：\(request.name)"
        alert.informativeText = request.instructions

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        var fields: [NSTextField] = []
        for prompt in request.prompts {
            let label = NSTextField(labelWithString: prompt.prompt.trimmingCharacters(in: .whitespaces))
            let field = prompt.echo ? NSTextField() : NSSecureTextField()
            field.translatesAutoresizingMaskIntoConstraints = false
            field.widthAnchor.constraint(equalToConstant: 280).isActive = true
            stack.addArrangedSubview(label)
            stack.addArrangedSubview(field)
            fields.append(field)
        }
        stack.setFrameSize(stack.fittingSize)
        alert.accessoryView = stack
        alert.addButton(withTitle: "确定")
        alert.addButton(withTitle: "取消")
        alert.window.initialFirstResponder = fields.first

        present(alert, in: window) { response in
            completion(response == .alertFirstButtonReturn ? fields.map(\.stringValue) : nil)
        }
    }

    /// 远端执行了 rz：选择要发送的文件
    static func chooseFilesToSend(window: NSWindow?, completion: @escaping ([String]?) -> Void) {
        let panel = NSOpenPanel()
        panel.title = "rz：选择要上传的文件"
        panel.message = "远端执行了 rz，选好的文件会用 ZMODEM 发送过去（单个文件不能超过 4 GB，大文件建议用文件面板）"
        panel.prompt = "发送"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        let handle = { (response: NSApplication.ModalResponse) in
            completion(response == .OK && !panel.urls.isEmpty ? panel.urls.map(\.path) : nil)
        }
        if let window = window ?? NSApp.keyWindow {
            panel.beginSheetModal(for: window, completionHandler: handle)
        } else {
            handle(panel.runModal())
        }
    }

    // MARK: 通用

    /// 确认框。suppressionKey 不为空时显示“不再提醒”，勾选后把这个偏好设为 false
    static func confirm(
        _ message: String,
        detail: String = "",
        confirmTitle: String,
        destructive: Bool = false,
        suppressionKey: String? = nil,
        window: NSWindow?,
        completion: @escaping (Bool) -> Void
    ) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        let button = alert.addButton(withTitle: confirmTitle)
        if destructive { button.hasDestructiveAction = true }
        alert.addButton(withTitle: "取消")
        if suppressionKey != nil {
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = "不再提醒"
        }
        present(alert, in: window) { response in
            let confirmed = response == .alertFirstButtonReturn
            if confirmed, let suppressionKey, alert.suppressionButton?.state == .on {
                UserDefaults.standard.set(false, forKey: suppressionKey)
            }
            completion(confirmed)
        }
    }

    /// 输入一行文字（新建分组、重命名分组）
    static func promptText(
        _ message: String,
        detail: String = "",
        initial: String = "",
        confirmTitle: String,
        window: NSWindow?,
        completion: @escaping (String?) -> Void
    ) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        let field = NSTextField(string: initial)
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: confirmTitle)
        alert.addButton(withTitle: "取消")
        alert.window.initialFirstResponder = field
        present(alert, in: window) { response in
            let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            completion(response == .alertFirstButtonReturn && !text.isEmpty ? text : nil)
        }
    }

    static func inform(_ message: String, detail: String = "", window: NSWindow?) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        alert.addButton(withTitle: "好")
        present(alert, in: window) { _ in }
    }

    /// 有窗口就挂成 sheet（同一个窗口上已有 sheet 时系统会排队），否则退回 App 级模态窗口
    private static func present(
        _ alert: NSAlert,
        in window: NSWindow?,
        completion: @escaping (NSApplication.ModalResponse) -> Void
    ) {
        if let window = window ?? NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first(where: \.isVisible) {
            alert.beginSheetModal(for: window, completionHandler: completion)
        } else {
            completion(alert.runModal())
        }
    }

    private final class ResultBox<T>: @unchecked Sendable {
        var value: T?
    }
}
