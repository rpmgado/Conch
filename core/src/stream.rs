//! 不走 SSH 的终端连接：Telnet 和串口。
//!
//! 和 [`SshSession`](crate::SshSession) 一样提供写入、改尺寸、流控、关闭，回调也用同一个
//! [`SessionDelegate`]，界面可以一视同仁。SFTP、端口转发、rz/sz 这些只有 SSH 才有。

use std::ffi::CString;
use std::io;
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};

use tokio::io::unix::AsyncFd;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpStream;
use tokio::sync::mpsc;

use crate::charset::{self, InputEncoder, OutputDecoder};
use crate::{CONNECT_TIMEOUT, CloseInfo, CoreError, Flow, RUNTIME, SessionDelegate, SessionInfo, describe_io_error};

enum StreamCommand {
    Data(Vec<u8>),
    Resize { cols: u32, rows: u32 },
    Close,
}

/// 一个 Telnet 或串口连接
#[derive(uniffi::Object)]
pub struct StreamSession {
    tx: mpsc::UnboundedSender<StreamCommand>,
    flow: Arc<Flow>,
    closing: Arc<AtomicBool>,
    info: SessionInfo,
}

#[uniffi::export]
impl StreamSession {
    pub fn write(&self, data: Vec<u8>) {
        let _ = self.tx.send(StreamCommand::Data(data));
    }

    pub fn resize(&self, cols: u32, rows: u32) {
        if cols > 0 && rows > 0 {
            let _ = self.tx.send(StreamCommand::Resize { cols, rows });
        }
    }

    pub fn ack(&self, bytes: u64) {
        self.flow.ack(bytes);
    }

    /// 主动关闭，之后会收到 on_closed（lost = false）
    pub fn close(&self) {
        if self.closing.swap(true, Ordering::AcqRel) {
            return;
        }
        let _ = self.tx.send(StreamCommand::Close);
        self.flow.ack(u64::MAX);
    }

    pub fn info(&self) -> SessionInfo {
        self.info.clone()
    }
}

/// 读到的数据交给终端（必要时先转码），并记流控账
fn deliver(delegate: &Arc<dyn SessionDelegate>, flow: &Flow, decoder: &mut OutputDecoder, bytes: &[u8]) {
    if bytes.is_empty() {
        return;
    }
    let text = decoder.decode(bytes);
    if !text.is_empty() {
        flow.consume(text.len() as u64);
        delegate.on_output(text);
    }
}

// ───────────────────────────── Telnet ─────────────────────────────

#[derive(Debug, Clone, uniffi::Record)]
pub struct TelnetConfig {
    pub host: String,
    pub port: u16,
    pub cols: u32,
    pub rows: u32,
    pub term: String,
    pub encoding: String,
}

/// 连接 Telnet 服务器（明文传输，一般只用于内网的网络设备、老系统）
#[uniffi::export]
pub async fn connect_telnet(
    config: TelnetConfig,
    delegate: Arc<dyn SessionDelegate>,
) -> Result<Arc<StreamSession>, CoreError> {
    RUNTIME
        .spawn(telnet_inner(config, delegate))
        .await
        .map_err(|e| CoreError::Session(e.to_string()))?
}

