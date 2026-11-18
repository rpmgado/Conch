import Foundation
import Testing
@testable import ConchKit

// MARK: - 会话模型

@Suite("会话模型和会话库")
struct SessionLibraryTests {
    @Test("老存档缺字段时用默认值")
    func decodesOldArchives() throws {
        let json = #"{"sessions":[{"id":"6B0A2C1E-1111-4C3B-9A55-0123456789AB","host":"10.0.0.5","username":"root"}]}"#
        let library = try JSONDecoder().decode(SessionLibrary.self, from: Data(json.utf8))
        let profile = try #require(library.sessions.first)
        #expect(profile.port == 22)
        #expect(profile.auth == .auto)
        #expect(profile.autoReconnect)
        #expect(profile.displayName == "root@10.0.0.5")
        #expect(library.groups.isEmpty)
    }

    @Test("树：分组在前、会话在后，都按名称排序，空分组也显示")
    func treeOrdering() {
        var library = SessionLibrary()
        library.upsert(SessionProfile(name: "web-10", group: "生产", host: "a"))
        library.upsert(SessionProfile(name: "web-2", group: "生产", host: "b"))
        library.upsert(SessionProfile(name: "db", group: "生产/数据库", host: "c"))
        library.upsert(SessionProfile(name: "local", host: "d"))
        library.addGroup("空分组")
        let tree = library.tree()
        #expect(tree.map(\.title) == ["空分组", "生产", "local"])
        let prod = tree[1]
        #expect(prod.children?.map(\.title) == ["数据库", "web-2", "web-10"])
        #expect(tree[0].children == [])
        #expect(tree[2].children == nil)
    }

    @Test("改分组名会带上下级分组和里面的会话")
    func renameGroup() {
        var library = SessionLibrary(groups: ["生产/空"])
        library.upsert(SessionProfile(name: "db", group: "生产/数据库", host: "c"))
        library.upsert(SessionProfile(name: "x", group: "生产其他", host: "e"))
        library.renameGroup("生产", to: "线上")
        #expect(library.sessions.first { $0.name == "db" }?.group == "线上/数据库")
        #expect(library.sessions.first { $0.name == "x" }?.group == "生产其他")
        #expect(library.allGroups.contains("线上/空"))
        #expect(!library.allGroups.contains("生产"))
    }

    @Test("删除分组时会话挪到上一级，不会丢")
    func removeGroupLiftsSessions() {
        var library = SessionLibrary(groups: ["a/b/c"])
        library.upsert(SessionProfile(name: "s1", group: "a/b", host: "h"))
        library.upsert(SessionProfile(name: "s2", group: "a/b/c", host: "h"))
        library.removeGroup("a/b")
        #expect(library.sessions.map(\.group).sorted() == ["a", "a/c"])
        #expect(library.allGroups == ["a", "a/c"])
    }

    @Test("跳板机链：最外层在前；被删除、循环都会报错")
    func jumpChains() throws {
        var library = SessionLibrary()
        let outer = SessionProfile(name: "outer", host: "o")
        var inner = SessionProfile(name: "inner", host: "i")
        inner.jumpHostID = outer.id
        var target = SessionProfile(name: "target", host: "t")
        target.jumpHostID = inner.id
        library.upsert(outer)
        library.upsert(inner)
        library.upsert(target)
        #expect(try library.jumpChain(for: target).map(\.name) == ["outer", "inner"])

        // 候选里不能有会形成循环的
        #expect(!library.jumpCandidates(for: outer.id).contains { $0.id == target.id })
        #expect(library.jumpCandidates(for: target.id).map(\.name) == ["inner", "outer"])

        var looped = library
        var outerLoop = outer
        outerLoop.jumpHostID = target.id
        looped.upsert(outerLoop)
        #expect(throws: SessionLibrary.ChainError.self) { try looped.jumpChain(for: target) }

        // 删除跳板机会把引用清掉
        library.remove(ids: [inner.id])
        #expect(library.session(target.id)?.jumpHostID == nil)
    }

    @Test("导入合并：重复的跳过，跳板机引用改指向已有会话")
    func mergeImports() {
        var library = SessionLibrary()
        let existingJump = SessionProfile(name: "jump", group: "SSH 配置", host: "j", username: "ops")
        library.upsert(existingJump)

        let importedJump = SessionProfile(name: "jump", group: "SSH 配置", host: "j", username: "ops")
        var importedTarget = SessionProfile(name: "app", group: "SSH 配置", host: "a", username: "ops")
        importedTarget.jumpHostID = importedJump.id
        let (added, skipped) = library.merge([importedJump, importedTarget])
        #expect(added == 1)
        #expect(skipped == 1)
        #expect(library.sessions.first { $0.name == "app" }?.jumpHostID == existingJump.id)
    }

