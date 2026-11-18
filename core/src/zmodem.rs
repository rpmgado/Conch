//! rz / sz：在终端输出里认出 ZMODEM 的握手，接管这条通道传文件，传完再把终端交还给用户。
//!
//! 协议本身用 zmodem2（调用方负责所有 I/O 的状态机，MIT/Apache 许可，不涉及 GPL 的 lrzsz 代码）。
//! 远端执行 `sz 文件` 时我们是接收方（下载），执行 `rz` 时我们是发送方（上传）。

use std::fs::File;
use std::io::{Read, Seek, SeekFrom, Write};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant, SystemTime};

use russh::{ChannelMsg, ChannelReadHalf};
use tokio::sync::mpsc;
use zmodem2::{Action, Event, FileInfo, Position, Receiver, Sender};

use crate::{Command, SessionDelegate, ZmodemEvent};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Direction {
    /// 远端 sz：我们接收
    Download,
    /// 远端 rz：我们发送
    Upload,
}

pub(crate) enum Scan {
    /// 在这个位置发现了 ZMODEM 握手
    Found(usize, Direction),
    /// 末尾这么多字节可能是握手的开头，先别交给终端
    Hold(usize),
    Nothing,
}

/// ZMODEM 十六进制帧头的开头：ZPAD ZPAD ZDLE 'B' '0'，再往后一位 0 是 ZRQINIT（对方要发），1 是 ZRINIT（对方要收）
const HEADER: &[u8] = b"**\x18B0";

pub(crate) fn scan(data: &[u8]) -> Scan {
    let mut from = 0;
    while let Some(offset) = data[from..].iter().position(|&b| b == b'*') {
        let pos = from + offset;
        let rest = &data[pos..];
        if rest.len() > HEADER.len() {
            if rest.starts_with(HEADER) {
                match rest[HEADER.len()] {
                    b'0' => return Scan::Found(pos, Direction::Download),
                    b'1' => return Scan::Found(pos, Direction::Upload),
                    _ => {}
                }
            }
        } else if HEADER.starts_with(rest) {
            return Scan::Hold(rest.len());
        }
        from = pos + 1;
    }
    Scan::Nothing
}

/// 一次传输用到的东西
pub(crate) struct Link<'a> {
    pub reader: &'a mut ChannelReadHalf,
    pub tx: &'a mpsc::UnboundedSender<Command>,
    pub delegate: &'a Arc<dyn SessionDelegate>,
    pub cancel: &'a AtomicBool,
}

/// 传输结束后的状况
pub(crate) struct Outcome {
    /// 传输结束后多出来的字节（远端 shell 的提示符等），交还给终端
    pub leftover: Vec<u8>,
    /// 通道已经关闭（远端 shell 退出了或连接断了）
    pub channel_closed: bool,
}

/// 两次进度通知之间至少隔这么久
const PROGRESS_INTERVAL: Duration = Duration::from_millis(200);
/// 每次等输入最多等这么久，期间检查用户有没有点取消
const POLL_WAIT: Duration = Duration::from_millis(500);
/// 这么久没有任何输入，通知状态机超时（它会重发或放弃）
const PROTOCOL_TIMEOUT: Duration = Duration::from_secs(10);
/// 这么久都没进展就放弃
const GIVE_UP: Duration = Duration::from_secs(60);
/// 下载结束后等 sz 的 "OO" 最多这么久
const OVER_AND_OUT_WAIT: Duration = Duration::from_millis(300);
/// 取消后丢弃对方的数据，直到安静这么久
const DRAIN_QUIET: Duration = Duration::from_millis(400);
/// 取消后最多丢弃这么久
const DRAIN_LIMIT: Duration = Duration::from_secs(5);
/// 连续发送时每隔这么多个包看一眼对方有没有回话（取消、要求重传）
const CHECK_INPUT_EVERY: u32 = 16;

