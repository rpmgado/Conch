//! 本地测试用的模拟 SSH 服务器（只监听 127.0.0.1）。
//!
//! 用来测非 root 的 OpenSSH 测试服务器测不了的东西，按用户名区分认证方式：
//!   pw    只开密码登录
//!   kbd   只开 keyboard-interactive：先问密码，再问动态口令（模拟走 PAM 的堡垒机）
//!   mfa   公钥 + 动态口令（相当于 AuthenticationMethods publickey,keyboard-interactive）
//! 登录后是一个很简单的“Shell”，支持：
//!   echo 文字、whoami、stty size、exit [退出码]
//!   gbk               用 GBK 编码输出一段中文（测终端编码转换）
//!   hex 文字          把收到的原始字节按十六进制打出来（测键盘输入的编码转换）
//!   sz 文件名 大小    用 ZMODEM 发一个测试文件给客户端（测 sz 下载）
//!   rz                用 ZMODEM 接收客户端发来的文件，存到 --rz-dir（测 rz 上传）
//! 另开通道执行命令（exec）时，收到服务器监控脚本就返回一份模拟的 Linux /proc 数据，每次调用数字都会变
//!
//! 加上 --telnet-port 时，再起一个模拟网络设备的 Telnet 服务：任意用户名 + 同一个密码登录，
//! 支持 whoami、echo、stty size（看 NAWS 报的窗口大小）、term（看 TTYPE 报的终端类型）、gbk、exit。
//!
//! cargo run --release --example mock_server -- --port 2224 --host-key <主机私钥> --password <密码> --otp <动态口令> [--rz-dir <目录>] [--telnet-port 2325]

use std::borrow::Cow;
use std::net::SocketAddr;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use russh::server::{self, Auth, Msg, Server as _, Session, VerifiedPublicKey};
use russh::{Channel, ChannelId, MethodKind, MethodSet, Pty};
use tokio::sync::mpsc;
use zmodem2::{Action, Event, FileInfo, Position, Receiver, Sender};

struct Settings {
    password: String,
    otp: String,
    rz_dir: PathBuf,
}

struct MockServer {
    settings: Arc<Settings>,
}

impl server::Server for MockServer {
    type Handler = Client;

    fn new_client(&mut self, _peer: Option<SocketAddr>) -> Client {
        Client {
            settings: self.settings.clone(),
            user: String::new(),
            stage: Stage::Start,
            pubkey_ok: false,
            line: Vec::new(),
            cols: 80,
            rows: 24,
            zmodem: Arc::new(Mutex::new(None)),
            monitor_ticks: 0,
        }
    }
}

#[derive(PartialEq)]
enum Stage {
    Start,
    AskedPassword,
    AskedOtp,
}

struct Client {
    settings: Arc<Settings>,
    user: String,
    stage: Stage,
    pubkey_ok: bool,
    line: Vec<u8>,
    cols: u32,
    rows: u32,
    /// ZMODEM 传输进行中时，客户端发来的数据转给传输任务
    zmodem: Arc<Mutex<Option<mpsc::UnboundedSender<Vec<u8>>>>>,
    /// 监控脚本被调用的次数（让模拟数据每次都变）
    monitor_ticks: u64,
}

fn methods(list: &[MethodKind]) -> MethodSet {
    MethodSet::from(list)
}

/// 每个测试用户允许的认证方式
fn methods_for(user: &str, pubkey_ok: bool) -> MethodSet {
    match user {
        "pw" => methods(&[MethodKind::Password]),
        "kbd" => methods(&[MethodKind::KeyboardInteractive]),
        "mfa" if pubkey_ok => methods(&[MethodKind::KeyboardInteractive]),
        "mfa" => methods(&[MethodKind::PublicKey]),
        _ => methods(&[MethodKind::Password, MethodKind::PublicKey]),
    }
}

