import Foundation

/// 服务器监控：在同一条 SSH 连接上另开通道执行一段脚本，读 /proc 里的数据。
/// 目前支持 Linux（绝大多数服务器）；其他系统会提示不支持。
public enum ServerMonitorScript {
    public static let separator = "@@CONCH@@"

    /// 用 /bin/sh 执行，不受用户登录 Shell（fish 等）的语法影响。脚本里不能有单引号
    public static var command: String {
        let lines = [
            "export LC_ALL=C",
            "S=\(separator)",
            "uname -s; echo $S",
            "hostname 2>/dev/null; echo $S",
            "cat /proc/loadavg 2>/dev/null; echo $S",
            "head -n 1 /proc/stat 2>/dev/null; echo $S",
            "grep -E \"^(MemTotal|MemAvailable|MemFree|Buffers|Cached|SwapTotal|SwapFree):\" /proc/meminfo 2>/dev/null; echo $S",
            "cat /proc/net/dev 2>/dev/null; echo $S",
            "df -kP 2>/dev/null; echo $S",
            "cat /proc/uptime 2>/dev/null; echo $S",
            "nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null; echo $S",
            "ps -eo pid,pcpu,pmem,comm --sort=-pcpu 2>/dev/null | head -n 9",
        ]
        return "/bin/sh -c '" + lines.joined(separator: "\n") + "'"
    }
}

/// 某一时刻采到的数据（CPU、网络是累计值，要两次相减才得到使用率和速度）
public struct ServerSample: Equatable, Sendable {
    public struct Disk: Equatable, Sendable {
        public var filesystem: String
        public var mount: String
        public var sizeKB: UInt64
        public var usedKB: UInt64
        public var availableKB: UInt64

        /// 和 df 的 Use% 一样按 已用 /（已用 + 可用）算：ext4 给 root 预留的空间普通用户用不了
        public var fraction: Double {
            let usable = usedKB + availableKB
            return usable > 0 ? Double(usedKB) / Double(usable) : 0
        }

        /// 百分比，和 df 一样向上取整
        public var percent: Int { Int((fraction * 100).rounded(.up)) }
    }

    public struct Process: Equatable, Sendable {
        public var pid: Int
        public var cpu: Double
        public var memory: Double
        public var command: String
    }

    public var system: String = ""
    public var hostname: String = ""
    public var load: [Double] = []
    /// /proc/stat 第一行：忙碌和空闲（含 iowait）的累计 jiffies
    public var cpuBusy: UInt64 = 0
    public var cpuIdle: UInt64 = 0
    public var cores: Int = 0
    public var memoryTotalKB: UInt64 = 0
    public var memoryAvailableKB: UInt64 = 0
    public var swapTotalKB: UInt64 = 0
    public var swapFreeKB: UInt64 = 0
    /// 除 lo 之外所有网卡的累计收发字节
    public var networkReceived: UInt64 = 0
    public var networkSent: UInt64 = 0
    public var disks: [Disk] = []
    public var uptime: TimeInterval = 0
    public var processes: [Process] = []

    public init() {}

    public var isLinux: Bool { system == "Linux" }

    public var memoryUsedKB: UInt64 { memoryTotalKB > memoryAvailableKB ? memoryTotalKB - memoryAvailableKB : 0 }
}

/// 两次采样之间算出来的速率
public struct ServerRates: Equatable, Sendable {
    /// 0～100
    public var cpuPercent: Double
    /// 字节 / 秒
    public var receivedPerSecond: Double
    public var sentPerSecond: Double

    public static func between(_ previous: ServerSample, _ current: ServerSample, seconds: TimeInterval) -> ServerRates {
        let busy = Double(current.cpuBusy &- previous.cpuBusy)
        let idle = Double(current.cpuIdle &- previous.cpuIdle)
        let cpu = busy + idle > 0 && current.cpuBusy >= previous.cpuBusy ? busy / (busy + idle) * 100 : 0
        let interval = max(seconds, 0.001)
        // 计数器被重置（网卡重启等）时不算负数
        let received = current.networkReceived >= previous.networkReceived ? Double(current.networkReceived - previous.networkReceived) / interval : 0
        let sent = current.networkSent >= previous.networkSent ? Double(current.networkSent - previous.networkSent) / interval : 0
        return ServerRates(cpuPercent: min(max(cpu, 0), 100), receivedPerSecond: received, sentPerSecond: sent)
    }
}

