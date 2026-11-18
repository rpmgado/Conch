import AppKit
import Charts
import ConchKit
import SwiftUI

/// 右侧的监控面板：CPU、内存、网络、磁盘、进程
struct MonitorPanel: View {
    @ObservedObject var monitor: ServerMonitor
    let tab: TerminalSession

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onAppear { monitor.activate() }
            .onDisappear { monitor.deactivate() }
    }

    @ViewBuilder
    private var content: some View {
        if let sample = monitor.sample, monitor.status == .running || monitor.status == .loading {
            dashboard(sample)
        } else {
            switch monitor.status {
            case .idle, .loading, .running:
                placeholder { ProgressView("正在采集…").controlSize(.small) }
            case .unsupported(let message):
                placeholder {
                    Label(message, systemImage: "info.circle")
                        .foregroundStyle(.secondary)
                }
            case .failed(let message):
                placeholder {
                    VStack(spacing: 8) {
                        Text(message).font(.callout).multilineTextAlignment(.center)
                        Text("监控在同一条 SSH 连接上另开通道执行命令，堡垒机或网络设备可能不允许").font(.caption).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        Button("重试") { monitor.retry() }
                    }
                }
            case .disconnected:
                placeholder {
                    VStack(spacing: 8) {
                        Text("连接已断开").foregroundStyle(.secondary)
                        if tab.isConnected { Button("重新开始") { monitor.retry() } }
                    }
                }
            }
        }
    }

    private func placeholder<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack { Spacer(); content().padding(); Spacer() }.frame(maxWidth: .infinity)
    }

    private func dashboard(_ sample: ServerSample) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header(sample)
                cpuSection(sample)
                memorySection(sample)
                networkSection
                if !sample.disks.isEmpty { diskSection(sample) }
                if !sample.processes.isEmpty { processSection(sample) }
            }
            .padding(12)
        }
    }

    // MARK: 各部分

    private func header(_ sample: ServerSample) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(sample.hostname.isEmpty ? (tab.profile?.host ?? "") : sample.hostname)
                .font(.headline)
                .lineLimit(1)
            HStack(spacing: 6) {
                Text("Linux · 已运行 \(Format.uptime(sample.uptime))")
                Spacer()
                if let warning = monitor.warning {
                    Label("刚才没采到", systemImage: "exclamationmark.triangle.fill")
                        .labelStyle(.titleAndIcon)
                        .help(warning)
                } else if let date = monitor.updatedAt {
                    Text("更新于 \(date.formatted(date: .omitted, time: .standard))")
                        .monospacedDigit()
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private func cpuSection(_ sample: ServerSample) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            StatLine(title: "CPU", value: monitor.rates.map { Format.percent($0.cpuPercent) } ?? "—")
            Text(cpuDetail(sample)).font(.caption).foregroundStyle(.secondary)
            Sparkline(series: [.init(name: "CPU", color: ChartColors.series1, points: monitor.cpu)],
                      maximum: 100, format: Format.percent)
        }
    }

    private func cpuDetail(_ sample: ServerSample) -> String {
        var parts: [String] = []
        if sample.cores > 0 { parts.append("\(sample.cores) 核") }
        if sample.load.count == 3 {
            parts.append("负载 " + sample.load.map { String(format: "%.2f", $0) }.joined(separator: " / "))
        }
        return parts.joined(separator: " · ")
    }

    private func memorySection(_ sample: ServerSample) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            let fraction = sample.memoryTotalKB > 0 ? Double(sample.memoryUsedKB) / Double(sample.memoryTotalKB) : 0
            StatLine(title: "内存", value: Format.percent(fraction * 100))
            Text("已用 \(Format.kilobytes(sample.memoryUsedKB)) / 共 \(Format.kilobytes(sample.memoryTotalKB)) · 可用 \(Format.kilobytes(sample.memoryAvailableKB))")
                .font(.caption)
                .foregroundStyle(.secondary)
            Sparkline(series: [.init(name: "内存", color: ChartColors.series1, points: monitor.memory)],
                      maximum: 100, format: Format.percent)
            if sample.swapTotalKB > 0 {
                let used = sample.swapTotalKB - min(sample.swapFreeKB, sample.swapTotalKB)
                MeterRow(title: "交换分区", fraction: Double(used) / Double(sample.swapTotalKB),
                         detail: "\(Format.kilobytes(used)) / \(Format.kilobytes(sample.swapTotalKB))")
            }
        }
    }

    private var networkSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("网络").font(.subheadline.weight(.semibold))
            // 两条线：图例常驻，并带上当前速度
            HStack(spacing: 14) {
                LegendItem(color: ChartColors.series1, title: "下载",
                           value: monitor.rates.map { Format.rate($0.receivedPerSecond) } ?? "—")
                LegendItem(color: ChartColors.series2, title: "上传",
                           value: monitor.rates.map { Format.rate($0.sentPerSecond) } ?? "—")
                Spacer(minLength: 0)
                // 纵轴是自动的，标出图上的最高值
                if let peak = (monitor.received + monitor.sent).map(\.value).max() {
                    Text("峰值 \(Format.rate(peak))").font(.caption2).foregroundStyle(.secondary)
                }
            }
            Sparkline(series: [
                .init(name: "下载", color: ChartColors.series1, points: monitor.received),
                .init(name: "上传", color: ChartColors.series2, points: monitor.sent),
            ], maximum: nil, format: Format.rate)
        }
    }

    private func diskSection(_ sample: ServerSample) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("磁盘").font(.subheadline.weight(.semibold))
            ForEach(sample.disks, id: \.mount) { disk in
                MeterRow(title: disk.mount, fraction: disk.fraction, percentText: "\(disk.percent)%",
                         detail: "\(Format.kilobytes(disk.usedKB)) / \(Format.kilobytes(disk.usedKB + disk.availableKB))",
                         help: "\(disk.filesystem) 挂载在 \(disk.mount)，剩余 \(Format.kilobytes(disk.availableKB))")
            }
        }
    }

    private func processSection(_ sample: ServerSample) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("占用 CPU 最多的进程").font(.subheadline.weight(.semibold))
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 3) {
                GridRow {
                    Text("PID").gridColumnAlignment(.trailing)
                    Text("CPU").gridColumnAlignment(.trailing)
                    Text("内存").gridColumnAlignment(.trailing)
                    Text("命令")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                ForEach(sample.processes, id: \.pid) { process in
                    GridRow {
                        Text(String(process.pid)).foregroundStyle(.secondary)
                        Text(String(format: "%.1f%%", process.cpu))
                        Text(String(format: "%.1f%%", process.memory))
                        Text(process.command).lineLimit(1).truncationMode(.middle)
                    }
                    .font(.caption.monospacedDigit())
                }
            }
        }
    }
}