fn prompt(name: &'static str, text: &'static str, echo: bool) -> Auth {
    Auth::Partial {
        name: Cow::Borrowed(name),
        instructions: Cow::Borrowed(""),
        prompts: Cow::Owned(vec![(Cow::Borrowed(text), echo)]),
    }
}

/// 测试文件的内容：按位置算出来，客户端那边用同样的公式核对
fn test_content(size: usize) -> Vec<u8> {
    (0..size).map(|i| ((i * 31 + 7) % 251) as u8).collect()
}

enum Outcome {
    Continue,
    Exit(u32),
    /// 开始 ZMODEM：Some((文件名, 大小)) 是 sz，None 是 rz
    Zmodem(Option<(String, usize)>),
}

impl Client {
    fn reject(&self, user: &str) -> Auth {
        Auth::Reject {
            proceed_with_methods: Some(methods_for(user, self.pubkey_ok)),
            partial_success: false,
        }
    }

    fn send(&self, session: &mut Session, channel: ChannelId, text: &str) {
        let _ = session.data(channel, text.replace('\n', "\r\n").into_bytes());
    }

    fn prompt_text(&self) -> String {
        format!("{}@mock$ ", self.user)
    }

    /// 执行一行命令
    fn run(&self, line: &[u8], session: &mut Session, channel: ChannelId) -> Outcome {
        // hex 要看原始字节，先处理
        if let Some(rest) = line.strip_prefix(b"hex ") {
            let hex: String = rest.iter().map(|b| format!("{b:02x}")).collect();
            self.send(session, channel, &format!("hex={hex}\n"));
            return Outcome::Continue;
        }
        let text = String::from_utf8_lossy(line).trim().to_string();
        let mut words = text.split_whitespace();
        let command = words.next().unwrap_or("");
        let rest = text[command.len()..].trim();
        match command {
            "" => {}
            "exit" | "logout" => return Outcome::Exit(rest.parse().unwrap_or(0)),
            "echo" => self.send(session, channel, &format!("{rest}\n")),
            "whoami" => self.send(session, channel, &format!("{}\n", self.user)),
            "stty" if rest == "size" => {
                self.send(session, channel, &format!("{} {}\n", self.rows, self.cols))
            }
            "gbk" => {
                // “编码测试：中文GBK”的 GBK 字节
                let (bytes, _, _) = encoding_rs::GBK.encode("编码测试：中文GBK\r\n");
                let _ = session.data(channel, bytes.into_owned());
            }
            "sz" => {
                let name = words.next().unwrap_or("test.bin").to_string();
                let size = words.next().and_then(|s| s.parse().ok()).unwrap_or(1024);
                return Outcome::Zmodem(Some((name, size)));
            }
            "rz" => {
                self.send(session, channel, "rz waiting to receive.");
                return Outcome::Zmodem(None);
            }
            other => self.send(session, channel, &format!("mock: 不支持的命令 {other}\n")),
        }
        Outcome::Continue
    }

    fn start_zmodem(&self, session: &mut Session, channel: ChannelId, send: Option<(String, usize)>) {
        let (tx, rx) = mpsc::unbounded_channel();
        *self.zmodem.lock().unwrap() = Some(tx);
        let handle = session.handle();
        let slot = self.zmodem.clone();
        let directory = self.settings.rz_dir.clone();
        let prompt = self.prompt_text();
        tokio::spawn(async move {
            let result = match send {
                Some((name, size)) => zmodem_send(&handle, channel, rx, &name, size).await,
                None => zmodem_receive(&handle, channel, rx, &directory).await,
            };
            *slot.lock().unwrap() = None;
            let message = match result {
                Ok(()) => format!("\r\nmock: 传输完成\r\n{prompt}"),
                Err(e) => format!("\r\nmock: 传输失败：{e}\r\n{prompt}"),
            };
            let _ = handle.data(channel, message.into_bytes()).await;
        });
    }
}

// ───────────────────────────── ZMODEM（模拟 sz / rz）─────────────────────────────