public enum ServerStatsParser {
    /// 解析监控脚本的输出。各段顺序和脚本里一致
    public static func parse(_ output: String) -> ServerSample {
        var sample = ServerSample()
        let sections = output.components(separatedBy: ServerMonitorScript.separator)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        func section(_ index: Int) -> String { index < sections.count ? sections[index] : "" }

        sample.system = section(0)
        sample.hostname = section(1)
        sample.load = section(2).split(separator: " ").prefix(3).compactMap { Double($0) }
        parseCPU(section(3), into: &sample)
        parseMemory(section(4), into: &sample)
        parseNetwork(section(5), into: &sample)
        sample.disks = parseDisks(section(6))
        sample.uptime = section(7).split(separator: " ").first.flatMap { Double($0) } ?? 0
        sample.cores = Int(section(8)) ?? 0
        sample.processes = parseProcesses(section(9))
        return sample
    }

    static func parseCPU(_ text: String, into sample: inout ServerSample) {
        // cpu  user nice system idle iowait irq softirq steal guest guest_nice
        let fields = text.split(separator: " ").dropFirst().compactMap { UInt64($0) }
        guard fields.count >= 4 else { return }
        let idle = fields[3] + (fields.count > 4 ? fields[4] : 0)
        // guest 已经算在 user 里，只加到 steal 为止
        let busy = fields.prefix(8).enumerated().filter { $0.offset != 3 && $0.offset != 4 }.reduce(0) { $0 + $1.element }
        sample.cpuIdle = idle
        sample.cpuBusy = busy
    }

    static func parseMemory(_ text: String, into sample: inout ServerSample) {
        var values: [String: UInt64] = [:]
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let number = parts[1].split(separator: " ").first.flatMap({ UInt64($0) }) else { continue }
            values[String(parts[0])] = number
        }
        sample.memoryTotalKB = values["MemTotal"] ?? 0
        // 老内核没有 MemAvailable，用 free + buffers + cached 估算
        sample.memoryAvailableKB = values["MemAvailable"]
            ?? (values["MemFree"] ?? 0) + (values["Buffers"] ?? 0) + (values["Cached"] ?? 0)
        sample.swapTotalKB = values["SwapTotal"] ?? 0
        sample.swapFreeKB = values["SwapFree"] ?? 0
    }

    static func parseNetwork(_ text: String, into sample: inout ServerSample) {
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let interface = parts[0].trimmingCharacters(in: .whitespaces)
            guard interface != "lo", !interface.isEmpty, !interface.contains("|") else { continue }
            let numbers = parts[1].split(separator: " ").compactMap { UInt64($0) }
            guard numbers.count >= 9 else { continue }
            sample.networkReceived += numbers[0]
            sample.networkSent += numbers[8]
        }
    }

    /// 只留真正的磁盘，去掉 tmpfs、overlay、/dev、/run 这类
    static func parseDisks(_ text: String) -> [ServerSample.Disk] {
        let skipFilesystems = ["tmpfs", "devtmpfs", "overlay", "shm", "udev", "none", "squashfs", "efivarfs", "map ", "devfs"]
        let skipMounts = ["/dev", "/run", "/sys", "/proc", "/snap", "/boot/efi", "/System/Volumes"]
        var disks: [ServerSample.Disk] = []
        for line in text.split(separator: "\n").dropFirst() {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard fields.count >= 6, let size = UInt64(fields[1]), let used = UInt64(fields[2]), let available = UInt64(fields[3]), size > 0 else { continue }
            let filesystem = fields[0]
            let mount = fields[5...].joined(separator: " ")
            if skipFilesystems.contains(where: { filesystem.hasPrefix($0) }) { continue }
            if skipMounts.contains(where: { mount == $0 || mount.hasPrefix($0 + "/") }) { continue }
            disks.append(.init(filesystem: filesystem, mount: mount, sizeKB: size, usedKB: used, availableKB: available))
        }
        return disks
    }

    static func parseProcesses(_ text: String) -> [ServerSample.Process] {
        text.split(separator: "\n").dropFirst().compactMap { line in
            let fields = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard fields.count == 4, let pid = Int(fields[0]), let cpu = Double(fields[1]), let memory = Double(fields[2]) else { return nil }
            return .init(pid: pid, cpu: cpu, memory: memory, command: String(fields[3]))
        }
    }
}
