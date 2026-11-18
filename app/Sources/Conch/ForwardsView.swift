import ConchKit
import SwiftUI

/// 状态栏上点开的端口转发面板：看这个连接上的转发状态，临时加一条或停掉
struct ForwardsPopover: View {
    @ObservedObject var tab: TerminalSession
    @StateObject private var draft = ForwardDraft()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("端口转发").font(.headline)
            if tab.forwards.isEmpty {
                Text("这个连接上还没有端口转发。可以在下面临时加一条，或者在会话设置里配好，以后连上就自动开启。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                // 每秒刷新一次连接数
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(tab.forwards) { entry in
                            ForwardRow(entry: entry, tab: tab)
                        }
                    }
                }
            }
            Divider()
            Text("临时添加（只对这个标签页有效，断线重连后自动恢复）").font(.caption).foregroundStyle(.secondary)
            ForwardRuleFields(rule: $draft.rule)
            HStack {
                Spacer()
                Button("添加") {
                    tab.addForward(draft.rule)
                    draft.reset()
                }
                .disabled(!draft.rule.isValid || !tab.isConnected)
            }
        }
        .padding(14)
        .frame(width: 440)
        // 弹出面板会继承状态栏的“只显示一行”，这里改回来
        .lineLimit(nil)
        .font(.body)
    }
}

final class ForwardDraft: ObservableObject {
    @Published var rule = ForwardRule(kind: .local, bindPort: 8080, targetHost: "127.0.0.1", targetPort: 80)

    func reset() {
        rule = ForwardRule(kind: rule.kind, bindHost: rule.bindHost, bindPort: rule.bindPort + 1,
                           targetHost: rule.targetHost, targetPort: rule.targetPort)
    }
}

private struct ForwardRow: View {
    @ObservedObject var entry: ForwardEntry
    let tab: TerminalSession

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Circle().fill(color).frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.rule.summary).font(.callout.monospaced()).lineLimit(1).truncationMode(.middle)
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            if case .running = entry.state {
                Button("停止") { entry.handle?.stop(); entry.state = .stopped("已停止") }
                    .controlSize(.small)
            } else if tab.isConnected {
                Button("启动") { tab.restartForward(entry) }
                    .controlSize(.small)
            }
            Button {
                tab.removeForward(entry)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("移除（会话设置里配的转发，下次连接还会开启）")
        }
    }

    private var color: SwiftUI.Color {
        switch entry.state {
        case .running: .green
        case .starting: .orange
        case .failed: .red
        case .stopped: .gray
        }
    }

    private var detail: String {
        switch entry.state {
        case .starting:
            return "正在启动…"
        case .running:
            guard let status = entry.handle?.status() else { return "运行中" }
            if let stopped = status.stopped { return stopped }
            let traffic = ByteCountFormatter.string(fromByteCount: Int64(status.bytesSent + status.bytesReceived), countStyle: .file)
            let address = entry.rule.kind == .remote ? "服务器上监听 \(entry.listenAddress)" : "本机监听 \(entry.listenAddress)"
            return "\(address) · 当前 \(status.activeConnections) 个连接，累计 \(status.totalConnections) 个 · \(traffic)"
        case .failed(let message):
            return message
        case .stopped(let reason):
            return reason
        }
    }
}

/// 编辑一条转发规则的几个输入框（会话编辑器和临时添加共用）
struct ForwardRuleFields: View {
    @Binding var rule: ForwardRule

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("类型", selection: $rule.kind) {
                ForEach(ForwardRule.Kind.allCases, id: \.self) { kind in
                    Text(kind.title).tag(kind)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            HStack(spacing: 6) {
                Text(rule.kind == .remote ? "服务器监听" : "本机监听").font(.callout).frame(width: 74, alignment: .leading)
                TextField("地址", text: $rule.bindHost).frame(width: 110)
                Text(":")
                TextField("端口", value: $rule.bindPort, format: .number.grouping(.never)).frame(width: 64)
            }
            if rule.kind != .dynamic {
                HStack(spacing: 6) {
                    Text(rule.kind == .remote ? "转到本机" : "转到").font(.callout).frame(width: 74, alignment: .leading)
                    TextField("目标主机", text: $rule.targetHost).frame(width: 110)
                    Text(":")
                    TextField("端口", value: $rule.targetPort, format: .number.grouping(.never)).frame(width: 64)
                }
            }
            Text(explanation).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .textFieldStyle(.roundedBorder)
    }

    private var explanation: String {
        switch rule.kind {
        case .local:
            "访问本机 \(rule.bindHost):\(rule.bindPort) 就等于在服务器上访问 \(rule.targetHost):\(rule.targetPort)，常用来连内网的数据库、管理后台（ssh -L）。"
        case .remote:
            "服务器上访问 \(rule.bindHost):\(rule.bindPort)，会转到你这台 Mac 能访问的 \(rule.targetHost):\(rule.targetPort)（ssh -R）。"
        case .dynamic:
            "在本机 \(rule.bindHost):\(rule.bindPort) 开一个 SOCKS5 代理，浏览器等设好代理后，流量都从服务器出去（ssh -D）。"
        }
    }
}

/// 会话编辑器里的“端口转发”一节
struct ForwardRulesEditor: View {
    @Binding var rules: [ForwardRule]

    var body: some View {
        ForEach($rules) { $rule in
            HStack(alignment: .top) {
                Toggle("", isOn: $rule.enabled).labelsHidden().help("连接后自动开启")
                ForwardRuleFields(rule: $rule)
                Button {
                    rules.removeAll { $0.id == rule.id }
                } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.borderless)
            }
            .padding(.vertical, 2)
        }
        Button {
            rules.append(ForwardRule(kind: .local, bindPort: 8080, targetHost: "127.0.0.1", targetPort: 80))
        } label: {
            Label("添加端口转发", systemImage: "plus")
        }
    }
}