enum Step {
    Write(Vec<u8>),
    WriteFile(Vec<u8>),
    ReadFile { offset: usize, max: usize },
    FileStarted(String),
    FileCompleted,
    SessionCompleted,
    Aborted,
    Idle,
}

fn step(action: Action<'_>) -> Step {
    match action {
        Action::WriteWire(bytes) => Step::Write(bytes.to_vec()),
        Action::WriteFile(bytes) => Step::WriteFile(bytes.to_vec()),
        Action::ReadFile { offset, max_len } => Step::ReadFile {
            offset: offset.get() as usize,
            max: max_len,
        },
        Action::Event(Event::FileStarted(info)) => Step::FileStarted(String::from_utf8_lossy(info.name).into_owned()),
        Action::Event(Event::FileCompleted) => Step::FileCompleted,
        Action::Event(Event::SessionCompleted) => Step::SessionCompleted,
        Action::Event(Event::Aborted) => Step::Aborted,
        _ => Step::Idle,
    }
}

/// 和 lrzsz 一样：连续 5 个 CAN 表示对方取消了（zmodem2 只认取消帧，不认这个）
fn cancelled(input: &[u8]) -> bool {
    input.windows(5).any(|w| w.iter().all(|&b| b == 0x18))
}

async fn next_input(rx: &mut mpsc::UnboundedReceiver<Vec<u8>>) -> Result<Option<Vec<u8>>, String> {
    match tokio::time::timeout(Duration::from_secs(10), rx.recv()).await {
        Ok(Some(bytes)) => Ok(Some(bytes)),
        Ok(None) => Err("通道关闭".into()),
        Err(_) => Ok(None),
    }
}

async fn zmodem_send(
    handle: &server::Handle,
    channel: ChannelId,
    mut rx: mpsc::UnboundedReceiver<Vec<u8>>,
    name: &str,
    size: usize,
) -> Result<(), String> {
    let content = test_content(size);
    let mut sender = Sender::new().map_err(|e| format!("{e:?}"))?;
    sender.set_streaming_window(usize::MAX);
    let mut input: Vec<u8> = Vec::new();
    let mut started = false;
    let mut file_done = false;
    let mut finished = false;
    // 状态机先报完成、再吐出最后要发的字节，完成后继续发完
    let mut completed = false;
    loop {
        // 和 lrzsz 的 sz 一样，连续发送时也要看对方有没有取消
        while let Ok(bytes) = rx.try_recv() {
            input.extend_from_slice(&bytes);
        }
        if cancelled(&input) {
            return Err("对方取消了".into());
        }
        if !input.is_empty() {
            let consumed = sender.submit_wire(&input).map_err(|e| format!("{e:?}"))?;
            input.drain(..consumed);
        }
        match step(sender.poll()) {
            Step::Write(bytes) => {
                let n = bytes.len();
                handle.data(channel, bytes).await.map_err(|_| "发送失败".to_string())?;
                sender.wire_written(n);
            }
            Step::ReadFile { offset, max } => {
                let end = (offset + max).min(content.len());
                sender
                    .submit_file(&content[offset.min(end)..end])
                    .map_err(|e| format!("{e:?}"))?;
            }
            Step::FileCompleted => file_done = true,
            Step::SessionCompleted => completed = true,
            Step::Aborted => return Err("对方取消了".into()),
            Step::Idle if completed => return Ok(()),
            Step::Idle => {
                if !started {
                    let info = FileInfo::new(name.as_bytes(), Some(Position::new(size as u32)));
                    sender.start_file(info).map_err(|e| format!("{e:?}"))?;
                    started = true;
                    continue;
                }
                if file_done && !finished {
                    sender.finish().map_err(|e| format!("{e:?}"))?;
                    finished = true;
                    continue;
                }
                if !input.is_empty() {
                    let consumed = sender.submit_wire(&input).map_err(|e| format!("{e:?}"))?;
                    if consumed > 0 {
                        input.drain(..consumed);
                        continue;
                    }
                }
                match next_input(&mut rx).await? {
                    Some(bytes) => input.extend_from_slice(&bytes),
                    None => sender.timeout().map_err(|e| format!("{e:?}"))?,
                }
            }
            _ => {}
        }
    }
}

