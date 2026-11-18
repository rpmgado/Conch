//! 阶段 2 功能的端到端测试：SFTP、端口转发、字符编码、rz / sz。
//! 对本地测试服务器跑（先 scripts/test-sshd.sh start）：
//!
//! cargo run --release --example features -- --keys <测试密钥目录> --password <模拟服务器密码> --rz-dir <模拟服务器的 rz 目录>
//!
//! 只测内核导出给 Swift 的同一套 API。

use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::{Duration, Instant};

use conch_core::{
    AuthMethod, CloseInfo, ConflictPolicy, ConnectConfig, ForwardKind, ForwardSpec, HopConfig,
    HostKeyInfo, KeyboardInteractiveRequest, SecretRequest, SerialConfig, SessionDelegate, SftpClient,
    SshSession, StreamSession, TelnetConfig, TransferObserver, TransferProgress, ZmodemEvent, connect,
    connect_telnet, open_serial,
};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpStream;
use tokio::sync::oneshot;

// ───────────────────────────── 测试用的回调 ─────────────────────────────

struct Probe {
    output: Mutex<Vec<u8>>,
    session: OnceLock<Arc<SshSession>>,
    unacked: AtomicU64,
    password: String,
    download_dir: PathBuf,
    upload_files: Mutex<Vec<String>>,
    zmodem: Mutex<Vec<ZmodemEvent>>,
    closed: Mutex<Option<CloseInfo>>,
}

impl Probe {
    fn new(password: &str, download_dir: PathBuf) -> Arc<Self> {
        Arc::new(Self {
            output: Mutex::new(Vec::new()),
            session: OnceLock::new(),
            unacked: AtomicU64::new(0),
            password: password.to_string(),
            download_dir,
            upload_files: Mutex::new(Vec::new()),
            zmodem: Mutex::new(Vec::new()),
            closed: Mutex::new(None),
        })
    }

    fn text(&self) -> String {
        String::from_utf8_lossy(&self.output.lock().unwrap()).into_owned()
    }

    fn zmodem_finished(&self) -> Option<(u32, Option<String>)> {
        self.zmodem.lock().unwrap().iter().rev().find_map(|e| match e {
            ZmodemEvent::Finished { files, error } => Some((*files, error.clone())),
            _ => None,
        })
    }
}

impl SessionDelegate for Probe {
    fn on_output(&self, data: Vec<u8>) {
        let n = data.len() as u64;
        self.output.lock().unwrap().extend_from_slice(&data);
        match self.session.get() {
            Some(session) => session.ack(n + self.unacked.swap(0, Ordering::Relaxed)),
            None => {
                self.unacked.fetch_add(n, Ordering::Relaxed);
            }
        }
    }
    fn on_progress(&self, _message: String) {}
    fn on_closed(&self, info: CloseInfo) {
        *self.closed.lock().unwrap() = Some(info);
    }
    fn verify_host_key(&self, _info: HostKeyInfo) -> bool {
        true
    }
    fn request_secret(&self, _request: SecretRequest) -> Option<String> {
        Some(self.password.clone())
    }
    fn keyboard_interactive(&self, request: KeyboardInteractiveRequest) -> Option<Vec<String>> {
        Some(request.prompts.iter().map(|_| self.password.clone()).collect())
    }
    fn zmodem_choose_files(&self) -> Option<Vec<String>> {
        Some(self.upload_files.lock().unwrap().clone())
    }
    fn zmodem_download_dir(&self) -> Option<String> {
        Some(self.download_dir.display().to_string())
    }
    fn on_zmodem_event(&self, event: ZmodemEvent) {
        self.zmodem.lock().unwrap().push(event);
    }
}

struct Waiter {
    done: Mutex<Option<oneshot::Sender<Option<String>>>>,
    last: Mutex<Option<TransferProgress>>,
}

impl TransferObserver for Waiter {
    fn on_progress(&self, progress: TransferProgress) {
        *self.last.lock().unwrap() = Some(progress);
    }
    fn on_finished(&self, error: Option<String>) {
        if let Some(tx) = self.done.lock().unwrap().take() {
            let _ = tx.send(error);
        }
    }
}

fn waiter() -> (Arc<Waiter>, oneshot::Receiver<Option<String>>) {
    let (tx, rx) = oneshot::channel();
    (
        Arc::new(Waiter {
            done: Mutex::new(Some(tx)),
            last: Mutex::new(None),
        }),
        rx,
    )
}

// 在第一批数据写出后取消，用固定的初始延迟越过进度回调节流窗口。
struct CancelAfterData {
    handle: OnceLock<Arc<conch_core::Transfer>>,
    bytes: AtomicU64,
    done: Mutex<Option<oneshot::Sender<Option<String>>>>,
}
impl TransferObserver for CancelAfterData {
    fn on_progress(&self, progress: TransferProgress) {
        if progress.bytes_done == 0 { std::thread::sleep(Duration::from_millis(170)); }
        else if progress.files_done == 0 {
            self.bytes.store(progress.bytes_done, Ordering::Relaxed);
            if let Some(handle) = self.handle.get() { handle.cancel(); }
        }
    }
    fn on_finished(&self, error: Option<String>) {
        if let Some(done) = self.done.lock().unwrap().take() { let _ = done.send(error); }
    }
}

// ───────────────────────────── 小工具 ─────────────────────────────

struct Report {
    failures: usize,
}

impl Report {
    fn check(&mut self, ok: bool, name: &str, detail: impl AsRef<str>) {
        println!("[{}] {name} {}", if ok { "PASS" } else { "FAIL" }, detail.as_ref());
        if !ok {
            self.failures += 1;
        }
    }
}

/// 和模拟服务器一样的测试内容
fn test_content(size: usize) -> Vec<u8> {
    (0..size).map(|i| ((i * 31 + 7) % 251) as u8).collect()
}

