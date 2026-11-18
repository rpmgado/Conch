import AppKit
import ConchKit
import SwiftUI

/// 新建 / 编辑会话的表单（以 sheet 弹出）
struct SessionEditor: View {
    let request: EditorRequest
    let workspace: WorkspaceModel
    @StateObject private var model: EditorModel
    @ObservedObject private var store = SessionStore.shared

    init(request: EditorRequest, workspace: WorkspaceModel) {
        self.request = request
        self.workspace = workspace
        _model = StateObject(wrappedValue: EditorModel(profile: request.profile))
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Text(request.isNew ? "新建会话" : "编辑会话")
                        .font(.system(size: 17, weight: .bold))
                    Spacer()
                    if !request.isNew {
                        Text(model.profile.displayName)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                ThemedSegments(
                    options: ConnectionKind.allCases.map { ($0.title, $0) },
                    selection: kindBinding,
                    height: 28
                )
                .accessibilityElement(children: .contain)
                .accessibilityLabel("连接协议")
            }
            .padding(.horizontal, 22)
            .padding(.top, 20)
            .padding(.bottom, 4)
            Form {
                switch model.profile.kind {
                case .ssh: sshSections
                case .telnet: telnetSections
                case .serial: serialSections
                }

                Section("会话名称与分组") {
                    TextField("名称", text: $model.profile.name, prompt: Text("留空就显示地址"))
                    HStack {
                        TextField("分组", text: $model.profile.group, prompt: Text("顶层；多级用 / 分隔"))
                        if let environment = store.library.environment(ofGroup: model.profile.group) {
                            EnvironmentChip(environment: environment)
                        }
                        Menu {
                            Button("顶层") { model.profile.group = "" }
                            ForEach(store.library.allGroups, id: \.self) { group in
                                Button(group) { model.profile.group = group }
                            }
                        } label: {
                            Image(systemName: "folder")
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        .help("选择已有的分组")
                    }
                }

                Section {
                    DisclosureGroup(isExpanded: $model.showAdvanced) {
                        advancedOptions
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("高级设置")
                            Text(model.profile.isSSH ? "跳板机、编码、日志、端口转发及备注" : "编码、重连、日志及备注")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                if !request.isNew {
                    Text(model.profile.address).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("取消") { workspace.editor = nil }
                    .keyboardShortcut(.cancelAction)
                Button("保存") { save(connect: false) }
                    .disabled(!model.profile.isValid)
                Button("保存并连接") { save(connect: true) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.profile.isValid)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(width: 540, height: 640)
        .navigationTitle(request.isNew ? "新建会话" : "编辑会话")
    }

    /// 切换协议时顺手把默认端口改过来
    private var kindBinding: Binding<ConnectionKind> {
        Binding(
            get: { model.profile.kind },
            set: { kind in
                if kind == .telnet, model.profile.port == 22 { model.profile.port = 23 }
                if kind == .ssh, model.profile.port == 23 { model.profile.port = 22 }
                if kind == .serial, model.profile.serial.path.isEmpty {
                    model.profile.serial.path = listSerialPorts().first { $0.contains("usb") } ?? ""
                }
                model.profile.kind = kind
            }
        )
    }

    @ViewBuilder
    private var sshSections: some View {
        Section {
            TextField("主机", text: $model.profile.host, prompt: Text("IP 或域名"))
            TextField("端口", value: $model.profile.port, format: .number.grouping(.never))
            TextField("用户名", text: $model.profile.username)
        }

        Section {
            Picker("认证方式", selection: $model.profile.auth) {
                ForEach(AuthKind.allCases) { kind in
                    Text(kind.title).tag(kind)
                }
            }
            .pickerStyle(.segmented)
            authFields
        }

    }

    @ViewBuilder
    private var telnetSections: some View {
        Section {
            TextField("主机", text: $model.profile.host, prompt: Text("IP 或域名"))
            TextField("端口", value: $model.profile.port, format: .number.grouping(.never))
        } footer: {
            Text("Telnet 不加密，账号密码和所有内容在网络上都是明文，只建议在内网连网络设备、老系统时使用。登录提示会出现在终端里，直接输入即可。")
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var serialSections: some View {
        Section {
            HStack {
                Picker("串口设备", selection: $model.profile.serial.path) {
                    if model.profile.serial.path.isEmpty { Text("请选择").tag("") }
                    ForEach(model.serialPorts, id: \.self) { port in
                        Text((port as NSString).lastPathComponent).tag(port)
                    }
                    if !model.profile.serial.path.isEmpty, !model.serialPorts.contains(model.profile.serial.path) {
                        Text("\((model.profile.serial.path as NSString).lastPathComponent)（未连接）").tag(model.profile.serial.path)
                    }
                }
                Button { model.refreshSerialPorts() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .help("插上 USB 转串口线后点这里刷新")
            }
            Picker("波特率", selection: $model.profile.serial.baudRate) {
                ForEach(SerialSettings.baudRates, id: \.self) { rate in Text(String(rate)).tag(rate) }
            }
            Picker("数据位", selection: $model.profile.serial.dataBits) {
                ForEach([5, 6, 7, 8], id: \.self) { bits in Text(String(bits)).tag(bits) }
            }
            .pickerStyle(.segmented)
            Picker("校验", selection: $model.profile.serial.parity) {
                Text("无").tag("none")
                Text("奇校验").tag("odd")
                Text("偶校验").tag("even")
            }
            .pickerStyle(.segmented)
            Picker("停止位", selection: $model.profile.serial.stopBits) {
                Text("1").tag(1)
                Text("2").tag(2)
            }
            .pickerStyle(.segmented)
            Picker("流控", selection: $model.profile.serial.flowControl) {
                Text("无").tag("none")
                Text("硬件 RTS/CTS").tag("hardware")
                Text("软件 XON/XOFF").tag("software")
            }
        } footer: {
            Text("交换机、路由器的 Console 口一般是 9600 8N1、无流控。设备列表里看不到时，检查 USB 转串口线的驱动。")
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var advancedOptions: some View {
        if model.profile.isSSH {
            Picker("跳板机", selection: $model.profile.jumpHostID) {
                Text("不使用").tag(UUID?.none)
                ForEach(store.library.jumpCandidates(for: model.profile.id).filter(\.isSSH)) { candidate in
                    Text(candidate.displayName).tag(UUID?.some(candidate.id))
                }
            }
            Toggle("兼容老设备算法", isOn: $model.profile.legacyAlgorithms)
                .help("只在连接老设备且默认算法不可用时开启")
        }
        commonOptions
        if model.profile.isSSH {
            Text("端口转发").font(.headline).padding(.top, 6)
            ForwardRulesEditor(rules: $model.profile.forwards)
        }
        TextField("备注", text: $model.profile.notes, axis: .vertical)
            .lineLimit(2...4)
    }

    /// 编码、自动重连、日志（三种协议都有）
    @ViewBuilder
    private var commonOptions: some View {
        Picker("字符编码", selection: $model.profile.encoding) {
            ForEach(TerminalEncoding.all, id: \.label) { item in
                Text(item.title).tag(item.label)
            }
            if !TerminalEncoding.all.contains(where: { $0.label == model.profile.encoding }) {
                Text(model.profile.encoding).tag(model.profile.encoding)
            }
        }
        .help("远端是 GBK 等编码（老服务器、网络设备常见）时选对应的编码，否则中文会乱码")
        Toggle(model.profile.kind == .serial ? "设备断开后自动重新打开" : "断线后自动重连", isOn: $model.profile.autoReconnect)
        Toggle("连接后自动记录会话日志", isOn: $model.profile.logSession)
    }

    @ViewBuilder
    private var authFields: some View {
        switch model.profile.auth {
        case .auto:
            Text("依次尝试 ssh-agent、私钥文件、密码，和 ssh 命令的默认做法一样。需要密码时会弹窗询问。")
                .font(.callout)
                .foregroundStyle(.secondary)
            keyPathField(title: "私钥", prompt: "可选，不填就用 ~/.ssh/id_ed25519 等默认私钥")
        case .password:
            SecureField("密码", text: $model.password,
                        prompt: Text(model.hasSavedPassword ? "已保存在钥匙串，留空不修改" : "留空就在连接时询问"))
            Toggle("保存到钥匙串", isOn: $model.savePassword)
        case .key:
            keyPathField(title: "私钥", prompt: "~/.ssh/id_ed25519")
            SecureField("私钥口令", text: $model.passphrase,
                        prompt: Text(model.hasSavedPassphrase ? "已保存在钥匙串，留空不修改" : "没有口令就留空"))
            Toggle("口令保存到钥匙串", isOn: $model.savePassword)
        case .agent:
            Text("只用 ssh-agent 里的密钥：系统钥匙串、1Password、Secretive 都可以。")
                .font(.callout)
                .foregroundStyle(.secondary)
            TextField("agent socket", text: $model.profile.identityAgent, prompt: Text("可选，默认用 SSH_AUTH_SOCK"))
        }
    }

    private func keyPathField(title: String, prompt: String) -> some View {
        HStack {
            TextField(title, text: Binding(
                get: { model.profile.keyPath },
                set: { model.profile.keyPath = $0.trimmingCharacters(in: .whitespaces) }
            ), prompt: Text(prompt))
            Button("选择…") { chooseKey() }
        }
    }

    private func chooseKey() {
        let panel = NSOpenPanel()
        panel.title = "选择私钥"
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh")
        panel.showsHiddenFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            model.profile.keyPath = (url.path as NSString).abbreviatingWithTildeInPath
            model.refreshSavedState()
        }
    }

    private func save(connect: Bool) {
        var profile = model.profile
        profile.group = GroupPath.normalize(profile.group)
        profile.host = profile.host.trimmingCharacters(in: .whitespaces)
        profile.username = profile.username.trimmingCharacters(in: .whitespaces)
        store.upsert(profile)

        // 这次连接要用的秘密信息；勾选了保存的同时写进钥匙串
        var entered: [(SecretKey, String)] = []
        if profile.auth == .password, !model.password.isEmpty {
            entered.append((.password(for: profile), model.password))
        }
        if profile.auth == .key, !model.passphrase.isEmpty, !profile.keyPath.isEmpty {
            entered.append((.passphrase(path: profile.keyPath), model.passphrase))
        }
        if model.savePassword {
            for (key, value) in entered { Keychain.save(value, for: key) }
        }
        // 正在用的标签页（快速连接保存成会话）直接用它自己的内存，否则给新标签页一份
        let secrets = request.adoptingTab?.secrets ?? SessionSecrets()
        for (key, value) in entered { secrets.set(key, value) }

        request.adoptingTab?.adopt(profile)
        workspace.editor = nil
        if connect {
            if let tab = request.adoptingTab {
                workspace.select(tab)
                tab.reconnect()
            } else {
                workspace.open(profile, secrets: secrets)
            }
        }
    }
}

final class EditorModel: ObservableObject {
    @Published var profile: SessionProfile {
        didSet {
            if oldValue.endpointKey != profile.endpointKey || oldValue.keyPath != profile.keyPath {
                refreshSavedState()
            }
        }
    }
    @Published var showAdvanced = false
    @Published var password = ""
    @Published var passphrase = ""
    @Published var savePassword = true
    @Published private(set) var hasSavedPassword = false
    @Published private(set) var hasSavedPassphrase = false
    @Published private(set) var serialPorts: [String] = listSerialPorts()

    func refreshSerialPorts() {
        serialPorts = listSerialPorts()
    }

    init(profile: SessionProfile) {
        self.profile = profile
        showAdvanced = profile.jumpHostID != nil || profile.legacyAlgorithms || profile.encoding != "UTF-8"
            || !profile.forwards.isEmpty || !profile.notes.isEmpty || profile.logSession
        refreshSavedState()
    }

    /// 只查钥匙串里有没有，不读内容（不会弹授权框）
    func refreshSavedState() {
        hasSavedPassword = !profile.host.isEmpty && Keychain.exists(.password(for: profile))
        hasSavedPassphrase = !profile.keyPath.isEmpty && Keychain.exists(.passphrase(path: profile.keyPath))
    }
}