pub(crate) async fn run(mut link: Link<'_>, direction: Direction, initial: Vec<u8>) -> Outcome {
    link.cancel.store(false, Ordering::Release);
    link.delegate.on_zmodem_event(ZmodemEvent::Started {
        upload: direction == Direction::Upload,
    });
    let mut state = Transfer {
        input: initial,
        start: 0,
        channel_closed: false,
        files: 0,
    };
    let result = match direction {
        Direction::Download => receive(&mut link, &mut state).await,
        Direction::Upload => send(&mut link, &mut state).await,
    };
    let error = result.err();
    if error.is_some() {
        // 让远端的 rz / sz 也停下来，再把它停下来之前还在发的数据收掉，免得显示成一屏乱码
        let _ = link.tx.send(Command::Raw(abort_sequence()));
        state.drain_until_quiet(link.reader).await;
    } else if direction == Direction::Download {
        // sz 收到我们的 ZFIN 后还会发 "OO"（over and out），稍等一下把它收下来，别显示在终端里
        let deadline = Instant::now() + OVER_AND_OUT_WAIT;
        while !state.channel_closed && Instant::now() < deadline {
            let rest = state.pending();
            let noise = trailer_noise(rest);
            if rest.len() >= noise + 2 {
                break;
            }
            if !matches!(state.read_more_within(link.reader, OVER_AND_OUT_WAIT).await, Ok(Fed::Progress)) {
                break;
            }
        }
        let rest = state.pending();
        let noise = trailer_noise(rest);
        if rest[noise..].starts_with(b"OO") {
            state.consume(noise + 2);
        }
    }
    link.delegate.on_zmodem_event(ZmodemEvent::Finished {
        files: state.files,
        error,
    });
    let mut leftover = state.input.split_off(state.start.min(state.input.len()));
    // 帧尾留下的带奇偶位的换行（0x8A）和 XON 不是给人看的
    let junk = leftover.iter().take_while(|&&b| b == 0x8a || b == 0x11).count();
    leftover.drain(..junk);
    Outcome {
        leftover,
        channel_closed: state.channel_closed,
    }
}

struct Transfer {
    /// 收到但状态机还没消化的字节（从 start 开始）
    input: Vec<u8>,
    start: usize,
    channel_closed: bool,
    files: u32,
}

/// 状态机要求的下一步（把借用的数据拷出来，好继续调用状态机的方法）
enum Step {
    Write(Vec<u8>),
    WriteFile(Vec<u8>),
    ReadFile { offset: u32, max: usize },
    FileStarted { name: String, size: Option<u64>, modified: Option<u32> },
    FileCompleted,
    SessionCompleted,
    Aborted,
    Idle,
}

fn step(action: Action<'_>) -> Step {
    match action {
        Action::WriteWire(bytes) => Step::Write(bytes.to_vec()),
        Action::WriteFile(bytes) => Step::WriteFile(bytes.to_vec()),
        Action::ReadFile { offset, max_len } => Step::ReadFile { offset: offset.get(), max: max_len },
        Action::Event(Event::FileStarted(info)) => Step::FileStarted {
            name: String::from_utf8_lossy(info.name).into_owned(),
            size: info.size.map(|p| u64::from(p.get())),
            modified: info.modified,
        },
        Action::Event(Event::FileCompleted) => Step::FileCompleted,
        Action::Event(Event::SessionCompleted) => Step::SessionCompleted,
        Action::Event(Event::Aborted) => Step::Aborted,
        _ => Step::Idle,
    }
}

/// 状态机闲着时：先把手上的输入喂给它，没有就等远端的下一批数据
enum Fed {
    Progress,
    Waiting,
}

impl Transfer {
    fn pending(&self) -> &[u8] {
        &self.input[self.start..]
    }

    fn consume(&mut self, n: usize) {
        self.start += n;
        if self.start == self.input.len() {
            self.input.clear();
            self.start = 0;
        } else if self.start > 64 * 1024 {
            self.input.drain(..self.start);
            self.start = 0;
        }
    }

    /// 等远端数据，最多 POLL_WAIT。通道关了返回 Err
    async fn read_more(&mut self, reader: &mut ChannelReadHalf) -> Result<Fed, String> {
        self.read_more_within(reader, POLL_WAIT).await
    }