async fn telnet_inner(cfg: TelnetConfig, delegate: Arc<dyn SessionDelegate>) -> Result<Arc<StreamSession>, CoreError> {
    let label = format!("{}:{}", cfg.host, cfg.port);
    delegate.on_progress(format!("正在连接 {label}（Telnet）…"));
    let stream = match tokio::time::timeout(CONNECT_TIMEOUT, TcpStream::connect((cfg.host.as_str(), cfg.port))).await {
        Err(_) => return Err(CoreError::Connect(format!("{label}：连接超时"))),
        Ok(Err(e)) => return Err(CoreError::Connect(format!("{label}：{}", describe_io_error(&e)))),
        Ok(Ok(stream)) => stream,
    };
    let _ = stream.set_nodelay(true);
    delegate.on_progress(format!("已连接 {label}（Telnet 不加密，内容在网络上是明文）"));

    let encoding = charset::lookup(&cfg.encoding);
    let telnet = Arc::new(Mutex::new(Telnet::new(&cfg.term, cfg.cols, cfg.rows)));
    let (mut reader, mut writer) = stream.into_split();
    let (tx, mut rx) = mpsc::unbounded_channel::<StreamCommand>();
    // 协商回复和键盘输入都从这里发出去，保证顺序
    let (wire_tx, mut wire_rx) = mpsc::unbounded_channel::<Vec<u8>>();
    let flow = Arc::new(Flow::default());
    let closing = Arc::new(AtomicBool::new(false));

    // 写：键盘输入转码、转义；尺寸变化发 NAWS
    {
        let telnet = telnet.clone();
        let wire_tx = wire_tx.clone();
        tokio::spawn(async move {
            let mut encoder = InputEncoder::new(encoding);
            while let Some(command) = rx.recv().await {
                let bytes = match command {
                    StreamCommand::Data(data) => {
                        let encoded = encoder.encode(data);
                        telnet.lock().map(|t| t.encode_input(&encoded)).unwrap_or_default()
                    }
                    StreamCommand::Resize { cols, rows } => {
                        telnet.lock().ok().and_then(|mut t| t.resize(cols, rows)).unwrap_or_default()
                    }
                    StreamCommand::Close => break,
                };
                if !bytes.is_empty() && wire_tx.send(bytes).is_err() {
                    break;
                }
            }
        });
    }
    tokio::spawn(async move {
        while let Some(bytes) = wire_rx.recv().await {
            if writer.write_all(&bytes).await.is_err() {
                break;
            }
        }
        // 所有发送方都结束了（主动关闭或连接断了），把 TCP 连接也关掉
        let _ = writer.shutdown().await;
    });

    // 读：剥掉协商命令，回复协商，数据交给终端
    {
        let flow = flow.clone();
        let closing = closing.clone();
        let wire = wire_tx;
        tokio::spawn(async move {
            let mut decoder = OutputDecoder::new(encoding);
            let mut buffer = vec![0u8; 64 * 1024];
            let lost = loop {
                flow.wait_for_credit().await;
                let read = tokio::select! {
                    read = reader.read(&mut buffer) => read,
                    // 主动关闭：不等服务器了
                    _ = wait_closing(&closing) => break false,
                };
                match read {
                    Ok(0) => break false,
                    Ok(n) => {
                        let (data, replies) = match telnet.lock() {
                            Ok(mut t) => t.receive(&buffer[..n]),
                            Err(_) => break true,
                        };
                        if !replies.is_empty() {
                            let _ = wire.send(replies);
                        }
                        deliver(&delegate, &flow, &mut decoder, &data);
                    }
                    Err(_) => break !closing.load(Ordering::Acquire),
                }
            };
            drop(wire);
            let local = closing.load(Ordering::Acquire);
            delegate.on_closed(CloseInfo {
                exit_status: None,
                reason: if local { None } else if lost { Some("连接中断".into()) } else { Some("服务器关闭了连接".into()) },
                lost: lost && !local,
            });
        });
    }

    Ok(Arc::new(StreamSession {
        tx,
        flow,
        closing,
        info: SessionInfo {
            kex: String::new(),
            host_key: String::new(),
            cipher: "不加密".into(),
            mac: String::new(),
            auth: "telnet".into(),
        },
    }))
}

async fn wait_closing(closing: &AtomicBool) {
    while !closing.load(Ordering::Acquire) {
        tokio::time::sleep(std::time::Duration::from_millis(100)).await;
    }
}

const IAC: u8 = 255;
const DONT: u8 = 254;
const DO: u8 = 253;
const WONT: u8 = 252;
const WILL: u8 = 251;
const SB: u8 = 250;
const SE: u8 = 240;
const OPT_ECHO: u8 = 1;
const OPT_SGA: u8 = 3;
const OPT_TTYPE: u8 = 24;
const OPT_NAWS: u8 = 31;

#[derive(Clone, Copy, PartialEq)]
enum ParseState {
    Data,
    Iac,
    Option(u8),
    Sub,
    SubIac,
}

/// Telnet 协议处理（RFC 854 及常用选项）：
/// - 我方同意发送终端类型（TTYPE）、窗口大小（NAWS），接受对方回显（ECHO）、不发 GA（SGA）；其他一律拒绝
/// - 只在状态真正改变时回复，避免两边来回协商死循环
/// - 数据里的 IAC IAC 还原成 0xFF；服务器发来的 CR NUL 还原成 CR
pub(crate) struct Telnet {
    term: String,
    cols: u32,
    rows: u32,
    local: [bool; 256],
    remote: [bool; 256],
    state: ParseState,
    sub: Vec<u8>,
    last_was_cr: bool,
}