// MARK: - 小部件

/// 标题 + 当前值（大号数字）
private struct StatLine: View {
    let title: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.subheadline.weight(.semibold))
            Spacer()
            Text(value).font(.title3.weight(.semibold))
        }
    }
}

/// 图例：色块 + 名称 + 当前值（文字用正文颜色，颜色只在色块上）
private struct LegendItem: View {
    let color: Color
    let title: String
    let value: String

    var body: some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 1.5).fill(color).frame(width: 10, height: 3)
            Text(title).foregroundStyle(.secondary)
            Text(value).monospacedDigit()
        }
        .font(.caption)
    }
}

/// 一行带进度条的占用：磁盘、交换分区。快满时换成警告色，并配图标和文字
private struct MeterRow: View {
    let title: String
    let fraction: Double
    var percentText: String?
    let detail: String
    var help: String?

    private enum Level { case normal, warning, critical }

    private var level: Level {
        fraction >= 0.9 ? .critical : fraction >= 0.8 ? .warning : .normal
    }

    private var color: Color {
        switch level {
        case .normal: ChartColors.series1
        case .warning: ChartColors.warning
        case .critical: ChartColors.critical
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(title).lineLimit(1).truncationMode(.middle)
                if level != .normal {
                    Label(level == .critical ? "空间不足" : "快满了", systemImage: "exclamationmark.triangle.fill")
                        .labelStyle(.titleAndIcon)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(percentText ?? Format.percent(fraction * 100)).monospacedDigit()
            }
            .font(.caption)
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(color.opacity(0.18))
                    Capsule().fill(color)
                        .frame(width: max(fraction > 0 ? 6 : 0, geometry.size.width * min(max(fraction, 0), 1)))
                }
            }
            .frame(height: 6)
            Text(detail).font(.caption2).foregroundStyle(.secondary)
        }
        .help(help ?? detail)
    }
}

/// 最近 3 分钟的小曲线。鼠标移上去显示那一刻的数值
struct Sparkline: View {
    struct Series: Identifiable {
        var id: String { name }
        let name: String
        let color: Color
        let points: [ServerMonitor.Point]
    }

    let series: [Series]
    /// 固定的上限（百分比用 100）；nil 时按数据自动
    let maximum: Double?
    let format: (Double) -> String
    @StateObject private var hover = HoverState()

    final class HoverState: ObservableObject {
        @Published var date: Date?
    }

    private var dates: [Date] {
        series.flatMap { $0.points.map(\.date) }
    }

    private var upperBound: Double {
        if let maximum { return maximum }
        let peak = series.flatMap { $0.points.map(\.value) }.max() ?? 0
        return max(peak * 1.15, 1024)
    }

