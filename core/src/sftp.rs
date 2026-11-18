//! SFTP：在同一条 SSH 连接上（经过跳板机也一样）开一个 sftp 子系统通道，
//! 浏览远端文件，上传下载单个文件或整个文件夹，支持断点续传。

use std::future::Future;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant, SystemTime};

use russh_sftp::client::SftpSession;
use russh_sftp::client::error::Error as SftpError;
use russh_sftp::protocol::{FileAttributes, StatusCode};

use crate::{CoreError, RUNTIME, SshSession, session_err};

#[path = "sftp_transfer.rs"]
mod safe;

/// 远端的一个文件或目录
#[derive(Debug, Clone, uniffi::Record)]
pub struct RemoteFile {
    pub name: String,
    pub path: String,
    /// 目录，或者指向目录的符号链接
    pub is_dir: bool,
    pub is_symlink: bool,
    pub size: u64,
    /// 修改时间（Unix 秒）
    pub modified: Option<i64>,
    /// 权限位，如 0o755（不含文件类型位）
    pub permissions: u32,
    pub owner: String,
    pub group: String,
}

/// 目标已经存在时怎么办
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum ConflictPolicy {
    Overwrite,
    /// 续传前逐块校验已有内容；不一致时重新传输，成功后才替换目标
    Resume,
    Skip,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct TransferProgress {
    pub bytes_done: u64,
    pub bytes_total: u64,
    pub files_done: u32,
    pub files_total: u32,
    /// 正在传的文件名
    pub current: String,
}

/// 传输进度回调（在内核线程上调用）
#[uniffi::export(with_foreign)]
pub trait TransferObserver: Send + Sync {
    fn on_progress(&self, progress: TransferProgress);
    /// 传输结束。error 为 None 表示成功
    fn on_finished(&self, error: Option<String>);
}

/// 一次传输，可以取消
#[derive(Default, uniffi::Object)]
pub struct Transfer {
    cancelled: AtomicBool,
}

#[uniffi::export]
impl Transfer {
    pub fn cancel(&self) {
        self.cancelled.store(true, Ordering::Release);
    }
}

#[derive(uniffi::Object)]
pub struct SftpClient {
    peer: String,
    sftp: Arc<SftpSession>,
}

#[uniffi::export]
impl SshSession {
    /// 在这条连接上打开 SFTP（服务器要开启 sftp 子系统，OpenSSH 默认是开的）
    pub async fn open_sftp(&self) -> Result<Arc<SftpClient>, CoreError> {
        let handle = self
            .hops
            .last()
            .cloned()
            .ok_or_else(|| CoreError::Session("连接已关闭".into()))?;
        let peer = self.transfer_peer.clone();
        run(async move {
            let channel = handle.channel_open_session().await.map_err(session_err)?;
            channel
                .request_subsystem(true, "sftp")
                .await
                .map_err(session_err)?;
            let sftp = SftpSession::new(channel.into_stream())
                .await
                .map_err(|e| CoreError::Session(format!("服务器没有开启 SFTP：{}", describe(e))))?;
            sftp.set_timeout(30);
            Ok(Arc::new(SftpClient {
                peer,
                sftp: Arc::new(sftp),
            }))
        })
        .await
    }
}

#[uniffi::export]
impl SftpClient {
    /// 登录后的默认目录（一般是家目录）
    pub async fn home(&self) -> Result<String, CoreError> {
        let sftp = self.sftp.clone();
        run(async move { sftp.canonicalize(".").await.map_err(sftp_error) }).await
    }

    /// 把路径规范化（处理 ..、符号链接），用于地址栏输入
    pub async fn resolve(&self, path: String) -> Result<String, CoreError> {
        let sftp = self.sftp.clone();
        run(async move { sftp.canonicalize(path).await.map_err(sftp_error) }).await
    }

    pub async fn list(&self, path: String) -> Result<Vec<RemoteFile>, CoreError> {
        let sftp = self.sftp.clone();
        run(async move {
            let mut files = Vec::new();
            for entry in sftp.read_dir(path.clone()).await.map_err(sftp_error)? {
                let name = entry.file_name();
                if name == "." || name == ".." {
                    continue;
                }
                let full = join(&path, &name);
                let mut file = remote_file(name, full.clone(), &entry.metadata());
                // 符号链接看它指向的是不是目录，这样双击能进去
                if file.is_symlink
                    && let Ok(target) = sftp.metadata(full).await
                {
                    file.is_dir = target.is_dir();
                }
                files.push(file);
            }
            Ok(files)
        })
        .await
    }

    pub async fn stat(&self, path: String) -> Result<RemoteFile, CoreError> {
        let sftp = self.sftp.clone();
        run(async move {
            let meta = sftp.metadata(path.clone()).await.map_err(sftp_error)?;
            Ok(remote_file(base_name(&path), path, &meta))
        })
        .await
    }

    pub async fn mkdir(&self, path: String) -> Result<(), CoreError> {
        let sftp = self.sftp.clone();
        run(async move { sftp.create_dir(path).await.map_err(sftp_error) }).await
    }

    /// 删除文件；目录连同里面的内容一起删
    pub async fn remove(&self, path: String) -> Result<(), CoreError> {
        let sftp = self.sftp.clone();
        run(async move { remove_tree(&sftp, &path).await }).await
    }

    pub async fn rename(&self, from: String, to: String) -> Result<(), CoreError> {
        let sftp = self.sftp.clone();
        run(async move { sftp.rename(from, to).await.map_err(sftp_error) }).await
    }

    /// 修改权限，mode 如 0o644
    pub async fn chmod(&self, path: String, mode: u32) -> Result<(), CoreError> {
        let sftp = self.sftp.clone();
        run(async move {
            let attributes = FileAttributes {
                permissions: Some(mode & 0o7777),
                ..Default::default()
            };
            sftp.set_metadata(path, attributes).await.map_err(sftp_error)
        })
        .await
    }

    /// 下载文件或整个目录到本地目录 local_dir 下
    pub fn download(
        &self,
        remote_path: String,
        local_dir: String,
        policy: ConflictPolicy,
        observer: Arc<dyn TransferObserver>,
    ) -> Arc<Transfer> {
        let transfer = Arc::new(Transfer::default());
        let sftp = self.sftp.clone();
        let handle = transfer.clone();
        let peer = self.peer.clone();
        RUNTIME.spawn(async move {
            let result = download(&sftp, &peer, &remote_path, Path::new(&local_dir), policy, &handle, &*observer).await;
            observer.on_finished(result.err());
        });
        transfer
    }

    /// 上传本地文件或整个目录到远端目录 remote_dir 下
    pub fn upload(
        &self,
        local_path: String,
        remote_dir: String,
        policy: ConflictPolicy,
        observer: Arc<dyn TransferObserver>,
    ) -> Arc<Transfer> {
        let transfer = Arc::new(Transfer::default());
        let sftp = self.sftp.clone();
        let handle = transfer.clone();
        let peer = self.peer.clone();
        RUNTIME.spawn(async move {
            let result = upload(&sftp, &peer, Path::new(&local_path), &remote_dir, policy, &handle, &*observer).await;
            observer.on_finished(result.err());
        });
        transfer
    }
}

/// 在内核运行时上执行，Swift 侧用什么执行器 await 都行
async fn run<T: Send + 'static>(
    work: impl Future<Output = Result<T, CoreError>> + Send + 'static,
) -> Result<T, CoreError> {
    RUNTIME
        .spawn(work)
        .await
        .map_err(|e| CoreError::Session(e.to_string()))?
}

