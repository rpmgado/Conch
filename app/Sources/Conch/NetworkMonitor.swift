import AppKit
import Network

extension Notification.Name {
    /// 网络恢复、或者电脑从睡眠中醒来：等着重连的标签页可以立刻再试
    static let conchNetworkMayBeBack = Notification.Name("conchNetworkMayBeBack")
}

/// 监听网络变化和睡眠唤醒，让自动重连不用干等退避时间
final class NetworkMonitor {
    static let shared = NetworkMonitor()

    private let monitor = NWPathMonitor()
    private var online = true
    private var wakeObserver: NSObjectProtocol?

    func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            let nowOnline = path.status == .satisfied
            DispatchQueue.main.async {
                guard let self else { return }
                let cameBack = nowOnline && !self.online
                self.online = nowOnline
                if cameBack {
                    // 刚恢复时 DNS、路由可能还没就绪，稍等一下
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                        NotificationCenter.default.post(name: .conchNetworkMayBeBack, object: nil)
                    }
                }
            }
        }
        monitor.start(queue: DispatchQueue(label: "conch.network-monitor"))

        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                NotificationCenter.default.post(name: .conchNetworkMayBeBack, object: nil)
            }
        }
    }
}