    private var xDomain: ClosedRange<Date> {
        let end = dates.max() ?? Date()
        return end.addingTimeInterval(-ServerMonitor.interval * Double(ServerMonitor.historyLength - 1))...end
    }

    var body: some View {
        let single = series.count == 1
        Chart {
            ForEach(series) { line in
                if single {
                    ForEach(line.points) { point in
                        AreaMark(x: .value("时间", point.date), y: .value(line.name, point.value))
                            .foregroundStyle(line.color.opacity(0.1))
                            .interpolationMethod(.monotone)
                    }
                }
                ForEach(line.points) { point in
                    LineMark(x: .value("时间", point.date), y: .value(line.name, point.value), series: .value("曲线", line.name))
                        .foregroundStyle(line.color)
                        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                        .interpolationMethod(.monotone)
                }
                // 最新的一点：带一圈背景色的小圆点
                if let last = (hover.date.flatMap { date in line.points.first { $0.date == date } }) ?? line.points.last {
                    PointMark(x: .value("时间", last.date), y: .value(line.name, last.value))
                        .symbol {
                            ZStack {
                                Circle().fill(ChartColors.surface).frame(width: 12, height: 12)
                                Circle().fill(line.color).frame(width: 8, height: 8)
                            }
                        }
                }
            }
            if let date = hover.date {
                RuleMark(x: .value("时间", date))
                    .foregroundStyle(ChartColors.axis)
                    .lineStyle(StrokeStyle(lineWidth: 1))
            }
        }
        .chartXScale(domain: xDomain)
        .chartYScale(domain: 0...upperBound)
        .chartXAxis(.hidden)
        .chartYAxis {
            AxisMarks(values: [0, upperBound]) { _ in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 1)).foregroundStyle(ChartColors.grid)
            }
        }
        .chartLegend(.hidden)
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            guard let plot = proxy.plotFrame else { return }
                            let origin = geometry[plot].origin
                            guard let date: Date = proxy.value(atX: location.x - origin.x) else { return }
                            hover.date = dates.min { abs($0.timeIntervalSince(date)) < abs($1.timeIntervalSince(date)) }
                        case .ended:
                            hover.date = nil
                        }
                    }
            }
        }
        .overlay(alignment: .topLeading) { tooltip }
        .frame(height: 54)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(series.map { line in "\(line.name) 当前 \(line.points.last.map { format($0.value) } ?? "无数据")" }.joined(separator: "，"))
    }

    @ViewBuilder
    private var tooltip: some View {
        if let date = hover.date {
            let values = series.compactMap { line in
                line.points.first { $0.date == date }.map { (line.name, line.color, $0.value) }
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(date.formatted(date: .omitted, time: .standard)).foregroundStyle(.secondary)
                ForEach(values, id: \.0) { name, color, value in
                    HStack(spacing: 4) {
                        Circle().fill(color).frame(width: 6, height: 6)
                        Text("\(name) \(format(value))")
                    }
                }
            }
            .font(.caption2.monospacedDigit())
            .padding(4)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 4))
        }
    }
}

/// 图表的颜色。系列色和状态色取自一套验证过色盲可读性的配色，浅色、深色各一套
enum ChartColors {
    static let series1 = dynamic(light: 0x2A78D6, dark: 0x3987E5)
    static let series2 = dynamic(light: 0xEB6834, dark: 0xD95926)
    static let warning = Color(nsColor: rgb(0xFAB219))
    static let critical = Color(nsColor: rgb(0xD03B3B))
    static let grid = dynamic(light: 0xE1E0D9, dark: 0x2C2C2A)
    static let axis = dynamic(light: 0xC3C2B7, dark: 0x383835)
    static let surface = Color(nsColor: .controlBackgroundColor)

    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? rgb(dark) : rgb(light)
        })
    }

    private static func rgb(_ value: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
                green: CGFloat((value >> 8) & 0xFF) / 255,
                blue: CGFloat(value & 0xFF) / 255,
                alpha: 1)
    }
}

/// 数字格式
enum Format {
    static func percent(_ value: Double) -> String {
        value < 10 && value > 0 ? String(format: "%.1f%%", value) : "\(Int(value.rounded()))%"
    }

    static func kilobytes(_ value: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(value) * 1024, countStyle: .memory)
    }

    static func rate(_ bytesPerSecond: Double) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytesPerSecond.rounded()), countStyle: .memory) + "/s"
    }

    static func uptime(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds / 60)
        let days = minutes / 1440
        let hours = minutes % 1440 / 60
        if days > 0 { return "\(days) 天 \(hours) 小时" }
        if hours > 0 { return "\(hours) 小时 \(minutes % 60) 分" }
        return "\(minutes) 分钟"
    }
}