// ───────────────────────────── 传输 ─────────────────────────────

/// 一个要传的文件
struct Job {
    remote: String,
    local: PathBuf,
    size: u64,
    modified: Option<u32>,
    permissions: Option<u32>,
}

/// 进度记账，节流后通知界面
struct Progress<'a> {
    observer: &'a dyn TransferObserver,
    transfer: &'a Transfer,
    bytes_done: u64,
    bytes_total: u64,
    files_done: u32,
    files_total: u32,
    current: String,
    last_report: Instant,
}

impl Progress<'_> {
    fn add(&mut self, bytes: u64) {
        self.bytes_done += bytes;
        if self.last_report.elapsed() >= Duration::from_millis(150) {
            self.report();
        }
    }

    fn report(&mut self) {
        self.last_report = Instant::now();
        self.observer.on_progress(TransferProgress {
            bytes_done: self.bytes_done,
            bytes_total: self.bytes_total,
            files_done: self.files_done,
            files_total: self.files_total,
            current: self.current.clone(),
        });
    }

    fn check_cancelled(&self) -> Result<(), String> {
        if self.transfer.cancelled.load(Ordering::Acquire) {
            Err("已取消".into())
        } else {
            Ok(())
        }
    }
}

async fn download(
    sftp: &SftpSession,
    peer: &str,
    remote_path: &str,
    local_dir: &Path,
    policy: ConflictPolicy,
    transfer: &Transfer,
    observer: &dyn TransferObserver,
) -> Result<(), String> {
    // 先把要下载的文件列出来，进度才知道总量
    let mut dirs = Vec::new();
    let mut jobs = Vec::new();
    plan_download(sftp, remote_path, local_dir, &mut dirs, &mut jobs, transfer).await?;
    for dir in &dirs {
        tokio::fs::create_dir_all(dir)
            .await
            .map_err(|e| format!("无法创建 {}：{e}", dir.display()))?;
    }
    let mut progress = Progress {
        observer,
        transfer,
        bytes_done: 0,
        bytes_total: jobs.iter().map(|j| j.size).sum(),
        files_done: 0,
        files_total: jobs.len() as u32,
        current: String::new(),
        last_report: Instant::now(),
    };
    for job in &jobs {
        progress.current = base_name(&job.remote);
        progress.report();
        safe::download_file(sftp, peer, job, policy, &mut progress)
            .await
            .map_err(|e| format!("{}：{e}", progress.current))?;
        progress.files_done += 1;
    }
    progress.report();
    Ok(())
}

