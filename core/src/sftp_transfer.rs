//! 文件级安全传输。失败时保留目标；同一次 App 运行中的重试复用已校验的隐藏临时文件。
use super::{ConflictPolicy, Job, Progress, describe};
use russh_sftp::{client::SftpSession, client::error::Error, protocol::{FileAttributes, OpenFlags, StatusCode}};
use std::{collections::{HashMap, HashSet}, io::SeekFrom, path::{Path, PathBuf},
    sync::{LazyLock, Mutex, atomic::{AtomicU64, Ordering}}, time::{Duration, SystemTime}};
use tokio::io::{AsyncRead, AsyncReadExt, AsyncSeekExt, AsyncWrite, AsyncWriteExt};

const CHUNK: usize = 256 * 1024;
static NEXT: AtomicU64 = AtomicU64::new(0);
#[derive(Default)]
struct Registry { active: HashSet<String>, partials: HashMap<String, String> }
static REGISTRY: LazyLock<Mutex<Registry>> = LazyLock::new(|| Mutex::new(Registry::default()));
struct Guard(String);
impl Guard {
    fn acquire(key: String) -> Result<Self, String> {
        if !REGISTRY.lock().unwrap().active.insert(key.clone()) {
            return Err("这个目标已有传输正在进行，请等待完成".into());
        }
        Ok(Self(key))
    }
}
impl Drop for Guard {
    fn drop(&mut self) { REGISTRY.lock().unwrap().active.remove(&self.0); }
}
fn partial(key: &str) -> Option<String> { REGISTRY.lock().unwrap().partials.get(key).cloned() }
fn remember(key: &str, path: &str) { REGISTRY.lock().unwrap().partials.insert(key.into(), path.into()); }
fn forget(key: &str) { REGISTRY.lock().unwrap().partials.remove(key); }
fn unique_name() -> String {
    let stamp = SystemTime::now().duration_since(SystemTime::UNIX_EPOCH).unwrap().as_nanos();
    format!(".conch-{stamp:x}-{}-{}.part", std::process::id(), NEXT.fetch_add(1, Ordering::Relaxed))
}
fn missing(error: &Error) -> bool {
    matches!(error, Error::Status(status) if status.status_code == StatusCode::NoSuchFile)
}
async fn remote_meta(sftp: &SftpSession, path: &str) -> Result<Option<FileAttributes>, String> {
    match sftp.symlink_metadata(path.to_string()).await {
        Ok(meta) if meta.is_dir() || meta.is_symlink() => Err("目标是目录或符号链接，请选择普通文件".into()),
        Ok(meta) => Ok(Some(meta)),
        Err(e) if missing(&e) => Ok(None),
        Err(e) => Err(describe(e)),
    }
}
async fn local_meta(path: &Path) -> Result<Option<std::fs::Metadata>, String> {
    match tokio::fs::symlink_metadata(path).await {
        Ok(meta) if !meta.is_file() => Err("目标是目录或符号链接，请选择普通文件".into()),
        Ok(meta) => Ok(Some(meta)),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(e) => Err(e.to_string()),
    }
}

/// 验证并复制整个前缀。网络数据必须 read_exact，不能假设两次 read 返回同样长度。
async fn prefix<S: AsyncRead + Unpin, C: AsyncRead + Unpin, W: AsyncWrite + Unpin>(
    source: &mut S, candidate: &mut C, stage: &mut W, len: u64, progress: &Progress<'_>,
) -> Result<bool, String> {
    let mut remaining = len;
    let mut a = vec![0; CHUNK]; let mut b = vec![0; CHUNK];
    while remaining > 0 {
        progress.check_cancelled()?;
        let n = remaining.min(CHUNK as u64) as usize;
        source.read_exact(&mut a[..n]).await.map_err(|e| e.to_string())?;
        if candidate.read_exact(&mut b[..n]).await.is_err() || a[..n] != b[..n] { return Ok(false); }
        stage.write_all(&a[..n]).await.map_err(|e| e.to_string())?;
        remaining -= n as u64;
    }
    Ok(true)
}
async fn copy<S: AsyncRead + Unpin, W: AsyncWrite + Unpin>(
    source: &mut S, stage: &mut W, offset: u64, expected: u64, progress: &mut Progress<'_>,
) -> Result<(), String> {
    let mut count = offset;
    progress.add(offset);
    let mut buffer = vec![0; CHUNK];
    loop {
        progress.check_cancelled()?;
        let n = source.read(&mut buffer).await.map_err(|e| e.to_string())?;
        if n == 0 { break; }
        count += n as u64;
        if count > expected { return Err("源文件在传输期间变大，请重新传输".into()); }
        stage.write_all(&buffer[..n]).await.map_err(|e| e.to_string())?;
        progress.add(n as u64);
    }
    if count != expected { return Err("源文件在传输期间变小，请重新传输".into()); }
    Ok(())
}