async fn zmodem_receive(
    handle: &server::Handle,
    channel: ChannelId,
    mut rx: mpsc::UnboundedReceiver<Vec<u8>>,
    directory: &Path,
) -> Result<(), String> {
    std::fs::create_dir_all(directory).map_err(|e| e.to_string())?;
    let mut receiver = Receiver::with_flow_control(0, true).map_err(|e| format!("{e:?}"))?;
    let mut input: Vec<u8> = Vec::new();
    let mut file: Option<std::fs::File> = None;
    let mut completed = false;
    loop {
        if cancelled(&input) {
            return Err("对方取消了".into());
        }
        match step(receiver.poll()) {
            Step::Write(bytes) => {
                let n = bytes.len();
                handle.data(channel, bytes).await.map_err(|_| "发送失败".to_string())?;
                receiver.wire_written(n);
            }
            Step::WriteFile(bytes) => {
                use std::io::Write;
                if let Some(file) = file.as_mut() {
                    file.write_all(&bytes).map_err(|e| e.to_string())?;
                }
                receiver.file_written(bytes.len()).map_err(|e| format!("{e:?}"))?;
            }
            Step::FileStarted(name) => {
                let name = Path::new(&name).file_name().map(|n| n.to_owned()).unwrap_or_default();
                file = Some(std::fs::File::create(directory.join(name)).map_err(|e| e.to_string())?);
            }
            Step::FileCompleted => file = None,
            Step::SessionCompleted => completed = true,
            Step::Aborted => return Err("对方取消了".into()),
            Step::Idle if completed => {
                // 和 lrzsz 的 rz 一样，收下发送方最后的 "OO"，不让它变成 Shell 的输入
                let deadline = tokio::time::Instant::now() + Duration::from_millis(500);
                while !input.windows(2).any(|w| w == b"OO") {
                    match tokio::time::timeout_at(deadline, rx.recv()).await {
                        Ok(Some(bytes)) => input.extend_from_slice(&bytes),
                        _ => break,
                    }
                }
                return Ok(());
            }
            Step::Idle => {
                if !input.is_empty() {
                    let consumed = receiver.submit_wire(&input).map_err(|e| format!("{e:?}"))?;
                    if consumed > 0 {
                        input.drain(..consumed);
                        continue;
                    }
                }
                match next_input(&mut rx).await? {
                    Some(bytes) => input.extend_from_slice(&bytes),
                    None => receiver.timeout().map_err(|e| format!("{e:?}"))?,
                }
            }
            Step::ReadFile { .. } => {}
        }
    }
}

// ───────────────────────────── SSH 处理 ─────────────────────────────

/// 模拟一台 4 核 Linux 服务器的监控数据：CPU 大约 30% 忙，网络每次多收 1.5 MB、多发 0.3 MB
fn monitor_output(tick: u64) -> String {
    let s = "@@CONCH@@";
    let busy = 100_000 + tick * 300;
    let idle = 400_000 + tick * 700;
    let rx = 50_000_000 + tick * 1_500_000;
    let tx = 20_000_000 + tick * 300_000;
    format!(
        "Linux\n{s}\nmock-linux\n{s}\n0.{load} 0.48 0.40 2/345 6789\n{s}\n\
         cpu  {user} 0 {system} {idle} 0 0 0 0 0 0\n{s}\n\
         MemTotal:        8000000 kB\nMemAvailable:    {avail} kB\nSwapTotal:       2097148 kB\nSwapFree:        2000000 kB\n{s}\n\
         Inter-|   Receive |  Transmit\n face |bytes packets|bytes\n    lo: 999 1 0 0 0 0 0 0 999 1 0 0 0 0 0 0\n  eth0: {rx} 2000 0 0 0 0 0 0 {tx} 1500 0 0 0 0 0 0\n{s}\n\
         Filesystem     1024-blocks      Used Available Capacity Mounted on\n\
         /dev/vda1         41152736  10288184  29010080      27% /\n\
         /dev/vdb1        103081248  82464998  15468126      85% /data\n{s}\n\
         {uptime}.12 234567.89\n{s}\n4\n{s}\n\
           PID %CPU %MEM COMMAND\n 1234 25.3  4.1 java\n  567  3.0  0.5 nginx\n   89  1.2  0.1 sshd\n",
        load = 50 + tick % 40,
        user = busy * 2 / 3,
        system = busy - busy * 2 / 3,
        avail = 2_000_000 + (tick % 5) * 100_000,
        uptime = 360_000 + tick * 3,
    )
}

