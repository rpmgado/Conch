//! 端到端冒烟测试：直接调用内核的公开 API（和 Swift 走的是同一套接口）。
//!
//! cargo run --release --example smoke -- <host> <port> <user> [选项]
//!   --auth auto|password|key|agent   认证方式（默认 auto）
//!   --key <私钥>                     --auth key 用的私钥；--auth auto 时作为唯一要试的私钥
//!   --password <密码>                服务器要密码时回答这个
//!   --wrong-password-first           第一次故意答错密码，测“重新输入”
//!   --passphrase <口令>              私钥口令
//!   --otp <动态口令>                 交互式认证里的验证码
//!   --jump <user@host:port>          经过一台跳板机（可重复，按顺序）
//!   --jump-key <私钥>                跳板机用的私钥（不给就自动认证）
//!   --legacy                         目标主机开兼容老设备算法
//!   --known-hosts <文件>             App 自己的 known_hosts
//!   --quick                          跳过吞吐和流控测试
//!   --mock                           目标是 mock_server（只支持简单命令）
//!   --expect-error <文字>            期望连接失败，且错误信息包含这段文字
//!
//! 检查项：登录、PTY 尺寸、resize、TERM、UTF-8 中文、大量输出的吞吐、
//! 慢速消费下 Ctrl+C 的响应时间（验证流控）、退出码。

use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex, OnceLock};
use std::thread;
use std::time::{Duration, Instant};

use conch_core::{
    AuthMethod, CloseInfo, ConnectConfig, HopConfig, HostKeyInfo, KeyboardInteractiveRequest,
    SecretKind, SecretRequest, SessionDelegate, SshSession, ZmodemEvent, connect,
};

/// 模拟 UI：on_output 只负责收件，另一个线程按设定速率“渲染”并 ack，
/// 和 Swift 那边“后台收、串行队列喂给终端”的结构一致。
struct Probe {
    inbox: Mutex<Vec<u8>>,
    closed: Mutex<Option<CloseInfo>>,
    received: AtomicU64,
    password: Option<String>,
    wrong_password_first: AtomicBool,
    passphrase: Option<String>,
    otp: Option<String>,
    secret_requests: Mutex<Vec<String>>,
}

impl SessionDelegate for Probe {
    fn on_output(&self, data: Vec<u8>) {
        self.received.fetch_add(data.len() as u64, Ordering::Relaxed);
        self.inbox.lock().unwrap().extend_from_slice(&data);
    }
    fn on_progress(&self, message: String) {
        println!("  · {message}");
    }
    fn on_closed(&self, info: CloseInfo) {
        *self.closed.lock().unwrap() = Some(info);
    }
    fn verify_host_key(&self, info: HostKeyInfo) -> bool {
        println!(
            "  · 首次连接 {}:{}，{} {}，测试中自动信任",
            info.host, info.port, info.algorithm, info.fingerprint
        );
        true
    }
    fn request_secret(&self, request: SecretRequest) -> Option<String> {
        let what = match request.kind {
            SecretKind::Password => format!("{}@{} 的密码", request.username, request.host),
            SecretKind::Passphrase => format!("私钥 {} 的口令", request.key_path),
        };
        println!("  · 内核要 {what}（第 {} 跳，retry={}）", request.hop, request.retry);
        self.secret_requests
            .lock()
            .unwrap()
            .push(format!("{:?}:{}:{}", request.kind, request.hop, request.retry));
        match request.kind {
            SecretKind::Password => {
                if self.wrong_password_first.swap(false, Ordering::Relaxed) {
                    return Some("wrong-password".into());
                }
                self.password.clone()
            }
            SecretKind::Passphrase => self.passphrase.clone(),
        }
    }
    fn keyboard_interactive(&self, request: KeyboardInteractiveRequest) -> Option<Vec<String>> {
        let prompts: Vec<&str> = request.prompts.iter().map(|p| p.prompt.as_str()).collect();
        println!("  · 交互式认证 {:?}：{prompts:?}", request.name);
        request
            .prompts
            .iter()
            .map(|p| {
                let lower = p.prompt.to_lowercase();
                if lower.contains("code") || lower.contains("otp") {
                    self.otp.clone()
                } else {
                    self.password.clone()
                }
            })
            .collect()
    }
    fn zmodem_choose_files(&self) -> Option<Vec<String>> {
        None
    }
    fn zmodem_download_dir(&self) -> Option<String> {
        None
    }
    fn on_zmodem_event(&self, _event: ZmodemEvent) {}
}