pub(super) async fn download_file(
    sftp: &SftpSession, peer: &str, job: &Job, policy: ConflictPolicy, progress: &mut Progress<'_>,
) -> Result<(), String> {
    use std::os::unix::fs::PermissionsExt;
    let _guard = Guard::acquire(format!("local:{}", job.local.display()))?;
    progress.check_cancelled()?;
    let existing = local_meta(&job.local).await?;
    if policy == ConflictPolicy::Skip && existing.is_some() { progress.add(job.size); return Ok(()); }
    // 先打开源；没有读取权限时，连临时文件也不创建。
    let mut source = sftp.open(job.remote.clone()).await.map_err(describe)?;
    let initial = source.metadata().await.map_err(describe)?;
    if initial.size != Some(job.size) { return Err("源文件已经变化，请刷新后重试".into()); }
    let key = format!("download:{peer}:{}:{}", job.remote, job.local.display());
    let parent = job.local.parent().ok_or("无效的下载路径")?;
    let candidate_path = if policy == ConflictPolicy::Resume {
        partial(&key).map(PathBuf::from).filter(|p| p.parent() == Some(parent))
            .filter(|p| p.is_file()).or_else(|| existing.as_ref().map(|_| job.local.clone()))
    } else { None };
    // 已知的本次运行临时文件可复用；用户原目标始终只读。
    let reuse = candidate_path.as_ref().is_some_and(|p| p != &job.local);
    let stage_path = if reuse { candidate_path.clone().unwrap() } else { parent.join(unique_name()) };
    let mut stage = tokio::fs::OpenOptions::new().read(true).write(true).create_new(!reuse).mode(0o600)
        .custom_flags(libc::O_NOFOLLOW).open(&stage_path).await.map_err(|e| e.to_string())?;
    remember(&key, &stage_path.to_string_lossy());
    let result = async {
        let mut offset = 0;
        if let Some(candidate_path) = &candidate_path {
            if let Some(meta) = local_meta(candidate_path).await? && meta.len() <= job.size {
                let mut candidate = tokio::fs::OpenOptions::new().read(true).custom_flags(libc::O_NOFOLLOW)
                    .open(candidate_path).await.map_err(|e| e.to_string())?;
                let matches = if reuse {
                    prefix(&mut source, &mut candidate, &mut tokio::io::sink(), meta.len(), progress).await?
                } else { prefix(&mut source, &mut candidate, &mut stage, meta.len(), progress).await? };
                if matches { offset = meta.len(); stage.seek(SeekFrom::Start(offset)).await.map_err(|e| e.to_string())?; }
            }
        }
        if offset == 0 {
            source.seek(SeekFrom::Start(0)).await.map_err(|e| e.to_string())?;
            stage.set_len(0).await.map_err(|e| e.to_string())?;
            stage.seek(SeekFrom::Start(0)).await.map_err(|e| e.to_string())?;
        }
        copy(&mut source, &mut stage, offset, job.size, progress).await?;
        let final_meta = source.metadata().await.map_err(describe)?;
        if final_meta.size != initial.size || final_meta.mtime != initial.mtime {
            return Err("源文件在传输期间被修改，请重新传输".into());
        }
        stage.flush().await.map_err(|e| e.to_string())?;
        stage.sync_all().await.map_err(|e| e.to_string())?;
        let mode = existing.as_ref().map(|m| m.permissions().mode() & 0o777)
            .unwrap_or(job.permissions.unwrap_or(0o600) & 0o777);
        stage.set_permissions(std::fs::Permissions::from_mode(mode)).await.map_err(|e| e.to_string())?;
        if let Some(seconds) = job.modified {
            stage.try_clone().await.map_err(|e| e.to_string())?.into_std().await.set_modified(SystemTime::UNIX_EPOCH + Duration::from_secs(seconds.into())).map_err(|e| e.to_string())?;
        }
        progress.check_cancelled()?;
        tokio::fs::rename(&stage_path, &job.local).await.map_err(|e| format!("无法替换目标，原文件保留：{e}"))?;
        Ok::<(), String>(())
    }.await;
    if result.is_err() { let _ = stage.flush().await; }
    if result.is_ok() {
        forget(&key);
        if let Some(old) = candidate_path && old != job.local {
            let _ = tokio::fs::remove_file(old).await;
        }
    }
    result.map_err(|e| if e == "已取消" {
        format!("原文件未替换，临时文件：{}；已取消", stage_path.display())
    } else { format!("{e}；原文件未替换，临时文件：{}", stage_path.display()) })
}

