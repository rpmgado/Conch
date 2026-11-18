//! Conch 连接内核。
//!
//! 负责 SSH 连接（含多级跳板机）、认证、主机密钥校验、PTY 会话和输出流控，通过 UniFFI 导出给 Swift。
//! UI 层实现 [`SessionDelegate`]，再调用 [`connect`] 拿到 [`SshSession`]。
//!
//! 密码、私钥口令不放在连接配置里：内核真正需要时才通过 [`SessionDelegate::request_secret`] 询问，
//! UI 可以先查内存和钥匙串，查不到再弹窗。这样只在用到时才读钥匙串，秘密也不会在各层之间传来传去。

use std::borrow::Cow;
use std::future::Future;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, LazyLock, Mutex};
use std::time::Duration;

use russh::client::{self, AuthResult, DisconnectReason, KeyboardInteractiveAuthResponse};
use russh::keys::agent::client::AgentClient;
use russh::keys::known_hosts::{check_known_hosts_path, learn_known_hosts_path};
use russh::keys::ssh_key::public::KeyData;
use russh::keys::{HashAlg, PrivateKeyWithHashAlg, PublicKey, PublicKeyOrCertificate};
use russh::{
    ChannelMsg, ChannelOpenFailure, ChannelReadHalf, ChannelWriteHalf, Disconnect, MethodKind,
    MethodSet, Preferred, Pty, cipher, kex, mac,
};
use tokio::sync::{Notify, mpsc};

mod charset;
mod forward;
mod sftp;
mod stream;
mod zmodem;

pub use forward::{ForwardKind, ForwardSpec, ForwardStatus, PortForward};
pub use stream::{SerialConfig, StreamSession, TelnetConfig, connect_telnet, list_serial_ports, open_serial};
pub use sftp::{ConflictPolicy, RemoteFile, SftpClient, Transfer, TransferObserver, TransferProgress};

uniffi::setup_scaffolding!();

/// 内核自己的 tokio 运行时。导出的 async 函数会把工作投递到这里，
/// 这样 Swift 侧用什么执行器来 await 都没关系。
static RUNTIME: LazyLock<tokio::runtime::Runtime> = LazyLock::new(|| {
    tokio::runtime::Builder::new_multi_thread()
        .worker_threads(2)
        .thread_name("conch-core")
        .enable_all()
        .build()
        .expect("无法创建 tokio 运行时")
});

/// 已交给 UI 但还没被终端消化的字节数超过这个值，就暂停读取远端输出。
/// 读取一停，russh 的通道缓冲和 TCP 窗口会依次填满，服务器自然就停下来了。
const FLOW_HIGH_WATER: u64 = 2 * 1024 * 1024;
/// 建立连接（TCP + 握手）的超时。等用户确认主机指纹的时间不计入
const CONNECT_TIMEOUT: Duration = Duration::from_secs(15);
/// 自动认证时最多试几把公钥。OpenSSH 服务器默认 MaxAuthTries 是 6，试多了会被直接断开，得给密码留机会
const AUTO_MAX_PUBLICKEY_ATTEMPTS: usize = 4;
/// 密码、口令最多问几次
const MAX_SECRET_ATTEMPTS: u32 = 3;
/// 主动关闭后最多等服务器多久回应，超时就直接断开
const CLOSE_GRACE: Duration = Duration::from_millis(1500);

// ───────────────────────────── 对外类型 ─────────────────────────────

/// 认证方式。密码、口令不在这里，内核需要时通过 [`SessionDelegate::request_secret`] 询问。
#[derive(Debug, Clone, uniffi::Enum)]
pub enum AuthMethod {
    /// 和 OpenSSH 的默认行为一样：依次试 ssh-agent、私钥文件，最后用密码 / 交互式认证。
    /// key_paths 为空时用 ~/.ssh/id_ed25519、id_ecdsa、id_rsa。
    /// identities_only 对应 ssh_config 的 IdentitiesOnly：只用 key_paths 里的密钥（agent 里也只用这几把）
    Auto {
        key_paths: Vec<String>,
        identities_only: bool,
    },
    Password,
    PrivateKey { path: String },
    /// 只用 ssh-agent
    Agent,
}