impl Telnet {
    pub(crate) fn new(term: &str, cols: u32, rows: u32) -> Self {
        Self {
            term: term.to_uppercase(),
            cols,
            rows,
            local: [false; 256],
            remote: [false; 256],
            state: ParseState::Data,
            sub: Vec::new(),
            last_was_cr: false,
        }
    }

    /// 处理服务器发来的字节：返回（给终端的数据，要回给服务器的协商）
    pub(crate) fn receive(&mut self, input: &[u8]) -> (Vec<u8>, Vec<u8>) {
        let mut data = Vec::with_capacity(input.len());
        let mut replies = Vec::new();
        for &byte in input {
            match self.state {
                ParseState::Data => {
                    if byte == IAC {
                        self.state = ParseState::Iac;
                    } else if byte == 0 && self.last_was_cr {
                        self.last_was_cr = false;
                    } else {
                        self.last_was_cr = byte == b'\r';
                        data.push(byte);
                    }
                }
                ParseState::Iac => match byte {
                    IAC => {
                        data.push(IAC);
                        self.state = ParseState::Data;
                    }
                    DO | DONT | WILL | WONT => self.state = ParseState::Option(byte),
                    SB => {
                        self.sub.clear();
                        self.state = ParseState::Sub;
                    }
                    _ => self.state = ParseState::Data, // NOP、GA 等
                },
                ParseState::Option(command) => {
                    self.negotiate(command, byte, &mut replies);
                    self.state = ParseState::Data;
                }
                ParseState::Sub => {
                    if byte == IAC {
                        self.state = ParseState::SubIac;
                    } else if self.sub.len() < 256 {
                        self.sub.push(byte);
                    }
                }
                ParseState::SubIac => {
                    if byte == SE {
                        self.subnegotiation(&mut replies);
                        self.state = ParseState::Data;
                    } else {
                        if byte == IAC && self.sub.len() < 256 {
                            self.sub.push(IAC);
                        }
                        self.state = ParseState::Sub;
                    }
                }
            }
        }
        (data, replies)
    }

    fn negotiate(&mut self, command: u8, option: u8, replies: &mut Vec<u8>) {
        let index = option as usize;
        match command {
            DO => {
                if matches!(option, OPT_TTYPE | OPT_NAWS | OPT_SGA) {
                    if !self.local[index] {
                        self.local[index] = true;
                        replies.extend([IAC, WILL, option]);
                        if option == OPT_NAWS {
                            replies.extend(self.naws());
                        }
                    }
                } else {
                    replies.extend([IAC, WONT, option]);
                }
            }
            DONT => {
                if self.local[index] {
                    self.local[index] = false;
                    replies.extend([IAC, WONT, option]);
                }
            }
            WILL => {
                if matches!(option, OPT_ECHO | OPT_SGA) {
                    if !self.remote[index] {
                        self.remote[index] = true;
                        replies.extend([IAC, DO, option]);
                    }
                } else {
                    replies.extend([IAC, DONT, option]);
                }
            }
            WONT => {
                if self.remote[index] {
                    self.remote[index] = false;
                    replies.extend([IAC, DONT, option]);
                }
            }
            _ => {}
        }
    }

    fn subnegotiation(&mut self, replies: &mut Vec<u8>) {
        // 服务器问终端类型：SB TTYPE SEND
        if self.sub.first() == Some(&OPT_TTYPE) && self.sub.get(1) == Some(&1) && self.local[OPT_TTYPE as usize] {
            replies.extend([IAC, SB, OPT_TTYPE, 0]);
            replies.extend(escape(self.term.as_bytes()));
            replies.extend([IAC, SE]);
        }
    }

    fn naws(&self) -> Vec<u8> {
        let width = self.cols.min(u32::from(u16::MAX)) as u16;
        let height = self.rows.min(u32::from(u16::MAX)) as u16;
        let mut bytes = vec![IAC, SB, OPT_NAWS];
        bytes.extend(escape(&[(width >> 8) as u8, width as u8, (height >> 8) as u8, height as u8]));
        bytes.extend([IAC, SE]);
        bytes
    }