    /// 取消后：丢掉对方还在发的数据，直到安静一阵子
    async fn drain_until_quiet(&mut self, reader: &mut ChannelReadHalf) {
        let deadline = Instant::now() + DRAIN_LIMIT;
        while !self.channel_closed && Instant::now() < deadline {
            self.input.clear();
            self.start = 0;
            if !matches!(self.read_more_within(reader, DRAIN_QUIET).await, Ok(Fed::Progress)) {
                break;
            }
        }
        self.input.clear();
        self.start = 0;
    }

    async fn read_more_within(&mut self, reader: &mut ChannelReadHalf, limit: Duration) -> Result<Fed, String> {
        let wait = tokio::time::timeout(limit, async {
            loop {
                match reader.wait().await {
                    Some(ChannelMsg::Data { data }) => return Some(data.to_vec()),
                    Some(ChannelMsg::Close) | None => return None,
                    // stderr、退出码等这时都不重要
                    Some(_) => continue,
                }
            }
        })
        .await;
        match wait {
            Ok(Some(data)) => {
                self.input.extend_from_slice(&data);
                Ok(Fed::Progress)
            }
            Ok(None) => {
                self.channel_closed = true;
                Err("连接在传输过程中断开了".into())
            }
            Err(_) => Ok(Fed::Waiting),
        }
    }
}

/// 记录多久没进展、什么时候该通知状态机超时
struct Watchdog {
    last_progress: Instant,
    last_timeout: Instant,
}

impl Watchdog {
    fn new() -> Self {
        Self {
            last_progress: Instant::now(),
            last_timeout: Instant::now(),
        }
    }

    fn progress(&mut self) {
        self.last_progress = Instant::now();
        self.last_timeout = Instant::now();
    }

    /// 返回 Some(true) 表示该调一次 timeout()，Err 表示等太久了
    fn idle(&mut self) -> Result<bool, String> {
        if self.last_progress.elapsed() > GIVE_UP {
            return Err("对方太久没有回应，传输已放弃".into());
        }
        if self.last_timeout.elapsed() > PROTOCOL_TIMEOUT {
            self.last_timeout = Instant::now();
            return Ok(true);
        }
        Ok(false)
    }
}

fn protocol_error(e: zmodem2::Error) -> String {
    format!("ZMODEM 协议错误：{e:?}")
}

// ───────────────────────────── 下载（远端 sz）─────────────────────────────