    @Test("搜索名称、主机、用户、分组")
    func search() {
        var library = SessionLibrary()
        library.upsert(SessionProfile(name: "订单库", group: "生产", host: "10.1.2.3", username: "dba"))
        library.upsert(SessionProfile(name: "web", group: "测试", host: "web.test", username: "deploy"))
        #expect(library.search("订单").map(\.name) == ["订单库"])
        #expect(library.search("dba 10.1").map(\.name) == ["订单库"])
        #expect(library.search("测试").map(\.name) == ["web"])
        #expect(library.search("").count == 2)
    }
}

// MARK: - ssh_config

@Suite("ssh_config 解析和导入")
struct SSHConfigTests {
    let home = URL(fileURLWithPath: "/Users/tester")

    @Test("第一个值生效，Host * 兜底，通配符和取反")
    func firstValueWins() {
        let config = SSHConfig.parse("""
        # 注释
        Host web-*  !web-legacy
            User deploy
            Port 2200

        Host web-1
            HostName 10.0.0.1
            User shouldnotwin

        Host web-legacy
            HostName 10.0.0.9

        Host *
            User fallback
            IdentityFile ~/.ssh/id_work
            Port 22
        """, home: home)
        #expect(config.aliases == ["web-1", "web-legacy"])

        let web1 = config.resolve("web-1", localUser: "me", home: home)
        #expect(web1.hostName == "10.0.0.1")
        #expect(web1.user == "deploy")
        #expect(web1.port == 2200)
        #expect(web1.identityFiles == ["/Users/tester/.ssh/id_work"])

        let legacy = config.resolve("web-legacy", localUser: "me", home: home)
        #expect(legacy.user == "fallback")
        #expect(legacy.port == 22)
    }

    @Test("Key=Value 写法、引号、多个 IdentityFile、%token 展开、IdentityAgent")
    func syntaxVariants() {
        let config = SSHConfig.parse("""
        Host box
          HostName=box.example.com
          User = alice
          IdentityFile "~/.ssh/my keys/id_%r_%h"
          IdentityFile ~/.ssh/id_rsa
          IdentitiesOnly yes
          IdentityAgent "~/Library/Group Containers/agent.sock"
        Match host box
          User nobody
        """, home: home)
        let box = config.resolve("box", localUser: "me", home: home)
        #expect(box.hostName == "box.example.com")
        #expect(box.user == "alice")
        #expect(box.identityFiles == [
            "/Users/tester/.ssh/my keys/id_alice_box.example.com",
            "/Users/tester/.ssh/id_rsa",
        ])
        #expect(box.identitiesOnly == true)
        #expect(box.identityAgent == "/Users/tester/Library/Group Containers/agent.sock")
    }

    @Test("Include 相对 ~/.ssh 展开，支持通配符")
    func include() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("conch-sshconfig-\(UUID().uuidString)")
        let sshDir = tmp.appendingPathComponent(".ssh/conf.d")
        try FileManager.default.createDirectory(at: sshDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        try "Host inc-a\n  HostName a.example.com\n".write(to: sshDir.appendingPathComponent("a.conf"), atomically: true, encoding: .utf8)
        try "Host inc-b\n  HostName b.example.com\n".write(to: sshDir.appendingPathComponent("b.conf"), atomically: true, encoding: .utf8)
        let main = tmp.appendingPathComponent(".ssh/config")
        try "Include conf.d/*.conf\nHost main\n  HostName main.example.com\n".write(to: main, atomically: true, encoding: .utf8)

        let config = SSHConfig.load(from: main, home: tmp)
        #expect(config.aliases == ["inc-a", "inc-b", "main"])
        #expect(config.resolve("inc-b", home: tmp).hostName == "b.example.com")
    }

    @Test("导入：ProxyJump 别名链、user@host:port 跳板机、ProxyCommand ssh -W")
    func importJumps() throws {
        let config = SSHConfig.parse("""
        Host bastion
          HostName bastion.example.com
          User ops
        Host inner
          HostName 10.0.0.2
          ProxyJump bastion
        Host deep
          HostName 10.0.1.3
          ProxyJump bastion,inner
        Host direct-jump
          HostName 10.0.2.4
          ProxyJump admin@gw.example.com:2222
        Host old-style
          HostName 10.0.3.5
          ProxyCommand ssh -W %h:%p -l ops bastion
        Host weird
          HostName 10.0.4.6
          ProxyCommand nc -X 5 -x proxy:1080 %h %p
        """, home: home)
        let result = SSHConfigImporter.importProfiles(from: config, localUser: "me", home: home)
        func profile(_ name: String) throws -> SessionProfile {
            try #require(result.profiles.first { $0.name == name })
        }
        let bastion = try profile("bastion")
        let inner = try profile("inner")
        #expect(inner.jumpHostID == bastion.id)
        #expect(try profile("deep").jumpHostID == inner.id)

        let gateway = try profile("admin@gw.example.com:2222")
        #expect(gateway.port == 2222)
        #expect(gateway.username == "admin")
        #expect(try profile("direct-jump").jumpHostID == gateway.id)

        // ProxyCommand ssh -W 带 -l 时等价于 ProxyJump ops@bastion，跳板机会单独建一个会话
        let oldStyle = try profile("old-style")
        let oldJump = try #require(result.profiles.first { $0.id == oldStyle.jumpHostID })
        #expect(oldJump.username == "ops")
        #expect(oldJump.host == "bastion.example.com")

        let weird = try profile("weird")
        #expect(weird.jumpHostID == nil)
        #expect(weird.notes.contains("ProxyCommand"))
        #expect(result.profiles.allSatisfy { $0.group == "SSH 配置" })
    }

    @Test("跳板机地址的各种写法")
    func jumpSpecs() {
        #expect(JumpSpec.parse("host") == JumpSpec(host: "host"))
        #expect(JumpSpec.parse("u@host:2222") == JumpSpec(user: "u", host: "host", port: 2222))
        #expect(JumpSpec.parse("u@[fe80::1]:22") == JumpSpec(user: "u", host: "fe80::1", port: 22))
        #expect(JumpSpec.parse("fe80::1") == JumpSpec(host: "fe80::1"))
        #expect(JumpSpec.parse("ssh://u@h:2") == JumpSpec(user: "u", host: "h", port: 2))
        #expect(JumpSpec.parseList("a, b@c:3").count == 2)
    }
}