    /// 窗口尺寸变了：协商过 NAWS 就把新尺寸告诉服务器
    pub(crate) fn resize(&mut self, cols: u32, rows: u32) -> Option<Vec<u8>> {
        self.cols = cols;
        self.rows = rows;
        self.local[OPT_NAWS as usize].then(|| self.naws())
    }

    /// 键盘输入 → 线上的字节：0xFF 要转义；单独的回车按协议发成 CR NUL
    pub(crate) fn encode_input(&self, input: &[u8]) -> Vec<u8> {
        let mut out = Vec::with_capacity(input.len() + 4);
        for (index, &byte) in input.iter().enumerate() {
            match byte {
                IAC => out.extend([IAC, IAC]),
                b'\r' if input.get(index + 1) != Some(&b'\n') => out.extend([b'\r', 0]),
                _ => out.push(byte),
            }
        }
        out
    }
}

fn escape(bytes: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(bytes.len());
    for &byte in bytes {
        out.push(byte);
        if byte == IAC {
            out.push(IAC);
        }
    }
    out
}

// ───────────────────────────── 串口 ─────────────────────────────

#[derive(Debug, Clone, uniffi::Record)]
pub struct SerialConfig {
    /// 设备路径，如 /dev/cu.usbserial-1410
    pub path: String,
    pub baud_rate: u32,
    /// 5～8
    pub data_bits: u8,
    /// "none" / "even" / "odd"
    pub parity: String,
    /// 1 或 2
    pub stop_bits: u8,
    /// "none" / "hardware"（RTS/CTS）/ "software"（XON/XOFF）
    pub flow_control: String,
    pub encoding: String,
}

/// 本机的串口设备（/dev/cu.*）。USB 转串口线插上后就会出现在这里
#[uniffi::export]
pub fn list_serial_ports() -> Vec<String> {
    let mut ports: Vec<String> = std::fs::read_dir("/dev")
        .map(|entries| {
            entries
                .filter_map(Result::ok)
                .map(|e| e.file_name().to_string_lossy().into_owned())
                .filter(|name| name.starts_with("cu."))
                .map(|name| format!("/dev/{name}"))
                .collect()
        })
        .unwrap_or_default();
    ports.sort();
    ports
}

#[uniffi::export]
pub async fn open_serial(
    config: SerialConfig,
    delegate: Arc<dyn SessionDelegate>,
) -> Result<Arc<StreamSession>, CoreError> {
    RUNTIME
        .spawn(serial_inner(config, delegate))
        .await
        .map_err(|e| CoreError::Session(e.to_string()))?
}

async fn serial_inner(cfg: SerialConfig, delegate: Arc<dyn SessionDelegate>) -> Result<Arc<StreamSession>, CoreError> {
    let fd = open_port(&cfg).map_err(|e| CoreError::Connect(format!("{}：{e}", cfg.path)))?;
    // SAFETY：OwnedFd 只交给这个 AsyncFd，在它的整个生命周期里一直打开，as_raw_fd 总是同一个描述符
    let fd = unsafe { AsyncFd::register(fd) }.map_err(|e| {
        let (_, cause) = e.into_parts();
        CoreError::Connect(format!("{}：{cause}", cfg.path))
    })?;
    let fd = Arc::new(fd);
    delegate.on_progress(format!(
        "已打开串口 {}（{} {}{}{}）",
        cfg.path,
        cfg.baud_rate,
        cfg.data_bits,
        match cfg.parity.as_str() {
            "even" => "E",
            "odd" => "O",
            _ => "N",
        },
        cfg.stop_bits
    ));

    let encoding = charset::lookup(&cfg.encoding);
    let (tx, mut rx) = mpsc::unbounded_channel::<StreamCommand>();
    let flow = Arc::new(Flow::default());
    let closing = Arc::new(AtomicBool::new(false));

    {
        let fd = fd.clone();
        tokio::spawn(async move {
            let mut encoder = InputEncoder::new(encoding);
            while let Some(command) = rx.recv().await {
                match command {
                    StreamCommand::Data(data) => {
                        let bytes = encoder.encode(data);
                        if write_all(&fd, &bytes).await.is_err() {
                            break;
                        }
                    }
                    StreamCommand::Resize { .. } => {}
                    StreamCommand::Close => break,
                }
            }
        });
    }
    {
        let flow = flow.clone();
        let closing = closing.clone();
        tokio::spawn(async move {
            let mut decoder = OutputDecoder::new(encoding);
            let mut buffer = vec![0u8; 16 * 1024];
            let lost = loop {
                flow.wait_for_credit().await;
                let read = tokio::select! {
                    read = read_some(&fd, &mut buffer) => read,
                    _ = wait_closing(&closing) => break false,
                };
                match read {
                    Ok(0) => break true,
                    Ok(n) => deliver(&delegate, &flow, &mut decoder, &buffer[..n]),
                    // USB 转串口线被拔掉时会读到 EIO / ENXIO
                    Err(_) => break true,
                }
            };
            let local = closing.load(Ordering::Acquire);
            delegate.on_closed(CloseInfo {
                exit_status: None,
                reason: if local { None } else { Some("串口设备已断开（线被拔掉了？）".into()) },
                lost: lost && !local,
            });
        });
    }

    Ok(Arc::new(StreamSession {
        tx,
        flow,
        closing,
        info: SessionInfo {
            kex: String::new(),
            host_key: String::new(),
            cipher: String::new(),
            mac: String::new(),
            auth: "serial".into(),
        },
    }))
}