impl server::Handler for Client {
    type Error = russh::Error;

    /// 另开通道执行命令：只认服务器监控脚本
    async fn exec_request(
        &mut self,
        channel: ChannelId,
        data: &[u8],
        session: &mut Session,
    ) -> Result<(), Self::Error> {
        session.channel_success(channel)?;
        let command = String::from_utf8_lossy(data);
        let output = if command.contains("@@CONCH@@") {
            self.monitor_ticks += 1;
            monitor_output(self.monitor_ticks)
        } else {
            format!("mock: 不支持执行 {command}\n")
        };
        session.data(channel, output.into_bytes())?;
        session.exit_status_request(channel, 0)?;
        session.eof(channel)?;
        session.close(channel)?;
        Ok(())
    }

    async fn auth_none(&mut self, user: &str) -> Result<Auth, Self::Error> {
        Ok(self.reject(user))
    }

    async fn auth_password(&mut self, user: &str, password: &str) -> Result<Auth, Self::Error> {
        if user == "pw" && password == self.settings.password {
            self.user = user.to_string();
            return Ok(Auth::Accept);
        }
        Ok(self.reject(user))
    }

    async fn auth_publickey(
        &mut self,
        user: &str,
        _key: VerifiedPublicKey<'_>,
    ) -> Result<Auth, Self::Error> {
        if user == "mfa" {
            // 公钥通过了，但还要动态口令
            self.pubkey_ok = true;
            return Ok(Auth::Reject {
                proceed_with_methods: Some(methods(&[MethodKind::KeyboardInteractive])),
                partial_success: true,
            });
        }
        Ok(self.reject(user))
    }