// MARK: - 快速连接

@Suite("快速连接解析")
struct QuickConnectTests {
    @Test("常见写法", arguments: [
        ("10.0.0.5", QuickConnectRequest(host: "10.0.0.5")),
        ("root@10.0.0.5", QuickConnectRequest(user: "root", host: "10.0.0.5")),
        ("root@10.0.0.5:2222", QuickConnectRequest(user: "root", host: "10.0.0.5", port: 2222)),
        ("ssh -p 2200 deploy@web", QuickConnectRequest(user: "deploy", host: "web", port: 2200)),
        ("ssh web -l bob -p2201", QuickConnectRequest(user: "bob", host: "web", port: 2201)),
        ("ssh -i ~/.ssh/k -J ops@jump:22 app", QuickConnectRequest(host: "app", identityFile: "~/.ssh/k", jump: "ops@jump:22")),
        ("ssh -o StrictHostKeyChecking=no u@h", QuickConnectRequest(user: "u", host: "h")),
        ("ssh://u@[::1]:2222", QuickConnectRequest(user: "u", host: "::1", port: 2222)),
    ])
    func parses(input: String, expected: QuickConnectRequest) {
        #expect(QuickConnectRequest.parse(input) == expected)
    }

    @Test("无效输入")
    func invalid() {
        #expect(QuickConnectRequest.parse("") == nil)
        #expect(QuickConnectRequest.parse("ssh") == nil)
        #expect(QuickConnectRequest.parse("u@h:99999") == nil)
    }
}

// MARK: - Xshell

@Suite("Xshell 会话导入")
struct XshellTests {
    static let sample = """
    [SessionInfo]
    Version=7.0
    Description=订单系统主库
    [CONNECTION]
    Port=2222
    Host=192.168.10.20
    Protocol=SSH
    [CONNECTION:AUTHENTICATION]
    UserName=dba
    Method=0
    Password=加密后的内容不导入
    [TERMINAL]
    Type=xterm
    """

    static func utf16le(_ text: String) -> Data {
        var data = Data([0xFF, 0xFE])
        data.append(text.data(using: .utf16LittleEndian)!)
        return data
    }

    @Test("UTF-16 带 BOM 的会话文件")
    func parsesUTF16() throws {
        let result = XshellImporter.parse(data: Self.utf16le(Self.sample), name: "订单库", group: "Xshell")
        let profile = try result.get()
        #expect(profile.host == "192.168.10.20")
        #expect(profile.port == 2222)
        #expect(profile.username == "dba")
        #expect(profile.auth == .password)
        #expect(profile.notes == "订单系统主库")
        #expect(profile.name == "订单库")
    }

    @Test("用户密钥会写进备注；非 SSH 会话跳过")
    func keysAndSkips() throws {
        let keyed = Self.sample.replacingOccurrences(of: "Method=0", with: "Method=1\nUserKey=id_rsa_2048")
        let profile = try XshellImporter.parse(data: Data(keyed.utf8), name: "k", group: "g").get()
        #expect(profile.auth == .auto)
        #expect(profile.notes.contains("id_rsa_2048"))

        // Telnet 从阶段 3 起会导入；RLOGIN 这类还是跳过
        let rlogin = Self.sample.replacingOccurrences(of: "Protocol=SSH", with: "Protocol=RLOGIN")
        if case .success = XshellImporter.parse(data: Data(rlogin.utf8), name: "t", group: "g") {
            Issue.record("RLOGIN 会话应该被跳过")
        }
    }