async fn read_some(fd: &AsyncFd<OwnedFd>, buffer: &mut [u8]) -> io::Result<usize> {
    loop {
        let mut guard = fd.readable().await?;
        match guard.try_io(|inner| {
            let n = unsafe { libc::read(inner.as_raw_fd(), buffer.as_mut_ptr().cast(), buffer.len()) };
            if n < 0 { Err(io::Error::last_os_error()) } else { Ok(n as usize) }
        }) {
            Ok(result) => return result,
            Err(_would_block) => continue,
        }
    }
}

async fn write_all(fd: &AsyncFd<OwnedFd>, mut bytes: &[u8]) -> io::Result<()> {
    while !bytes.is_empty() {
        let mut guard = fd.writable().await?;
        match guard.try_io(|inner| {
            let n = unsafe { libc::write(inner.as_raw_fd(), bytes.as_ptr().cast(), bytes.len()) };
            if n < 0 { Err(io::Error::last_os_error()) } else { Ok(n as usize) }
        }) {
            Ok(Ok(n)) => bytes = &bytes[n..],
            Ok(Err(e)) => return Err(e),
            Err(_would_block) => continue,
        }
    }
    Ok(())
}

/// 打开串口并设置波特率、数据位、校验、停止位、流控（和 screen、minicom 的做法一样）
fn open_port(cfg: &SerialConfig) -> Result<OwnedFd, String> {
    let path = CString::new(cfg.path.clone()).map_err(|_| "设备路径不对".to_string())?;
    let raw = unsafe { libc::open(path.as_ptr(), libc::O_RDWR | libc::O_NOCTTY | libc::O_NONBLOCK) };
    if raw < 0 {
        let e = io::Error::last_os_error();
        return Err(match e.raw_os_error() {
            Some(libc::ENOENT) => "找不到这个串口设备（线插好了吗？）".into(),
            Some(libc::EBUSY) => "串口正被其他程序占用".into(),
            Some(libc::EACCES) => "没有权限打开这个串口".into(),
            _ => e.to_string(),
        });
    }
    let fd = unsafe { OwnedFd::from_raw_fd(raw) };
    let raw = fd.as_raw_fd();
    unsafe {
        // 独占，避免两个程序同时读写同一个串口
        libc::ioctl(raw, libc::TIOCEXCL as libc::c_ulong);
        let mut tio: libc::termios = std::mem::zeroed();
        if libc::tcgetattr(raw, &mut tio) != 0 {
            return Err("这不是串口设备".into());
        }
        libc::cfmakeraw(&mut tio);
        tio.c_cflag |= libc::CLOCAL | libc::CREAD;
        tio.c_cflag &= !libc::CSIZE;
        tio.c_cflag |= match cfg.data_bits {
            5 => libc::CS5,
            6 => libc::CS6,
            7 => libc::CS7,
            _ => libc::CS8,
        };
        match cfg.parity.as_str() {
            "even" => {
                tio.c_cflag |= libc::PARENB;
                tio.c_cflag &= !libc::PARODD;
            }
            "odd" => tio.c_cflag |= libc::PARENB | libc::PARODD,
            _ => tio.c_cflag &= !libc::PARENB,
        }
        if cfg.stop_bits == 2 {
            tio.c_cflag |= libc::CSTOPB;
        } else {
            tio.c_cflag &= !libc::CSTOPB;
        }
        tio.c_iflag &= !(libc::IXON | libc::IXOFF | libc::IXANY);
        tio.c_cflag &= !libc::CRTSCTS;
        match cfg.flow_control.as_str() {
            "hardware" => tio.c_cflag |= libc::CRTSCTS,
            "software" => tio.c_iflag |= libc::IXON | libc::IXOFF,
            _ => {}
        }
        tio.c_cc[libc::VMIN] = 1;
        tio.c_cc[libc::VTIME] = 0;
        libc::cfsetspeed(&mut tio, cfg.baud_rate as libc::speed_t);
        if libc::tcsetattr(raw, libc::TCSANOW, &tio) != 0 {
            return Err(format!("设置串口参数失败：{}", io::Error::last_os_error()));
        }
        // 非标准波特率（如 250000）要用 macOS 的 IOSSIOSPEED
        const IOSSIOSPEED: libc::c_ulong = 0x8008_5402;
        if !STANDARD_BAUD_RATES.contains(&cfg.baud_rate) {
            let speed = cfg.baud_rate as libc::speed_t;
            libc::ioctl(raw, IOSSIOSPEED, &speed);
        }
        libc::tcflush(raw, libc::TCIOFLUSH);
    }
    Ok(fd)
}