async fn plan_download(
    sftp: &SftpSession,
    remote_path: &str,
    local_dir: &Path,
    dirs: &mut Vec<PathBuf>,
    jobs: &mut Vec<Job>,
    transfer: &Transfer,
) -> Result<(), String> {
    if transfer.cancelled.load(Ordering::Acquire) {
        return Err("已取消".into());
    }
    let meta = sftp
        .symlink_metadata(remote_path.to_string())
        .await
        .map_err(|e| format!("{remote_path}：{}", describe(e)))?;
    if meta.is_symlink() { return Err("不自动下载符号链接，请进入实际目录后选择文件".into()); }
    let name = base_name(remote_path);
    if name.is_empty() || name == "." || name == ".." || name.contains('/') || name.contains('\0') {
        return Err("服务器返回了不安全的文件名".into());
    }
    let local = local_dir.join(name);
    if meta.is_dir() {
        dirs.push(local.clone());
        let entries = sftp
            .read_dir(remote_path.to_string())
            .await
            .map_err(|e| format!("{remote_path}：{}", describe(e)))?;
        for entry in entries {
            let name = entry.file_name();
            if name == "." || name == ".." {
                continue;
            }
            if name.contains('/') || name.contains('\0') { return Err("服务器返回了不安全的文件名".into()); }
            Box::pin(plan_download(sftp, &join(remote_path, &name), &local, dirs, jobs, transfer)).await?;
        }
    } else {
        jobs.push(Job {
            remote: remote_path.to_string(),
            local,
            size: meta.size.unwrap_or(0),
            modified: meta.mtime,
            permissions: meta.permissions,
        });
    }
    Ok(())
}

async fn upload(
    sftp: &SftpSession,
    peer: &str,
    local_path: &Path,
    remote_dir: &str,
    policy: ConflictPolicy,
    transfer: &Transfer,
    observer: &dyn TransferObserver,
) -> Result<(), String> {
    let mut dirs = Vec::new();
    let mut jobs = Vec::new();
    plan_upload(local_path, remote_dir, &mut dirs, &mut jobs)?;
    for dir in &dirs {
        // 已经存在的目录不算错
        if sftp.metadata(dir.clone()).await.is_err() {
            sftp.create_dir(dir.clone())
                .await
                .map_err(|e| format!("无法创建目录 {dir}：{}", describe(e)))?;
        }
    }
    let mut progress = Progress {
        observer,
        transfer,
        bytes_done: 0,
        bytes_total: jobs.iter().map(|j| j.size).sum(),
        files_done: 0,
        files_total: jobs.len() as u32,
        current: String::new(),
        last_report: Instant::now(),
    };
    for job in &jobs {
        progress.current = job
            .local
            .file_name()
            .map(|n| n.to_string_lossy().into_owned())
            .unwrap_or_default();
        progress.report();
        safe::upload_file(sftp, peer, job, policy, &mut progress)
            .await
            .map_err(|e| format!("{}：{e}", progress.current))?;
        progress.files_done += 1;
    }
    progress.report();
    Ok(())
}