async fn wait_until(timeout: Duration, mut condition: impl FnMut() -> bool) -> bool {
    let deadline = Instant::now() + timeout;
    while Instant::now() < deadline {
        if condition() {
            return true;
        }
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    condition()
}

async fn open(
    host_port: (&str, u16),
    user: &str,
    auth: AuthMethod,
    encoding: &str,
    probe: Arc<Probe>,
) -> Arc<SshSession> {
    let config = ConnectConfig {
        jumps: vec![],
        target: HopConfig {
            host: host_port.0.into(),
            port: host_port.1,
            username: user.into(),
            auth,
            legacy_algorithms: false,
            identity_agent: "none".into(),
        },
        cols: 100,
        rows: 30,
        term: "xterm-256color".into(),
        known_hosts_path: std::env::temp_dir().join("conch-features-known_hosts").display().to_string(),
        encoding: encoding.into(),
    };
    let session = connect(config, probe.clone()).await.expect("连接失败");
    let _ = probe.session.set(session.clone());
    session
}

/// 连上转发端口，读到 SSH 版本行（转发目标是模拟 SSH 服务器）
async fn read_banner(stream: &mut TcpStream) -> String {
    let mut buffer = vec![0u8; 64];
    match tokio::time::timeout(Duration::from_secs(5), stream.read(&mut buffer)).await {
        Ok(Ok(n)) => String::from_utf8_lossy(&buffer[..n]).trim().to_string(),
        _ => String::new(),
    }
}

async fn transfer(
    start: impl FnOnce(Arc<Waiter>),
) -> (Option<String>, Option<TransferProgress>, Duration) {
    let (observer, done) = waiter();
    let t0 = Instant::now();
    start(observer.clone());
    let error = tokio::time::timeout(Duration::from_secs(120), done)
        .await
        .ok()
        .and_then(|r| r.ok())
        .unwrap_or(Some("超时".into()));
    let last = observer.last.lock().unwrap().clone();
    (error, last, t0.elapsed())
}

fn mbps(bytes: usize, elapsed: Duration) -> String {
    format!("{:.0} MB/s", bytes as f64 / 1e6 / elapsed.as_secs_f64())
}

// ───────────────────────────── 测试 ─────────────────────────────

#[tokio::main]
async fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let value_of = |flag: &str| {
        args.iter()
            .position(|a| a == flag)
            .and_then(|i| args.get(i + 1))
            .cloned()
    };
    let keys = PathBuf::from(value_of("--keys").expect("需要 --keys <测试密钥目录>"));
    let password = value_of("--password").expect("需要 --password");
    let rz_dir = PathBuf::from(value_of("--rz-dir").expect("需要 --rz-dir"));
    let user = std::env::var("USER").unwrap_or_else(|_| "user".into());
    let work = std::env::temp_dir().join(format!("conch-features-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&work);
    std::fs::create_dir_all(&work).unwrap();
    let mut report = Report { failures: 0 };

    let key_auth = || AuthMethod::PrivateKey {
        path: keys.join("client_ed25519").display().to_string(),
    };

    // ───── SFTP ─────
    println!("\n==> SFTP（OpenSSH 测试服务器）");
    let probe = Probe::new(&password, work.join("zmodem-unused"));
    let session = open(("127.0.0.1", 2222), &user, key_auth(), "UTF-8", probe.clone()).await;
    let sftp: Arc<SftpClient> = session.open_sftp().await.expect("打开 SFTP 失败");
    let home = sftp.home().await.unwrap_or_default();
    report.check(!home.is_empty(), "打开 SFTP、取得家目录", &home);

    let remote_dir = format!("{home}/conch-sftp-test-{}", std::process::id());
    let _ = sftp.remove(remote_dir.clone()).await;
    report.check(sftp.mkdir(remote_dir.clone()).await.is_ok(), "新建目录", &remote_dir);

    let local_src = work.join("src");
    std::fs::create_dir_all(local_src.join("tree/子目录")).unwrap();
    let big = test_content(24 * 1024 * 1024);
    std::fs::write(local_src.join("big.bin"), &big).unwrap();
    std::fs::write(local_src.join("tree/子目录/说明.txt"), "你好，SFTP\n").unwrap();
    std::fs::write(local_src.join("tree/run.sh"), "#!/bin/sh\necho ok\n").unwrap();
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(local_src.join("tree/run.sh"), std::fs::Permissions::from_mode(0o755)).unwrap();
    }

    let (error, last, elapsed) = transfer(|o| {
        sftp.upload(local_src.join("big.bin").display().to_string(), remote_dir.clone(), ConflictPolicy::Overwrite, o);
    })
    .await;
    report.check(error.is_none(), "上传 24 MB 文件", format!("{error:?}，{}", mbps(big.len(), elapsed)));
    report.check(
        last.as_ref().is_some_and(|p| p.bytes_done == big.len() as u64 && p.files_done == 1),
        "上传进度",
        format!("{last:?}"),
    );
    let stat = sftp.stat(format!("{remote_dir}/big.bin")).await;
    report.check(stat.as_ref().is_ok_and(|f| f.size == big.len() as u64), "远端文件大小一致", format!("{:?}", stat.map(|f| f.size)));

    let (error, last, _) = transfer(|o| {
        sftp.upload(local_src.join("tree").display().to_string(), remote_dir.clone(), ConflictPolicy::Overwrite, o);
    })
    .await;
    report.check(error.is_none() && last.as_ref().is_some_and(|p| p.files_total == 2), "上传整个文件夹", format!("{error:?} {last:?}"));
    let listing = sftp.list(format!("{remote_dir}/tree/子目录")).await.unwrap_or_default();
    report.check(listing.iter().any(|f| f.name == "说明.txt"), "子目录和中文文件名", format!("{:?}", listing.iter().map(|f| &f.name).collect::<Vec<_>>()));
    let script = sftp.stat(format!("{remote_dir}/tree/run.sh")).await;
    report.check(script.as_ref().is_ok_and(|f| f.permissions & 0o111 != 0), "保留可执行权限", format!("{:o}", script.map(|f| f.permissions).unwrap_or(0)));

    // 覆盖已有文件时不改它的权限（远程编辑不能把 600 的文件变成本机副本的 644）
    let _ = sftp.chmod(format!("{remote_dir}/tree/run.sh"), 0o700).await;
    let (error, _, _) = transfer(|o| {
        sftp.upload(local_src.join("tree/run.sh").display().to_string(), format!("{remote_dir}/tree"), ConflictPolicy::Overwrite, o);
    })
    .await;
    let mode = sftp.stat(format!("{remote_dir}/tree/run.sh")).await.map(|f| f.permissions & 0o777).unwrap_or(0);
    report.check(error.is_none() && mode == 0o700, "覆盖已有文件时保留它的权限", format!("{error:?} {mode:o}"));

    let local_out = work.join("out");
    std::fs::create_dir_all(&local_out).unwrap();
    let (error, _, elapsed) = transfer(|o| {
        sftp.download(format!("{remote_dir}/big.bin"), local_out.display().to_string(), ConflictPolicy::Overwrite, o);
    })
    .await;
    let same = std::fs::read(local_out.join("big.bin")).map(|d| d == big).unwrap_or(false);
    report.check(error.is_none() && same, "下载并核对内容", format!("{error:?}，{}", mbps(big.len(), elapsed)));

    // 断点续传：本地只有前 5 MB，续传补全
    let resume_dir = work.join("resume");
    std::fs::create_dir_all(&resume_dir).unwrap();
    std::fs::write(resume_dir.join("big.bin"), &big[..5 * 1024 * 1024]).unwrap();
    let (error, _, _) = transfer(|o| {
        sftp.download(format!("{remote_dir}/big.bin"), resume_dir.display().to_string(), ConflictPolicy::Resume, o);
    })
    .await;
    let same = std::fs::read(resume_dir.join("big.bin")).map(|d| d == big).unwrap_or(false);
    report.check(error.is_none() && same, "下载断点续传（本地已有前 5 MB）", format!("{error:?}"));

    // 上传续传：远端先放一个只有前 3 MB 的同名文件
    let part_dir = work.join("part");
    std::fs::create_dir_all(&part_dir).unwrap();
    std::fs::write(part_dir.join("big.bin"), &big[..3 * 1024 * 1024]).unwrap();
    let remote_resume = format!("{remote_dir}/resume");
    let _ = sftp.mkdir(remote_resume.clone()).await;
    let _ = transfer(|o| {
        sftp.upload(part_dir.join("big.bin").display().to_string(), remote_resume.clone(), ConflictPolicy::Overwrite, o);
    })
    .await;
    let (error, _, _) = transfer(|o| {
        sftp.upload(local_src.join("big.bin").display().to_string(), remote_resume.clone(), ConflictPolicy::Resume, o);
    })
    .await;
    let check_dir = work.join("check");
    std::fs::create_dir_all(&check_dir).unwrap();
    let _ = transfer(|o| {
        sftp.download(format!("{remote_resume}/big.bin"), check_dir.display().to_string(), ConflictPolicy::Overwrite, o);
    })
    .await;
    let same = std::fs::read(check_dir.join("big.bin")).map(|d| d == big).unwrap_or(false);
    report.check(error.is_none() && same, "上传断点续传（远端已有前 3 MB）", format!("{error:?}"));

    // 发布前回归：读取源失败不能损伤旧目标，等长异内容不能被当成续传完成。
    {
        use std::os::unix::fs::PermissionsExt;
        let local_safe = work.join("safe-transfer");
        std::fs::create_dir_all(&local_safe).unwrap();
        let source = PathBuf::from(format!("{remote_dir}/protected-download.txt"));
        let destination = local_safe.join("protected-download.txt");
        std::fs::write(&source, b"new source").unwrap();
        std::fs::write(&destination, b"KEEP ORIGINAL").unwrap();
        std::fs::set_permissions(&source, std::fs::Permissions::from_mode(0)).unwrap();
        let (error, _, _) = transfer(|o| { sftp.download(source.display().to_string(), local_safe.display().to_string(), ConflictPolicy::Overwrite, o); }).await;
        std::fs::set_permissions(&source, std::fs::Permissions::from_mode(0o600)).unwrap();
        report.check(error.is_some() && std::fs::read(&destination).unwrap() == b"KEEP ORIGINAL", "下载源读取失败保留原文件", format!("{error:?}"));
        let source = local_safe.join("protected-upload.txt");
        let destination = PathBuf::from(format!("{remote_dir}/protected-upload.txt"));
        std::fs::write(&source, b"new source").unwrap();
        std::fs::write(&destination, b"KEEP ORIGINAL").unwrap();
        std::fs::set_permissions(&source, std::fs::Permissions::from_mode(0)).unwrap();
        let (error, _, _) = transfer(|o| { sftp.upload(source.display().to_string(), remote_dir.clone(), ConflictPolicy::Overwrite, o); }).await;
        std::fs::set_permissions(&source, std::fs::Permissions::from_mode(0o600)).unwrap();
        report.check(error.is_some() && std::fs::read(&destination).unwrap() == b"KEEP ORIGINAL", "上传源读取失败保留原文件", format!("{error:?}"));
        for upload in [false, true] {
            for (name, stale) in [("same-size.txt", &b"OLD!"[..]), ("wrong-prefix.txt", &b"OL"[..])] {
                let local = local_safe.join(name);
                let remote = PathBuf::from(format!("{remote_dir}/{name}"));
                let (source, destination) = if upload { (&local, &remote) } else { (&remote, &local) };
                std::fs::write(source, b"NEW!").unwrap();
                std::fs::write(destination, stale).unwrap();
                let (error, _, _) = transfer(|o| {
                    if upload { sftp.upload(local.display().to_string(), remote_dir.clone(), ConflictPolicy::Resume, o); }
                    else { sftp.download(remote.display().to_string(), local_safe.display().to_string(), ConflictPolicy::Resume, o); }
                }).await;
                report.check(error.is_none() && std::fs::read(destination).unwrap() == b"NEW!",
                    "续传校验内容：等长不等于相同，错误前缀重新传输", format!("upload={upload} {name} {error:?}"));
            }
        }
        // 目标没有变化且所有数据已写好之前，取消不能清空旧版本。
        let destination = local_safe.join("big.bin");
        std::fs::write(&destination, b"KEEP ORIGINAL").unwrap();
        let (error, _, _) = transfer(|o| { let t = sftp.download(format!("{remote_dir}/big.bin"), local_safe.display().to_string(), ConflictPolicy::Overwrite, o); t.cancel(); }).await;
        report.check(error.is_some() && std::fs::read(&destination).unwrap() == b"KEEP ORIGINAL", "取消覆盖下载保留旧版本", format!("{error:?}"));
        for upload in [false, true] {
            let destination = if upload { PathBuf::from(format!("{remote_dir}/big.bin")) } else { local_safe.join("big.bin") };
            std::fs::write(&destination, b"KEEP ORIGINAL").unwrap();
            // 下载用独立源，上传恢复同名远端文件。
            let remote_source = format!("{remote_dir}/large-source.bin");
            std::fs::write(&remote_source, &big).unwrap();
            if !upload { std::fs::write(local_safe.join("large-source.bin"), b"KEEP ORIGINAL").unwrap(); }
            let (done, rx) = oneshot::channel();
            let observer = Arc::new(CancelAfterData { handle: OnceLock::new(), bytes: AtomicU64::new(0), done: Mutex::new(Some(done)) });
            let handle = if upload { sftp.upload(local_src.join("big.bin").display().to_string(), remote_dir.clone(), ConflictPolicy::Overwrite, observer.clone()) }
                else { sftp.download(remote_source.clone(), local_safe.display().to_string(), ConflictPolicy::Overwrite, observer.clone()) };
            let _ = observer.handle.set(handle);
            let error = tokio::time::timeout(Duration::from_secs(30), rx).await.unwrap().unwrap();
            let target = if upload { destination } else { local_safe.join("large-source.bin") };
            report.check(observer.bytes.load(Ordering::Relaxed) > 0 && error.is_some() && std::fs::read(&target).unwrap() == b"KEEP ORIGINAL",
                "中途取消保留旧文件", format!("upload={upload} {error:?}"));
            let (error, _, _) = transfer(|o| {
                if upload { sftp.upload(local_src.join("big.bin").display().to_string(), remote_dir.clone(), ConflictPolicy::Resume, o); }
                else { sftp.download(remote_source.clone(), local_safe.display().to_string(), ConflictPolicy::Resume, o); }
            }).await;
            report.check(error.is_none() && std::fs::read(&target).unwrap() == big,
                "取消后重试复用临时文件并完成校验", format!("upload={upload} {error:?}"));
        }
        let linked = local_safe.join("linked");
        std::os::unix::fs::symlink(&local_src, &linked).unwrap();
        let (error, _, _) = transfer(|o| { sftp.upload(linked.display().to_string(), remote_dir.clone(), ConflictPolicy::Overwrite, o); }).await;
        report.check(error.is_some(), "不自动递归上传符号链接", format!("{error:?}"));
    }

    // 取消
    let cancel_dir = work.join("cancel");
    std::fs::create_dir_all(&cancel_dir).unwrap();
    let (error, _, _) = transfer(|o| {
        let handle = sftp.download(format!("{remote_dir}/big.bin"), cancel_dir.display().to_string(), ConflictPolicy::Overwrite, o);
        handle.cancel();
    })
    .await;
    report.check(error.as_deref().is_some_and(|e| e.ends_with("已取消")), "取消传输", format!("{error:?}"));

    let renamed = format!("{remote_dir}/改名.bin");
    report.check(sftp.rename(format!("{remote_dir}/big.bin"), renamed.clone()).await.is_ok(), "重命名", "");
    let chmod = sftp.chmod(renamed.clone(), 0o600).await;
    let mode = sftp.stat(renamed.clone()).await.map(|f| f.permissions).unwrap_or(0);
    report.check(chmod.is_ok() && mode == 0o600, "修改权限", format!("{mode:o}"));
    let missing = sftp.list(format!("{remote_dir}/不存在")).await;
    report.check(
        matches!(&missing, Err(e) if e.to_string().contains("不存在")),
        "错误信息是中文",
        format!("{:?}", missing.err().map(|e| e.to_string())),
    );
    report.check(sftp.remove(remote_dir.clone()).await.is_ok(), "递归删除目录", "");
    report.check(sftp.stat(remote_dir.clone()).await.is_err(), "删除后不存在了", "");

    // ───── 远程执行命令（服务器监控用）─────
    println!("\n==> 远程执行命令");
    let result = session.exec("echo hello; echo oops >&2; exit 5".into(), 10).await;
    report.check(
        result.as_ref().is_ok_and(|r| r.stdout == b"hello\n" && r.stderr == b"oops\n" && r.exit_status == Some(5)),
        "输出、错误输出、退出码分开拿到",
        format!("{:?}", result.as_ref().map(|r| (String::from_utf8_lossy(&r.stdout).to_string(), r.exit_status))),
    );
    let slow = session.exec("sleep 5".into(), 1).await;
    report.check(matches!(&slow, Err(e) if e.to_string().contains("超时")), "超时会放弃", format!("{:?}", slow.err().map(|e| e.to_string())));
    let parallel = futures_lite_join(&session).await;
    report.check(parallel, "多条命令同时执行，终端不受影响", "");

    // ───── 端口转发（同一条连接）─────
    println!("\n==> 端口转发（经 OpenSSH 测试服务器，目标是模拟服务器 2224）");
    let local = session
        .start_forward(ForwardSpec {
            kind: ForwardKind::Local,
            bind_host: "127.0.0.1".into(),
            bind_port: 0,
            target_host: "127.0.0.1".into(),
            target_port: 2224,
        })
        .await
        .expect("本地转发启动失败");
    let local_port = local.status().bound_port;
    let mut stream = TcpStream::connect(("127.0.0.1", local_port)).await.unwrap();
    let banner = read_banner(&mut stream).await;
    report.check(banner.starts_with("SSH-2.0"), "本地转发（-L）", format!("端口 {local_port}：{banner}"));
    drop(stream);

    let dynamic = session
        .start_forward(ForwardSpec {
            kind: ForwardKind::Dynamic,
            bind_host: "127.0.0.1".into(),
            bind_port: 0,
            target_host: String::new(),
            target_port: 0,
        })
        .await
        .expect("动态转发启动失败");
    let socks_port = dynamic.status().bound_port;
    let mut stream = TcpStream::connect(("127.0.0.1", socks_port)).await.unwrap();
    stream.write_all(&[5, 1, 0]).await.unwrap();
    let mut greeting = [0u8; 2];
    stream.read_exact(&mut greeting).await.unwrap();
    let mut request = vec![5, 1, 0, 3, 9];
    request.extend_from_slice(b"localhost");
    request.extend_from_slice(&2224u16.to_be_bytes());
    stream.write_all(&request).await.unwrap();
    let mut reply = [0u8; 10];
    stream.read_exact(&mut reply).await.unwrap();
    let banner = read_banner(&mut stream).await;
    report.check(
        greeting == [5, 0] && reply[1] == 0 && banner.starts_with("SSH-2.0"),
        "动态转发（SOCKS5，-D）",
        format!("端口 {socks_port}：{banner}"),
    );
    drop(stream);

    let remote = session
        .start_forward(ForwardSpec {
            kind: ForwardKind::Remote,
            bind_host: "127.0.0.1".into(),
            bind_port: 0,
            target_host: "127.0.0.1".into(),
            target_port: 2224,
        })
        .await
        .expect("远程转发启动失败");
    let remote_port = remote.status().bound_port;
    let banner = match TcpStream::connect(("127.0.0.1", remote_port)).await {
        Ok(mut stream) => read_banner(&mut stream).await,
        Err(e) => e.to_string(),
    };
    report.check(banner.starts_with("SSH-2.0"), "远程转发（-R，服务器分配端口）", format!("端口 {remote_port}：{banner}"));
    let counted = wait_until(Duration::from_secs(2), || local.status().total_connections == 1).await;
    report.check(counted, "转发连接计数", format!("{:?}", local.status()));

    local.stop();
    tokio::time::sleep(Duration::from_millis(200)).await;
    let refused = TcpStream::connect(("127.0.0.1", local_port)).await.is_err();
    report.check(refused && local.status().stopped.is_some(), "停止转发后端口关闭", format!("{:?}", local.status().stopped));

    session.write(b"exit\n".to_vec());
    let stopped = wait_until(Duration::from_secs(5), || dynamic.status().stopped.is_some()).await;
    report.check(
        stopped && dynamic.status().stopped.as_deref() == Some("连接已断开"),
        "连接断开时转发自动停止",
        format!("{:?}", dynamic.status().stopped),
    );
    let _ = remote;

    // ───── 字符编码 + rz / sz（模拟服务器）─────
    println!("\n==> GBK 编码（模拟服务器）");
    let downloads = work.join("downloads");
    let probe = Probe::new(&password, downloads.clone());
    let session = open(("127.0.0.1", 2224), "pw", AuthMethod::Password, "GBK", probe.clone()).await;
    session.write(b"gbk\r".to_vec());
    let ok = wait_until(Duration::from_secs(5), || probe.text().contains("编码测试：中文GBK")).await;
    report.check(ok, "GBK 输出转成 UTF-8 显示", "");
    session.write("hex 中文\r".as_bytes().to_vec());
    let ok = wait_until(Duration::from_secs(5), || probe.text().contains("hex=d6d0cec4")).await;
    report.check(ok, "键盘输入转成 GBK 发送", "");

    println!("\n==> sz 下载（模拟服务器，GBK 会话里也能传二进制）");
    let size = 3_000_000;
    let t0 = Instant::now();
    session.write(format!("sz report.bin {size}\r").into_bytes());
    let finished = wait_until(Duration::from_secs(60), || probe.zmodem_finished().is_some()).await;
    let elapsed = t0.elapsed();
    let result = probe.zmodem_finished();
    let same = std::fs::read(downloads.join("report.bin")).map(|d| d == test_content(size)).unwrap_or(false);
    report.check(
        finished && result == Some((1, None)) && same,
        "sz：收到的文件和远端一致",
        format!("{result:?}，{}", mbps(size, elapsed)),
    );
    // 这个会话是 GBK 的，模拟服务器的提示是 UTF-8，只看其中的 ASCII 部分
    let back = wait_until(Duration::from_secs(5), || probe.text().contains("mock: ")).await;
    report.check(back, "传完后终端恢复正常显示", "");
    // 同名文件再下载一次：不覆盖，改名保存
    probe.zmodem.lock().unwrap().clear();
    session.write(b"sz report.bin 1000\r".to_vec());
    wait_until(Duration::from_secs(30), || probe.zmodem_finished().is_some()).await;
    report.check(downloads.join("report (1).bin").exists(), "同名文件不覆盖", "");

    println!("\n==> rz 上传");
    let upload = work.join("上传测试.bin");
    let upload_size = 2_500_000;
    std::fs::write(&upload, test_content(upload_size)).unwrap();
    *probe.upload_files.lock().unwrap() = vec![upload.display().to_string()];
    probe.zmodem.lock().unwrap().clear();
    let _ = std::fs::remove_file(rz_dir.join("上传测试.bin"));
    let t0 = Instant::now();
    session.write(b"rz\r".to_vec());
    let finished = wait_until(Duration::from_secs(60), || probe.zmodem_finished().is_some()).await;
    let elapsed = t0.elapsed();
    let result = probe.zmodem_finished();
    // 模拟服务器写完文件稍等一下
    let same = wait_until(Duration::from_secs(3), || {
        std::fs::read(rz_dir.join("上传测试.bin")).map(|d| d == test_content(upload_size)).unwrap_or(false)
    })
    .await;
    report.check(
        finished && result == Some((1, None)) && same,
        "rz：远端收到的文件一致",
        format!("{result:?}，{}", mbps(upload_size, elapsed)),
    );

    println!("\n==> 取消 sz");
    probe.zmodem.lock().unwrap().clear();
    session.write(b"sz huge.bin 200000000\r".to_vec());
    wait_until(Duration::from_secs(10), || {
        probe.zmodem.lock().unwrap().iter().any(|e| matches!(e, ZmodemEvent::Progress { .. }))
    })
    .await;
    session.cancel_zmodem();
    let finished = wait_until(Duration::from_secs(20), || probe.zmodem_finished().is_some()).await;
    report.check(
        finished && probe.zmodem_finished().is_some_and(|(_, e)| e.as_deref() == Some("你取消了传输")),
        "取消传输",
        format!("{:?}", probe.zmodem_finished()),
    );
    if !finished {
        let events = probe.zmodem.lock().unwrap().clone();
        let text = probe.text();
        let tail: String = text.chars().rev().take(300).collect::<Vec<_>>().into_iter().rev().collect();
        println!("  · 事件：{events:?}\n  · 终端末尾：{tail:?}");
    }
    // 取消后会话还能用
    let marker_before = probe.text().matches("hex=41").count();
    let usable = {
        let mut ok = false;
        for _ in 0..10 {
            session.write(b"hex A\r".to_vec());
            if wait_until(Duration::from_secs(2), || probe.text().matches("hex=41").count() > marker_before).await {
                ok = true;
                break;
            }
        }
        ok
    };
    report.check(usable, "取消后终端还能继续用", "");

    session.write(b"exit 3\r".to_vec());
    let closed = wait_until(Duration::from_secs(5), || probe.closed.lock().unwrap().is_some()).await;
    report.check(closed, "退出", format!("{:?}", probe.closed.lock().unwrap()));

    telnet_tests(&mut report).await;
    serial_tests(&mut report).await;

    // ───── 真实的 lrzsz（给了 --lrzsz 目录时才测）─────
    if let Some(bin) = value_of("--lrzsz") {
        lrzsz_tests(&mut report, &work, &keys, &user, &password, Path::new(&bin)).await;
    }

    let _ = std::fs::remove_dir_all(&work);
    if report.failures > 0 {
        println!("\n{} 项失败", report.failures);
        std::process::exit(1);
    }
    println!("\n全部通过");
}

/// 和真实的 lrzsz 互通：在 OpenSSH 测试服务器的 Shell 里执行 sz / rz
async fn lrzsz_tests(report: &mut Report, work: &Path, keys: &Path, user: &str, password: &str, bin: &Path) {
    println!("\n==> 真实 lrzsz（{}）", bin.display());
    let sz = bin.join("sz").display().to_string();
    let rz = bin.join("rz").display().to_string();
    let remote_dir = work.join("lrzsz-remote");
    let downloads = work.join("lrzsz-downloads");
    std::fs::create_dir_all(&remote_dir).unwrap();
    let probe = Probe::new(password, downloads.clone());
    let auth = AuthMethod::PrivateKey { path: keys.join("client_ed25519").display().to_string() };
    let session = open(("127.0.0.1", 2222), user, auth, "UTF-8", probe.clone()).await;
    tokio::time::sleep(Duration::from_millis(800)).await;

    // 1) sz 一个 5 MB 文件
    let size = 5_000_000;
    std::fs::write(remote_dir.join("真实sz.bin"), test_content(size)).unwrap();
    let t0 = Instant::now();
    session.write(format!("cd '{}' && {sz} 真实sz.bin\n", remote_dir.display()).into_bytes());
    let finished = wait_until(Duration::from_secs(60), || probe.zmodem_finished().is_some()).await;
    let elapsed = t0.elapsed();
    let same = std::fs::read(downloads.join("真实sz.bin")).map(|d| d == test_content(size)).unwrap_or(false);
    report.check(finished && probe.zmodem_finished() == Some((1, None)) && same,
        "lrzsz sz → Conch 下载", format!("{:?}，{}", probe.zmodem_finished(), mbps(size, elapsed)));

    // 2) sz 一次发两个文件
    probe.zmodem.lock().unwrap().clear();
    std::fs::write(remote_dir.join("a.txt"), b"first file\n").unwrap();
    std::fs::write(remote_dir.join("b.txt"), test_content(70_000)).unwrap();
    session.write(format!("{sz} a.txt b.txt\n").into_bytes());
    wait_until(Duration::from_secs(30), || probe.zmodem_finished().is_some()).await;
    let both = std::fs::read(downloads.join("a.txt")).map(|d| d == b"first file\n").unwrap_or(false)
        && std::fs::read(downloads.join("b.txt")).map(|d| d == test_content(70_000)).unwrap_or(false);
    report.check(both && probe.zmodem_finished() == Some((2, None)), "lrzsz sz 多个文件", format!("{:?}", probe.zmodem_finished()));

    // 3) rz：Conch 上传
    probe.zmodem.lock().unwrap().clear();
    let upload = work.join("真实rz.bin");
    let upload_size = 4_000_000;
    std::fs::write(&upload, test_content(upload_size)).unwrap();
    *probe.upload_files.lock().unwrap() = vec![upload.display().to_string()];
    let t0 = Instant::now();
    session.write(format!("{rz}\n").into_bytes());
    let finished = wait_until(Duration::from_secs(60), || probe.zmodem_finished().is_some()).await;
    let elapsed = t0.elapsed();
    let same = wait_until(Duration::from_secs(3), || {
        std::fs::read(remote_dir.join("真实rz.bin")).map(|d| d == test_content(upload_size)).unwrap_or(false)
    })
    .await;
    report.check(finished && probe.zmodem_finished() == Some((1, None)) && same,
        "Conch 上传 → lrzsz rz", format!("{:?}，{}", probe.zmodem_finished(), mbps(upload_size, elapsed)));

    // 4) 取消一个大文件的 sz，之后终端还能用
    probe.zmodem.lock().unwrap().clear();
    let big = remote_dir.join("big.bin");
    std::fs::write(&big, test_content(150_000_000)).unwrap();
    session.write(format!("{sz} big.bin\n").into_bytes());
    wait_until(Duration::from_secs(10), || {
        probe.zmodem.lock().unwrap().iter().any(|e| matches!(e, ZmodemEvent::Progress { .. }))
    })
    .await;
    session.cancel_zmodem();
    let cancelled = wait_until(Duration::from_secs(20), || probe.zmodem_finished().is_some()).await;
    report.check(cancelled && probe.zmodem_finished().is_some_and(|(_, e)| e.as_deref() == Some("你取消了传输")),
        "取消 lrzsz sz", format!("{:?}", probe.zmodem_finished()));
    let before = probe.text().matches("lrzsz-still-ok").count();
    let mut usable = false;
    for _ in 0..5 {
        session.write(b"\necho lrzsz-still-$((1+1))ok\n".to_vec());
        if wait_until(Duration::from_secs(2), || probe.text().contains("lrzsz-still-2ok")).await {
            usable = true;
            break;
        }
    }
    let _ = before;
    report.check(usable, "取消后终端还能用", "");
    session.write(b"exit\n".to_vec());
    wait_until(Duration::from_secs(5), || probe.closed.lock().unwrap().is_some()).await;
}

/// 同时跑 3 条命令，都要拿到正确结果
async fn futures_lite_join(session: &Arc<SshSession>) -> bool {
    let a = session.exec("echo a".into(), 10);
    let b = session.exec("echo b".into(), 10);
    let c = session.exec("echo c".into(), 10);
    let (a, b, c) = tokio::join!(a, b, c);
    matches!((a, b, c), (Ok(a), Ok(b), Ok(c)) if a.stdout == b"a\n" && b.stdout == b"b\n" && c.stdout == b"c\n")
}

// ───────────────────────────── Telnet ─────────────────────────────

fn contains(haystack: &[u8], needle: &[u8]) -> bool {
    haystack.windows(needle.len()).any(|w| w == needle)
}

async fn telnet_tests(report: &mut Report) {
    println!("\n==> Telnet（测试里自带一个小 Telnet 服务器）");
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    // 服务器：先协商，再要终端类型，再给登录提示，最后回显收到的东西
    let server = tokio::spawn(async move {
        let (mut stream, _) = listener.accept().await.unwrap();
        stream.write_all(&[255, 253, 24, 255, 253, 31, 255, 251, 1, 255, 251, 3]).await.unwrap();
        let mut seen: Vec<u8> = Vec::new();
        let mut buffer = [0u8; 1024];
        let read_until = |seen: &Vec<u8>, needle: &[u8]| contains(seen, needle);
        let deadline = Instant::now() + Duration::from_secs(5);
        while !read_until(&seen, &[255, 250, 31, 0, 100, 0, 30, 255, 240]) && Instant::now() < deadline {
            let n = tokio::time::timeout(Duration::from_secs(1), stream.read(&mut buffer)).await.ok().and_then(|r| r.ok()).unwrap_or(0);
            seen.extend_from_slice(&buffer[..n]);
        }
        stream.write_all(&[255, 250, 24, 1, 255, 240]).await.unwrap();
        stream.write_all("欢迎使用测试交换机\r\nlogin: ".as_bytes()).await.unwrap();
        stream.write_all(&[b'[', 255, 255, b']']).await.unwrap();
        let deadline = Instant::now() + Duration::from_secs(5);
        while !contains(&seen, b"admin\r\0") && Instant::now() < deadline {
            let n = tokio::time::timeout(Duration::from_secs(1), stream.read(&mut buffer)).await.ok().and_then(|r| r.ok()).unwrap_or(0);
            seen.extend_from_slice(&buffer[..n]);
        }
        let deadline = Instant::now() + Duration::from_secs(5);
        while !contains(&seen, &[255, 250, 31, 0, 120, 0, 40, 255, 240]) && Instant::now() < deadline {
            let n = tokio::time::timeout(Duration::from_secs(1), stream.read(&mut buffer)).await.ok().and_then(|r| r.ok()).unwrap_or(0);
            seen.extend_from_slice(&buffer[..n]);
        }
        stream.write_all(b"\r\nbye\r\n").await.unwrap();
        drop(stream);
        seen
    });

    let probe = Probe::new("", std::env::temp_dir());
    let session: Arc<StreamSession> = connect_telnet(
        TelnetConfig { host: "127.0.0.1".into(), port, cols: 100, rows: 30, term: "xterm-256color".into(), encoding: "UTF-8".into() },
        probe.clone(),
    )
    .await
    .expect("Telnet 连接失败");
    let shown = wait_until(Duration::from_secs(5), || probe.text().contains("login: [")).await;
    // 协商命令（IAC 开头）不能出现在终端里：除了故意发的那个 0xFF，输出里不该有别的 0xFF
    let raw = probe.output.lock().unwrap().clone();
    report.check(shown && probe.text().contains("欢迎使用测试交换机") && raw.iter().filter(|&&b| b == 0xFF).count() == 1,
        "协商命令被剥掉，提示正常显示", "");
    report.check(probe.output.lock().unwrap().windows(3).any(|w| w == [b'[', 0xFF, b']']), "数据里的 0xFF 还原", "");
    session.write(b"admin\r".to_vec());
    session.resize(120, 40);
    let closed = wait_until(Duration::from_secs(5), || probe.closed.lock().unwrap().is_some()).await;
    let seen = server.await.unwrap();
    report.check(contains(&seen, &[255, 251, 24]) && contains(&seen, &[255, 251, 31]), "答应发终端类型和窗口大小", "");
    report.check(contains(&seen, &[255, 250, 31, 0, 100, 0, 30, 255, 240]), "发出了初始窗口大小 100×30", "");
    report.check(contains(&seen, &[255, 253, 1]) && contains(&seen, &[255, 253, 3]), "接受服务器回显", "");
    let mut ttype = vec![255, 250, 24, 0];
    ttype.extend_from_slice(b"XTERM-256COLOR");
    ttype.extend([255, 240]);
    report.check(contains(&seen, &ttype), "终端类型 XTERM-256COLOR", "");
    report.check(contains(&seen, b"admin\r\0"), "回车按协议发成 CR NUL", "");
    report.check(contains(&seen, &[255, 250, 31, 0, 120, 0, 40, 255, 240]), "改尺寸发了 NAWS", "");
    let info = probe.closed.lock().unwrap().clone();
    report.check(closed && info.as_ref().is_some_and(|i| !i.lost && i.reason.as_deref() == Some("服务器关闭了连接")),
        "服务器断开时正常结束（不算意外断线）", format!("{info:?}"));

    // 连不上的端口
    let refused = connect_telnet(
        TelnetConfig { host: "127.0.0.1".into(), port: 1, cols: 80, rows: 24, term: "xterm".into(), encoding: "UTF-8".into() },
        Probe::new("", std::env::temp_dir()),
    )
    .await;
    report.check(matches!(&refused, Err(e) if e.to_string().contains("连接被拒绝")), "连不上时中文提示", format!("{:?}", refused.err().map(|e| e.to_string())));
}

// ───────────────────────────── 串口（用伪终端代替真实设备）─────────────────────────────

async fn serial_tests(report: &mut Report) {
    println!("\n==> 串口（用伪终端模拟一根串口线）");
    let (mut master, mut slave) = (0, 0);
    let ok = unsafe { libc::openpty(&mut master, &mut slave, std::ptr::null_mut(), std::ptr::null_mut(), std::ptr::null_mut()) } == 0;
    if !ok {
        report.check(false, "创建伪终端", "");
        return;
    }
    let path = unsafe { std::ffi::CStr::from_ptr(libc::ttyname(slave)) }.to_string_lossy().into_owned();
    unsafe { libc::close(slave) };
    let probe = Probe::new("", std::env::temp_dir());
    let opened = open_serial(
        SerialConfig { path: path.clone(), baud_rate: 115200, data_bits: 8, parity: "none".into(), stop_bits: 1, flow_control: "none".into(), encoding: "UTF-8".into() },
        probe.clone(),
    )
    .await;
    let Ok(session) = opened else {
        report.check(false, "打开串口", format!("{:?}", opened.err().map(|e| e.to_string())));
        return;
    };
    report.check(true, "打开串口", &path);

    // 设备 → 终端
    let line = "Router> 设备启动完成\r\n";
    unsafe { libc::write(master, line.as_ptr().cast(), line.len()) };
    let shown = wait_until(Duration::from_secs(3), || probe.text().contains("Router> 设备启动完成")).await;
    report.check(shown, "设备输出显示在终端", "");

    // 终端 → 设备
    session.write(b"show version\r".to_vec());
    let mut received = Vec::new();
    let deadline = Instant::now() + Duration::from_secs(3);
    while !contains(&received, b"show version\r") && Instant::now() < deadline {
        let mut buffer = [0u8; 256];
        let mut fds = libc::pollfd { fd: master, events: libc::POLLIN, revents: 0 };
        if unsafe { libc::poll(&mut fds, 1, 200) } > 0 {
            let n = unsafe { libc::read(master, buffer.as_mut_ptr().cast(), buffer.len()) };
            if n > 0 { received.extend_from_slice(&buffer[..n as usize]); }
        }
    }
    report.check(contains(&received, b"show version\r"), "键盘输入发到设备", format!("{:?}", String::from_utf8_lossy(&received)));

    // 拔线：关掉伪终端的另一头
    unsafe { libc::close(master) };
    let closed = wait_until(Duration::from_secs(3), || probe.closed.lock().unwrap().is_some()).await;
    let info = probe.closed.lock().unwrap().clone();
    report.check(closed && info.as_ref().is_some_and(|i| i.lost), "拔线算意外断开（可以自动重连）", format!("{info:?}"));

    let missing = open_serial(
        SerialConfig { path: "/dev/cu.不存在".into(), baud_rate: 9600, data_bits: 8, parity: "none".into(), stop_bits: 1, flow_control: "none".into(), encoding: "UTF-8".into() },
        Probe::new("", std::env::temp_dir()),
    )
    .await;
    report.check(matches!(&missing, Err(e) if e.to_string().contains("找不到")), "设备不存在时中文提示", format!("{:?}", missing.err().map(|e| e.to_string())));
    let _ = session;
}