    @Test("导入整个文件夹：子文件夹变成分组")
    func importsFolders() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("conch-xsh-\(UUID().uuidString)")
        let sessions = tmp.appendingPathComponent("Sessions")
        try FileManager.default.createDirectory(at: sessions.appendingPathComponent("生产/数据库"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        try Self.utf16le(Self.sample).write(to: sessions.appendingPathComponent("生产/数据库/订单库.xsh"))
        try Data(Self.sample.utf8).write(to: sessions.appendingPathComponent("跳板机.xsh"))
        try Data("not an ini".utf8).write(to: sessions.appendingPathComponent("说明.txt"))

        let result = XshellImporter.importItems(at: [sessions])
        let groups = Dictionary(uniqueKeysWithValues: result.profiles.map { ($0.name, $0.group) })
        #expect(groups["订单库"] == "Xshell/Sessions/生产/数据库")
        #expect(groups["跳板机"] == "Xshell/Sessions")
        #expect(result.profiles.count == 2)
    }
}

// MARK: - 日志纯文本过滤

@Suite("会话日志的纯文本过滤")
struct PlainTextFilterTests {
    @Test("去掉颜色、标题等控制序列，CRLF 变成 LF")
    func stripsSequences() {
        var filter = PlainTextFilter(timestamps: false)
        let input = "\u{1b}]0;user@host: ~\u{07}\u{1b}[1;32muser@host\u{1b}[0m:~$ ls\r\nfile1  \u{1b}[01;34mdir\u{1b}[0m\r\n"
        let out = filter.feed(Array(input.utf8))
        #expect(String(decoding: out, as: UTF8.self) == "user@host:~$ ls\nfile1  dir\n")
    }

    @Test("控制序列被拆成两半也能正确处理")
    func splitSequences() {
        var filter = PlainTextFilter(timestamps: false)
        var out = filter.feed(Array("abc\u{1b}[3".utf8))
        out += filter.feed(Array("1mred\u{1b}".utf8))
        out += filter.feed(Array("]2;title\u{1b}".utf8))
        out += filter.feed(Array("\\done\n".utf8))
        #expect(String(decoding: out, as: UTF8.self) == "abcreddone\n")
    }

    @Test("退格左移、后面的字覆盖（汉字占两格）；半行在 finish 时输出")
    func backspaceAndFinish() {
        var filter = PlainTextFilter(timestamps: false)
        // shell 删一个汉字时发两个退格
        var out = filter.feed(Array("中文\u{08}\u{08}字".utf8))
        #expect(out.isEmpty)
        out += filter.finish()
        #expect(String(decoding: out, as: UTF8.self) == "中字\n")

        var ascii = PlainTextFilter(timestamps: false)
        #expect(String(decoding: ascii.feed(Array("abc\u{08}\u{08}X\n".utf8)), as: UTF8.self) == "aXc\n")
    }

    @Test("回车后覆盖：zsh 的提示符、进度条、擦除行")
    func carriageReturnOverwrites() {
        var zsh = PlainTextFilter(timestamps: false)
        let promptSP = "%" + String(repeating: " ", count: 30) + "\r \r\u{1b}[0m\u{1b}[J" + "me@mac ~ % ls\r\n"
        #expect(String(decoding: zsh.feed(Array(promptSP.utf8)), as: UTF8.self) == "me@mac ~ % ls\n")

        var progress = PlainTextFilter(timestamps: false)
        #expect(String(decoding: progress.feed(Array("下载 10%\r下载 55%\r下载 100%\n".utf8)), as: UTF8.self) == "下载 100%\n")

        var erase = PlainTextFilter(timestamps: false)
        #expect(String(decoding: erase.feed(Array("hello world\r\u{1b}[Khi\n".utf8)), as: UTF8.self) == "hi\n")

        var moves = PlainTextFilter(timestamps: false)
        // 命令行编辑：光标左移两格，插入两个空位再写字
        #expect(String(decoding: moves.feed(Array("lsal\u{1b}[2D\u{1b}[2@ -\n".utf8)), as: UTF8.self) == "ls -al\n")
    }

    @Test("每行前面加时间戳")
    func timestamps() {
        let fixed = Date(timeIntervalSince1970: 0)
        var filter = PlainTextFilter(timestamps: true, clock: { fixed })
        let out = String(decoding: filter.feed(Array("a\nb\n".utf8)), as: UTF8.self)
        let lines = out.split(separator: "\n")
        #expect(lines.count == 2)
        #expect(lines.allSatisfy { $0.hasPrefix("[") && $0.contains("] ") })
        #expect(lines[1].hasSuffix("] b"))
    }
}

// MARK: - 主题

@Suite("配色主题")
struct ThemeTests {
    @Test("内置主题都是 16 色，ID 不重复")
    func palettes() {
        #expect(TerminalTheme.all.allSatisfy { $0.ansi.count == 16 })
        #expect(Set(TerminalTheme.all.map(\.id)).count == TerminalTheme.all.count)
    }