async fn receive(link: &mut Link<'_>, state: &mut Transfer) -> Result<(), String> {
    let delegate = link.delegate.clone();
    let directory = tokio::task::spawn_blocking(move || delegate.zmodem_download_dir())
        .await
        .ok()
        .flatten()
        .ok_or_else(|| "你取消了接收文件".to_string())?;
    let directory = PathBuf::from(directory);
    std::fs::create_dir_all(&directory).map_err(|e| format!("无法创建下载目录 {}：{e}", directory.display()))?;

    // SSH 是可靠的传输，告诉 sz 可以不停地发（缓冲 0 + 重叠 I/O），否则每 1KB 就要等一次确认
    let mut receiver = Receiver::with_flow_control(0, true).map_err(protocol_error)?;
    let mut watchdog = Watchdog::new();
    let mut current: Option<(File, PathBuf, Option<u32>)> = None;
    let mut name = String::new();
    let mut done: u64 = 0;
    let mut total: u64 = 0;
    let mut last_report = Instant::now();
    // 状态机先报“完成”再吐出最后要发的字节（回给对方的 ZFIN），所以完成后要继续把它们发完
    let mut completed = false;

    loop {
        if link.cancel.load(Ordering::Acquire) && !completed {
            return Err("你取消了传输".into());
        }
        match step(receiver.poll()) {
            Step::Write(bytes) => {
                let n = bytes.len();
                let _ = link.tx.send(Command::Raw(bytes));
                receiver.wire_written(n);
            }
            Step::WriteFile(bytes) => {
                if let Some((file, _, _)) = current.as_mut() {
                    file.write_all(&bytes).map_err(|e| format!("写文件失败：{e}"))?;
                }
                receiver.file_written(bytes.len()).map_err(protocol_error)?;
                done += bytes.len() as u64;
                if last_report.elapsed() >= PROGRESS_INTERVAL {
                    last_report = Instant::now();
                    link.delegate.on_zmodem_event(ZmodemEvent::Progress {
                        name: name.clone(),
                        done,
                        total,
                    });
                }
            }
            Step::FileStarted {
                name: remote_name,
                size,
                modified,
            } => {
                let path = unique_path(&directory, &safe_file_name(&remote_name));
                let file = File::create(&path).map_err(|e| format!("无法创建 {}：{e}", path.display()))?;
                name = path
                    .file_name()
                    .map(|n| n.to_string_lossy().into_owned())
                    .unwrap_or_default();
                done = 0;
                total = size.unwrap_or(0);
                link.delegate.on_zmodem_event(ZmodemEvent::FileStarted {
                    name: name.clone(),
                    size: total,
                });
                current = Some((file, path, modified));
            }
            Step::FileCompleted => {
                if let Some((mut file, path, modified)) = current.take() {
                    let _ = file.flush();
                    if let Some(seconds) = modified {
                        let time = SystemTime::UNIX_EPOCH + Duration::from_secs(u64::from(seconds));
                        let _ = file.set_modified(time);
                    }
                    state.files += 1;
                    link.delegate.on_zmodem_event(ZmodemEvent::FileFinished {
                        name: name.clone(),
                        local_path: path.display().to_string(),
                    });
                }
            }
            Step::SessionCompleted => completed = true,
            Step::Aborted => {
                // 收了一半的文件删掉，免得留下不完整的文件
                if let Some((_, path, _)) = current.take() {
                    let _ = std::fs::remove_file(path);
                }
                return Err("对方取消了传输".into());
            }
            Step::ReadFile { .. } => {}
            Step::Idle if completed => return Ok(()),
            Step::Idle => {
                if !state.pending().is_empty() {
                    let consumed = receiver.submit_wire(state.pending()).map_err(protocol_error)?;
                    if consumed > 0 {
                        state.consume(consumed);
                        watchdog.progress();
                        continue;
                    }
                }
                match state.read_more(link.reader).await? {
                    Fed::Progress => watchdog.progress(),
                    Fed::Waiting => {
                        if watchdog.idle()? {
                            receiver.timeout().map_err(protocol_error)?;
                        }
                    }
                }
            }
        }
    }
}

// ───────────────────────────── 上传（远端 rz）─────────────────────────────

struct Outgoing {
    file: File,
    name: String,
    size: u64,
}

