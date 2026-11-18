#!/bin/bash
# 在本机起几个只监听 127.0.0.1 的临时 SSH 服务器，给 Conch 做测试用：
#   2222  OpenSSH，现代算法（也可以当跳板机：默认允许转发）
#   2223  OpenSSH，只开老算法，模拟老交换机 / CentOS 6：
#         diffie-hellman-group14-sha1 / group1-sha1 + aes128-cbc / 3des-cbc + hmac-sha1 + ssh-rsa
#   2224  模拟服务器（core/examples/mock_server.rs），测非 root 的 sshd 测不了的认证：
#         用户 pw 只开密码；kbd 先问密码再问动态口令；mfa 公钥 + 动态口令
#         登录后的模拟 Shell 还支持 gbk / hex（测编码）、sz / rz（测 ZMODEM，rz 收到的文件放在 $DIR/rz）
#   2325  模拟网络设备的 Telnet 服务（同一个模拟服务器），任意用户名 + 下面的密码登录
# 另外起一个独立的 ssh-agent（不碰你自己的 agent），预先加好测试密钥。
#
# 不需要 root、不改系统设置；OpenSSH 只能以当前用户登录，只接受这里生成的测试密钥。
# 测试用的密码和动态口令就是下面的 MOCK_PASSWORD、MOCK_OTP，只在本机测试里用。
#
# 用法：
#   scripts/test-sshd.sh start [目录]    默认目录 $TMPDIR/conch-test-sshd
#   scripts/test-sshd.sh stop  [目录]
set -euo pipefail

CMD="${1:-start}"
DIR="${2:-${TMPDIR:-/tmp}/conch-test-sshd}"
DIR="${DIR%/}"
case "$DIR" in *" "*) echo "目录路径里不能有空格（sshd_config 不好转义）：$DIR" >&2; exit 1 ;; esac
# Unix socket 路径不能超过 104 字节，agent 的 socket 单独放在系统临时目录
TMP="${TMPDIR:-/tmp}"
AGENT_SOCK="${TMP%/}/conch-test-agent.sock"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MOCK_PASSWORD="conch-test-password"
MOCK_OTP="246810"
export CARGO_TARGET_DIR="${CONCH_BUILD_CACHE:-$ROOT/.build-cache}/cargo"

stop_all() {
  for pidfile in "$DIR"/*.pid; do
    [ -f "$pidfile" ] || continue
    kill "$(cat "$pidfile")" 2>/dev/null || true
    rm -f "$pidfile"
  done
  rm -f "$AGENT_SOCK"
}

if [ "$CMD" = "stop" ]; then
  stop_all
  echo "已停止 $DIR 下的测试 sshd 和 ssh-agent"
  exit 0
fi

mkdir -p "$DIR/sftp-root"
chmod 700 "$DIR"
stop_all

key() { [ -f "$DIR/$1" ] || ssh-keygen -q -t "$2" ${3:+-b "$3"} -N "${4:-}" -C "$1" -f "$DIR/$1"; }
key host_ed25519 ed25519
key host_rsa rsa 3072
key client_ed25519 ed25519
key client_rsa rsa 3072
# 带口令的私钥，用来测试“私钥口令”输入框；口令只用于本地测试
key client_ed25519_pass ed25519 "" conch-test-passphrase
cat "$DIR"/client_*.pub > "$DIR/authorized_keys"

common="ListenAddress 127.0.0.1
AuthorizedKeysFile $DIR/authorized_keys
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
UsePAM no
StrictModes no
AcceptEnv LANG LC_*
Subsystem sftp internal-sftp -d $DIR/sftp-root
LogLevel VERBOSE"

cat > "$DIR/modern.conf" <<EOF
Port 2222
PidFile $DIR/modern.pid
HostKey $DIR/host_ed25519
HostKey $DIR/host_rsa
$common
EOF

cat > "$DIR/legacy.conf" <<EOF
Port 2223
PidFile $DIR/legacy.pid
HostKey $DIR/host_rsa
HostKeyAlgorithms ssh-rsa
KexAlgorithms diffie-hellman-group14-sha1,diffie-hellman-group1-sha1
Ciphers aes128-cbc,3des-cbc
MACs hmac-sha1
PubkeyAcceptedAlgorithms ssh-rsa
$common
EOF

# sshd 必须用绝对路径启动（re-exec 的要求）
/usr/sbin/sshd -f "$DIR/modern.conf" -E "$DIR/modern.log"
/usr/sbin/sshd -f "$DIR/legacy.conf" -E "$DIR/legacy.log"

# 模拟服务器：先编译（第一次要一会儿），用 OpenSSH 测试服务器的主机密钥
(cd "$ROOT/core" && MACOSX_DEPLOYMENT_TARGET=14.0 cargo build --locked --release -q --example mock_server)
"$CARGO_TARGET_DIR/release/examples/mock_server" --port 2224 --host-key "$DIR/host_ed25519" \
  --password "$MOCK_PASSWORD" --otp "$MOCK_OTP" --rz-dir "$DIR/rz" --telnet-port 2325 > "$DIR/mock.log" 2>&1 &
echo $! > "$DIR/mock.pid"

eval "$(ssh-agent -s -a "$AGENT_SOCK")" > /dev/null
echo "$SSH_AGENT_PID" > "$DIR/agent.pid"
SSH_AUTH_SOCK="$AGENT_SOCK" ssh-add -q "$DIR/client_ed25519"

# 最多等 5 秒，每个端口都能连上才算启动成功
for port in 2222 2223 2224 2325; do
  for _ in $(seq 1 50); do
    nc -z 127.0.0.1 "$port" 2>/dev/null && break
    sleep 0.1
  done
  nc -z 127.0.0.1 "$port" 2>/dev/null || { echo "端口 $port 上的服务没起来，看看 $DIR/*.log" >&2; exit 1; }
done

cat <<EOF
测试 sshd 已启动（用户名：$(whoami)）
  现代算法  127.0.0.1:2222   私钥 $DIR/client_ed25519
  老算法    127.0.0.1:2223   私钥 $DIR/client_rsa（老设备只认 ssh-rsa）
  带口令    私钥 $DIR/client_ed25519_pass（口令见本脚本）
  模拟服务器 127.0.0.1:2224   用户 pw / kbd / mfa（密码和动态口令见本脚本）
  Telnet    127.0.0.1:2325   任意用户名，密码同上
  ssh-agent SSH_AUTH_SOCK=$AGENT_SOCK
停止：$0 stop $DIR
EOF