    async fn auth_keyboard_interactive<'a>(
        &'a mut self,
        user: &str,
        _submethods: &str,
        response: Option<server::Response<'a>>,
    ) -> Result<Auth, Self::Error> {
        let answer = response.and_then(|mut r| r.next());
        let matches = |expected: &str| answer.as_deref() == Some(expected.as_bytes());
        let next = match (user, &self.stage) {
            ("kbd", Stage::Start) => {
                self.stage = Stage::AskedPassword;
                prompt("登录", "Password: ", false)
            }
            ("kbd", Stage::AskedPassword) if matches(&self.settings.password) => {
                self.stage = Stage::AskedOtp;
                prompt("二次验证", "Verification code: ", true)
            }
            ("mfa", Stage::Start) if self.pubkey_ok => {
                self.stage = Stage::AskedOtp;
                prompt("二次验证", "Verification code: ", true)
            }
            (_, Stage::AskedOtp) if matches(&self.settings.otp) => {
                self.user = user.to_string();
                self.stage = Stage::Start;
                Auth::Accept
            }
            _ => {
                self.stage = Stage::Start;
                self.reject(user)
            }
        };
        Ok(next)
    }

    async fn channel_open_session(
        &mut self,
        _channel: Channel<Msg>,
        reply: server::ChannelOpenHandle,
        _session: &mut Session,
    ) -> Result<(), Self::Error> {
        // 不需要 Channel 对象，数据从 Handler::data 收；丢掉它，免得没人读的缓冲把会话堵住
        reply.accept().await;
        Ok(())
    }

    async fn pty_request(
        &mut self,
        channel: ChannelId,
        _term: &str,
        cols: u32,
        rows: u32,
        _pix_width: u32,
        _pix_height: u32,
        _modes: &[(Pty, u32)],
        session: &mut Session,
    ) -> Result<(), Self::Error> {
        self.cols = cols;
        self.rows = rows;
        session.channel_success(channel)?;
        Ok(())
    }

    async fn window_change_request(
        &mut self,
        _channel: ChannelId,
        cols: u32,
        rows: u32,
        _pix_width: u32,
        _pix_height: u32,
        _session: &mut Session,
    ) -> Result<(), Self::Error> {
        self.cols = cols;
        self.rows = rows;
        Ok(())
    }

    async fn shell_request(
        &mut self,
        channel: ChannelId,
        session: &mut Session,
    ) -> Result<(), Self::Error> {
        session.channel_success(channel)?;
        self.send(session, channel, &format!("模拟服务器：已以 {} 登录\n", self.user));
        let prompt = self.prompt_text();
        self.send(session, channel, &prompt);
        Ok(())
    }

    async fn data(
        &mut self,
        channel: ChannelId,
        data: &[u8],
        session: &mut Session,
    ) -> Result<(), Self::Error> {
        // ZMODEM 传输中：数据交给传输任务
        if let Some(tx) = self.zmodem.lock().unwrap().as_ref() {
            let _ = tx.send(data.to_vec());
            return Ok(());
        }
        for &byte in data {
            match byte {
                b'\r' | b'\n' => {
                    self.send(session, channel, "\n");
                    let line = std::mem::take(&mut self.line);
                    match self.run(&line, session, channel) {
                        Outcome::Continue => {
                            let prompt = self.prompt_text();
                            self.send(session, channel, &prompt);
                        }
                        Outcome::Exit(code) => {
                            self.send(session, channel, "logout\n");
                            session.exit_status_request(channel, code)?;
                            session.eof(channel)?;
                            session.close(channel)?;
                            return Ok(());
                        }
                        Outcome::Zmodem(send) => {
                            self.start_zmodem(session, channel, send);
                            return Ok(());
                        }
                    }
                }
                // Ctrl+C
                3 => {
                    self.line.clear();
                    self.send(session, channel, "^C\n");
                    let prompt = self.prompt_text();
                    self.send(session, channel, &prompt);
                }
                // 退格
                0x7f | 8 => {
                    if self.line.pop().is_some() {
                        let _ = session.data(channel, b"\x08 \x08".to_vec());
                    }
                }
                _ => {
                    self.line.push(byte);
                    let _ = session.data(channel, vec![byte]);
                }
            }
        }
        Ok(())
    }
}

#[tokio::main]
async fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let value_of = |flag: &str| {
        args.iter()
            .position(|a| a == flag)
            .and_then(|i| args.get(i + 1))
            .cloned()
    };
    let port: u16 = value_of("--port").and_then(|p| p.parse().ok()).unwrap_or(2224);
    let host_key_path = value_of("--host-key").expect("需要 --host-key <主机私钥>");
    let settings = Settings {
        password: value_of("--password").expect("需要 --password"),
        otp: value_of("--otp").expect("需要 --otp"),
        rz_dir: value_of("--rz-dir")
            .map(PathBuf::from)
            .unwrap_or_else(|| std::env::temp_dir().join("conch-mock-rz")),
    };

    let host_key = russh::keys::load_secret_key(&host_key_path, None).expect("读取主机私钥失败");
    let config = server::Config {
        keys: vec![host_key],
        methods: methods(&[
            MethodKind::Password,
            MethodKind::PublicKey,
            MethodKind::KeyboardInteractive,
        ]),
        // 默认会故意延迟 1 秒回复失败（防暴力破解），测试里不需要
        auth_rejection_time: Duration::from_millis(50),
        auth_rejection_time_initial: Some(Duration::ZERO),
        inactivity_timeout: Some(Duration::from_secs(3600)),
        ..Default::default()
    };
    let settings = Arc::new(settings);
    if let Some(port) = value_of("--telnet-port").and_then(|p| p.parse::<u16>().ok()) {
        let listener = tokio::net::TcpListener::bind(("127.0.0.1", port))
            .await
            .expect("Telnet 端口监听失败");
        println!("模拟 Telnet 服务器监听 127.0.0.1:{port}");
        let settings = settings.clone();
        tokio::spawn(async move {
            loop {
                let Ok((stream, _)) = listener.accept().await else { continue };
                let settings = settings.clone();
                tokio::spawn(async move {
                    let _ = telnet_client(stream, settings).await;
                });
            }
        });
    }
    let mut server = MockServer { settings };
    println!("模拟 SSH 服务器监听 127.0.0.1:{port}");
    server
        .run_on_address(Arc::new(config), ("127.0.0.1", port))
        .await
        .expect("服务器异常退出");
}