async fn send(link: &mut Link<'_>, state: &mut Transfer) -> Result<(), String> {
    let delegate = link.delegate.clone();
    let chosen = tokio::task::spawn_blocking(move || delegate.zmodem_choose_files())
        .await
        .ok()
        .flatten()
        .unwrap_or_default();
    let mut queue: Vec<PathBuf> = chosen
        .into_iter()
        .map(PathBuf::from)
        .filter(|p| p.is_file())
        .collect();
    if queue.is_empty() {
        return Err("你取消了发送文件".into());
    }
    queue.reverse(); // 从末尾 pop，保持用户选择的顺序

    let mut sender = Sender::new().map_err(protocol_error)?;
    // SSH 是可靠的传输，不用每 10 个包停下来等确认
    sender.set_streaming_window(usize::MAX);
    let mut watchdog = Watchdog::new();
    let mut current: Option<Outgoing> = None;
    let mut finishing = false;
    let mut buffer = vec![0u8; 8 * 1024];
    let mut last_report = Instant::now();
    // 完成后还要把最后的 "OO" 发出去
    let mut completed = false;
    let mut writes: u32 = 0;

    loop {
        if link.cancel.load(Ordering::Acquire) && !completed {
            return Err("你取消了传输".into());
        }
        match step(sender.poll()) {
            Step::Write(bytes) => {
                let n = bytes.len();
                let _ = link.tx.send(Command::Raw(bytes));
                sender.wire_written(n);
                // 连续发送时状态机不会闲下来，隔一阵子主动看看对方有没有取消或要求重传
                writes += 1;
                if writes.is_multiple_of(CHECK_INPUT_EVERY) {
                    if state.pending().is_empty() {
                        state.read_more_within(link.reader, Duration::ZERO).await?;
                    }
                    if !state.pending().is_empty() {
                        let consumed = sender.submit_wire(state.pending()).map_err(protocol_error)?;
                        state.consume(consumed);
                    }
                }
            }
            Step::ReadFile { offset, max } => {
                let Some(outgoing) = current.as_mut() else {
                    return Err("ZMODEM 状态错误：没有正在发送的文件".into());
                };
                if buffer.len() < max {
                    buffer.resize(max, 0);
                }
                outgoing
                    .file
                    .seek(SeekFrom::Start(u64::from(offset)))
                    .map_err(|e| format!("读文件失败：{e}"))?;
                let n = read_up_to(&mut outgoing.file, &mut buffer[..max]).map_err(|e| format!("读文件失败：{e}"))?;
                sender.submit_file(&buffer[..n]).map_err(protocol_error)?;
                if last_report.elapsed() >= PROGRESS_INTERVAL {
                    last_report = Instant::now();
                    link.delegate.on_zmodem_event(ZmodemEvent::Progress {
                        name: outgoing.name.clone(),
                        done: u64::from(offset) + n as u64,
                        total: outgoing.size,
                    });
                }
            }
            Step::FileCompleted => {
                if let Some(outgoing) = current.take() {
                    state.files += 1;
                    link.delegate.on_zmodem_event(ZmodemEvent::FileFinished {
                        name: outgoing.name,
                        local_path: String::new(),
                    });
                }
            }
            Step::SessionCompleted => completed = true,
            Step::Aborted => return Err("对方取消了传输".into()),
            Step::WriteFile(_) | Step::FileStarted { .. } => {}
            Step::Idle if completed => return Ok(()),
            Step::Idle => {
                if current.is_none() && !finishing {
                    if let Some(path) = queue.pop() {
                        let outgoing = open_outgoing(&path)?;
                        let modified = modified_seconds(&path);
                        let mut info = FileInfo::new(
                            outgoing.name.as_bytes(),
                            Some(Position::new(outgoing.size as u32)),
                        );
                        if let Some(seconds) = modified {
                            info = info.with_modified(seconds);
                        }
                        sender.start_file(info).map_err(protocol_error)?;
                        link.delegate.on_zmodem_event(ZmodemEvent::FileStarted {
                            name: outgoing.name.clone(),
                            size: outgoing.size,
                        });
                        current = Some(outgoing);
                    } else {
                        sender.finish().map_err(protocol_error)?;
                        finishing = true;
                    }
                    continue;
                }
                if !state.pending().is_empty() {
                    let consumed = sender.submit_wire(state.pending()).map_err(protocol_error)?;
                    if consumed > 0 {
                        state.consume(consumed);
                        watchdog.progress();
                        continue;
                    }
                }
                match state.read_more(link.reader).await? {
                    Fed::Progress => watchdog.progress(),
                    Fed::Waiting => {
                        if watchdog.idle()? {
                            sender.timeout().map_err(protocol_error)?;
                        }
                    }
                }
            }
        }
    }
}

fn open_outgoing(path: &Path) -> Result<Outgoing, String> {
    let file = File::open(path).map_err(|e| format!("无法读取 {}：{e}", path.display()))?;
    let size = file.metadata().map(|m| m.len()).unwrap_or(0);
    if size > u64::from(u32::MAX) {
        return Err(format!(
            "{} 超过 4 GB，ZMODEM 传不了，请改用 SFTP",
            path.display()
        ));
    }
    let name = path
        .file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_else(|| "file".into());
    Ok(Outgoing { file, name, size })
}

fn modified_seconds(path: &Path) -> Option<u32> {
    let modified = std::fs::metadata(path).ok()?.modified().ok()?;
    let seconds = modified.duration_since(SystemTime::UNIX_EPOCH).ok()?.as_secs();
    u32::try_from(seconds).ok()
}

