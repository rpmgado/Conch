#!/bin/bash
# 内核回归测试：单元测试 + 对本地测试服务器跑一组端到端场景。
# 先运行 scripts/test-sshd.sh start。
#
# 用法：scripts/core-tests.sh [--quick]    --quick 跳过吞吐和流控（每个场景快很多）
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIR="${TMPDIR:-/tmp}/conch-test-sshd"
DIR="${DIR%/}"
export CARGO_TARGET_DIR="${CONCH_BUILD_CACHE:-$ROOT/.build-cache}/cargo"
export MACOSX_DEPLOYMENT_TARGET=14.0
# 和 build.sh 用同一套 rustup 工具链（core/rust-toolchain.toml）；没装 rustup 时用系统里的 cargo
if [ -x "$HOME/.cargo/bin/rustup" ]; then export PATH="$HOME/.cargo/bin:$PATH"; fi
SMOKE="$CARGO_TARGET_DIR/release/examples/smoke"
QUICK="${1:-}"
# 测试服务器的密码、口令（见 test-sshd.sh），只在本机测试里用
PASSWORD="conch-test-password"
OTP="246810"
PASSPHRASE="conch-test-passphrase"
USER_NAME="$(whoami)"

nc -z 127.0.0.1 2224 2>/dev/null || { echo "测试服务器没在运行，先执行 scripts/test-sshd.sh start" >&2; exit 1; }

cd "$ROOT/core"
echo "==> 单元测试"
cargo test --locked --release -q -p conch_core --lib 2>&1 | grep -E "test result|FAILED|panicked" || exit 1
cargo build --locked --release -q --example smoke --example mock_server --example features || exit 1

KNOWN="$(mktemp -t conch-known_hosts)"
pass=0
fail=0
failed_names=()

run() {
  local name="$1"; shift
  printf '\n==> %s\n' "$name"
  if "$SMOKE" "$@" --known-hosts "$KNOWN"; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    failed_names+=("$name")
  fi
}

# 不让测试意外用到你自己的 ssh-agent
export SSH_AUTH_SOCK=/nonexistent

run "OpenSSH：自动认证，指定私钥" 127.0.0.1 2222 "$USER_NAME" --key "$DIR/client_ed25519" $QUICK
TEST_AGENT="${TMPDIR%/}/conch-test-agent.sock"
SSH_AUTH_SOCK="$TEST_AGENT" run "OpenSSH：自动认证，走 ssh-agent" 127.0.0.1 2222 "$USER_NAME" --quick
SSH_AUTH_SOCK="$TEST_AGENT" run "OpenSSH：只用 ssh-agent" 127.0.0.1 2222 "$USER_NAME" --auth agent --quick
run "OpenSSH：带口令的私钥" 127.0.0.1 2222 "$USER_NAME" --auth key --key "$DIR/client_ed25519_pass" --passphrase "$PASSPHRASE" --quick
run "OpenSSH：私钥口令一直不对" 127.0.0.1 2222 "$USER_NAME" --auth key --key "$DIR/client_ed25519_pass" --passphrase "wrong" \
  --expect-error "私钥口令错误次数过多"
run "OpenSSH：不给口令（取消）" 127.0.0.1 2222 "$USER_NAME" --auth key --key "$DIR/client_ed25519_pass" \
  --expect-error "你取消了输入私钥口令"
run "老设备：兼容算法 + ssh-rsa" 127.0.0.1 2223 "$USER_NAME" --key "$DIR/client_rsa" --legacy $QUICK
run "老设备：没开兼容" 127.0.0.1 2223 "$USER_NAME" --key "$DIR/client_rsa" \
  --expect-error "兼容老设备算法"
run "跳板机 → 老设备" 127.0.0.1 2223 "$USER_NAME" --key "$DIR/client_rsa" --legacy \
  --jump "$USER_NAME@127.0.0.1:2222" --jump-key "$DIR/client_ed25519" $QUICK
run "跳板机 → 不通的端口" 127.0.0.1 2299 "$USER_NAME" --key "$DIR/client_rsa" \
  --jump "$USER_NAME@127.0.0.1:2222" --jump-key "$DIR/client_ed25519" --expect-error "连不上"
run "模拟服务器：密码" 127.0.0.1 2224 pw --auth password --password "$PASSWORD" --mock
run "模拟服务器：先输错密码再重输" 127.0.0.1 2224 pw --auth password --password "$PASSWORD" --wrong-password-first --mock
run "模拟服务器：取消输入密码" 127.0.0.1 2224 pw --auth password --expect-error "你取消了输入密码"
run "模拟服务器：自动认证落到密码" 127.0.0.1 2224 pw --password "$PASSWORD" --mock
run "模拟服务器：交互式密码 + 动态口令" 127.0.0.1 2224 kbd --auth password --password "$PASSWORD" --otp "$OTP" --mock
run "模拟服务器：动态口令错误" 127.0.0.1 2224 kbd --auth password --password "$PASSWORD" --otp "000000" \
  --expect-error "交互式认证失败次数过多"
run "模拟服务器：公钥 + 动态口令" 127.0.0.1 2224 mfa --key "$DIR/client_ed25519" --otp "$OTP" --mock
run "跳板机 → 模拟服务器（密码）" 127.0.0.1 2224 pw --auth password --password "$PASSWORD" --mock \
  --jump "$USER_NAME@127.0.0.1:2222" --jump-key "$DIR/client_ed25519"

printf '\n==> 阶段 2、3 功能：SFTP、端口转发、编码、rz/sz、远程执行、Telnet、串口\n'
# 装了 lrzsz（brew install lrzsz）就顺带测和真实 rz/sz 的兼容性
LRZSZ=()
SZ_PATH="$(command -v sz || true)"
if [ -n "$SZ_PATH" ]; then LRZSZ=(--lrzsz "$(dirname "$SZ_PATH")"); fi
if "$CARGO_TARGET_DIR/release/examples/features" --keys "$DIR" --password "$PASSWORD" --rz-dir "$DIR/rz" ${LRZSZ[@]+"${LRZSZ[@]}"}; then
  pass=$((pass + 1))
else
  fail=$((fail + 1))
  failed_names+=("阶段 2、3 功能")
fi

rm -f "$KNOWN"
printf '\n==> 结果：%d 个通过，%d 个失败\n' "$pass" "$fail"
# macOS 自带的 bash 3.2 在 set -u 下展开空数组会报错，所以这样写
for name in ${failed_names[@]+"${failed_names[@]}"}; do echo "    失败：$name"; done
[ "$fail" -eq 0 ]