/// 一跳连接的参数：目标主机或某一级跳板机。
#[derive(Debug, Clone, uniffi::Record)]
pub struct HopConfig {
    pub host: String,
    pub port: u16,
    pub username: String,
    pub auth: AuthMethod,
    /// 额外开启老算法（diffie-hellman-group1/14-sha1、aes-cbc、3des-cbc、hmac-sha1），连老设备用
    pub legacy_algorithms: bool,
    /// ssh-agent 的 socket 路径（对应 ssh_config 的 IdentityAgent）。
    /// 空字符串用 SSH_AUTH_SOCK，"none" 表示不用 agent
    pub identity_agent: String,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct ConnectConfig {
    /// 依次经过的跳板机，第一个最先连接。为空表示直连
    pub jumps: Vec<HopConfig>,
    pub target: HopConfig,
    pub cols: u32,
    pub rows: u32,
    /// 一般用 "xterm-256color"
    pub term: String,
    /// App 自己的 known_hosts。新信任的主机写到这里，不改动 ~/.ssh/known_hosts（那个只读）
    pub known_hosts_path: String,
    /// 远端终端的字符编码，如 "UTF-8"、"GBK"、"Big5"；空字符串当 UTF-8
    pub encoding: String,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct HostKeyInfo {
    pub host: String,
    pub port: u16,
    pub algorithm: String,
    /// 形如 "SHA256:xxxx"，与 OpenSSH 显示的一致
    pub fingerprint: String,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct AuthPrompt {
    pub prompt: String,
    /// false 表示输入时不应回显（密码、动态口令）
    pub echo: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum SecretKind {
    Password,
    Passphrase,
}

/// 向 UI 要密码或私钥口令。
#[derive(Debug, Clone, uniffi::Record)]
pub struct SecretRequest {
    /// 第几跳：0 是第一台跳板机（没有跳板机时就是目标主机），最后一跳是目标主机
    pub hop: u32,
    pub kind: SecretKind,
    pub host: String,
    pub port: u16,
    pub username: String,
    /// 要私钥口令时是私钥的完整路径，否则为空
    pub key_path: String,
    /// true 表示上一次给的不对（服务器拒绝了密码，或口令解不开私钥），UI 不应再用缓存或钥匙串里的旧值
    pub retry: bool,
}

/// 交互式认证（堡垒机二次验证、动态口令等）的一轮提问。
#[derive(Debug, Clone, uniffi::Record)]
pub struct KeyboardInteractiveRequest {
    pub hop: u32,
    pub host: String,
    pub port: u16,
    pub username: String,
    pub name: String,
    pub instructions: String,
    pub prompts: Vec<AuthPrompt>,
}

/// 协商出来的算法和认证方式，方便在界面上显示、排查兼容性问题。
#[derive(Debug, Clone, Default, uniffi::Record)]
pub struct SessionInfo {
    pub kex: String,
    pub host_key: String,
    pub cipher: String,
    pub mac: String,
    /// 目标主机是怎么认证通过的，如 "publickey (ssh-agent)"、"publickey + keyboard-interactive"
    pub auth: String,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct CloseInfo {
    pub exit_status: Option<u32>,
    /// 给用户看的原因；正常退出、主动关闭时为 None
    pub reason: Option<String>,
    /// true 表示连接意外中断（网络断开、服务器重启、保活超时、被服务器踢下线），适合自动重连。
    /// 远端 Shell 正常退出、被信号终止、服务器主动关闭通道、本地主动关闭时为 false
    pub lost: bool,
}

/// rz / sz 传输的进展
#[derive(Debug, Clone, uniffi::Enum)]
pub enum ZmodemEvent {
    /// 远端执行了 rz（upload = true，我们发送）或 sz（我们接收）
    Started { upload: bool },
    FileStarted { name: String, size: u64 },
    Progress { name: String, done: u64, total: u64 },
    /// 一个文件传完；下载时 local_path 是保存的位置
    FileFinished { name: String, local_path: String },
    /// 整个传输结束；error 为 None 表示成功
    Finished { files: u32, error: Option<String> },
}

#[derive(Debug, thiserror::Error, uniffi::Error)]
#[uniffi(flat_error)]
pub enum CoreError {
    #[error("无法连接 {0}")]
    Connect(String),
    #[error("{0}")]
    HostKey(String),
    #[error("认证失败：{0}")]
    Auth(String),
    /// 用户在弹窗里点了取消
    #[error("{0}")]
    Cancelled(String),
    #[error("会话错误：{0}")]
    Session(String),
}

/// UI 层实现的回调。所有方法都在内核的后台线程上调用，实现方自己切回主线程。
/// 标注“可以阻塞”的方法在专门的阻塞线程上执行，可以放心等待用户操作或读钥匙串。
#[uniffi::export(with_foreign)]
pub trait SessionDelegate: Send + Sync {
    /// 远端输出（stdout 和 stderr 合并）。交给终端渲染后，记得调用 [`SshSession::ack`] 归还额度。
    fn on_output(&self, data: Vec<u8>);
    /// 连接过程中的进度（正在连接、认证通过……），适合用灰字显示在终端里。
    fn on_progress(&self, message: String);
    /// 会话结束。
    fn on_closed(&self, info: CloseInfo);
    /// 遇到未知主机密钥时询问用户，返回 true 表示信任并记住。可以阻塞。
    fn verify_host_key(&self, info: HostKeyInfo) -> bool;
    /// 要密码或私钥口令。返回 None 表示用户取消。可以阻塞。
    fn request_secret(&self, request: SecretRequest) -> Option<String>;
    /// 交互式认证。返回 None 表示用户取消。可以阻塞。
    fn keyboard_interactive(&self, request: KeyboardInteractiveRequest) -> Option<Vec<String>>;
    /// 远端执行了 rz：选择要上传的文件。返回 None 或空数组表示取消。可以阻塞。
    fn zmodem_choose_files(&self) -> Option<Vec<String>>;
    /// 远端执行了 sz：文件保存到哪个目录。返回 None 表示取消。可以阻塞。
    fn zmodem_download_dir(&self) -> Option<String>;
    /// rz / sz 的进展（开始、进度、完成）
    fn on_zmodem_event(&self, event: ZmodemEvent);
}

/// 远程执行一条命令的结果
#[derive(Debug, Clone, Default, uniffi::Record)]
pub struct ExecOutput {
    pub stdout: Vec<u8>,
    pub stderr: Vec<u8>,
    pub exit_status: Option<u32>,
}

/// 一个已登录、已打开 Shell 的会话。
#[derive(uniffi::Object)]
pub struct SshSession {
    transfer_peer: String,
    tx: mpsc::UnboundedSender<Command>,
    flow: Arc<Flow>,
    info: SessionInfo,
    closing: Arc<AtomicBool>,
    /// 每一跳的连接句柄（跳板机在前，目标主机在最后）。只要这个对象还活着，连接就不会被回收
    hops: Vec<Arc<client::Handle<Handler>>>,
    /// 目标主机那一跳的共享状态（远程转发的登记表在这里）
    target_shared: Arc<Shared>,
    /// 正在运行的端口转发，连接断开时一起停掉
    forwards: Arc<Mutex<Vec<Arc<PortForward>>>>,
    /// 用户点了取消 rz / sz
    zmodem_cancel: Arc<AtomicBool>,
}

#[uniffi::export]
impl SshSession {
    /// 把用户输入（键盘、粘贴）发给远端。
    pub fn write(&self, data: Vec<u8>) {
        let _ = self.tx.send(Command::Data(data));
    }

    /// 终端尺寸变化时调用，会发送 window-change 请求。
    pub fn resize(&self, cols: u32, rows: u32) {
        if cols > 0 && rows > 0 {
            let _ = self.tx.send(Command::Resize { cols, rows });
        }
    }

    /// UI 已经把这么多字节交给终端渲染，归还流控额度。
    pub fn ack(&self, bytes: u64) {
        self.flow.ack(bytes);
    }

    /// 主动关闭会话（发送 EOF 并关闭通道），之后会收到 on_closed（lost = false）。
    /// 网络已经断了、服务器不回应时，最多等 1.5 秒就直接断开。
    pub fn close(&self) {
        if self.closing.swap(true, Ordering::AcqRel) {
            return;
        }
        let _ = self.tx.send(Command::Close);
        // 读循环可能正卡在流控上（UI 不再 ack 了），放开它
        self.flow.ack(u64::MAX);
        let hops = self.hops.clone();
        RUNTIME.spawn(async move {
            tokio::time::sleep(CLOSE_GRACE).await;
            disconnect_all(&hops).await;
        });
    }

    pub fn info(&self) -> SessionInfo {
        self.info.clone()
    }

    /// 取消正在进行的 rz / sz（远端的 rz / sz 也会收到取消）
    pub fn cancel_zmodem(&self) {
        self.zmodem_cancel.store(true, Ordering::Release);
    }
}

#[uniffi::export]
impl SshSession {
    /// 在同一条连接上另开一个通道执行命令（不影响终端里的 Shell），用于服务器监控等。
    /// 输出最多保留 4 MB；超过 timeout_secs 秒没执行完就放弃
    pub async fn exec(&self, command: String, timeout_secs: u32) -> Result<ExecOutput, CoreError> {
        let handle = self
            .hops
            .last()
            .cloned()
            .ok_or_else(|| CoreError::Session("连接已关闭".into()))?;
        let limit = Duration::from_secs(u64::from(timeout_secs.max(1)));
        RUNTIME
            .spawn(async move {
                let mut channel = handle.channel_open_session().await.map_err(session_err)?;
                channel.exec(true, command).await.map_err(session_err)?;
                let mut output = ExecOutput::default();
                let collect = async {
                    while let Some(message) = channel.wait().await {
                        match message {
                            ChannelMsg::Data { data } if output.stdout.len() < EXEC_OUTPUT_LIMIT => {
                                output.stdout.extend_from_slice(&data)
                            }
                            ChannelMsg::ExtendedData { data, .. } if output.stderr.len() < EXEC_OUTPUT_LIMIT => {
                                output.stderr.extend_from_slice(&data)
                            }
                            ChannelMsg::ExitStatus { exit_status } => output.exit_status = Some(exit_status),
                            ChannelMsg::Close => break,
                            _ => {}
                        }
                    }
                };
                if tokio::time::timeout(limit, collect).await.is_err() {
                    let _ = channel.close().await;
                    return Err(CoreError::Session("命令执行超时".into()));
                }
                Ok(output)
            })
            .await
            .map_err(|e| CoreError::Session(e.to_string()))?
    }
}

const EXEC_OUTPUT_LIMIT: usize = 4 * 1024 * 1024;

/// 连接（必要时经过跳板机）、认证并打开一个带 PTY 的交互式 Shell。
#[uniffi::export]
pub async fn connect(
    config: ConnectConfig,
    delegate: Arc<dyn SessionDelegate>,
) -> Result<Arc<SshSession>, CoreError> {
    RUNTIME
        .spawn(connect_inner(config, delegate))
        .await
        .map_err(|e| CoreError::Session(e.to_string()))?
}

#[uniffi::export]
pub fn core_version() -> String {
    format!("conch_core {} (russh 0.65)", env!("CARGO_PKG_VERSION"))
}

// ───────────────────────────── 连接 ─────────────────────────────

enum Command {
    /// 用户输入：远端不是 UTF-8 时要转换编码；rz / sz 传输期间丢弃（否则会搅乱协议）
    Data(Vec<u8>),
    /// 原样发送（rz / sz 的协议数据）
    Raw(Vec<u8>),
    Resize { cols: u32, rows: u32 },
    Close,
    Shutdown,
}

/// 基于额度的流控：读取方每交给 UI 一批字节就记账，UI 渲染完再 ack。
#[derive(Default)]
struct Flow {
    pending: AtomicU64,
    notify: Notify,
}

impl Flow {
    fn consume(&self, n: u64) {
        self.pending.fetch_add(n, Ordering::AcqRel);
    }

    fn ack(&self, n: u64) {
        let _ = self
            .pending
            .try_update(Ordering::AcqRel, Ordering::Acquire, |v| Some(v.saturating_sub(n)));
        // 没有等待者时 notify_one 会留下一个许可，不会丢失唤醒
        self.notify.notify_one();
    }

    async fn wait_for_credit(&self) {
        while self.pending.load(Ordering::Acquire) > FLOW_HIGH_WATER {
            self.notify.notified().await;
        }
    }
}

/// Handler 和会话之间共享的状态（握手阶段的失败原因、断开原因、协商结果）。
#[derive(Default)]
struct Shared {
    host_key_error: Mutex<Option<String>>,
    disconnect_reason: Mutex<Option<String>>,
    names: Mutex<Option<SessionInfo>>,
    /// 正在等用户确认主机指纹，这段时间不算连接超时
    awaiting_user: AtomicBool,
    /// 远程转发：服务器上的端口 → 本机目标
    remote_forwards: forward::RemoteForwards,
}

fn put<T>(slot: &Mutex<Option<T>>, value: T) {
    if let Ok(mut guard) = slot.lock() {
        *guard = Some(value);
    }
}

fn take<T>(slot: &Mutex<Option<T>>) -> Option<T> {
    slot.lock().ok().and_then(|mut guard| guard.take())
}

struct Handler {
    host: String,
    port: u16,
    app_known_hosts: PathBuf,
    delegate: Arc<dyn SessionDelegate>,
    shared: Arc<Shared>,
}

impl client::Handler for Handler {
    type Error = russh::Error;

    async fn auth_banner(
        &mut self,
        banner: &str,
        _session: &mut client::Session,
    ) -> Result<(), Self::Error> {
        // 登录横幅直接显示在终端里；终端需要 \r\n 才会回到行首
        self.delegate.on_output(to_crlf(banner).into_bytes());
        Ok(())
    }

    async fn check_server_key(
        &mut self,
        server_key: &PublicKeyOrCertificate,
    ) -> Result<bool, Self::Error> {
        let key = server_key.public_key();

        // 先查用户的 ~/.ssh/known_hosts（只读，兼容 OpenSSH 的记录），再查 App 自己的
        let mut files = Vec::new();
        if let Some(home) = std::env::home_dir() {
            files.push(home.join(".ssh").join("known_hosts"));
        }
        files.push(self.app_known_hosts.clone());

        for path in &files {
            match check_known_hosts_path(&self.host, self.port, &key, path) {
                Ok(true) => return Ok(true),
                Ok(false) => {}
                Err(russh::keys::Error::KeyChanged { line }) => {
                    put(
                        &self.shared.host_key_error,
                        format!(
                            "警告：{}:{} 的主机密钥与 {} 第 {} 行的记录不一致，可能存在中间人攻击，已拒绝连接",
                            self.host,
                            self.port,
                            path.display(),
                            line
                        ),
                    );
                    return Ok(false);
                }
                // 文件不存在或某行解析失败，按“未知”处理
                Err(_) => {}
            }
        }

        let info = HostKeyInfo {
            host: self.host.clone(),
            port: self.port,
            algorithm: key.algorithm().to_string(),
            fingerprint: key.fingerprint(HashAlg::Sha256).to_string(),
        };
        let delegate = self.delegate.clone();
        // 询问用户可能要等很久，放到阻塞线程上，别占住异步工作线程
        self.shared.awaiting_user.store(true, Ordering::Release);
        let trusted = tokio::task::spawn_blocking(move || delegate.verify_host_key(info))
            .await
            .unwrap_or(false);
        self.shared.awaiting_user.store(false, Ordering::Release);
        if !trusted {
            put(
                &self.shared.host_key_error,
                "你没有信任该主机的密钥，已取消连接".to_string(),
            );
            return Ok(false);
        }
        // 记住失败只影响下次是否再询问，不影响本次连接
        let _ = learn_known_hosts_path(&self.host, self.port, &key, &self.app_known_hosts);
        Ok(true)
    }

    async fn kex_done(
        &mut self,
        _shared_secret: Option<&[u8]>,
        names: &russh::Names,
        _session: &mut client::Session,
    ) -> Result<(), Self::Error> {
        let cipher = names.cipher.as_ref().to_string();
        // GCM / ChaCha20-Poly1305 是 AEAD，自带完整性校验，协商出来的 MAC 并不会被使用
        let mac = if cipher.contains("gcm") || cipher.contains("poly1305") {
            "AEAD".to_string()
        } else {
            names.client_mac.as_ref().to_string()
        };
        put(
            &self.shared.names,
            SessionInfo {
                kex: names.kex.as_ref().to_string(),
                host_key: names.key.to_string(),
                cipher,
                mac,
                auth: String::new(),
            },
        );
        Ok(())
    }

    /// 远程转发：服务器上有连接进来了
    #[allow(clippy::too_many_arguments)]
    async fn server_channel_open_forwarded_tcpip(
        &mut self,
        channel: russh::Channel<client::Msg>,
        _connected_address: &str,
        connected_port: u32,
        _originator_address: &str,
        _originator_port: u32,
        reply: client::ChannelOpenHandle,
        _session: &mut client::Session,
    ) -> Result<(), Self::Error> {
        forward::accept_remote(&self.shared, channel, connected_port, reply).await;
        Ok(())
    }

    async fn disconnected(
        &mut self,
        reason: DisconnectReason<Self::Error>,
    ) -> Result<(), Self::Error> {
        match reason {
            DisconnectReason::ReceivedDisconnect(info) => {
                let message = if info.message.is_empty() {
                    format!("{}:{} 断开了连接", self.host, self.port)
                } else {
                    format!("{}:{} 断开了连接：{}", self.host, self.port, info.message)
                };
                put(&self.shared.disconnect_reason, message);
                Ok(())
            }
            DisconnectReason::Error(e) => {
                put(
                    &self.shared.disconnect_reason,
                    format!("与 {}:{} 的连接中断：{e}", self.host, self.port),
                );
                Err(e)
            }
        }
    }
}

fn client_config(legacy: bool) -> client::Config {
    client::Config {
        // 15 秒没收到数据就发保活，连续 3 次没回应判定断线
        keepalive_interval: Some(Duration::from_secs(15)),
        keepalive_max: 3,
        inactivity_timeout: None,
        // 交互式终端要关掉 Nagle，否则按键会有明显延迟
        nodelay: true,
        preferred: preferred_algorithms(legacy),
        ..Default::default()
    }
}

/// 给用户看的这一跳的名字
fn hop_label(hop: &HopConfig, is_jump: bool) -> String {
    let address = format!("{}@{}:{}", hop.username, hop.host, hop.port);
    if is_jump {
        format!("跳板机 {address}")
    } else {
        address
    }
}

async fn connect_inner(
    cfg: ConnectConfig,
    delegate: Arc<dyn SessionDelegate>,
) -> Result<Arc<SshSession>, CoreError> {
    let known_hosts = PathBuf::from(&cfg.known_hosts_path);
    let hops: Vec<HopConfig> = cfg
        .jumps
        .iter()
        .cloned()
        .chain(std::iter::once(cfg.target.clone()))
        .collect();
    let mut handles: Vec<Arc<client::Handle<Handler>>> = Vec::with_capacity(hops.len());
    let mut shareds: Vec<Arc<Shared>> = Vec::with_capacity(hops.len());
    let mut target_auth = String::new();

    for (index, hop) in hops.iter().enumerate() {
        let is_target = index + 1 == hops.len();
        let label = hop_label(hop, !is_target);
        let shared = Arc::new(Shared::default());
        let handler = Handler {
            host: hop.host.clone(),
            port: hop.port,
            app_known_hosts: known_hosts.clone(),
            delegate: delegate.clone(),
            shared: shared.clone(),
        };
        let config = Arc::new(client_config(hop.legacy_algorithms));

        let established = match handles.last() {
            None => {
                delegate.on_progress(format!("正在连接 {label} …"));
                let connecting = client::connect(config, (hop.host.clone(), hop.port), handler);
                handshake(connecting, &shared, &label, hop.legacy_algorithms).await
            }
            Some(previous) => {
                // 让上一跳的 sshd 帮我们连到这一跳（等同 ssh -J），SSH 协议跑在这条转发通道上
                delegate.on_progress(format!("正在经由跳板机连接 {label} …"));
                let jump_label = hop_label(&hops[index - 1], true);
                let open = previous.channel_open_direct_tcpip(
                    hop.host.clone(),
                    u32::from(hop.port),
                    "127.0.0.1",
                    0,
                );
                let channel = match tokio::time::timeout(CONNECT_TIMEOUT, open).await {
                    Err(_) => {
                        Err(CoreError::Connect(format!("{label}：{jump_label} 转发超时")))
                    }
                    Ok(Err(e)) => Err(CoreError::Connect(describe_forward_error(
                        &label,
                        &jump_label,
                        e,
                    ))),
                    Ok(Ok(channel)) => Ok(channel),
                };
                match channel {
                    Ok(channel) => {
                        let connecting =
                            client::connect_stream(config, channel.into_stream(), handler);
                        handshake(connecting, &shared, &label, hop.legacy_algorithms).await
                    }
                    Err(e) => Err(e),
                }
            }
        };
        let mut handle = match established {
            Ok(handle) => handle,
            Err(e) => {
                disconnect_all(&handles).await;
                return Err(e);
            }
        };

        match authenticate(&mut handle, hop, index as u32, &delegate).await {
            Ok(method) => {
                delegate.on_progress(format!("{label} 认证通过（{method}）"));
                if is_target {
                    target_auth = method;
                }
            }
            Err(e) => {
                let _ = handle.disconnect(Disconnect::ByApplication, "", "en").await;
                disconnect_all(&handles).await;
                // 跳板机认证失败时说清楚是哪一台
                return Err(if is_target || cfg.jumps.is_empty() {
                    e
                } else {
                    prefix_error(e, &label)
                });
            }
        }
        handles.push(Arc::new(handle));
        shareds.push(shared);
    }

    let target = handles.last().expect("至少有目标主机这一跳").clone();
    let encoding = charset::lookup(&cfg.encoding);
    let channel = match open_shell(&target, &cfg, encoding.is_none()).await {
        Ok(channel) => channel,
        Err(e) => {
            disconnect_all(&handles).await;
            return Err(e);
        }
    };

    let mut info = shareds
        .last()
        .and_then(|s| take(&s.names))
        .unwrap_or_default();
    info.auth = target_auth;
    let (reader, writer) = channel.split();
    let (tx, rx) = mpsc::unbounded_channel();
    let flow = Arc::new(Flow::default());
    let closing = Arc::new(AtomicBool::new(false));
    let target_shared = shareds.last().expect("至少有目标主机这一跳").clone();
    let forwards = Arc::new(Mutex::new(Vec::new()));
    let zmodem_cancel = Arc::new(AtomicBool::new(false));
    let zmodem_active = Arc::new(AtomicBool::new(false));

    tokio::spawn(write_loop(
        writer,
        rx,
        charset::InputEncoder::new(encoding),
        zmodem_active.clone(),
    ));
    tokio::spawn(read_loop(ReadLoop {
        reader,
        delegate,
        flow: flow.clone(),
        shareds,
        hops: handles.clone(),
        tx: tx.clone(),
        closing: closing.clone(),
        decoder: charset::OutputDecoder::new(encoding),
        forwards: forwards.clone(),
        zmodem_cancel: zmodem_cancel.clone(),
        zmodem_active,
    }));

    Ok(Arc::new(SshSession {
        transfer_peer: cfg.jumps.iter().chain(std::iter::once(&cfg.target))
            .map(|hop| format!("{}@{}:{}", hop.username, hop.host, hop.port))
            .collect::<Vec<_>>().join(" -> "),
        tx,
        flow,
        info,
        closing,
        hops: handles,
        target_shared,
        forwards,
        zmodem_cancel,
    }))
}

/// 等待 TCP 连接和 SSH 握手完成。超时只计算真正在等网络的时间，用户看主机指纹的时间不算。
async fn handshake<F>(
    connecting: F,
    shared: &Shared,
    label: &str,
    legacy: bool,
) -> Result<client::Handle<Handler>, CoreError>
where
    F: Future<Output = Result<client::Handle<Handler>, russh::Error>>,
{
    let mut connecting = std::pin::pin!(connecting);
    let tick = Duration::from_millis(250);
    let mut waited = Duration::ZERO;
    let result = loop {
        match tokio::time::timeout(tick, connecting.as_mut()).await {
            Ok(result) => break result,
            Err(_) => {
                if !shared.awaiting_user.load(Ordering::Acquire) {
                    waited += tick;
                    if waited >= CONNECT_TIMEOUT {
                        return Err(CoreError::Connect(format!("{label}：连接超时")));
                    }
                }
            }
        }
    };
    result.map_err(|e| match take(&shared.host_key_error) {
        Some(message) => CoreError::HostKey(message),
        None => CoreError::Connect(describe_connect_error(label, legacy, e)),
    })
}

async fn open_shell(
    handle: &client::Handle<Handler>,
    cfg: &ConnectConfig,
    utf8: bool,
) -> Result<russh::Channel<client::Msg>, CoreError> {
    let channel = handle.channel_open_session().await.map_err(session_err)?;
    // UTF-8 时告诉远端 tty 输入是 UTF-8，退格删除中文时才不会删半个字
    let modes: &[(Pty, u32)] = if utf8 { &[(Pty::IUTF8, 1)] } else { &[] };
    channel
        .request_pty(false, &cfg.term, cfg.cols.max(1), cfg.rows.max(1), 0, 0, modes)
        .await
        .map_err(session_err)?;
    // 和 OpenSSH 一样尝试传 LANG；服务器没开 AcceptEnv 会静默忽略。GBK 等编码的服务器用它自己的设置
    if utf8 {
        let _ = channel.set_env(false, "LANG", "en_US.UTF-8").await;
    }
    channel.request_shell(false).await.map_err(session_err)?;
    Ok(channel)
}

async fn disconnect_all(handles: &[Arc<client::Handle<Handler>>]) {
    // 先断目标主机，再从里往外断跳板机
    for handle in handles.iter().rev() {
        let _ = handle.disconnect(Disconnect::ByApplication, "", "en").await;
    }
}

fn prefix_error(e: CoreError, label: &str) -> CoreError {
    match e {
        CoreError::Auth(m) => CoreError::Auth(format!("{label}：{m}")),
        CoreError::Cancelled(m) => CoreError::Cancelled(format!("{label}：{m}")),
        CoreError::Session(m) => CoreError::Session(format!("{label}：{m}")),
        other => other,
    }
}

// ───────────────────────────── 认证 ─────────────────────────────

/// 一步认证的结果
enum Step {
    /// 认证完成
    Done,
    /// 这一步通过了，但服务器还要下一步（多因素认证）
    Partial(MethodSet),
    /// 被拒绝，附带服务器还允许的方式
    Rejected(MethodSet),
    /// 这条路没法走（没有 agent、私钥不存在、用户跳过了口令），换下一种
    Skipped,
}

fn step_of(result: AuthResult) -> Step {
    match result {
        AuthResult::Success => Step::Done,
        AuthResult::Failure {
            remaining_methods,
            partial_success: true,
        } => Step::Partial(remaining_methods),
        AuthResult::Failure {
            remaining_methods, ..
        } => Step::Rejected(remaining_methods),
    }
}

/// 认证一跳。成功时返回用过的认证方式，给界面显示。
async fn authenticate(
    handle: &mut client::Handle<Handler>,
    hop: &HopConfig,
    index: u32,
    delegate: &Arc<dyn SessionDelegate>,
) -> Result<String, CoreError> {
    let mut auth = Authenticator {
        handle,
        hop,
        index,
        delegate,
        password: None,
        rsa_hash: None,
        tried: Vec::new(),
        used: Vec::new(),
    };

    // 先用 none 探一下服务器允许哪些方式（OpenSSH 客户端也是这么做的）
    let allowed = match auth.none().await? {
        Step::Done => return Ok("none".into()),
        Step::Partial(methods) | Step::Rejected(methods) => methods,
        Step::Skipped => MethodSet::empty(),
    };

    let mut step = match &hop.auth {
        AuthMethod::Password => auth.password_or_keyboard(&allowed).await?,
        AuthMethod::PrivateKey { path } => auth.key_file(path, true).await?,
        AuthMethod::Agent => auth.agent(true, usize::MAX, &[]).await?,
        AuthMethod::Auto {
            key_paths,
            identities_only,
        } => auth.auto(&allowed, key_paths, *identities_only).await?,
    };

    // 服务器要求多因素时（AuthenticationMethods publickey,keyboard-interactive 之类）继续下一步
    for _ in 0..4 {
        match step {
            Step::Done => return Ok(auth.used.join(" + ")),
            Step::Partial(methods) => {
                auth.delegate.on_progress("服务器要求进一步验证 …".into());
                step = auth.next_factor(&methods).await?;
            }
            Step::Rejected(methods) => {
                return Err(CoreError::Auth(format!(
                    "服务器拒绝了登录（服务器允许的方式：{}）",
                    describe_methods(&methods)
                )));
            }
            Step::Skipped => {
                return Err(CoreError::Auth(format!(
                    "没有可用的认证方式（服务器允许的方式：{}）",
                    describe_methods(&allowed)
                )));
            }
        }
    }
    Err(CoreError::Auth("认证步骤过多".into()))
}

struct Authenticator<'a> {
    handle: &'a mut client::Handle<Handler>,
    hop: &'a HopConfig,
    index: u32,
    delegate: &'a Arc<dyn SessionDelegate>,
    /// 已经验证过（或刚输入、待验证）的密码，交互式认证遇到密码提示时自动填一次
    password: Option<String>,
    rsa_hash: Option<Option<HashAlg>>,
    /// 已经试过的公钥，同一把钥匙（agent 里一份、文件一份）不重复试
    tried: Vec<KeyData>,
    used: Vec<&'static str>,
}

impl Authenticator<'_> {
    fn user(&self) -> String {
        self.hop.username.clone()
    }

    async fn none(&mut self) -> Result<Step, CoreError> {
        let user = self.user();
        let result = self
            .handle
            .authenticate_none(user)
            .await
            .map_err(session_err)?;
        Ok(step_of(result))
    }

    /// 自动认证：agent → 私钥文件 → 密码 / 交互式认证
    async fn auto(
        &mut self,
        allowed: &MethodSet,
        key_paths: &[String],
        identities_only: bool,
    ) -> Result<Step, CoreError> {
        let mut remaining = allowed.clone();
        if allowed.contains(&MethodKind::PublicKey) {
            let files = key_files(key_paths);
            // IdentitiesOnly：agent 里也只用这几把钥匙
            let only: Vec<KeyData> = if identities_only {
                files
                    .iter()
                    .filter_map(|path| peek_public_key(path))
                    .map(|key| key.key_data().clone())
                    .collect()
            } else {
                Vec::new()
            };
            let skip_agent = identities_only && only.is_empty();
            if !skip_agent {
                match self.agent(false, AUTO_MAX_PUBLICKEY_ATTEMPTS, &only).await? {
                    Step::Skipped => {}
                    Step::Rejected(methods) => remaining = methods,
                    other => return Ok(other),
                }
            }
            for path in files {
                if self.tried.len() >= AUTO_MAX_PUBLICKEY_ATTEMPTS {
                    break;
                }
                match self.key_file(&path.display().to_string(), false).await? {
                    Step::Skipped => {}
                    Step::Rejected(methods) => remaining = methods,
                    other => return Ok(other),
                }
            }
        }
        if remaining.contains(&MethodKind::Password)
            || remaining.contains(&MethodKind::KeyboardInteractive)
        {
            return self.password_or_keyboard(&remaining).await;
        }
        Ok(Step::Rejected(remaining))
    }

    /// 多因素认证的下一步
    async fn next_factor(&mut self, methods: &MethodSet) -> Result<Step, CoreError> {
        if methods.contains(&MethodKind::KeyboardInteractive) {
            return self.keyboard_interactive().await;
        }
        if methods.contains(&MethodKind::Password) {
            return self.password().await;
        }
        if methods.contains(&MethodKind::PublicKey) {
            let paths = match &self.hop.auth {
                AuthMethod::PrivateKey { path } => vec![path.clone()],
                AuthMethod::Auto { key_paths, .. } => key_paths.clone(),
                _ => Vec::new(),
            };
            match self.agent(false, AUTO_MAX_PUBLICKEY_ATTEMPTS, &[]).await? {
                Step::Skipped | Step::Rejected(_) => {}
                other => return Ok(other),
            }
            for path in key_files(&paths) {
                match self.key_file(&path.display().to_string(), false).await? {
                    Step::Skipped | Step::Rejected(_) => {}
                    other => return Ok(other),
                }
            }
        }
        Ok(Step::Rejected(methods.clone()))
    }

    /// 用户选的是“密码”：服务器开了 password 就用它，只开 keyboard-interactive（PAM）时用同一个密码走交互式
    async fn password_or_keyboard(&mut self, allowed: &MethodSet) -> Result<Step, CoreError> {
        if allowed.contains(&MethodKind::Password) {
            return self.password().await;
        }
        if allowed.contains(&MethodKind::KeyboardInteractive) {
            return self.keyboard_interactive().await;
        }
        Err(CoreError::Auth(format!(
            "服务器不接受密码登录（服务器允许的方式：{}）",
            describe_methods(allowed)
        )))
    }

    async fn ask_secret(
        &self,
        kind: SecretKind,
        key_path: Option<&Path>,
        retry: bool,
    ) -> Option<String> {
        let request = SecretRequest {
            hop: self.index,
            kind,
            host: self.hop.host.clone(),
            port: self.hop.port,
            username: self.hop.username.clone(),
            key_path: key_path.map(|p| p.display().to_string()).unwrap_or_default(),
            retry,
        };
        let delegate = self.delegate.clone();
        tokio::task::spawn_blocking(move || delegate.request_secret(request))
            .await
            .unwrap_or(None)
    }

    async fn password(&mut self) -> Result<Step, CoreError> {
        let mut retry = false;
        for _ in 0..MAX_SECRET_ATTEMPTS {
            let Some(password) = self.ask_secret(SecretKind::Password, None, retry).await else {
                return Err(CoreError::Cancelled("你取消了输入密码".into()));
            };
            let user = self.user();
            let result = self
                .handle
                .authenticate_password(user, password.clone())
                .await
                .map_err(session_err)?;
            match step_of(result) {
                Step::Rejected(methods) => {
                    // 服务器不再接受密码（比如改成只允许别的方式），就不必再问了
                    if !methods.contains(&MethodKind::Password) {
                        return Ok(Step::Rejected(methods));
                    }
                    retry = true;
                }
                other => {
                    self.password = Some(password);
                    self.used.push("password");
                    return Ok(other);
                }
            }
        }
        Err(CoreError::Auth("密码错误次数过多".into()))
    }

    async fn keyboard_interactive(&mut self) -> Result<Step, CoreError> {
        // 密码提示答错时，下一次不能再用缓存或钥匙串里的旧密码
        let mut password_was_wrong = false;
        for _ in 0..MAX_SECRET_ATTEMPTS {
            let user = self.user();
            let mut response = self
                .handle
                .authenticate_keyboard_interactive_start(user, None::<String>)
                .await
                .map_err(session_err)?;
            let mut known_password = self.password.take();
            let mut answered_password: Option<String> = None;
            let mut last_was_password = false;

            // 服务器可以发很多轮提问，设个上限防止死循环
            let mut rounds = 0;
            let step = loop {
                rounds += 1;
                if rounds > 16 {
                    return Err(CoreError::Auth("交互式认证的轮数过多".into()));
                }
                match response {
                    KeyboardInteractiveAuthResponse::Success => break Step::Done,
                    KeyboardInteractiveAuthResponse::Failure {
                        remaining_methods,
                        partial_success,
                    } => {
                        break if partial_success {
                            Step::Partial(remaining_methods)
                        } else {
                            Step::Rejected(remaining_methods)
                        };
                    }
                    KeyboardInteractiveAuthResponse::InfoRequest {
                        name,
                        instructions,
                        prompts,
                    } => {
                        let answers = if prompts.is_empty() {
                            last_was_password = false;
                            Vec::new()
                        } else if prompts.len() == 1
                            && !prompts[0].echo
                            && is_password_prompt(&prompts[0].prompt)
                        {
                            // 单个密码提示：先用已知的密码，没有就像密码登录一样询问（UI 可以查钥匙串）
                            let password = match known_password.take() {
                                Some(password) if !password_was_wrong => password,
                                _ => self
                                    .ask_secret(SecretKind::Password, None, password_was_wrong)
                                    .await
                                    .ok_or_else(|| {
                                        CoreError::Cancelled("你取消了输入密码".into())
                                    })?,
                            };
                            answered_password = Some(password.clone());
                            last_was_password = true;
                            vec![password]
                        } else {
                            last_was_password = false;
                            let request = KeyboardInteractiveRequest {
                                hop: self.index,
                                host: self.hop.host.clone(),
                                port: self.hop.port,
                                username: self.hop.username.clone(),
                                name,
                                instructions,
                                prompts: prompts
                                    .iter()
                                    .map(|p| AuthPrompt {
                                        prompt: p.prompt.clone(),
                                        echo: p.echo,
                                    })
                                    .collect(),
                            };
                            let delegate = self.delegate.clone();
                            match tokio::task::spawn_blocking(move || {
                                delegate.keyboard_interactive(request)
                            })
                            .await
                            {
                                Ok(Some(answers)) => answers,
                                _ => {
                                    return Err(CoreError::Cancelled(
                                        "你取消了交互式认证".into(),
                                    ));
                                }
                            }
                        };
                        response = self
                            .handle
                            .authenticate_keyboard_interactive_respond(answers)
                            .await
                            .map_err(session_err)?;
                    }
                }
            };

            match step {
                Step::Rejected(methods) if methods.contains(&MethodKind::KeyboardInteractive) => {
                    // 答错了，重新来一轮。最后答的是密码就说明密码错了；否则密码没问题，下次继续自动填
                    password_was_wrong = last_was_password;
                    if !last_was_password {
                        self.password = answered_password;
                    }
                }
                Step::Rejected(methods) => return Ok(Step::Rejected(methods)),
                other => {
                    if let Some(password) = answered_password {
                        self.password = Some(password);
                    }
                    self.used.push("keyboard-interactive");
                    return Ok(other);
                }
            }
        }
        Err(CoreError::Auth("交互式认证失败次数过多".into()))
    }

    async fn rsa_hash_for(&mut self, key: &PublicKey) -> Result<Option<HashAlg>, CoreError> {
        if !key.algorithm().is_rsa() {
            return Ok(None);
        }
        if self.rsa_hash.is_none() {
            let hash = self
                .handle
                .best_supported_rsa_hash()
                .await
                .map_err(session_err)?
                .flatten();
            self.rsa_hash = Some(hash);
        }
        Ok(self.rsa_hash.flatten())
    }

    /// 用 ssh-agent 里的密钥。explicit 为 true 时（用户明确选了 agent）出问题直接报错，否则跳过。
    /// only 不为空时只用这几把钥匙（IdentitiesOnly）。
    async fn agent(
        &mut self,
        explicit: bool,
        budget: usize,
        only: &[KeyData],
    ) -> Result<Step, CoreError> {
        let socket = self.hop.identity_agent.trim().to_string();
        if socket.eq_ignore_ascii_case("none") {
            return if explicit {
                Err(CoreError::Auth("这个会话设置了不使用 ssh-agent".into()))
            } else {
                Ok(Step::Skipped)
            };
        }
        let connected = if socket.is_empty() || socket == "SSH_AUTH_SOCK" {
            AgentClient::connect_env().await
        } else {
            AgentClient::connect_uds(expand_tilde(&socket)).await
        };
        let mut agent = match connected {
            Ok(agent) => agent,
            Err(e) if explicit => {
                return Err(CoreError::Auth(format!("无法连接 ssh-agent：{e}")));
            }
            Err(_) => return Ok(Step::Skipped),
        };
        let identities = match agent.request_identities().await {
            Ok(identities) => identities,
            Err(e) if explicit => {
                return Err(CoreError::Auth(format!("读取 ssh-agent 中的密钥失败：{e}")));
            }
            Err(_) => return Ok(Step::Skipped),
        };
        if identities.is_empty() && explicit {
            return Err(CoreError::Auth(
                "ssh-agent 里没有密钥，先用 ssh-add 添加".into(),
            ));
        }

        let mut last = Step::Skipped;
        let mut attempts = 0;
        for identity in identities {
            if attempts >= budget {
                break;
            }
            let key = identity.public_key().into_owned();
            if !only.is_empty() && !only.contains(key.key_data()) {
                continue;
            }
            if self.tried.contains(key.key_data()) {
                continue;
            }
            attempts += 1;
            self.tried.push(key.key_data().clone());
            let hash = self.rsa_hash_for(&key).await?;
            let user = self.user();
            match self
                .handle
                .authenticate_publickey_with(user, key, hash, &mut agent)
                .await
            {
                Ok(result) => match step_of(result) {
                    Step::Rejected(methods) => last = Step::Rejected(methods),
                    other => {
                        self.used.push("publickey (ssh-agent)");
                        return Ok(other);
                    }
                },
                // agent 拒绝签名（比如 1Password 里点了拒绝）
                Err(e) if explicit => {
                    return Err(CoreError::Auth(format!("ssh-agent 签名失败：{e}")));
                }
                Err(_) => {}
            }
        }
        Ok(last)
    }

    /// 用私钥文件。有口令时向 UI 要；explicit 为 false 时（自动认证）文件不存在、读不了、用户不给口令都只是跳过。
    async fn key_file(&mut self, path: &str, explicit: bool) -> Result<Step, CoreError> {
        let full = expand_tilde(path);
        if !full.is_file() {
            return if explicit {
                Err(CoreError::Auth(format!("找不到私钥文件 {path}")))
            } else {
                Ok(Step::Skipped)
            };
        }
        // 先看公钥部分（.pub 文件或 OpenSSH 格式私钥里不加密的公钥），试过的钥匙不再试，也免得白问一次口令
        if let Some(public) = peek_public_key(&full)
            && self.tried.contains(public.key_data())
        {
            return Ok(Step::Skipped);
        }

        let mut passphrase: Option<String> = None;
        let mut asked = 0;
        let key = loop {
            match russh::keys::load_secret_key(&full, passphrase.as_deref()) {
                Ok(key) => break key,
                Err(e) if is_passphrase_problem(&e, passphrase.is_some()) => {
                    if asked >= MAX_SECRET_ATTEMPTS {
                        return Err(CoreError::Auth("私钥口令错误次数过多".into()));
                    }
                    let retry = passphrase.is_some();
                    asked += 1;
                    match self
                        .ask_secret(SecretKind::Passphrase, Some(&full), retry)
                        .await
                    {
                        Some(value) => passphrase = Some(value),
                        None if explicit => {
                            return Err(CoreError::Cancelled("你取消了输入私钥口令".into()));
                        }
                        None => return Ok(Step::Skipped),
                    }
                }
                Err(e) if explicit => {
                    return Err(CoreError::Auth(describe_key_error(
                        path,
                        passphrase.is_some(),
                        e,
                    )));
                }
                Err(_) => return Ok(Step::Skipped),
            }
        };

        let public = key.public_key().clone();
        if self.tried.contains(public.key_data()) {
            return Ok(Step::Skipped);
        }
        self.tried.push(public.key_data().clone());
        let hash = self.rsa_hash_for(&public).await?;
        let user = self.user();
        let result = self
            .handle
            .authenticate_publickey(user, PrivateKeyWithHashAlg::new(Arc::new(key), hash))
            .await
            .map_err(session_err)?;
        let step = step_of(result);
        if !matches!(step, Step::Rejected(_)) {
            self.used.push("publickey");
        }
        Ok(step)
    }
}

/// 自动认证要试的私钥文件
fn key_files(paths: &[String]) -> Vec<PathBuf> {
    if !paths.is_empty() {
        return paths.iter().map(|p| expand_tilde(p)).collect();
    }
    let Some(home) = std::env::home_dir() else {
        return Vec::new();
    };
    ["id_ed25519", "id_ecdsa", "id_rsa"]
        .iter()
        .map(|name| home.join(".ssh").join(name))
        .collect()
}

/// 不解密就拿到私钥对应的公钥：先找同名 .pub 文件，再看 OpenSSH 新格式私钥里明文存放的公钥
fn peek_public_key(path: &Path) -> Option<PublicKey> {
    let mut pub_path = path.as_os_str().to_owned();
    pub_path.push(".pub");
    if let Ok(key) = russh::keys::load_public_key(PathBuf::from(pub_path)) {
        return Some(key);
    }
    let text = std::fs::read_to_string(path).ok()?;
    russh::keys::ssh_key::PrivateKey::from_openssh(text)
        .ok()
        .map(|key| key.public_key().clone())
}

/// 这个错误是不是“需要口令 / 口令不对”
fn is_passphrase_problem(e: &russh::keys::Error, had_passphrase: bool) -> bool {
    if matches!(e, russh::keys::Error::KeyIsEncrypted) {
        return true;
    }
    let lower = e.to_string().to_lowercase();
    if had_passphrase {
        lower.contains("crypto") || lower.contains("decrypt") || lower.contains("encrypt")
    } else {
        lower.contains("encrypt")
    }
}

/// 交互式认证里的这个提示是不是在要登录密码（而不是动态口令、验证码）
fn is_password_prompt(prompt: &str) -> bool {
    let lower = prompt.to_lowercase();
    let otp_words = [
        "verification", "otp", "code", "token", "one-time", "mfa", "2fa", "动态", "验证码", "令牌",
    ];
    if otp_words.iter().any(|w| lower.contains(w)) {
        return false;
    }
    lower.contains("password") || lower.contains("passwd") || prompt.contains("密码")
}

// ───────────────────────────── 会话读写 ─────────────────────────────

async fn write_loop(
    writer: ChannelWriteHalf<client::Msg>,
    mut rx: mpsc::UnboundedReceiver<Command>,
    mut encoder: charset::InputEncoder,
    zmodem_active: Arc<AtomicBool>,
) {
    while let Some(command) = rx.recv().await {
        let result = match command {
            // rz / sz 传输期间的键盘输入会搅乱协议，丢掉
            Command::Data(_) if zmodem_active.load(Ordering::Acquire) => continue,
            Command::Data(bytes) => writer.data_bytes(encoder.encode(bytes)).await,
            Command::Raw(bytes) => writer.data_bytes(bytes).await,
            Command::Resize { cols, rows } => writer.window_change(cols, rows, 0, 0).await,
            Command::Close => {
                let _ = writer.eof().await;
                let _ = writer.close().await;
                break;
            }
            Command::Shutdown => break,
        };
        if result.is_err() {
            break;
        }
    }
}

struct ReadLoop {
    reader: ChannelReadHalf,
    delegate: Arc<dyn SessionDelegate>,
    flow: Arc<Flow>,
    shareds: Vec<Arc<Shared>>,
    hops: Vec<Arc<client::Handle<Handler>>>,
    tx: mpsc::UnboundedSender<Command>,
    closing: Arc<AtomicBool>,
    decoder: charset::OutputDecoder,
    forwards: Arc<Mutex<Vec<Arc<PortForward>>>>,
    zmodem_cancel: Arc<AtomicBool>,
    zmodem_active: Arc<AtomicBool>,
}

impl ReadLoop {
    /// 交给终端显示（必要时先转成 UTF-8），并记流控账
    fn deliver(&mut self, bytes: &[u8]) {
        if bytes.is_empty() {
            return;
        }
        let text = self.decoder.decode(bytes);
        if text.is_empty() {
            return;
        }
        self.flow.consume(text.len() as u64);
        self.delegate.on_output(text);
    }
}

/// 末尾几个字节可能是 rz / sz 握手的开头时，最多等这么久看后面的数据；没等到就照常显示
const ZMODEM_HOLD: Duration = Duration::from_millis(30);

async fn read_loop(mut ctx: ReadLoop) {
    let mut exit_status = None;
    let mut signal = None;
    // 收到服务器的 CHANNEL_CLOSE 说明是对方有意关闭；连接断掉时通道只会直接结束（None）
    let mut closed_by_server = false;
    // 可能是 ZMODEM 握手开头、先扣下没显示的字节
    let mut held: Vec<u8> = Vec::new();
    // rz / sz 结束后剩下的数据，下一轮先处理
    let mut incoming: Option<Vec<u8>> = None;
    loop {
        let chunk = match incoming.take() {
            Some(chunk) => chunk,
            None => {
                // UI 消化不过来时在这里等，而不是无限缓冲
                ctx.flow.wait_for_credit().await;
                let message = if held.is_empty() {
                    Some(ctx.reader.wait().await)
                } else {
                    tokio::time::timeout(ZMODEM_HOLD, ctx.reader.wait()).await.ok()
                };
                match message {
                    // 等不到后续数据：扣下的字节不是握手，照常显示
                    None => {
                        let bytes = std::mem::take(&mut held);
                        ctx.deliver(&bytes);
                        continue;
                    }
                    Some(Some(ChannelMsg::Data { data })) => {
                        let mut chunk = std::mem::take(&mut held);
                        chunk.extend_from_slice(&data);
                        chunk
                    }
                    Some(Some(ChannelMsg::ExtendedData { data, .. })) => {
                        let bytes = std::mem::take(&mut held);
                        ctx.deliver(&bytes);
                        ctx.deliver(&data);
                        continue;
                    }
                    Some(Some(ChannelMsg::ExitStatus { exit_status: code })) => {
                        exit_status = Some(code);
                        continue;
                    }
                    Some(Some(ChannelMsg::ExitSignal {
                        signal_name,
                        error_message,
                        ..
                    })) => {
                        let detail = error_message.trim();
                        signal = Some(if detail.is_empty() {
                            format!("远端进程被信号 {signal_name:?} 终止")
                        } else {
                            format!("远端进程被信号 {signal_name:?} 终止：{detail}")
                        });
                        continue;
                    }
                    Some(Some(ChannelMsg::Close)) => {
                        closed_by_server = true;
                        break;
                    }
                    Some(None) => break,
                    Some(Some(_)) => continue,
                }
            }
        };

        match zmodem::scan(&chunk) {
            zmodem::Scan::Nothing => ctx.deliver(&chunk),
            zmodem::Scan::Hold(n) => {
                let split = chunk.len() - n;
                ctx.deliver(&chunk[..split]);
                held = chunk[split..].to_vec();
            }
            zmodem::Scan::Found(position, direction) => {
                ctx.deliver(&chunk[..position]);
                ctx.zmodem_active.store(true, Ordering::Release);
                let outcome = zmodem::run(
                    zmodem::Link {
                        reader: &mut ctx.reader,
                        tx: &ctx.tx,
                        delegate: &ctx.delegate,
                        cancel: &ctx.zmodem_cancel,
                    },
                    direction,
                    chunk[position..].to_vec(),
                )
                .await;
                ctx.zmodem_active.store(false, Ordering::Release);
                if !outcome.leftover.is_empty() {
                    incoming = Some(outcome.leftover);
                }
                if outcome.channel_closed {
                    if let Some(rest) = incoming.take() {
                        ctx.deliver(&rest);
                    }
                    break;
                }
            }
        }
    }
    let rest = std::mem::take(&mut held);
    ctx.deliver(&rest);
    let _ = ctx.tx.send(Command::Shutdown);

    if let Ok(forwards) = ctx.forwards.lock() {
        for forward in forwards.iter() {
            forward.stop_with_reason("连接已断开");
        }
    }

    let closed_locally = ctx.closing.load(Ordering::Acquire);
    let lost =
        !closed_locally && !closed_by_server && exit_status.is_none() && signal.is_none();
    let reason = if signal.is_some() {
        signal
    } else if lost {
        // 外层（跳板机）断开往往才是根本原因，所以从前往后找
        Some(
            ctx.shareds
                .iter()
                .find_map(|s| take(&s.disconnect_reason))
                .unwrap_or_else(|| "连接已中断".into()),
        )
    } else {
        None
    };
    disconnect_all(&ctx.hops).await;
    ctx.delegate.on_closed(CloseInfo {
        exit_status,
        reason,
        lost,
    });
}

// ───────────────────────────── 算法与错误说明 ─────────────────────────────

/// 默认只用安全算法；勾选“兼容老设备”时额外追加 russh 支持的老算法（排在后面，优先级最低）。
fn preferred_algorithms(legacy: bool) -> Preferred {
    let base = Preferred::default();
    if !legacy {
        return base;
    }
    let extensions = [
        kex::EXTENSION_SUPPORT_AS_CLIENT,
        kex::EXTENSION_SUPPORT_AS_SERVER,
        kex::EXTENSION_OPENSSH_STRICT_KEX_AS_CLIENT,
        kex::EXTENSION_OPENSSH_STRICT_KEX_AS_SERVER,
    ];
    let mut kexes: Vec<kex::Name> = base
        .kex
        .iter()
        .filter(|name| !extensions.contains(name))
        .cloned()
        .collect();
    kexes.extend([
        kex::ECDH_SHA2_NISTP256,
        kex::ECDH_SHA2_NISTP384,
        kex::ECDH_SHA2_NISTP521,
        kex::DH_G14_SHA1,
        kex::DH_GEX_SHA1,
        kex::DH_G1_SHA1,
    ]);
    kexes.extend(extensions);

    let mut ciphers = base.cipher.to_vec();
    ciphers.extend([
        cipher::AES_256_CBC,
        cipher::AES_192_CBC,
        cipher::AES_128_CBC,
        cipher::TRIPLE_DES_CBC,
    ]);

    let mut macs = base.mac.to_vec();
    macs.extend([mac::HMAC_SHA1_ETM, mac::HMAC_SHA1]);

    Preferred {
        kex: Cow::Owned(kexes),
        cipher: Cow::Owned(ciphers),
        mac: Cow::Owned(macs),
        ..base
    }
}

fn describe_methods(methods: &MethodSet) -> String {
    if methods.is_empty() {
        return "无".into();
    }
    methods
        .iter()
        .map(|m| <&'static str>::from(m))
        .collect::<Vec<_>>()
        .join(", ")
}

/// 把握手阶段的错误翻译成能直接给用户看的话。算法协商失败是连老设备时最常见的问题。
fn describe_connect_error(label: &str, legacy_enabled: bool, e: russh::Error) -> String {
    match e {
        russh::Error::NoCommonAlgo { kind, theirs, .. } => {
            let what = match kind {
                russh::AlgorithmKind::Kex => "密钥交换",
                russh::AlgorithmKind::Key => "主机密钥",
                russh::AlgorithmKind::Cipher => "加密",
                russh::AlgorithmKind::Mac => "MAC 校验",
                russh::AlgorithmKind::Compression => "压缩",
            };
            // 去掉 ext-info-s、kex-strict-* 这类协议扩展标记，只列真正的算法
            let offered: Vec<String> = theirs
                .into_iter()
                .filter(|name| !name.starts_with("ext-info-") && !name.starts_with("kex-strict-"))
                .collect();
            let hint = if legacy_enabled {
                "，这些算法 Conch 目前也不支持"
            } else {
                "。如果是老设备，打开“兼容老设备算法”再试"
            };
            format!(
                "{label}：和服务器没有共同支持的{what}算法（服务器只提供 {}）{hint}",
                offered.join("、")
            )
        }
        russh::Error::IO(io) => format!("{label}：{}", describe_io_error(&io)),
        russh::Error::Disconnect => format!("{label}：服务器断开了连接"),
        other => format!("{label}：{other}"),
    }
}

/// 常见的网络错误换成中文说明，附上系统原文方便搜索
pub(crate) fn describe_io_error(e: &std::io::Error) -> String {
    use std::io::ErrorKind;
    let text = e.to_string();
    let hint = match e.kind() {
        ErrorKind::ConnectionRefused => "连接被拒绝：端口没有开放，或者服务没启动",
        ErrorKind::TimedOut => "连接超时",
        ErrorKind::HostUnreachable => "到不了这台主机：网络不通",
        ErrorKind::NetworkUnreachable => "网络不可用",
        ErrorKind::ConnectionReset => "连接被对方重置",
        ErrorKind::ConnectionAborted => "连接被中断",
        ErrorKind::UnexpectedEof => "对方关闭了连接（可能不是 SSH 服务，或者被防火墙拦截）",
        _ if text.contains("lookup address") || text.contains("nodename nor servname") => {
            "找不到这个主机名：检查拼写或 DNS"
        }
        _ => return text,
    };
    format!("{hint}（{text}）")
}

fn describe_forward_error(label: &str, jump_label: &str, e: russh::Error) -> String {
    match e {
        russh::Error::ChannelOpenFailure(ChannelOpenFailure::AdministrativelyProhibited) => {
            format!("{jump_label} 不允许转发连接（可能关闭了 AllowTcpForwarding），到不了 {label}")
        }
        russh::Error::ChannelOpenFailure(ChannelOpenFailure::ConnectFailed) => format!(
            "{jump_label} 连不上 {label}（地址或端口不对，或者跳板机到这台主机的网络不通）"
        ),
        other => format!("{jump_label} 转发到 {label} 失败：{other}"),
    }
}

fn describe_key_error(path: &str, has_passphrase: bool, e: russh::keys::Error) -> String {
    let text = e.to_string();
    let lower = text.to_lowercase();
    match e {
        russh::keys::Error::IO(io) if io.kind() == std::io::ErrorKind::NotFound => {
            format!("找不到私钥文件 {path}")
        }
        russh::keys::Error::KeyIsEncrypted => "这个私钥有口令，请填写私钥口令".into(),
        _ if !has_passphrase && lower.contains("encrypt") => "这个私钥有口令，请填写私钥口令".into(),
        _ if has_passphrase && (lower.contains("crypto") || lower.contains("decrypt")) => {
            "私钥口令不对（也可能是私钥文件已损坏）".into()
        }
        _ => format!("读取私钥 {path} 失败：{text}"),
    }
}

fn session_err(e: russh::Error) -> CoreError {
    CoreError::Session(e.to_string())
}

fn to_crlf(text: &str) -> String {
    text.replace("\r\n", "\n").replace('\n', "\r\n")
}

fn expand_tilde(path: &str) -> PathBuf {
    match (path.strip_prefix("~/"), std::env::home_dir()) {
        (Some(rest), Some(home)) => home.join(rest),
        _ => PathBuf::from(path),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn legacy_algorithms_are_appended_after_safe_ones() {
        let legacy = preferred_algorithms(true);
        let safe = preferred_algorithms(false);
        assert_eq!(&legacy.kex[..2], &safe.kex[..2]);
        assert!(legacy.kex.contains(&kex::DH_G1_SHA1));
        assert!(legacy.cipher.contains(&cipher::TRIPLE_DES_CBC));
        assert!(legacy.mac.contains(&mac::HMAC_SHA1));
        assert!(!safe.kex.contains(&kex::DH_G1_SHA1));
        // 扩展标记必须保留在列表里，否则会丢掉 strict-kex（Terrapin 缓解）
        assert!(legacy.kex.contains(&kex::EXTENSION_OPENSSH_STRICT_KEX_AS_CLIENT));
    }

    #[test]
    fn crlf_conversion() {
        assert_eq!(to_crlf("a\nb\r\nc"), "a\r\nb\r\nc");
    }

    #[test]
    fn flow_blocks_above_high_water_and_resumes_after_ack() {
        let flow = Flow::default();
        flow.consume(FLOW_HIGH_WATER + 1);
        assert!(flow.pending.load(Ordering::Acquire) > FLOW_HIGH_WATER);
        flow.ack(FLOW_HIGH_WATER);
        assert_eq!(flow.pending.load(Ordering::Acquire), 1);
        flow.ack(100);
        assert_eq!(flow.pending.load(Ordering::Acquire), 0);
        // 主动关闭时用 u64::MAX 一次性放开
        flow.consume(10);
        flow.ack(u64::MAX);
        assert_eq!(flow.pending.load(Ordering::Acquire), 0);
    }

    #[test]
    fn password_prompts_are_told_apart_from_otp_prompts() {
        assert!(is_password_prompt("Password: "));
        assert!(is_password_prompt("root@10.0.0.5's password:"));
        assert!(is_password_prompt("请输入密码："));
        assert!(!is_password_prompt("Verification code: "));
        assert!(!is_password_prompt("OTP Password: "));
        assert!(!is_password_prompt("请输入动态密码："));
        assert!(!is_password_prompt("[MFA auth]: "));
    }

    #[test]
    fn default_key_files_are_used_when_none_given() {
        let files = key_files(&[]);
        assert_eq!(files.len(), 3);
        assert!(files[0].ends_with(".ssh/id_ed25519"));
        let given = key_files(&["/tmp/a".into()]);
        assert_eq!(given, vec![PathBuf::from("/tmp/a")]);
    }
}