fn plan_upload(local_path: &Path, remote_dir: &str, dirs: &mut Vec<String>, jobs: &mut Vec<Job>) -> Result<(), String> {
    let meta = std::fs::symlink_metadata(local_path).map_err(|e| format!("{}：{e}", local_path.display()))?;
    if meta.is_symlink() { return Err("不自动上传符号链接，请选择实际文件或目录".into()); }
    if !meta.is_dir() && !meta.is_file() { return Err("只支持普通文件和目录".into()); }
    let name = local_path
        .file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_else(|| "upload".into());
    let remote = join(remote_dir, &name);
    if meta.is_dir() {
        dirs.push(remote.clone());
        let mut entries: Vec<_> = std::fs::read_dir(local_path)
            .map_err(|e| format!("{}：{e}", local_path.display()))?
            .filter_map(Result::ok)
            .collect();
        entries.sort_by_key(|e| e.file_name());
        for entry in entries {
            // 访达的 .DS_Store 不用传
            if entry.file_name() == ".DS_Store" {
                continue;
            }
            plan_upload(&entry.path(), &remote, dirs, jobs)?;
        }
    } else {
        use std::os::unix::fs::PermissionsExt;
        jobs.push(Job {
            remote,
            local: local_path.to_path_buf(),
            size: meta.len(),
            modified: meta
                .modified()
                .ok()
                .and_then(|t| t.duration_since(SystemTime::UNIX_EPOCH).ok())
                .and_then(|d| u32::try_from(d.as_secs()).ok()),
            permissions: Some(meta.permissions().mode() & 0o777),
        });
    }
    Ok(())
}

async fn remove_tree(sftp: &SftpSession, path: &str) -> Result<(), CoreError> {
    let meta = sftp.symlink_metadata(path.to_string()).await.map_err(sftp_error)?;
    if meta.is_dir() && !meta.is_symlink() {
        for entry in sftp.read_dir(path.to_string()).await.map_err(sftp_error)? {
            let name = entry.file_name();
            if name == "." || name == ".." {
                continue;
            }
            Box::pin(remove_tree(sftp, &join(path, &name))).await?;
        }
        sftp.remove_dir(path.to_string()).await.map_err(sftp_error)
    } else {
        sftp.remove_file(path.to_string()).await.map_err(sftp_error)
    }
}

// ───────────────────────────── 小工具 ─────────────────────────────

fn remote_file(name: String, path: String, meta: &FileAttributes) -> RemoteFile {
    RemoteFile {
        name,
        path,
        is_dir: meta.is_dir(),
        is_symlink: meta.is_symlink(),
        size: meta.size.unwrap_or(0),
        modified: meta.mtime.map(i64::from),
        permissions: meta.permissions.unwrap_or(0) & 0o7777,
        owner: meta
            .user
            .clone()
            .unwrap_or_else(|| meta.uid.map(|u| u.to_string()).unwrap_or_default()),
        group: meta
            .group
            .clone()
            .unwrap_or_else(|| meta.gid.map(|g| g.to_string()).unwrap_or_default()),
    }
}

/// 远端路径一律用 /
pub(crate) fn join(dir: &str, name: &str) -> String {
    if dir.is_empty() || dir == "." {
        name.to_string()
    } else if dir.ends_with('/') {
        format!("{dir}{name}")
    } else {
        format!("{dir}/{name}")
    }
}

pub(crate) fn base_name(path: &str) -> String {
    let trimmed = path.trim_end_matches('/');
    match trimmed.rsplit_once('/') {
        Some((_, name)) if !name.is_empty() => name.to_string(),
        _ if trimmed.is_empty() => "/".to_string(),
        _ => trimmed.to_string(),
    }
}

fn describe(e: SftpError) -> String {
    match e {
        SftpError::Status(status) => {
            let detail = status.error_message.trim().to_string();
            let what = match status.status_code {
                StatusCode::NoSuchFile => "文件或目录不存在",
                StatusCode::PermissionDenied => "没有权限",
                StatusCode::OpUnsupported => "服务器不支持这个操作",
                StatusCode::NoConnection | StatusCode::ConnectionLost => "连接已断开",
                StatusCode::Eof => "已经到文件末尾",
                _ => "操作失败",
            };
            if detail.is_empty() || matches!(status.status_code, StatusCode::NoSuchFile | StatusCode::PermissionDenied) {
                what.to_string()
            } else {
                format!("{what}（{detail}）")
            }
        }
        SftpError::Timeout => "服务器响应超时".into(),
        other => other.to_string(),
    }
}

fn sftp_error(e: SftpError) -> CoreError {
    CoreError::Session(describe(e))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn remote_paths() {
        assert_eq!(join("/home/a", "b.txt"), "/home/a/b.txt");
        assert_eq!(join("/", "etc"), "/etc");
        assert_eq!(base_name("/home/a/b.txt"), "b.txt");
        assert_eq!(base_name("/home/a/dir/"), "dir");
        assert_eq!(base_name("/"), "/");
        assert_eq!(base_name("file"), "file");
    }

}
