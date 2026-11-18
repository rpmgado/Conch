//! 端口转发：本地（ssh -L）、远程（ssh -R）、动态 SOCKS 代理（ssh -D）。
//! 都走当前这条连接；经过跳板机时以最后一跳（目标主机）为准，和 ssh -J 加 -L 的效果一样。

use std::collections::HashMap;
use std::net::{Ipv4Addr, Ipv6Addr, SocketAddr};
use std::sync::atomic::{AtomicU32, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};

use russh::client;
use russh::{Channel, ChannelOpenFailure};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::watch;
use tokio::task::JoinSet;

use crate::{CoreError, Handler, RUNTIME, Shared, SshSession, session_err};

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum ForwardKind {
    /// 本机监听，经服务器连到目标（ssh -L）
    Local,
    /// 服务器上监听，经本机连到目标（ssh -R）
    Remote,
    /// 本机开一个 SOCKS4/5 代理，目标由使用代理的程序决定（ssh -D）
    Dynamic,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct ForwardSpec {
    pub kind: ForwardKind,
    /// 监听地址：本地和动态转发在本机，远程转发在服务器上。一般用 127.0.0.1（只允许本机访问）
    pub bind_host: String,
    /// 监听端口，0 表示随便挑一个空闲端口
    pub bind_port: u16,
    /// 转发目标；动态转发不用填。本地转发是从服务器看的地址，远程转发是从本机看的地址
    pub target_host: String,
    pub target_port: u16,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct ForwardStatus {
    /// 实际监听的端口（请求 0 时由系统或服务器分配）
    pub bound_port: u16,
    pub active_connections: u32,
    pub total_connections: u64,
    /// 已结束的连接累计发出 / 收到的字节数
    pub bytes_sent: u64,
    pub bytes_received: u64,
    /// 已停止时的原因；还在运行时为 None
    pub stopped: Option<String>,
}

#[derive(Default)]
pub(crate) struct ForwardStats {
    active: AtomicU32,
    total: AtomicU64,
    sent: AtomicU64,
    received: AtomicU64,
    stopped: Mutex<Option<String>>,
}

impl ForwardStats {
    fn opened(&self) {
        self.total.fetch_add(1, Ordering::Relaxed);
        self.active.fetch_add(1, Ordering::Relaxed);
    }

    fn closed(&self, sent: u64, received: u64) {
        self.active.fetch_sub(1, Ordering::Relaxed);
        self.sent.fetch_add(sent, Ordering::Relaxed);
        self.received.fetch_add(received, Ordering::Relaxed);
    }

    fn stop(&self, reason: &str) {
        if let Ok(mut stopped) = self.stopped.lock()
            && stopped.is_none()
        {
            *stopped = Some(reason.to_string());
        }
    }
}

/// 服务器上监听的远程转发：服务器有连接进来时，按端口找到要连的本机目标
pub(crate) struct RemoteTarget {
    host: String,
    port: u16,
    stats: Arc<ForwardStats>,
}

pub(crate) type RemoteForwards = Mutex<HashMap<u32, RemoteTarget>>;

/// 一条正在运行的转发
#[derive(uniffi::Object)]
pub struct PortForward {
    spec: ForwardSpec,
    bound_port: u16,
    stats: Arc<ForwardStats>,
    stop: watch::Sender<bool>,
    /// 远程转发停止时要通知服务器取消监听
    remote: Option<(Arc<client::Handle<Handler>>, Arc<Shared>)>,
}

#[uniffi::export]
impl PortForward {
    pub fn spec(&self) -> ForwardSpec {
        self.spec.clone()
    }

    pub fn status(&self) -> ForwardStatus {
        ForwardStatus {
            bound_port: self.bound_port,
            active_connections: self.stats.active.load(Ordering::Relaxed),
            total_connections: self.stats.total.load(Ordering::Relaxed),
            bytes_sent: self.stats.sent.load(Ordering::Relaxed),
            bytes_received: self.stats.received.load(Ordering::Relaxed),
            stopped: self.stats.stopped.lock().ok().and_then(|s| s.clone()),
        }
    }

    /// 停止监听，并断开经过它的所有连接
    pub fn stop(&self) {
        self.stop_with_reason("已停止");
    }
}

impl PortForward {
    pub(crate) fn stop_with_reason(&self, reason: &str) {
        self.stats.stop(reason);
        let _ = self.stop.send(true);
        if let Some((handle, shared)) = &self.remote {
            let port = u32::from(self.bound_port);
            if let Ok(mut map) = shared.remote_forwards.lock() {
                map.remove(&port);
            }
            let handle = handle.clone();
            let host = self.spec.bind_host.clone();
            RUNTIME.spawn(async move {
                let _ = handle.cancel_tcpip_forward(host, port).await;
            });
        }
    }
}

#[uniffi::export]
impl SshSession {
    /// 在这条连接上开一个端口转发。连接断开时转发会自动停止
    pub async fn start_forward(&self, spec: ForwardSpec) -> Result<Arc<PortForward>, CoreError> {
        let handle = self
            .hops
            .last()
            .cloned()
            .ok_or_else(|| CoreError::Session("连接已关闭".into()))?;
        let shared = self.target_shared.clone();
        let forward = RUNTIME
            .spawn(start(handle, shared, spec))
            .await
            .map_err(|e| CoreError::Session(e.to_string()))??;
        if let Ok(mut list) = self.forwards.lock() {
            list.retain(|f| f.status().stopped.is_none());
            list.push(forward.clone());
        }
        Ok(forward)
    }
}

async fn start(
    handle: Arc<client::Handle<Handler>>,
    shared: Arc<Shared>,
    spec: ForwardSpec,
) -> Result<Arc<PortForward>, CoreError> {
    let stats = Arc::new(ForwardStats::default());
    let (stop, stop_rx) = watch::channel(false);
    match spec.kind {
        ForwardKind::Local | ForwardKind::Dynamic => {
            let listener = TcpListener::bind((spec.bind_host.as_str(), spec.bind_port))
                .await
                .map_err(|e| {
                    CoreError::Session(format!("无法在本机 {}:{} 上监听：{e}", spec.bind_host, spec.bind_port))
                })?;
            let bound_port = listener.local_addr().map(|a| a.port()).unwrap_or(spec.bind_port);
            tokio::spawn(accept_loop(listener, handle, spec.clone(), stats.clone(), stop_rx));
            Ok(Arc::new(PortForward {
                spec,
                bound_port,
                stats,
                stop,
                remote: None,
            }))
        }
        ForwardKind::Remote => {
            let requested = u32::from(spec.bind_port);
            let allocated = handle
                .tcpip_forward(spec.bind_host.clone(), requested)
                .await
                .map_err(|e| match e {
                    russh::Error::RequestDenied => CoreError::Session(format!(
                        "服务器拒绝在 {}:{} 上监听（端口被占用，或者服务器关闭了 AllowTcpForwarding）",
                        spec.bind_host, spec.bind_port
                    )),
                    other => session_err(other),
                })?;
            let port = if requested == 0 { allocated } else { requested };
            if let Ok(mut map) = shared.remote_forwards.lock() {
                map.insert(
                    port,
                    RemoteTarget {
                        host: spec.target_host.clone(),
                        port: spec.target_port,
                        stats: stats.clone(),
                    },
                );
            }
            Ok(Arc::new(PortForward {
                spec,
                bound_port: u16::try_from(port).unwrap_or(0),
                stats,
                stop,
                remote: Some((handle, shared)),
            }))
        }
    }
}

async fn accept_loop(
    listener: TcpListener,
    handle: Arc<client::Handle<Handler>>,
    spec: ForwardSpec,
    stats: Arc<ForwardStats>,
    mut stop: watch::Receiver<bool>,
) {
    let mut connections = JoinSet::new();
    loop {
        tokio::select! {
            _ = stop.changed() => break,
            accepted = listener.accept() => match accepted {
                Ok((stream, peer)) => {
                    let _ = stream.set_nodelay(true);
                    stats.opened();
                    let handle = handle.clone();
                    let spec = spec.clone();
                    let stats = stats.clone();
                    connections.spawn(async move {
                        let (sent, received) = match spec.kind {
                            ForwardKind::Dynamic => socks(handle, stream, peer).await,
                            _ => local(handle, stream, peer, &spec.target_host, spec.target_port).await,
                        }
                        .unwrap_or((0, 0));
                        stats.closed(sent, received);
                    });
                }
                Err(e) => {
                    stats.stop(&format!("监听出错：{e}"));
                    break;
                }
            },
            Some(_) = connections.join_next(), if !connections.is_empty() => {}
        }
    }
    // 停止时把还开着的连接一并断掉
    connections.abort_all();
}

/// 本地转发的一条连接：经服务器连到目标，然后双向转发
async fn local(
    handle: Arc<client::Handle<Handler>>,
    mut stream: TcpStream,
    peer: SocketAddr,
    host: &str,
    port: u16,
) -> Option<(u64, u64)> {
    let channel = handle
        .channel_open_direct_tcpip(host, u32::from(port), peer.ip().to_string(), u32::from(peer.port()))
        .await
        .ok()?;
    pipe(&mut stream, channel).await
}

async fn pipe(stream: &mut TcpStream, channel: Channel<client::Msg>) -> Option<(u64, u64)> {
    let mut remote = channel.into_stream();
    tokio::io::copy_bidirectional(stream, &mut remote).await.ok()
}

// ───────────────────────────── 动态转发（SOCKS）─────────────────────────────

enum SocksVersion {
    V4,
    V5,
}

/// SOCKS4 / 4a / 5（只支持 CONNECT、不要认证，和 ssh -D 一样）
async fn socks(
    handle: Arc<client::Handle<Handler>>,
    mut stream: TcpStream,
    peer: SocketAddr,
) -> Option<(u64, u64)> {
    let (version, host, port) = socks_handshake(&mut stream).await.ok()?;
    let opened = handle
        .channel_open_direct_tcpip(host, u32::from(port), peer.ip().to_string(), u32::from(peer.port()))
        .await;
    let channel = match opened {
        Ok(channel) => {
            let reply: &[u8] = match version {
                SocksVersion::V5 => &[5, 0, 0, 1, 0, 0, 0, 0, 0, 0],
                SocksVersion::V4 => &[0, 0x5A, 0, 0, 0, 0, 0, 0],
            };
            stream.write_all(reply).await.ok()?;
            channel
        }
        Err(e) => {
            let reply: Vec<u8> = match version {
                SocksVersion::V5 => {
                    let code = match e {
                        russh::Error::ChannelOpenFailure(ChannelOpenFailure::ConnectFailed) => 5,
                        russh::Error::ChannelOpenFailure(ChannelOpenFailure::AdministrativelyProhibited) => 2,
                        _ => 1,
                    };
                    vec![5, code, 0, 1, 0, 0, 0, 0, 0, 0]
                }
                SocksVersion::V4 => vec![0, 0x5B, 0, 0, 0, 0, 0, 0],
            };
            let _ = stream.write_all(&reply).await;
            return None;
        }
    };
    pipe(&mut stream, channel).await
}

async fn socks_handshake(stream: &mut TcpStream) -> std::io::Result<(SocksVersion, String, u16)> {
    let invalid = |what: &str| std::io::Error::new(std::io::ErrorKind::InvalidData, what.to_string());
    match stream.read_u8().await? {
        5 => {
            let count = stream.read_u8().await? as usize;
            let mut methods = vec![0u8; count];
            stream.read_exact(&mut methods).await?;
            if !methods.contains(&0) {
                stream.write_all(&[5, 0xFF]).await?;
                return Err(invalid("客户端要求认证"));
            }
            stream.write_all(&[5, 0]).await?;
            let mut request = [0u8; 4];
            stream.read_exact(&mut request).await?;
            if request[1] != 1 {
                // 只支持 CONNECT
                stream.write_all(&[5, 7, 0, 1, 0, 0, 0, 0, 0, 0]).await?;
                return Err(invalid("不支持的 SOCKS 命令"));
            }
            let host = match request[3] {
                1 => {
                    let mut ip = [0u8; 4];
                    stream.read_exact(&mut ip).await?;
                    Ipv4Addr::from(ip).to_string()
                }
                3 => {
                    let len = stream.read_u8().await? as usize;
                    let mut name = vec![0u8; len];
                    stream.read_exact(&mut name).await?;
                    String::from_utf8_lossy(&name).into_owned()
                }
                4 => {
                    let mut ip = [0u8; 16];
                    stream.read_exact(&mut ip).await?;
                    Ipv6Addr::from(ip).to_string()
                }
                _ => return Err(invalid("不支持的地址类型")),
            };
            let port = stream.read_u16().await?;
            Ok((SocksVersion::V5, host, port))
        }
        4 => {
            let command = stream.read_u8().await?;
            let port = stream.read_u16().await?;
            let mut ip = [0u8; 4];
            stream.read_exact(&mut ip).await?;
            read_null_terminated(stream).await?; // 用户名，忽略
            if command != 1 {
                stream.write_all(&[0, 0x5B, 0, 0, 0, 0, 0, 0]).await?;
                return Err(invalid("不支持的 SOCKS 命令"));
            }
            // SOCKS4a：IP 是 0.0.0.x（x 非 0）时，后面跟着域名
            let host = if ip[0] == 0 && ip[1] == 0 && ip[2] == 0 && ip[3] != 0 {
                read_null_terminated(stream).await?
            } else {
                Ipv4Addr::from(ip).to_string()
            };
            Ok((SocksVersion::V4, host, port))
        }
        _ => Err(invalid("不是 SOCKS 请求")),
    }
}

async fn read_null_terminated(stream: &mut TcpStream) -> std::io::Result<String> {
    let mut bytes = Vec::new();
    loop {
        let byte = stream.read_u8().await?;
        if byte == 0 || bytes.len() > 255 {
            break;
        }
        bytes.push(byte);
    }
    Ok(String::from_utf8_lossy(&bytes).into_owned())
}

// ───────────────────────────── 远程转发 ─────────────────────────────

/// 服务器上有连接进来（远程转发）：找到对应的本机目标，连过去并双向转发
pub(crate) async fn accept_remote(
    shared: &Shared,
    channel: Channel<client::Msg>,
    connected_port: u32,
    reply: russh::client::ChannelOpenHandle,
) {
    let target = shared
        .remote_forwards
        .lock()
        .ok()
        .and_then(|map| map.get(&connected_port).map(|t| (t.host.clone(), t.port, t.stats.clone())));
    let Some((host, port, stats)) = target else {
        reply.reject(ChannelOpenFailure::AdministrativelyProhibited).await;
        return;
    };
    reply.accept().await;
    stats.opened();
    tokio::spawn(async move {
        let result = match TcpStream::connect((host.as_str(), port)).await {
            Ok(mut stream) => {
                let _ = stream.set_nodelay(true);
                pipe(&mut stream, channel).await
            }
            Err(_) => None,
        };
        // 和本地转发一样：sent 是本机这边发出去的，received 是从服务器那边收到的
        let (sent, received) = result.unwrap_or((0, 0));
        stats.closed(sent, received);
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    async fn handshake(bytes: Vec<u8>) -> (SocksVersion, String, u16, Vec<u8>) {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        let client = tokio::spawn(async move {
            let mut stream = TcpStream::connect(address).await.unwrap();
            stream.write_all(&bytes).await.unwrap();
            let mut reply = vec![0u8; 2];
            let _ = stream.read_exact(&mut reply).await;
            reply
        });
        let (mut stream, _) = listener.accept().await.unwrap();
        let (version, host, port) = socks_handshake(&mut stream).await.unwrap();
        drop(stream);
        let reply = client.await.unwrap();
        (version, host, port, reply)
    }

    #[tokio::test]
    async fn socks5_domain_request() {
        let mut bytes = vec![5, 1, 0, 5, 1, 0, 3, 11];
        bytes.extend_from_slice(b"example.com");
        bytes.extend_from_slice(&443u16.to_be_bytes());
        let (version, host, port, reply) = handshake(bytes).await;
        assert!(matches!(version, SocksVersion::V5));
        assert_eq!((host.as_str(), port), ("example.com", 443));
        assert_eq!(reply, vec![5, 0]);
    }

    #[tokio::test]
    async fn socks4a_request() {
        let mut bytes = vec![4, 1];
        bytes.extend_from_slice(&80u16.to_be_bytes());
        bytes.extend_from_slice(&[0, 0, 0, 1]);
        bytes.extend_from_slice(b"me\0intranet.local\0");
        let (version, host, port, _) = handshake(bytes).await;
        assert!(matches!(version, SocksVersion::V4));
        assert_eq!((host.as_str(), port), ("intranet.local", 80));
    }
}