const STANDARD_BAUD_RATES: [u32; 13] = [300, 600, 1200, 2400, 4800, 9600, 19200, 38400, 57600, 115200, 230400, 460800, 921600];

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn negotiates_terminal_type_and_window_size() {
        let mut t = Telnet::new("xterm-256color", 120, 40);
        // 服务器：DO TTYPE、DO NAWS、WILL ECHO、DO LINEMODE(34)，夹着一点数据
        let (data, replies) = t.receive(&[IAC, DO, OPT_TTYPE, IAC, DO, OPT_NAWS, b'h', b'i', IAC, WILL, OPT_ECHO, IAC, DO, 34]);
        assert_eq!(data, b"hi");
        assert_eq!(
            replies,
            vec![IAC, WILL, OPT_TTYPE, IAC, WILL, OPT_NAWS, IAC, SB, OPT_NAWS, 0, 120, 0, 40, IAC, SE, IAC, DO, OPT_ECHO, IAC, WONT, 34]
        );
        // 再问一次不回复（避免死循环）
        let (_, again) = t.receive(&[IAC, DO, OPT_NAWS, IAC, WILL, OPT_ECHO]);
        assert!(again.is_empty());
        // SB TTYPE SEND
        let (_, ttype) = t.receive(&[IAC, SB, OPT_TTYPE, 1, IAC, SE]);
        let mut expected = vec![IAC, SB, OPT_TTYPE, 0];
        expected.extend_from_slice(b"XTERM-256COLOR");
        expected.extend([IAC, SE]);
        assert_eq!(ttype, expected);
        // 改尺寸
        assert_eq!(t.resize(80, 24), Some(vec![IAC, SB, OPT_NAWS, 0, 80, 0, 24, IAC, SE]));
    }

    #[test]
    fn data_escaping_and_newlines() {
        let mut t = Telnet::new("xterm", 80, 24);
        // 跨两批到达的 IAC IAC，以及服务器的 CR NUL
        let (a, _) = t.receive(&[b'a', IAC]);
        let (b, _) = t.receive(&[IAC, b'\r', 0, b'b']);
        assert_eq!([a, b].concat(), vec![b'a', 0xFF, b'\r', b'b']);
        assert_eq!(t.encode_input(&[b'l', b's', b'\r']), vec![b'l', b's', b'\r', 0]);
        assert_eq!(t.encode_input(b"x\r\ny"), b"x\r\ny".to_vec());
        assert_eq!(t.encode_input(&[0xFF]), vec![0xFF, 0xFF]);
        // 没协商过 NAWS 就不发尺寸
        assert_eq!(t.resize(100, 30), None);
        // 协商过之后，尺寸里的 255 也要转义
        t.receive(&[IAC, DO, OPT_NAWS]);
        assert_eq!(t.resize(255, 24), Some(vec![IAC, SB, OPT_NAWS, 0, 255, 255, 0, 24, IAC, SE]));
    }
}