pub(super) async fn upload_file(
    sftp: &SftpSession, peer: &str, job: &Job, policy: ConflictPolicy, progress: &mut Progress<'_>,
) -> Result<(), String> {
    let _guard = Guard::acquire(format!("remote:{peer}:{}", job.remote))?;
    progress.check_cancelled()?;
    // 先打开本地源文件，不能先截断服务器上的旧文件。
    let mut source = tokio::fs::File::open(&job.local).await.map_err(|e| format!("无法读取源文件：{e}"))?;
    let initial = source.metadata().await.map_err(|e| e.to_string())?;
    if !initial.is_file() || initial.len() != job.size { return Err("源文件已经变化或不是普通文件".into()); }
    let existing = remote_meta(sftp, &job.remote).await?;
    if policy == ConflictPolicy::Skip && existing.is_some() { progress.add(job.size); return Ok(()); }
    let key = format!("upload:{peer}:{}:{}", job.local.display(), job.remote);
    let candidate_path = if policy == ConflictPolicy::Resume {
        partial(&key).or_else(|| existing.as_ref().map(|_| job.remote.clone()))
    } else { None };
    let parent = job.remote.rsplit_once('/').map(|(p, _)| if p.is_empty() { "/" } else { p }).unwrap_or(".");
    let reuse = if let Some(path) = &candidate_path {
        path != &job.remote && remote_meta(sftp, path).await?.is_some()
    } else { false };
    let stage_path = if reuse { candidate_path.clone().unwrap() } else { super::join(parent, &unique_name()) };
    let flags = if reuse { OpenFlags::WRITE } else { OpenFlags::WRITE | OpenFlags::CREATE | OpenFlags::EXCLUDE };
    let mut stage = sftp.open_with_flags_and_attributes(stage_path.clone(), flags,
        FileAttributes { permissions: Some(0o600), ..Default::default() }).await.map_err(describe)?;
    remember(&key, &stage_path);
    let result = async {
        let mut offset = 0;
        if let Some(path) = &candidate_path {
            if let Some(meta) = remote_meta(sftp, path).await? && let Some(len) = meta.size && len <= job.size {
                let mut candidate = sftp.open(path.clone()).await.map_err(describe)?;
                let matches = if reuse {
                    prefix(&mut source, &mut candidate, &mut tokio::io::sink(), len, progress).await?
                } else { prefix(&mut source, &mut candidate, &mut stage, len, progress).await? };
                if matches { offset = len; stage.seek(SeekFrom::Start(offset)).await.map_err(|e| e.to_string())?; }
            }
        }
        if offset == 0 {
            source.seek(SeekFrom::Start(0)).await.map_err(|e| e.to_string())?;
            stage.flush().await.map_err(|e| e.to_string())?;
            stage.set_metadata(FileAttributes { size: Some(0), ..Default::default() }).await.map_err(describe)?;
            stage.seek(SeekFrom::Start(0)).await.map_err(|e| e.to_string())?;
        }
        copy(&mut source, &mut stage, offset, job.size, progress).await?;
        let final_meta = source.metadata().await.map_err(|e| e.to_string())?;
        if final_meta.len() != initial.len() || final_meta.modified().ok() != initial.modified().ok() {
            return Err("源文件在传输期间被修改，请重新传输".into());
        }
        stage.flush().await.map_err(|e| e.to_string())?;
        stage.shutdown().await.map_err(|e| e.to_string())?;
        // 替换的是 inode：在提交前恢复旧文件的权限和所有者，不能把私密文件扩大权限。
        let attrs = FileAttributes {
            permissions: existing.as_ref().and_then(|m| m.permissions).or(job.permissions).map(|p| p & 0o777),
            uid: existing.as_ref().and_then(|m| m.uid),
            gid: existing.as_ref().and_then(|m| m.gid),
            atime: job.modified, mtime: job.modified, ..Default::default()
        };
        sftp.set_metadata(stage_path.clone(), attrs).await.map_err(describe)?;
        progress.check_cancelled()?;
        let now = remote_meta(sftp, &job.remote).await?;
        if now.as_ref().map(|m| (m.size, m.mtime)) != existing.as_ref().map(|m| (m.size, m.mtime)) {
            return Err("目标文件在传输期间被修改，未覆盖，请刷新后重试".into());
        }
        // 标准 SFTP v3 不保证覆盖 rename；保留备份，失败时回滚，绝不先删除旧文件。
        if existing.is_some() {
            let backup = super::join(parent, &format!("{}.backup", unique_name()));
            let journal = super::join(parent, &format!("{}.recovery.json", unique_name()));
            let mut record = sftp.open_with_flags_and_attributes(journal.clone(),
                OpenFlags::WRITE | OpenFlags::CREATE | OpenFlags::EXCLUDE,
                FileAttributes { permissions: Some(0o600), ..Default::default() }).await.map_err(describe)?;
            let recovery = serde_json::json!({"version": 1, "destination": job.remote, "temporary": stage_path, "backup": backup});
            record.write_all(recovery.to_string().as_bytes()).await.map_err(|e| e.to_string())?;
            record.flush().await.map_err(|e| e.to_string())?;
            record.shutdown().await.map_err(|e| e.to_string())?;
            // 在第一次改名之前写好恢复映射；进程崩溃也能找到备份对应的目标。
            sftp.rename(job.remote.clone(), backup.clone()).await
                .map_err(|e| format!("准备备份失败或状态未知：{}；恢复记录：{journal}", describe(e)))?;
            if let Err(error) = sftp.rename(stage_path.clone(), job.remote.clone()).await {
                let restored = sftp.rename(backup.clone(), job.remote.clone()).await.is_ok();
                if restored { let _ = sftp.remove_file(journal.clone()).await; }
                return Err(format!("替换失败：{}；{}，旧版备份位置：{backup}；恢复记录：{journal}", describe(error),
                    if restored { "已恢复原文件" } else { "连接或路径状态不确定，请检查目标和备份" }));
            }
            if let Err(e) = sftp.remove_file(backup.clone()).await {
                return Err(format!("新文件已保存，但旧版备份未清理：{backup}（{}）；恢复记录：{journal}", describe(e)));
            }
            let _ = sftp.remove_file(journal).await;
        } else {
            sftp.rename(stage_path.clone(), job.remote.clone()).await.map_err(describe)?;
        }
        Ok::<(), String>(())
    }.await;
    if result.is_err() {
        // 取消时也等已提交写请求结束，避免立即重试和旧写请求并发修改临时文件。
        let _ = stage.flush().await;
        let _ = stage.shutdown().await;
    }
    if result.is_ok() {
        forget(&key);
        if let Some(old) = candidate_path && old != job.remote { let _ = sftp.remove_file(old).await; }
    }
    result.map_err(|e| if e == "已取消" {
        format!("传输临时文件：{stage_path}；已取消")
    } else { format!("{e}；传输临时文件：{stage_path}") })
}