    @Test("跟随系统按深浅色切换，未知 ID 退回默认")
    func resolve() {
        #expect(TerminalTheme.resolve(TerminalTheme.systemID, darkMode: true).id == "conch-dark")
        #expect(TerminalTheme.resolve(TerminalTheme.systemID, darkMode: false).id == "conch-light")
        #expect(TerminalTheme.resolve("nope", darkMode: false).id == "conch-dark")
        #expect(TerminalTheme.resolve("dracula", darkMode: false).id == "dracula")
    }
}

// MARK: - 阶段 2：端口转发规则、快捷命令、关键字高亮

@Suite("端口转发规则")
struct ForwardRuleTests {
    @Test("ssh_config 和 ssh -L 的各种写法")
    func parsing() {
        let a = ForwardRule.parse(kind: .local, value: "8080 db.internal:3306")
        #expect(a == ForwardRule(id: a!.id, kind: .local, bindHost: "127.0.0.1", bindPort: 8080, targetHost: "db.internal", targetPort: 3306))
        let b = ForwardRule.parse(kind: .local, value: "*:9000 localhost:9000")
        #expect(b?.bindHost == "0.0.0.0" && b?.targetHost == "localhost" && b?.targetPort == 9000)
        let c = ForwardRule.parse(kind: .local, value: "5432:pg:5432")
        #expect(c?.bindPort == 5432 && c?.targetHost == "pg" && c?.bindHost == "127.0.0.1")
        let d = ForwardRule.parse(kind: .remote, value: "0.0.0.0:2222:127.0.0.1:22")
        #expect(d?.bindHost == "0.0.0.0" && d?.bindPort == 2222 && d?.targetPort == 22)
        let e = ForwardRule.parse(kind: .dynamic, value: "1080")
        #expect(e?.bindPort == 1080 && e?.kind == .dynamic && e?.isValid == true)
        let f = ForwardRule.parse(kind: .local, value: "[::1]:8443 [fe80::2]:443")
        #expect(f?.bindHost == "::1" && f?.targetHost == "fe80::2" && f?.targetPort == 443)
        #expect(ForwardRule.parse(kind: .local, value: "abc") == nil)
    }

    @Test("从 ssh_config 导入转发")
    func importsForwards() {
        let config = SSHConfig.parse("""
        Host app
          HostName 10.0.0.8
          LocalForward 8080 localhost:80
          LocalForward 3307 db:3306
          DynamicForward 1080
          RemoteForward 9000 127.0.0.1:9000
        """, home: URL(fileURLWithPath: "/Users/t"))
        let profile = SSHConfigImporter.importProfiles(from: config, localUser: "me", home: URL(fileURLWithPath: "/Users/t")).profiles.first
        #expect(profile?.forwards.count == 4)
        #expect(profile?.forwards.map(\.kind) == [.local, .local, .dynamic, .remote])
    }

    @Test("老存档没有编码和转发字段")
    func decodesWithoutNewFields() throws {
        let json = #"{"host":"h","username":"u"}"#
        let profile = try JSONDecoder().decode(SessionProfile.self, from: Data(json.utf8))
        #expect(profile.encoding == "UTF-8")
        #expect(profile.forwards.isEmpty)
    }

    @Test("快捷命令：多行逐行回车")
    func quickCommandPayload() {
        #expect(QuickCommand(name: "a", command: "df -h").payload == "df -h\r")
        #expect(QuickCommand(name: "b", command: "cd /tmp\nls", pressEnter: true).payload == "cd /tmp\rls\r")
        #expect(QuickCommand(name: "c", command: "sudo ", pressEnter: false).payload == "sudo ")
    }
}

@Suite("关键字高亮")
struct HighlighterTests {
    func run(_ input: String, _ highlighter: inout KeywordHighlighter) -> String {
        String(decoding: highlighter.process(Array(input.utf8)), as: UTF8.self)
    }

    let rules = KeywordHighlighter.rules(red: "error, failed", yellow: "warning", green: "")

    @Test("整词、不分大小写")
    func wholeWords() {
        var h = KeywordHighlighter(rules: rules)
        #expect(run("ERROR: disk failed\n", &h) == "\u{1b}[1;31mERROR\u{1b}[0m: disk \u{1b}[1;31mfailed\u{1b}[0m\n")
        // 不是整词的不动
        #expect(run("errors error_code myerror\n", &h) == "errors error_code myerror\n")
    }

    @Test("高亮后恢复原来的颜色（包括 256 色里的 0）")
    func restoresStyle() {
        var h = KeywordHighlighter(rules: rules)
        let out = run("\u{1b}[1;38;5;0mwarning here", &h)
        #expect(out == "\u{1b}[1;38;5;0m\u{1b}[1;33mwarning\u{1b}[0;1;38;5;0m here")
        let reset = run("\u{1b}[0mwarning ", &h)
        #expect(reset == "\u{1b}[0m\u{1b}[1;33mwarning\u{1b}[0m ")
    }

    @Test("全屏程序里不高亮，控制序列原样通过")
    func alternateScreen() {
        var h = KeywordHighlighter(rules: rules)
        #expect(run("\u{1b}[?1049herror\u{1b}]0;error title\u{07}", &h) == "\u{1b}[?1049herror\u{1b}]0;error title\u{07}")
        #expect(run("\u{1b}[?1049l error ", &h) == "\u{1b}[?1049l \u{1b}[1;31merror\u{1b}[0m ")
    }