// ───────────────────────────── Telnet（模拟网络设备）─────────────────────────────

const T_IAC: u8 = 255;
const T_DO: u8 = 253;
const T_WILL: u8 = 251;
const T_WONT: u8 = 252;
const T_DONT: u8 = 254;
const T_SB: u8 = 250;
const T_SE: u8 = 240;
const T_ECHO: u8 = 1;
const T_SGA: u8 = 3;
const T_TTYPE: u8 = 24;
const T_NAWS: u8 = 31;

#[derive(Default)]
struct TelnetPeer {
    state: TelnetParse,
    sub: Vec<u8>,
    cols: u16,
    rows: u16,
    term: String,
}

#[derive(Default, Clone, Copy)]
enum TelnetParse {
    #[default]
    Data,
    Iac,
    Option(u8),
    Sub,
    SubIac,
}

impl TelnetPeer {
    /// 拆出普通数据，顺便处理协商；返回 (数据, 要回给客户端的字节)
    fn feed(&mut self, input: &[u8]) -> (Vec<u8>, Vec<u8>) {
        let mut data = Vec::new();
        let mut replies = Vec::new();
        for &byte in input {
            self.state = match self.state {
                TelnetParse::Data if byte == T_IAC => TelnetParse::Iac,
                TelnetParse::Data => {
                    data.push(byte);
                    TelnetParse::Data
                }
                TelnetParse::Iac => match byte {
                    T_IAC => {
                        data.push(T_IAC);
                        TelnetParse::Data
                    }
                    T_WILL | T_WONT | T_DO | T_DONT => TelnetParse::Option(byte),
                    T_SB => {
                        self.sub.clear();
                        TelnetParse::Sub
                    }
                    _ => TelnetParse::Data,
                },
                TelnetParse::Option(command) => {
                    // 客户端同意报终端类型后，问它要
                    if command == T_WILL && byte == T_TTYPE {
                        replies.extend([T_IAC, T_SB, T_TTYPE, 1, T_IAC, T_SE]);
                    }
                    TelnetParse::Data
                }
                TelnetParse::Sub if byte == T_IAC => TelnetParse::SubIac,
                TelnetParse::Sub => {
                    self.sub.push(byte);
                    TelnetParse::Sub
                }
                TelnetParse::SubIac if byte == T_SE => {
                    self.subnegotiation();
                    TelnetParse::Data
                }
                TelnetParse::SubIac => {
                    self.sub.push(byte);
                    TelnetParse::Sub
                }
            };
        }
        (data, replies)
    }

    fn subnegotiation(&mut self) {
        match self.sub.as_slice() {
            [T_NAWS, c1, c2, r1, r2, ..] => {
                self.cols = u16::from_be_bytes([*c1, *c2]);
                self.rows = u16::from_be_bytes([*r1, *r2]);
            }
            [T_TTYPE, 0, name @ ..] => self.term = String::from_utf8_lossy(name).into_owned(),
            _ => {}
        }
    }
}