#[cfg(test)]
mod tests {
    use super::*;
    struct Observer;
    impl super::super::TransferObserver for Observer {
        fn on_progress(&self, _: super::super::TransferProgress) {}
        fn on_finished(&self, _: Option<String>) {}
    }
    fn progress<'a>(observer: &'a Observer, transfer: &'a super::super::Transfer) -> Progress<'a> {
        Progress { observer, transfer, bytes_done: 0, bytes_total: 4, files_done: 0, files_total: 1,
            current: String::new(), last_report: std::time::Instant::now() }
    }
    #[tokio::test]
    async fn equal_size_different_content_is_not_a_resume_match() {
        let transfer = super::super::Transfer::default();
        let p = progress(&Observer, &transfer);
        let mut source = &b"NEW!"[..]; let mut old = &b"OLD!"[..]; let mut stage = Vec::new();
        assert!(!prefix(&mut source, &mut old, &mut stage, 4, &p).await.unwrap());
        assert!(stage.is_empty());
    }
    #[tokio::test]
    async fn entire_prefix_is_verified_and_copied() {
        let transfer = super::super::Transfer::default();
        let p = progress(&Observer, &transfer);
        let bytes = vec![42; CHUNK + 13];
        let mut source = &bytes[..]; let mut candidate = &bytes[..]; let mut stage = Vec::new();
        assert!(prefix(&mut source, &mut candidate, &mut stage, bytes.len() as u64, &p).await.unwrap());
        assert_eq!(stage, bytes);
    }
    #[tokio::test]
    async fn cancellation_stops_verification() {
        let transfer = super::super::Transfer::default(); transfer.cancel();
        let p = progress(&Observer, &transfer);
        assert_eq!(prefix(&mut &b"data"[..], &mut &b"data"[..], &mut Vec::new(), 4, &p).await.unwrap_err(), "已取消");
    }
    #[test]
    fn same_destination_is_serialized() {
        let key = unique_name(); let first = Guard::acquire(key.clone()).unwrap();
        assert!(Guard::acquire(key.clone()).is_err()); drop(first);
        assert!(Guard::acquire(key).is_ok());
    }
}