    @Test("一批输出末尾的半个单词不扣着（键盘回显不会变慢）")
    func doesNotHoldBytes() {
        var h = KeywordHighlighter(rules: rules)
        #expect(run("err", &h) == "err")
        #expect(run("or\n", &h) == "or\n")
        #expect(run("中文 error 中文", &h) == "中文 \u{1b}[1;31merror\u{1b}[0m 中文")
    }
}

// MARK: - 阶段 3：连接方式、Telnet 快速连接、服务器监控

@Suite("阶段 3 的模型")
struct Phase3ModelTests {
    @Test("打开同步时合并两边的会话")
    func absorb() {
        let shared = SessionProfile(name: "两边都有", host: "10.0.0.1", username: "root")
        var renamed = shared
        renamed.name = "同步文件夹里改过名"
        let importedHere = SessionProfile(name: "web", group: "生产", host: "10.0.0.2", username: "deploy")
        var importedThere = importedHere
        importedThere.id = UUID()  // 两台 Mac 各自导入了同一台服务器
        let onlyHere = SessionProfile(name: "只有本机有", host: "10.0.0.3", username: "ops")

        var folder = SessionLibrary(sessions: [renamed, importedThere], groups: ["生产"])
        folder.absorb(SessionLibrary(sessions: [shared, importedHere, onlyHere], groups: ["测试"]))
        #expect(folder.sessions.count == 3)
        #expect(folder.session(shared.id)?.name == "同步文件夹里改过名")
        #expect(folder.sessions.contains { $0.id == onlyHere.id })
        #expect(Set(folder.groups) == ["生产", "测试"])
    }

