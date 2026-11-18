import ConchKit
import Foundation

/// 服务器监控：面板打开时，每 3 秒在同一条 SSH 连接上另开一个通道执行采集脚本（不占用终端，也不用再登录一次）
final class ServerMonitor: ObservableObject {
    enum Status: Equatable {
        case idle
        case loading
        case running
        /// 不是 Linux
        case unsupported(String)
        case failed(String)
        case disconnected
    }

    struct Point: Identifiable, Equatable {
        let id: Int
        let date: Date
        let value: Double
    }

    static let interval: TimeInterval = 3
    /// 曲线上保留的点数（3 分钟）
    static let historyLength = 60
    /// 已经有数据时，连续失败几次才停下来报错（偶尔一次超时不打断）
    static let failuresBeforeStop = 3

    @Published private(set) var status: Status = .idle
    @Published private(set) var sample: ServerSample?
    @Published private(set) var rates: ServerRates?
    /// CPU 使用率 0～100
    @Published private(set) var cpu: [Point] = []
    /// 内存使用率 0～100
    @Published private(set) var memory: [Point] = []
    /// 网络收发，字节 / 秒
    @Published private(set) var received: [Point] = []
    @Published private(set) var sent: [Point] = []
    @Published private(set) var updatedAt: Date?
    /// 最近一次失败（还在继续采集时显示成提示）
    @Published private(set) var warning: String?

    private weak var session: TerminalSession?
    private var task: Task<Void, Never>?
    private var previous: (sample: ServerSample, date: Date)?
    private var nextID = 0
    private var failures = 0
    /// 面板正在显示（只在显示时采集）
    private var wanted = false

    init(session: TerminalSession) {
        self.session = session
    }

    func activate() {
        wanted = true
        start()
    }

    func deactivate() {
        wanted = false
        stop()
    }

    func connectionEstablished() {
        if wanted { start() }
    }

    func connectionEnded() {
        stop()
        previous = nil
        if status != .idle { status = .disconnected }
    }

    func retry() {
        stop()
        start()
    }

    private func stop() {
        task?.cancel()
        task = nil
    }

    private func start() {
        guard task == nil else { return }
        guard let connection = session?.connection else {
            status = .disconnected
            return
        }
        if status != .running { status = .loading }
        failures = 0
        task = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, await self.poll(connection) else { return }
                // 第一次只有一个采样点，算不出 CPU 和网速，1 秒后马上再采一次
                let delay = self.cpu.isEmpty ? 1 : Self.interval
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
    }

    /// 采一次；返回 false 表示停下来
    @MainActor
    private func poll(_ connection: SshSession) async -> Bool {
        do {
            let output = try await connection.exec(command: ServerMonitorScript.command, timeoutSecs: 8)
            guard !Task.isCancelled else { return false }
            let sample = ServerStatsParser.parse(String(decoding: output.stdout, as: UTF8.self))
            if sample.system.isEmpty {
                let detail = String(decoding: output.stderr, as: UTF8.self)
                    .split(separator: "\n").first.map { "：\($0)" } ?? ""
                return fail("没有拿到监控数据\(detail)")
            }
            guard sample.isLinux else {
                task = nil
                status = .unsupported(sample.system == "Darwin"
                    ? "这台服务器是 macOS，监控目前只支持 Linux"
                    : "这台服务器是 \(sample.system)，监控目前只支持 Linux")
                return false
            }
            record(sample, at: Date())
            failures = 0
            warning = nil
            status = .running
            return true
        } catch {
            guard !Task.isCancelled else { return false }
            return fail("采集失败：\(error.userMessage)")
        }
    }

    @MainActor
    private func fail(_ message: String) -> Bool {
        failures += 1
        if sample != nil, failures < Self.failuresBeforeStop {
            warning = message
            return true
        }
        task = nil
        status = .failed(message)
        return false
    }

    private func record(_ sample: ServerSample, at date: Date) {
        if let previous {
            let rates = ServerRates.between(previous.sample, sample, seconds: date.timeIntervalSince(previous.date))
            self.rates = rates
            append(rates.cpuPercent, at: date, to: &cpu)
            append(rates.receivedPerSecond, at: date, to: &received)
            append(rates.sentPerSecond, at: date, to: &sent)
        }
        if sample.memoryTotalKB > 0 {
            append(Double(sample.memoryUsedKB) / Double(sample.memoryTotalKB) * 100, at: date, to: &memory)
        }
        previous = (sample, date)
        self.sample = sample
        updatedAt = date
    }

    private func append(_ value: Double, at date: Date, to points: inout [Point]) {
        nextID += 1
        points.append(Point(id: nextID, date: date, value: value))
        if points.count > Self.historyLength { points.removeFirst(points.count - Self.historyLength) }
    }
}