async fn telnet_client(mut stream: tokio::net::TcpStream, settings: Arc<Settings>) -> std::io::Result<()> {
    use tokio::io::{AsyncReadExt, AsyncWriteExt};

    enum Login {
        User,
        Password(String),
        Shell(String),
    }
    stream
        .write_all(&[T_IAC, T_DO, T_TTYPE, T_IAC, T_DO, T_NAWS, T_IAC, T_WILL, T_ECHO, T_IAC, T_WILL, T_SGA])
        .await?;
    stream.write_all(b"\r\nConch mock telnet device\r\n\r\nlogin: ").await?;

    let mut peer = TelnetPeer::default();
    let mut login = Login::User;
    let mut line: Vec<u8> = Vec::new();
    let mut last_cr = false;
    let mut buffer = [0u8; 4096];
    loop {
        let n = stream.read(&mut buffer).await?;
        if n == 0 {
            return Ok(());
        }
        let (data, replies) = peer.feed(&buffer[..n]);
        let mut out = replies;
        for byte in data {
            // 回车可能是 CR NUL、CR LF 或单独的 LF
            let after_cr = std::mem::replace(&mut last_cr, byte == b'\r');
            match byte {
                0 => continue,
                b'\n' if after_cr => continue,
                b'\r' | b'\n' => {
                    let text = String::from_utf8_lossy(&line).trim().to_string();
                    line.clear();
                    out.extend_from_slice(b"\r\n");
                    login = match login {
                        Login::User if text.is_empty() => {
                            out.extend_from_slice(b"login: ");
                            Login::User
                        }
                        Login::User => {
                            out.extend_from_slice(b"Password: ");
                            Login::Password(text)
                        }
                        Login::Password(user) if text == settings.password => {
                            out.extend_from_slice(format!("Welcome, {user}\r\n{user}@device> ").as_bytes());
                            Login::Shell(user)
                        }
                        Login::Password(_) => {
                            out.extend_from_slice(b"Login incorrect\r\n\r\nlogin: ");
                            Login::User
                        }
                        Login::Shell(user) => {
                            let (command, rest) = text.split_once(' ').unwrap_or((text.as_str(), ""));
                            match command {
                                "" => {}
                                "exit" | "quit" | "logout" => {
                                    out.extend_from_slice(b"Bye\r\n");
                                    stream.write_all(&out).await?;
                                    return Ok(());
                                }
                                "whoami" => out.extend_from_slice(format!("{user}\r\n").as_bytes()),
                                "echo" => out.extend_from_slice(format!("{rest}\r\n").as_bytes()),
                                "stty" if rest == "size" => {
                                    out.extend_from_slice(format!("{} {}\r\n", peer.rows, peer.cols).as_bytes())
                                }
                                "term" => out.extend_from_slice(format!("TERM={}\r\n", peer.term).as_bytes()),
                                "gbk" => {
                                    let (bytes, _, _) = encoding_rs::GBK.encode("编码测试：中文GBK\r\n");
                                    out.extend_from_slice(&bytes);
                                }
                                other => out.extend_from_slice(format!("% Unknown command: {other}\r\n").as_bytes()),
                            }
                            out.extend_from_slice(format!("{user}@device> ").as_bytes());
                            Login::Shell(user)
                        }
                    };
                }
                0x7f | 0x08 => {
                    if line.pop().is_some() && !matches!(login, Login::Password(_)) {
                        out.extend_from_slice(b"\x08 \x08");
                    }
                }
                _ => {
                    line.push(byte);
                    // 服务器负责回显（WILL ECHO），密码不回显
                    if !matches!(login, Login::Password(_)) {
                        out.push(byte);
                        if byte == T_IAC {
                            out.push(T_IAC);
                        }
                    }
                }
            }
        }
        if !out.is_empty() {
            stream.write_all(&out).await?;
        }
    }
}