    @Test("老存档默认是 SSH；Telnet、串口的显示和校验")
    func connectionKinds() throws {
        let old = try JSONDecoder().decode(SessionProfile.self, from: Data(#"{"host":"h","username":"u"}"#.utf8))
        #expect(old.kind == .ssh && old.isSSH)
        var telnet = SessionProfile(kind: .telnet, host: "10.0.0.1", port: 23)
        telnet.username = ""
        #expect(telnet.isValid && telnet.address == "10.0.0.1:23（Telnet）")
        var serial = SessionProfile(kind: .serial)
        #expect(!serial.isValid)
        serial.serial = SerialSettings(path: "/dev/cu.usbserial-1410", baudRate: 115200)
        #expect(serial.isValid && serial.address == "cu.usbserial-1410 115200 8N1" && !serial.isSSH)
        #expect(SerialSettings(baudRate: 9600, dataBits: 7, parity: "even", stopBits: 2).summary == "9600 7E2")
    }

    @Test("快速连接认 telnet 写法", arguments: [
        ("telnet 10.0.0.1", "10.0.0.1", 23),
        ("telnet 10.0.0.1 2323", "10.0.0.1", 2323),
        ("telnet://switch.local:8023", "switch.local", 8023),
    ])
    func telnetQuickConnect(input: String, host: String, port: Int) {
        let request = QuickConnectRequest.parse(input)
        #expect(request?.telnet == true && request?.host == host && request?.port == port)
    }

    @Test("Xshell 的 Telnet 会话会导入，串口会话说明原因后跳过")
    func xshellTelnet() throws {
        let telnet = "[CONNECTION]\nHost=192.168.1.1\nPort=23\nProtocol=TELNET\n"
        let profile = try XshellImporter.parse(data: Data(telnet.utf8), name: "核心交换机", group: "g").get()
        #expect(profile.kind == .telnet && profile.port == 23 && profile.host == "192.168.1.1")
        let serial = "[CONNECTION]\nHost=COM3\nProtocol=SERIAL\n"
        if case .failure(let reason) = XshellImporter.parse(data: Data(serial.utf8), name: "console", group: "g") {
            #expect(reason.message.contains("串口"))
        } else {
            Issue.record("串口会话应该被跳过")
        }
    }
}

@Suite("服务器监控解析")
struct ServerStatsTests {
    static func output(cpu: String, rx: UInt64, tx: UInt64) -> String {
        let s = ServerMonitorScript.separator
        return """
        Linux
        \(s)
        web-01
        \(s)
        0.52 0.48 0.40 2/345 6789
        \(s)
        \(cpu)
        \(s)
        MemTotal:        8000000 kB
        MemFree:          500000 kB
        MemAvailable:    2000000 kB
        Buffers:          100000 kB
        Cached:          1500000 kB
        SwapTotal:       2097148 kB
        SwapFree:        2000000 kB
        \(s)
        Inter-|   Receive                                                |  Transmit
         face |bytes    packets errs drop fifo frame compressed multicast|bytes    packets errs drop fifo colls carrier compressed
            lo: 999999 100 0 0 0 0 0 0 999999 100 0 0 0 0 0 0
          eth0: \(rx) 2000 0 0 0 0 0 0 \(tx) 1500 0 0 0 0 0 0
        \(s)
        Filesystem     1024-blocks      Used Available Capacity Mounted on
        udev               4000000         0   4000000       0% /dev
        tmpfs               800000      1000    799000       1% /run
        /dev/vda1         41152736  10288184  29010080      27% /
        /dev/vdb1        103081248  51540624  46281624      53% /data disk
        \(s)
        123456.78 234567.89
        \(s)
        4
        \(s)
          PID %CPU %MEM COMMAND
         1234 25.3  4.1 java
          567  3.0  0.5 nginx: worker
        """
    }

    @Test("解析 /proc 和 df、ps 的输出")
    func parse() {
        let sample = ServerStatsParser.parse(Self.output(cpu: "cpu  1000 0 500 8000 500 0 0 0 0 0", rx: 1_000_000, tx: 500_000))
        #expect(sample.isLinux && sample.hostname == "web-01" && sample.cores == 4)
        #expect(sample.load == [0.52, 0.48, 0.40])
        #expect(sample.cpuBusy == 1500 && sample.cpuIdle == 8500)
        #expect(sample.memoryTotalKB == 8_000_000 && sample.memoryUsedKB == 6_000_000)
        #expect(sample.swapTotalKB == 2_097_148)
        #expect(sample.networkReceived == 1_000_000 && sample.networkSent == 500_000)
        #expect(sample.disks.map(\.mount) == ["/", "/data disk"])
        #expect(sample.disks.map(\.percent) == [27, 53])  // 和 df 显示的一样
        #expect(sample.uptime > 123456)
        #expect(sample.processes.count == 2 && sample.processes[1].command == "nginx: worker")
    }

    @Test("两次采样算出 CPU 使用率和网速")
    func rates() {
        let a = ServerStatsParser.parse(Self.output(cpu: "cpu  1000 0 500 8000 500 0 0 0 0 0", rx: 1_000_000, tx: 500_000))
        let b = ServerStatsParser.parse(Self.output(cpu: "cpu  1300 0 600 8500 600 0 0 0 0 0", rx: 4_000_000, tx: 800_000))
        let rates = ServerRates.between(a, b, seconds: 2)
        // 忙 400、闲 600 → 40%
        #expect(abs(rates.cpuPercent - 40) < 0.01)
        #expect(rates.receivedPerSecond == 1_500_000 && rates.sentPerSecond == 150_000)
        // 计数器被重置时不出负数
        #expect(ServerRates.between(b, a, seconds: 2).receivedPerSecond == 0)
    }

    @Test("不是 Linux")
    func notLinux() {
        let sample = ServerStatsParser.parse("Darwin\n\(ServerMonitorScript.separator)\nmac")
        #expect(!sample.isLinux && sample.system == "Darwin")
    }

    @Test("脚本里没有单引号（整段放在 sh -c '…' 里）")
    func scriptQuoting() {
        let command = ServerMonitorScript.command
        #expect(command.hasPrefix("/bin/sh -c '") && command.hasSuffix("'"))
        #expect(command.dropFirst(12).dropLast().contains("'") == false)
    }
}

// MARK: - 界面改版：分组环境标签、配套的终端配色

@Suite("分组环境标签")
struct SessionEnvironmentTests {
    @Test("下级分组跟着上级，自己设了就用自己的")
    func inheritance() {
        var library = SessionLibrary(sessions: [
            SessionProfile(name: "web", group: "电商/生产", host: "10.0.0.1", username: "deploy"),
            SessionProfile(name: "db", group: "电商/生产/数据库", host: "10.0.0.2", username: "dba"),
            SessionProfile(name: "无标签", group: "杂项", host: "10.0.0.3", username: "root"),
        ])
        library.setEnvironment(.production, forGroup: "电商/生产")
        library.setEnvironment(.device, forGroup: "电商/生产/数据库")
        #expect(library.environment(of: library.sessions[0]) == .production)
        #expect(library.environment(of: library.sessions[1]) == .device)
        #expect(library.environment(of: library.sessions[2]) == nil)
        #expect(library.environment(ofGroup: "电商") == nil)
        library.setEnvironment(nil, forGroup: "电商/生产/数据库")
        #expect(library.environment(of: library.sessions[1]) == .production)
        // 顶层（没有分组）不能设
        library.setEnvironment(.testing, forGroup: "")
        #expect(library.environments[""] == nil)
    }

    @Test("改分组名、删分组时标签跟着走")
    func renameAndRemove() {
        var library = SessionLibrary(groups: ["老名字", "老名字/子", "已有"])
        library.setEnvironment(.production, forGroup: "老名字")
        library.setEnvironment(.testing, forGroup: "老名字/子")
        library.setEnvironment(.device, forGroup: "已有")
        library.renameGroup("老名字", to: "新名字")
        #expect(library.environments == ["新名字": .production, "新名字/子": .testing, "已有": .device])
        // 合并进已有的分组：以那边原来的标签为准
        library.renameGroup("新名字", to: "已有")
        #expect(library.environments["已有"] == .device)
        #expect(library.environments["已有/子"] == .testing)
        // 删掉分组：自己的标签不要了，下级挪上来
        library.removeGroup("已有")
        #expect(library.environments == ["子": .testing])
    }

    @Test("存档读写；老存档没有标签；认不出的标签跳过")
    func coding() throws {
        var library = SessionLibrary(groups: ["生产"])
        library.setEnvironment(.production, forGroup: "生产")
        let data = try JSONEncoder().encode(library)
        #expect(try JSONDecoder().decode(SessionLibrary.self, from: data) == library)
        let old = Data(#"{"version":1,"sessions":[],"groups":["生产"]}"#.utf8)
        #expect(try JSONDecoder().decode(SessionLibrary.self, from: old).environments.isEmpty)
        let future = Data(#"{"groups":["a","b"],"environments":{"a":"production","b":"staging"}}"#.utf8)
        #expect(try JSONDecoder().decode(SessionLibrary.self, from: future).environments == ["a": .production])
    }

    @Test("打开同步时标签取并集，两边都有时以同步文件夹的为准")
    func absorb() {
        var folder = SessionLibrary(groups: ["生产"], environments: ["生产": .production])
        folder.absorb(SessionLibrary(groups: ["生产", "测试"], environments: ["生产": .testing, "测试": .testing]))
        #expect(folder.environments == ["生产": .production, "测试": .testing])
    }

    @Test("跟随界面主题时的终端配色")
    func terminalThemes() {
        #expect(TerminalTheme.forUITheme("glass").id == "conch-glass")
        #expect(TerminalTheme.forUITheme("graphite").background == RGB(0x111216))
        #expect(TerminalTheme.forUITheme("environment").isDark)
        #expect(TerminalTheme.forUITheme("别的").id == "conch-glass")
        #expect(TerminalTheme.all.count == Set(TerminalTheme.all.map(\.id)).count)
        // 设置里选的 id 不认识时不崩，退回深色
        #expect(TerminalTheme.resolve(TerminalTheme.followUIID, darkMode: true) == .conchDark)
    }
}

// MARK: - 换 App 标识后搬设置

@Suite("换 App 标识后搬设置")
struct LegacyDefaultsTests {
    @Test("新标识下已有的不覆盖；老默认的终端配色不搬，别的配色照搬")
    func valuesToWrite() {
        let old: [String: Any] = ["themeID": "system", "fontSize": 15.0, "uiTheme": "graphite"]
        let values = LegacyDefaults.valuesToWrite(old: old, existing: ["uiTheme": "glass"])
        #expect(Set(values.keys) == ["fontSize", LegacyDefaults.migratedKey])
        #expect(values["fontSize"] as? Double == 15)
        let custom = LegacyDefaults.valuesToWrite(old: ["themeID": "dracula"], existing: [:])
        #expect(custom["themeID"] as? String == "dracula")
    }

    @Test("新用户没有旧设置：只记一笔，以后不再查")
    func newUser() {
        let values = LegacyDefaults.valuesToWrite(old: nil, existing: [:])
        #expect(values.count == 1)
        #expect(values[LegacyDefaults.migratedKey] as? Bool == true)
    }
}

// MARK: - 右键菜单里拷贝的地址和 ssh 命令

@Suite("拷贝地址和 ssh 命令")
struct CopyableAddressTests {
    @Test("地址：SSH 带用户名，端口不是 22 才写；Telnet 是 主机:端口；串口是设备路径")
    func address() {
        #expect(SessionProfile(host: "10.0.0.5", port: 22, username: "root").copyableAddress == "root@10.0.0.5")
        #expect(SessionProfile(host: "web-01", port: 2222, username: "deploy").copyableAddress == "deploy@web-01:2222")
        #expect(SessionProfile(host: "fe80::1", port: 2222, username: "ops").copyableAddress == "ops@[fe80::1]:2222")
        #expect(SessionProfile(kind: .telnet, host: "192.168.1.1", port: 23).copyableAddress == "192.168.1.1:23")
        var serial = SessionProfile(kind: .serial)
        serial.serial.path = "/dev/cu.usbserial-1410"
        #expect(serial.copyableAddress == "/dev/cu.usbserial-1410")
    }

    @Test("ssh 命令：端口、指定私钥、跳板机都带上，路径里有空格时加引号")
    func sshCommand() {
        #expect(SessionProfile(host: "10.0.0.5", port: 22, username: "root").sshCommand() == "ssh root@10.0.0.5")
        var keyed = SessionProfile(host: "db", port: 2200, username: "dba", auth: .key)
        keyed.keyPaths = ["~/My Keys/id_ed25519"]
        let jump1 = SessionProfile(host: "bastion.example.com", port: 22, username: "ops")
        let jump2 = SessionProfile(host: "fe80::2", port: 2222, username: "")
        #expect(keyed.sshCommand(jumps: [jump1, jump2])
            == "ssh -p 2200 -i ~/'My Keys/id_ed25519' -J 'ops@bastion.example.com,[fe80::2]:2222' dba@db")
        #expect(SessionProfile(kind: .telnet, host: "sw1", port: 23).sshCommand() == nil)
    }
}