/// 渲染线程：每 10ms 从收件箱取一批数据、找标记、ack。
struct Renderer {
    found: Mutex<HashMap<String, Instant>>,
    markers: Vec<String>,
    tail: Mutex<Vec<u8>>,
    bytes_per_tick: AtomicU64, // 0 表示不限速
}

fn spawn_renderer(
    probe: Arc<Probe>,
    session: Arc<OnceLock<Arc<SshSession>>>,
    markers: Vec<String>,
) -> Arc<Renderer> {
    let renderer = Arc::new(Renderer {
        found: Mutex::new(HashMap::new()),
        markers,
        tail: Mutex::new(Vec::new()),
        bytes_per_tick: AtomicU64::new(0),
    });
    let r = renderer.clone();
    thread::spawn(move || {
        loop {
            thread::sleep(Duration::from_millis(10));
            let Some(session) = session.get() else { continue };
            let chunk = {
                let mut inbox = probe.inbox.lock().unwrap();
                let limit = r.bytes_per_tick.load(Ordering::Relaxed) as usize;
                let n = if limit == 0 { inbox.len() } else { inbox.len().min(limit) };
                inbox.drain(..n).collect::<Vec<u8>>()
            };
            if chunk.is_empty() {
                continue;
            }
            let mut tail = r.tail.lock().unwrap();
            tail.extend_from_slice(&chunk);
            for marker in &r.markers {
                if find(&tail, marker.as_bytes()) {
                    r.found
                        .lock()
                        .unwrap()
                        .entry(marker.clone())
                        .or_insert_with(Instant::now);
                }
            }
            // 只保留末尾一段，既能跨块匹配标记，又不会无限增长
            let keep = 8192.min(tail.len());
            let cut = tail.len() - keep;
            tail.drain(..cut);
            session.ack(chunk.len() as u64);
        }
    });
    renderer
}

fn find(haystack: &[u8], needle: &[u8]) -> bool {
    haystack.windows(needle.len()).any(|w| w == needle)
}

fn wait_marker(r: &Renderer, marker: &str, timeout: Duration) -> Option<Instant> {
    let deadline = Instant::now() + timeout;
    while Instant::now() < deadline {
        if let Some(t) = r.found.lock().unwrap().get(marker) {
            return Some(*t);
        }
        thread::sleep(Duration::from_millis(5));
    }
    None
}

struct Report {
    failures: usize,
}

impl Report {
    fn check(&mut self, ok: bool, name: &str, detail: impl AsRef<str>) {
        let mark = if ok { "PASS" } else { "FAIL" };
        println!("[{mark}] {name} {}", detail.as_ref());
        if !ok {
            self.failures += 1;
        }
    }
}

/// user@host:port → HopConfig（自动认证）
fn parse_hop(text: &str, key: Option<String>) -> HopConfig {
    let (user, rest) = text.split_once('@').expect("跳板机格式：user@host:port");
    let (host, port) = rest.rsplit_once(':').unwrap_or((rest, "22"));
    HopConfig {
        host: host.into(),
        port: port.parse().expect("端口必须是数字"),
        username: user.into(),
        auth: AuthMethod::Auto {
            key_paths: key.into_iter().collect(),
            identities_only: false,
        },
        legacy_algorithms: false,
        identity_agent: String::new(),
    }
}