fn read_up_to(file: &mut File, buffer: &mut [u8]) -> std::io::Result<usize> {
    let mut filled = 0;
    while filled < buffer.len() {
        match file.read(&mut buffer[filled..])? {
            0 => break,
            n => filled += n,
        }
    }
    Ok(filled)
}

/// 帧头末尾跟着的 CR、LF（可能带奇偶位成了 0x8A）和 XON，状态机解析完帧头后不会吃掉它们
fn trailer_noise(bytes: &[u8]) -> usize {
    bytes
        .iter()
        .take_while(|&&b| matches!(b, b'\r' | b'\n' | 0x8a | 0x11))
        .count()
}

/// 十个 CAN 加十个退格：让对方的 rz / sz 放弃，并擦掉终端上显示的乱码（和 lrzsz 的做法一样）
pub(crate) fn abort_sequence() -> Vec<u8> {
    let mut bytes = vec![0x18u8; 10];
    bytes.extend(std::iter::repeat_n(0x08u8, 10));
    bytes
}

/// 远端给的文件名只取最后一段，去掉路径分隔符，防止写到下载目录外面
fn safe_file_name(name: &str) -> String {
    let last = name.rsplit(['/', '\\']).next().unwrap_or("");
    let cleaned: String = last.chars().filter(|c| *c != '\0' && *c != ':').collect();
    match cleaned.trim() {
        "" | "." | ".." => "received-file".into(),
        other => other.to_string(),
    }
}

/// 同名文件已经存在时改成“名字 (1).扩展名”
fn unique_path(directory: &Path, name: &str) -> PathBuf {
    let candidate = directory.join(name);
    if !candidate.exists() {
        return candidate;
    }
    let path = Path::new(name);
    let stem = path.file_stem().map(|s| s.to_string_lossy().into_owned()).unwrap_or_default();
    let extension = path.extension().map(|e| format!(".{}", e.to_string_lossy())).unwrap_or_default();
    (1..)
        .map(|n| directory.join(format!("{stem} ({n}){extension}")))
        .find(|p| !p.exists())
        .expect("总能找到一个没用过的名字")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn finds_handshakes_and_holds_partial_ones() {
        assert!(matches!(scan(b"abc"), Scan::Nothing));
        assert!(matches!(scan(b"rz waiting\r**\x18B0100000023be50\r\n"), Scan::Found(11, Direction::Upload)));
        assert!(matches!(scan(b"**\x18B00000000000000\r\x8a\x11"), Scan::Found(0, Direction::Download)));
        // 末尾可能是握手的开头：先留着
        assert!(matches!(scan(b"hello **\x18B"), Scan::Hold(4)));
        assert!(matches!(scan(b"hello *"), Scan::Hold(1)));
        // 中间的星号不影响
        assert!(matches!(scan(b"a ** b *x"), Scan::Nothing));
        assert!(matches!(scan(b"**\x18B02"), Scan::Nothing));
    }

    #[test]
    fn frame_trailers_are_skipped() {
        assert_eq!(trailer_noise(b"\r\x8aOO\r\n$ "), 2);
        assert_eq!(trailer_noise(b"OO"), 0);
        assert_eq!(trailer_noise(b"\r\n\x11"), 3);
    }

    #[test]
    fn remote_file_names_cannot_escape_the_download_folder() {
        assert_eq!(safe_file_name("../../etc/passwd"), "passwd");
        assert_eq!(safe_file_name("dir\\evil.txt"), "evil.txt");
        assert_eq!(safe_file_name(".."), "received-file");
        assert_eq!(safe_file_name("报告 2026.pdf"), "报告 2026.pdf");
    }

    #[test]
    fn existing_files_are_not_overwritten() {
        let dir = std::env::temp_dir().join(format!("conch-zmodem-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join("a.txt"), b"x").unwrap();
        std::fs::write(dir.join("a (1).txt"), b"x").unwrap();
        assert_eq!(unique_path(&dir, "a.txt"), dir.join("a (2).txt"));
        assert_eq!(unique_path(&dir, "b.txt"), dir.join("b.txt"));
        std::fs::remove_dir_all(&dir).unwrap();
    }
}