#[tokio::main]
async fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    if args.len() < 3 {
        eprintln!("用法：smoke <host> <port> <user> [选项]，选项见文件开头的说明");
        std::process::exit(2);
    }
    let value_of = |flag: &str| {
        args.iter()
            .position(|a| a == flag)
            .and_then(|i| args.get(i + 1))
            .cloned()
    };
    let has = |flag: &str| args.iter().any(|a| a == flag);
    let key = value_of("--key");
    let auth = match value_of("--auth").as_deref().unwrap_or("auto") {
        "password" => AuthMethod::Password,
        "agent" => AuthMethod::Agent,
        "key" => AuthMethod::PrivateKey {
            path: key.clone().expect("--auth key 需要 --key"),
        },
        _ => AuthMethod::Auto {
            key_paths: key.clone().into_iter().collect(),
            identities_only: key.is_some(),
        },
    };
    let jump_key = value_of("--jump-key");
    let jumps: Vec<HopConfig> = args
        .iter()
        .enumerate()
        .filter(|(_, a)| *a == "--jump")
        .filter_map(|(i, _)| args.get(i + 1))
        .map(|text| parse_hop(text, jump_key.clone()))
        .collect();
    let quick = has("--quick");
    let mock = has("--mock");
    let user = args[2].clone();
    let known_hosts = value_of("--known-hosts").unwrap_or_else(|| {
        std::env::temp_dir()
            .join("conch-smoke-known_hosts")
            .display()
            .to_string()
    });

    let config = ConnectConfig {
        jumps,
        target: HopConfig {
            host: args[0].clone(),
            port: args[1].parse().expect("端口必须是数字"),
            username: user.clone(),
            auth,
            legacy_algorithms: has("--legacy"),
            identity_agent: String::new(),
        },
        cols: 100,
        rows: 30,
        term: "xterm-256color".into(),
        known_hosts_path: known_hosts,
        encoding: "UTF-8".into(),
    };

    let probe = Arc::new(Probe {
        inbox: Mutex::new(Vec::new()),
        closed: Mutex::new(None),
        received: AtomicU64::new(0),
        password: value_of("--password"),
        wrong_password_first: AtomicBool::new(has("--wrong-password-first")),
        passphrase: value_of("--passphrase"),
        otp: value_of("--otp"),
        secret_requests: Mutex::new(Vec::new()),
    });
    let slot = Arc::new(OnceLock::new());
    let who = format!("\r\n{user}\r\n");
    let markers: Vec<String> = [
        "30 100",
        "40 120",
        "xterm-256color",
        "中文-OK",
        "__FLOOD_DONE__",
        "__INT_OK__",
        who.as_str(),
    ]
    .iter()
    .map(|s| s.to_string())
    .collect();
    let renderer = spawn_renderer(probe.clone(), slot.clone(), markers);
    let mut report = Report { failures: 0 };

    let started = Instant::now();
    let result = connect(config, probe.clone()).await;
    if let Some(expected) = value_of("--expect-error") {
        match result {
            Err(e) => {
                let message = e.to_string();
                report.check(
                    message.contains(&expected),
                    "预期中的连接失败",
                    format!("{message}"),
                );
            }
            Ok(_) => report.check(false, "预期中的连接失败", "结果却连上了"),
        }
        println!("  · 内核询问记录：{:?}", probe.secret_requests.lock().unwrap());
        std::process::exit(if report.failures > 0 { 1 } else { 0 });
    }
    let session = match result {
        Ok(s) => s,
        Err(e) => {
            println!("[FAIL] 连接与认证 {e}");
            std::process::exit(1);
        }
    };
    let info = session.info();
    report.check(
        true,
        "连接与认证",
        format!(
            "耗时 {:?}；kex={} hostkey={} cipher={} mac={} auth={}",
            started.elapsed(),
            info.kex,
            info.host_key,
            info.cipher,
            info.mac,
            info.auth
        ),
    );
    println!("  · 内核询问记录：{:?}", probe.secret_requests.lock().unwrap());
    let _ = slot.set(session.clone());
    let send = |s: &str| session.write(s.as_bytes().to_vec());
    let t = Duration::from_secs(5);

    thread::sleep(Duration::from_millis(800)); // 等 shell 起来
    if mock {
        send("stty size\r");
        report.check(wait_marker(&renderer, "30 100", t).is_some(), "PTY 初始尺寸 100x30", "");
        send("whoami\r");
        report.check(wait_marker(&renderer, &who, t).is_some(), "登录用户", &user);
        session.resize(120, 40);
        thread::sleep(Duration::from_millis(300));
        send("stty size\r");
        report.check(wait_marker(&renderer, "40 120", t).is_some(), "resize 到 120x40", "");
        send("exit 7\r");
    } else {
        send("stty size; echo $TERM; printf '\\344\\270\\255\\346\\226\\207-%s\\n' OK\n");
        report.check(wait_marker(&renderer, "30 100", t).is_some(), "PTY 初始尺寸 100x30", "");
        report.check(wait_marker(&renderer, "xterm-256color", t).is_some(), "TERM=xterm-256color", "");
        report.check(wait_marker(&renderer, "中文-OK", t).is_some(), "UTF-8 中文透传", "");

        session.resize(120, 40);
        thread::sleep(Duration::from_millis(300));
        send("stty size\n");
        report.check(wait_marker(&renderer, "40 120", t).is_some(), "resize 到 120x40", "");

        if !quick {
            // 1) 吞吐：不限速消费，约 16MB 输出
            let before = probe.received.load(Ordering::Relaxed);
            let t0 = Instant::now();
            send("yes 'conch flood line 0123456789abcdef' | head -n 500000; printf '__FLOOD%s__\\n' _DONE\n");
            let done = wait_marker(&renderer, "__FLOOD_DONE__", Duration::from_secs(60));
            let bytes = probe.received.load(Ordering::Relaxed) - before;
            let secs = t0.elapsed().as_secs_f64();
            report.check(
                done.is_some(),
                "大量输出",
                format!("{:.1} MB，{:.2} 秒，{:.0} MB/s", bytes as f64 / 1e6, secs, bytes as f64 / 1e6 / secs),
            );

            // 2) 流控：UI 只能每秒消化 10MB，远端 `yes` 狂刷 2 秒后按 Ctrl+C
            renderer.bytes_per_tick.store(100 * 1024, Ordering::Relaxed);
            send("yes\n");
            thread::sleep(Duration::from_secs(2));
            let backlog = probe.inbox.lock().unwrap().len();
            let t_int = Instant::now();
            session.write(vec![0x03]);
            send("printf '__INT%s__\\n' _OK\n");
            let seen = wait_marker(&renderer, "__INT_OK__", Duration::from_secs(60));
            renderer.bytes_per_tick.store(0, Ordering::Relaxed);
            let latency = seen.map(|t| t.duration_since(t_int));
            report.check(
                latency.is_some_and(|d| d < Duration::from_secs(3)),
                "慢速 UI 下 Ctrl+C 响应",
                format!(
                    "按下到看到输出 {:?}；按下时待渲染积压 {:.1} MB（上限约 2 MB）",
                    latency,
                    backlog as f64 / 1e6
                ),
            );
        }
        send("exit 7\n");
    }

    let deadline = Instant::now() + Duration::from_secs(10);
    let mut closed = None;
    while Instant::now() < deadline {
        if let Some(c) = probe.closed.lock().unwrap().clone() {
            closed = Some(c);
            break;
        }
        thread::sleep(Duration::from_millis(20));
    }
    report.check(
        matches!(&closed, Some(CloseInfo { exit_status: Some(7), lost: false, .. })),
        "退出码透传（且不算意外断线）",
        format!("{closed:?}"),
    );

    if report.failures > 0 {
        let tail = renderer.tail.lock().unwrap();
        println!("--- 终端输出末尾 ---\n{}", String::from_utf8_lossy(&tail));
        std::process::exit(1);
    }
    println!("全部通过");
}
