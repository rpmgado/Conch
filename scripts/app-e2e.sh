#!/bin/bash
# 界面层端到端测试：用测试钩子启动真实的 Conch.app，连本地测试服务器，
# 检查标签页状态、屏幕文字、会话日志、导入、钥匙串、断线重连；
# 最后一段模拟点击、拖动、滚轮和按键（Conch 会到前台几秒）。
#
# 先运行 CONCH_TESTING=1 scripts/build.sh 和 scripts/test-sshd.sh start。
# 用法：scripts/app-e2e.sh [输出目录]   截图和导出的文字都放在输出目录里
#
# 测试数据放在临时目录，钥匙串用单独的服务名（测试结束自动删除），不碰你真实的会话和密码。
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_BUNDLE="$ROOT/build/Conch-Test.app"
APP_BIN="$APP_BUNDLE/Contents/MacOS/Conch"
SSHD_DIR="${TMPDIR%/}/conch-test-sshd"
AGENT_SOCK="${TMPDIR%/}/conch-test-agent.sock"
OUT="${1:-$(mktemp -d -t conch-e2e)}"
mkdir -p "$OUT"
USER_NAME="$(whoami)"
# 测试服务器的密码和动态口令（见 test-sshd.sh），只在本机测试里用
PASSWORD="conch-test-password"
OTP="246810"
KEYCHAIN_SERVICE="Conch-E2E-$$"

[ -x "$APP_BIN" ] || { echo "先运行 CONCH_TESTING=1 scripts/build.sh" >&2; exit 1; }
[ "$(plutil -extract ConchTestBuild raw "$APP_BUNDLE/Contents/Info.plist" 2>/dev/null)" = true ] || { echo "端到端测试必须使用独立的 Conch-Test.app" >&2; exit 1; }
nc -z 127.0.0.1 2224 2>/dev/null || { echo "先运行 scripts/test-sshd.sh start" >&2; exit 1; }

pass=0
fail=0
check() {
  local name="$1" file="$2" expr="$3"
  if python3 - "$file" "$expr" <<'EOF'
import json, sys
path, expr = sys.argv[1], sys.argv[2]
text = open(path, encoding="utf-8", errors="replace").read() if path else ""
s = json.loads(text) if path.endswith(".json") else None
ok = eval(expr, {"s": s, "text": text, "lines": [l.strip() for l in text.splitlines()]})
sys.exit(0 if ok else 1)
EOF
  then
    echo "[PASS] $name"; pass=$((pass + 1))
  else
    echo "[FAIL] ${name}（${file}）"; fail=$((fail + 1))
  fi
}

# 启动 App，等它截图后自己退出；卡住就强制结束
run_app() {
  local name="$1" delay="$2"; shift 2
  local data="$OUT/$name-data"
  rm -rf "$data"; mkdir -p "$data"
  [ -f "$OUT/sessions.json" ] && cp "$OUT/sessions.json" "$data/sessions.json"
  env CONCH_DATA_DIR="$data" CONCH_KEYCHAIN_SERVICE="$KEYCHAIN_SERVICE" CONCH_TRUST_NEW_HOSTS=1 \
      CONCH_NO_METAL=1 SSH_AUTH_SOCK="$AGENT_SOCK" CONCH_SSH_CONFIG="$OUT/ssh_config" \
      CONCH_SNAPSHOT="$OUT/$name.png" CONCH_DUMP_TEXT="$OUT/$name" CONCH_DUMP_STATE="$OUT/$name-state.json" \
      CONCH_SNAPSHOT_DELAY="$delay" CONCH_QUIT_AFTER_SNAPSHOT=1 "$@" \
      "$APP_BIN" > "$OUT/$name.log" 2>&1 &
  local pid=$!
  local limit=$(( ${delay%.*} + 25 ))
  for _ in $(seq 1 "$limit"); do
    kill -0 "$pid" 2>/dev/null || break
    sleep 1
  done
  if kill -0 "$pid" 2>/dev/null; then
    echo "[FAIL] $name 没有按时退出，结束测试实例"
    fail=$((fail + 1))
    kill "$pid" 2>/dev/null
  fi
  wait "$pid" 2>/dev/null
}

# 用伪终端模拟一台接在串口上的设备（见 scripts/mock-serial.py），测试结束时关掉
SERIAL_PATH_FILE="$OUT/serial-path.txt"; rm -f "$SERIAL_PATH_FILE"
python3 "$ROOT/scripts/mock-serial.py" "$SERIAL_PATH_FILE" &
SERIAL_PID=$!
trap 'kill $SERIAL_PID 2>/dev/null' EXIT
for _ in $(seq 1 50); do [ -s "$SERIAL_PATH_FILE" ] && break; sleep 0.1; done
SERIAL_PATH="$(cat "$SERIAL_PATH_FILE" 2>/dev/null)"

# ───── 测试数据 ─────
python3 - "$OUT" "$SSHD_DIR" "$USER_NAME" "$SERIAL_PATH" <<'EOF'
import json, os, sys, uuid
out, keys, user, serial_path = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
def s(name, group, host, port, username, auth, keys_=(), legacy=False, jump=None, log=False):
    return {"id": str(uuid.uuid4()).upper(), "name": name, "group": group, "host": host, "port": port,
            "username": username, "auth": auth, "keyPaths": list(keys_), "identitiesOnly": bool(keys_),
            "identityAgent": "", "legacyAlgorithms": legacy, "jumpHostID": jump, "autoReconnect": True,
            "logSession": log, "notes": ""}
modern = s("本机现代", "测试/OpenSSH", "127.0.0.1", 2222, user, "key", [f"{keys}/client_ed25519"], log=True)
agent = s("自动走agent", "测试/OpenSSH", "127.0.0.1", 2222, user, "auto")
jump = s("跳板机", "测试/OpenSSH", "127.0.0.1", 2222, user, "auto", [f"{keys}/client_ed25519"])
legacy = s("经跳板机的老设备", "测试/OpenSSH", "127.0.0.1", 2223, user, "auto", [f"{keys}/client_rsa"], legacy=True, jump=jump["id"])
pw = s("密码登录", "测试/模拟服务器", "127.0.0.1", 2224, "pw", "password")
kbd = s("堡垒机二次验证", "测试/模拟服务器", "127.0.0.1", 2224, "kbd", "password")
mfa = s("公钥加动态口令", "测试/模拟服务器", "127.0.0.1", 2224, "mfa", "auto", [f"{keys}/client_ed25519"])
dead = s("连不上的端口", "测试", "127.0.0.1", 2299, user, "auto", [f"{keys}/client_ed25519"])
gbk = s("GBK 设备", "测试/模拟服务器", "127.0.0.1", 2224, "pw", "password")
gbk["encoding"] = "GB18030"
forwarded = s("带转发", "测试/OpenSSH", "127.0.0.1", 2222, user, "key", [f"{keys}/client_ed25519"])
forwarded["forwards"] = [
    {"id": str(uuid.uuid4()).upper(), "kind": "local", "bindHost": "127.0.0.1", "bindPort": 22999,
     "targetHost": "127.0.0.1", "targetPort": 2224, "enabled": True},
    {"id": str(uuid.uuid4()).upper(), "kind": "dynamic", "bindHost": "127.0.0.1", "bindPort": 22998,
     "targetHost": "", "targetPort": 0, "enabled": True},
]
telnet = s("Telnet 设备", "测试/网络设备", "127.0.0.1", 2325, "", "auto")
telnet["kind"] = "telnet"
telnet["encoding"] = "GB18030"
def serial(name, path, **settings):
    p = s(name, "测试/网络设备", "", 22, "", "auto")
    p["kind"] = "serial"
    p["serial"] = {"path": path, "baudRate": 9600, "dataBits": 8, "parity": "none", "stopBits": 1, "flowControl": "none", **settings}
    return p
console = serial("串口设备", serial_path, baudRate=115200, dataBits=7, parity="even", stopBits=2, flowControl="software")
unplugged = serial("拔掉的串口", "/dev/cu.conch-missing")
json.dump({"version": 1, "groups": ["空分组"], "sessions": [modern, agent, jump, legacy, pw, kbd, mfa, dead, gbk, forwarded,
                                                          telnet, console, unplugged]},
          open(f"{out}/sessions.json", "w"), ensure_ascii=False, indent=2)

open(f"{out}/ssh_config", "w").write(f"""
Host testjump
  HostName 127.0.0.1
  Port 2222
  User {user}
  IdentityFile {keys}/client_ed25519
  IdentitiesOnly yes
Host legacybox
  HostName 127.0.0.1
  Port 2223
  User {user}
  IdentityFile {keys}/client_rsa
  IdentitiesOnly yes
  ProxyJump testjump
Host web-* !web-old
  User deploy
Host web-01
  HostName 10.20.0.1
Host *
  ServerAliveInterval 30
""")

xsh = f"{out}/xsh/Sessions/生产/数据库"
os.makedirs(xsh, exist_ok=True)
content = "[SessionInfo]\nVersion=7.0\nDescription=订单主库\n[CONNECTION]\nPort=2200\nHost=10.9.8.7\nProtocol=SSH\n[CONNECTION:AUTHENTICATION]\nUserName=dba\nMethod=0\n"
open(f"{xsh}/订单库.xsh", "wb").write(b"\xff\xfe" + content.encode("utf-16-le"))
open(f"{out}/xsh/Sessions/串口.xsh", "w").write("[CONNECTION]\nProtocol=SERIAL\nHost=COM1\n")
EOF

echo "输出目录：$OUT"

# ───── 1. 多个标签页：各种认证方式、跳板机、日志 ─────
echo; echo "==> 多标签页"
run_app tabs 6 \
  CONCH_OPEN_SESSIONS="本机现代,自动走agent,经跳板机的老设备,密码登录,堡垒机二次验证,公钥加动态口令" \
  CONCH_TEST_SECRETS="password:pw@127.0.0.1:2224=$PASSWORD;password:kbd@127.0.0.1:2224=$PASSWORD" \
  CONCH_TEST_OTP="$OTP" CONCH_AUTOTYPE='whoami\r' CONCH_SELECT_TAB=2
S="$OUT/tabs-state.json"
check "6 个标签页都连上了" "$S" 'len(s["tabs"]) == 6 and all(t["phase"] == "connected" for t in s["tabs"])'
check "私钥认证" "$S" 's["tabs"][0]["auth"] == "publickey"'
check "自动认证走 ssh-agent" "$S" 's["tabs"][1]["auth"] == "publickey (ssh-agent)"'
check "经跳板机连老设备" "$S" '"经由 跳板机" in s["tabs"][2]["route"]'
check "密码认证" "$S" 's["tabs"][3]["auth"] == "password"'
check "交互式密码 + 动态口令" "$S" 's["tabs"][4]["auth"] == "keyboard-interactive"'
# 测试 agent 里也有这把钥匙，所以公钥这一步可能走 agent，也可能走文件
check "公钥 + 动态口令" "$S" 's["tabs"][5]["auth"].startswith("publickey") and s["tabs"][5]["auth"].endswith(" + keyboard-interactive")'
check "选中了第 3 个标签页" "$S" 's["selected"] == 2'
check "OpenSSH 标签页里执行了命令" "$OUT/tabs-0.txt" "'$USER_NAME' in lines"
check "经跳板机的标签页里执行了命令" "$OUT/tabs-2.txt" "'$USER_NAME' in lines"
check "模拟服务器标签页里执行了命令" "$OUT/tabs-3.txt" "'pw' in lines"
check "终端里显示了连接进度" "$OUT/tabs-2.txt" '"跳板机" in text and "认证通过" in text'
LOG="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["tabs"][0]["log"] or "")' "$S" 2>/dev/null)"
if [ -n "$LOG" ] && [ -f "$LOG" ]; then
  check "会话日志写了内容" "$LOG" "any(l.endswith('% whoami') or l.endswith('\$ whoami') for l in lines) and '$USER_NAME' in lines"
  check "日志是纯文本（没有控制字符、没有 zsh 的 % 填充）" "$LOG" '"\x1b" not in text and "\r" not in text and not any(l.startswith("%  ") for l in lines)'
else
  echo "[FAIL] 会话日志没有生成"; fail=$((fail + 1))
fi

# ───── 2. 导入、钥匙串自检、新标签页 ─────
echo; echo "==> 导入和钥匙串自检"
run_app import 3 CONCH_IMPORT_SSH_CONFIG="$OUT/ssh_config" CONCH_IMPORT_XSH="$OUT/xsh/Sessions" CONCH_TEST_KEYCHAIN=1
S="$OUT/import-state.json"
check "ssh_config 的别名都导入了" "$S" 'all(n in s["sessions"] for n in ["testjump", "legacybox", "web-01"])'
check "ProxyJump 变成了跳板机设置" "$S" '"jump=testjump" in s["sessions"]["legacybox"]'
check "Host 通配符的默认用户生效" "$S" '"deploy@10.20.0.1" in s["sessions"]["web-01"]'
check "Xshell 会话按文件夹分组" "$S" 's["sessions"]["订单库"].startswith("Xshell/Sessions/生产/数据库|dba@10.9.8.7:2200|password")'
check "Xshell 的串口会话被跳过" "$S" '"串口" not in s["sessions"]'
check "钥匙串读写自检" "$S" 's["keychainSelfTest"] == "ok"'
check "没有打开会话时是新标签页" "$S" 's["tabs"][0]["phase"] == "idle"'

# ───── 3. 密码框勾选“记住” → 存进钥匙串 ─────
echo; echo "==> 记住密码"
run_app remember 4 CONCH_OPEN_SESSIONS="密码登录" CONCH_TEST_PROMPT_ANSWER="$PASSWORD;remember"
S="$OUT/remember-state.json"
check "用输入的密码登录成功" "$S" 's["tabs"][0]["phase"] == "connected" and s["tabs"][0]["auth"] == "password"'
check "密码存进了钥匙串" "$S" 's["tabs"][0]["savedPassword"] is True'

# ───── 4. 钥匙串里已有密码 → 直接登录，不弹窗 ─────
echo; echo "==> 用钥匙串里的密码"
run_app keychain 4 CONCH_OPEN_SESSIONS="密码登录" CONCH_TEST_KEYCHAIN_SEED="password:pw@127.0.0.1:2224=$PASSWORD"
check "从钥匙串读密码登录" "$OUT/keychain-state.json" 's["tabs"][0]["phase"] == "connected"'

# ───── 5. 快速连接：ssh_config 别名 + ProxyJump ─────
echo; echo "==> 快速连接"
run_app quick 4 CONCH_QUICK_CONNECT="legacybox" CONCH_QUICK_CONNECT_LEGACY=1 CONCH_AUTOTYPE='whoami\r'
S="$OUT/quick-state.json"
check "别名解析出跳板机并连上" "$S" 's["tabs"][0]["phase"] == "connected" and "经由 testjump" in s["tabs"][0]["route"]'
check "快速连接的标签页显示别名" "$S" 's["tabs"][0]["title"] == "legacybox"'

# ───── 6. 连接失败的显示 ─────
echo; echo "==> 连接失败"
run_app failed 3 CONCH_OPEN_SESSIONS="连不上的端口"
check "连不上时显示失败原因" "$OUT/failed-state.json" 's["tabs"][0]["phase"].startswith("failed:")'
check "终端里显示了红色的错误" "$OUT/failed-0.txt" '"2299" in text and "按回车键重新连接" in text'

# ───── 7. 断线自动重连：连上后把服务器那边的 sshd 进程杀掉 ─────
echo; echo "==> 断线自动重连"
(
  sleep 4
  for pid in $(pgrep -P "$(cat "$SSHD_DIR/modern.pid")"); do kill "$pid" 2>/dev/null; done
) &
run_app reconnect 13 CONCH_OPEN_SESSIONS="本机现代" CONCH_AUTOTYPE='whoami\r'
S="$OUT/reconnect-state.json"
check "断线后又连上了" "$S" 's["tabs"][0]["phase"] == "connected"'
check "终端里提示了自动重连" "$OUT/reconnect-0.txt" '"秒后自动重连（第 1 次）" in text'
check "重连后命令又执行了一次" "$OUT/reconnect-0.txt" "lines.count('$USER_NAME') >= 2"

# ───── 8. “断开”按钮，断开后在终端里按回车重新连接 ─────
echo; echo "==> 断开和按回车重连"
run_app disconnect 9 CONCH_OPEN_SESSIONS="密码登录" CONCH_TEST_SECRETS="password:pw@127.0.0.1:2224=$PASSWORD" \
  CONCH_TEST_DISCONNECT_AFTER=2 CONCH_TEST_ENTER_AFTER_DISCONNECT=1 CONCH_DUMP_MENUS="$OUT/menus.txt"
check "断开后按回车又连上了" "$OUT/disconnect-state.json" 's["tabs"][0]["phase"] == "connected"'
check "终端里显示了已断开" "$OUT/disconnect-0.txt" '"[已断开连接，按回车键重新连接]" in text'
# 窗口不是前台时菜单项叫“关闭”（关当前窗口），是前台时叫“关闭标签页”；系统自带的“关闭”要已经被替换掉
check "⌘W 只有一个菜单项" "$OUT/menus.txt" 'sum(1 for l in text.splitlines() if l.endswith("\t⌘w")) == 1'

# ───── 阶段 2 ─────
test_content() {  # 和模拟服务器一样的测试内容
  python3 -c "import sys; n=int(sys.argv[2]); open(sys.argv[1],'wb').write(bytes(((i*31+7)%251) for i in range(n)))" "$1" "$2"
}
same_file() {  # 文件存在且和期望内容一致
  python3 -c "import sys; n=int(sys.argv[2]); d=open(sys.argv[1],'rb').read(); sys.exit(0 if d==bytes(((i*31+7)%251) for i in range(n)) else 1)" "$1" "$2" 2>/dev/null
}
check_file() {
  if same_file "$2" "$3"; then echo "[PASS] $1"; pass=$((pass + 1)); else echo "[FAIL] $1（$2）"; fail=$((fail + 1)); fi
}

# ───── 9. 文件面板：打开、进目录、上传 ─────
echo; echo "==> 文件面板（SFTP）"
SFTP_DIR="$OUT/sftp-remote"; rm -rf "$SFTP_DIR"; mkdir -p "$SFTP_DIR/子目录"
test_content "$OUT/面板上传.bin" 1500000
run_app files 6 CONCH_OPEN_SESSIONS="本机现代" CONCH_SHOW_FILES=1 CONCH_SHOW_COMPOSE=1 \
  CONCH_TEST_SFTP_PATH="$SFTP_DIR" CONCH_TEST_SFTP_UPLOAD="$OUT/面板上传.bin"
S="$OUT/files-state.json"
check "SFTP 打开并进到测试目录" "$S" 's["tabs"][0]["files"]["status"] == "ready" and s["tabs"][0]["files"]["path"].endswith("sftp-remote")'
check "上传完成并出现在列表里" "$S" '"面板上传.bin: finished" in s["tabs"][0]["files"]["transfers"] and "面板上传.bin" in s["tabs"][0]["files"]["entries"] and "子目录/" in s["tabs"][0]["files"]["entries"]'
check_file "上传的文件内容一致" "$SFTP_DIR/面板上传.bin" 1500000

# ───── 10. 会话里配的端口转发 ─────
echo; echo "==> 端口转发"
(
  sleep 4
  python3 - "$OUT/forward-probe.txt" <<'PY'
import socket, sys
out = []
def banner(sock):
    sock.settimeout(3)
    return sock.recv(64).decode(errors="replace").strip()
try:
    with socket.create_connection(("127.0.0.1", 22999), timeout=3) as s:
        out.append("local=" + banner(s))
except Exception as e:
    out.append(f"local=ERR {e}")
try:
    with socket.create_connection(("127.0.0.1", 22998), timeout=3) as s:
        s.sendall(bytes([5, 1, 0])); s.recv(2)
        s.sendall(bytes([5, 1, 0, 1, 127, 0, 0, 1]) + (2224).to_bytes(2, "big")); s.recv(10)
        out.append("socks=" + banner(s))
except Exception as e:
    out.append(f"socks=ERR {e}")
open(sys.argv[1], "w").write("\n".join(out))
PY
) &
run_app forwards 7 CONCH_OPEN_SESSIONS="带转发"
check "转发都启动了" "$OUT/forwards-state.json" 'len(s["tabs"][0]["forwards"]) == 2 and all("running:" in f for f in s["tabs"][0]["forwards"])'
check "本地转发能连到目标" "$OUT/forward-probe.txt" '"local=SSH-2.0" in text'
check "SOCKS 代理能连到目标" "$OUT/forward-probe.txt" '"socks=SSH-2.0" in text'

# ───── 11. GBK 编码 ─────
echo; echo "==> GBK 编码"
run_app gbk 5 CONCH_OPEN_SESSIONS="GBK 设备" CONCH_TEST_SECRETS="password:pw@127.0.0.1:2224=$PASSWORD" \
  CONCH_AUTOTYPE='gbk\r' CONCH_KEYS='hex 中文\r' CONCH_KEYS_DELAY=3
check "GBK 输出正常显示" "$OUT/gbk-0.txt" '"编码测试：中文GBK" in text'
check "键盘输入按 GBK 发送" "$OUT/gbk-0.txt" '"hex=d6d0cec4" in text'
check "状态栏显示编码" "$OUT/gbk-state.json" 's["tabs"][0]["encoding"] == "GB18030"'

# ───── 12. sz 下载、rz 上传 ─────
echo; echo "==> rz / sz"
ZDL="$OUT/zmodem-downloads"; rm -rf "$ZDL"
run_app sz 6 CONCH_OPEN_SESSIONS="密码登录" CONCH_TEST_SECRETS="password:pw@127.0.0.1:2224=$PASSWORD" \
  CONCH_TEST_ZMODEM_DIR="$ZDL" CONCH_AUTOTYPE='sz 界面下载.bin 300000\r'
check_file "sz 收到的文件一致" "$ZDL/界面下载.bin" 300000
check "终端里提示了保存位置" "$OUT/sz-0.txt" '"[rz/sz] 已保存到" in text and "OO" not in text'
test_content "$OUT/界面上传.bin" 250000
rm -f "$SSHD_DIR/rz/界面上传.bin"
run_app rz 6 CONCH_OPEN_SESSIONS="密码登录" CONCH_TEST_SECRETS="password:pw@127.0.0.1:2224=$PASSWORD" \
  CONCH_TEST_RZ_FILES="$OUT/界面上传.bin" CONCH_AUTOTYPE='rz\r'
check_file "rz 发过去的文件一致" "$SSHD_DIR/rz/界面上传.bin" 250000
check "rz 之后终端恢复正常" "$OUT/rz-0.txt" '"mock: 传输完成" in text'

# ───── 13. 同步输入、查找 ─────
echo; echo "==> 同步输入和查找"
run_app broadcast 6 CONCH_OPEN_SESSIONS="密码登录,堡垒机二次验证" \
  CONCH_TEST_SECRETS="password:pw@127.0.0.1:2224=$PASSWORD;password:kbd@127.0.0.1:2224=$PASSWORD" CONCH_TEST_OTP="$OTP" \
  CONCH_BROADCAST=1 CONCH_KEYS='echo sync-ok\r' CONCH_KEYS_DELAY=3 CONCH_FIND="sync-ok" CONCH_SHOW_COMPOSE=1
check "同步输入：第 1 个标签页收到" "$OUT/broadcast-0.txt" '"sync-ok" in lines'
check "同步输入：第 2 个标签页也收到" "$OUT/broadcast-1.txt" '"sync-ok" in lines'
check "查找找到了" "$OUT/broadcast-state.json" 's["find"] is not None and not s["find"].endswith("没有找到") and int(s["find"].split("/")[1]) >= 1'

# 撰写栏的发送范围独立于终端同步输入。用不同输出标记检查实际收到命令的会话。
run_app compose-scope 9 CONCH_OPEN_SESSIONS="密码登录,堡垒机二次验证" \
  CONCH_TEST_SECRETS="password:pw@127.0.0.1:2224=$PASSWORD;password:kbd@127.0.0.1:2224=$PASSWORD" CONCH_TEST_OTP="$OTP" \
  CONCH_BROADCAST=1 CONCH_SHOW_COMPOSE=1 CONCH_TEST_SCRIPT_DELAY=4 \
  CONCH_TEST_SCRIPT='tab:0;compose:current:echo compose-current-only;compose:all:echo compose-all-received'
check "撰写栏测试中已开启同步输入且两条连接正常" "$OUT/compose-scope-state.json" 's["broadcast"] and len(s["tabs"]) == 2 and all(tab["phase"] == "connected" for tab in s["tabs"])'
check "撰写栏选当前会话时当前会话收到" "$OUT/compose-scope-0.txt" '"compose-current-only" in lines'
check "撰写栏选当前会话时其他会话没有收到" "$OUT/compose-scope-1.txt" '"compose-current-only" not in text'
check "撰写栏选全部会话时当前会话收到" "$OUT/compose-scope-0.txt" '"compose-all-received" in lines'
check "撰写栏选全部会话时其他会话也收到" "$OUT/compose-scope-1.txt" '"compose-all-received" in lines'

# ───── 阶段 3 ─────

# ───── 14. Telnet ─────
echo; echo "==> Telnet"
run_app telnet 5 CONCH_OPEN_SESSIONS="Telnet 设备" CONCH_AUTOTYPE="admin\r$PASSWORD\rwhoami\rstty size\rterm\rgbk\r"
S="$OUT/telnet-state.json"
check "Telnet 连上了" "$S" 's["tabs"][0]["phase"] == "connected" and s["tabs"][0]["kind"] == "telnet" and "Telnet" in s["tabs"][0]["route"]'
check "Telnet 登录并执行了命令" "$OUT/telnet-0.txt" '"Welcome, admin" in text and "admin" in lines'
check "密码没有回显" "$OUT/telnet-0.txt" "'$PASSWORD' not in text"
check "NAWS 报的窗口大小和终端一致" "$OUT/telnet-0.txt" \
  '(lambda t: "%d %d" % (t["rows"], t["cols"]) in lines)(__import__("json").load(open("'"$S"'"))["tabs"][0])'
check "TTYPE 报了终端类型" "$OUT/telnet-0.txt" '"TERM=XTERM-256COLOR" in text.upper()'
check "Telnet 上的 GBK 编码" "$OUT/telnet-0.txt" '"编码测试：中文GBK" in text'
check "Telnet 状态栏没有 SFTP 和转发" "$S" 's["tabs"][0]["forwards"] == [] and s["tabs"][0].get("files") is None'

run_app telnetquick 5 CONCH_QUICK_CONNECT="telnet 127.0.0.1 2325" CONCH_AUTOTYPE="ops\r$PASSWORD\rexit\r"
S="$OUT/telnetquick-state.json"
check "快速连接认 telnet 命令" "$S" 's["tabs"][0]["kind"] == "telnet" and s["tabs"][0]["title"].startswith("127.0.0.1:2325")'
check "设备断开后不自动重连" "$S" 's["tabs"][0]["phase"].startswith("closed")'
check "终端里显示了设备的告别" "$OUT/telnetquick-0.txt" '"Bye" in text'

# ───── 15. 串口 ─────
echo; echo "==> 串口"
if [ -n "$SERIAL_PATH" ]; then
  run_app serial 5 CONCH_OPEN_SESSIONS="串口设备,拔掉的串口" CONCH_SELECT_TAB=0 CONCH_SHOW_FILES=1 \
    CONCH_AUTOTYPE='\rshow version\rshow line\r'
  S="$OUT/serial-state.json"
  check "串口打开了" "$S" 's["tabs"][0]["phase"] == "connected" and s["tabs"][0]["kind"] == "serial" and s["tabs"][0]["route"].endswith("115200 7E2")'
  check "和设备交互" "$OUT/serial-0.txt" '"Mock Switch Software, Version 1.0" in text and "Switch>" in text'
  check "串口参数设置到了设备上" "$OUT/serial-0.txt" '"speed=115200 bits=7 parity=even stop=2 flow=software" in lines'
  check "串口标签页不显示文件面板" "$S" 's["tabs"][0].get("files") is None'
  check "找不到串口时提示原因" "$S" '"找不到这个串口设备" in s["tabs"][1]["phase"]'
else
  echo "[FAIL] 模拟串口设备没有启动"; fail=$((fail + 1))
fi

# ───── 16. 分屏 ─────
echo; echo "==> 分屏"
# 左右分屏 → 右边再上下分屏 → 在最下面那块右边打开另一个会话 → 切回上一个分屏并关掉它
run_app split 12 CONCH_OPEN_SESSIONS="本机现代" CONCH_TEST_SECRETS="password:pw@127.0.0.1:2224=$PASSWORD" \
  CONCH_PANE_ACTIONS="h,v,open:密码登录,prev,close" CONCH_KEYS='stty size\r' CONCH_KEYS_DELAY=10
S="$OUT/split-state.json"
check "分屏结构正确" "$S" 's["layouts"] == ["H(0,V(1,2))"] and all(t["tab"] == 0 for t in s["tabs"])'
check "3 个分屏都连上了" "$S" 'len(s["tabs"]) == 3 and all(t["phase"] == "connected" for t in s["tabs"])'
check "分屏里打开了另一个会话" "$S" 's["tabs"][2]["title"] == "密码登录" and s["tabs"][1]["title"] == "本机现代"'
check "关闭分屏后焦点给了相邻的分屏" "$S" 's["selected"] == 1 and s["tabs"][1]["focused"]'
check "左右各占一半" "$S" 'abs(s["tabs"][0]["cols"] - s["tabs"][1]["cols"]) <= 2 and s["tabs"][1]["cols"] == s["tabs"][2]["cols"]'
check "上下各占一半" "$S" 'abs(s["tabs"][1]["rows"] - s["tabs"][2]["rows"]) <= 2 and s["tabs"][0]["rows"] > s["tabs"][1]["rows"] * 1.8'
check "服务器那边的终端尺寸跟着分屏变" "$OUT/split-1.txt" \
  '(lambda t: "%d %d" % (t["rows"], t["cols"]) in lines)(__import__("json").load(open("'"$S"'"))["tabs"][1])'

run_app zoom 8 CONCH_OPEN_SESSIONS="本机现代" CONCH_PANE_ACTIONS="h,zoom" CONCH_KEYS='stty size\r' CONCH_KEYS_DELAY=6
S="$OUT/zoom-state.json"
check "放大当前分屏" "$S" 's["layouts"] == ["H(0,1) zoom=1"] and s["tabs"][1]["cols"] > s["tabs"][0]["cols"] * 1.8'
check "放大后终端尺寸是整个区域" "$OUT/zoom-1.txt" \
  '(lambda t: "%d %d" % (t["rows"], t["cols"]) in lines)(__import__("json").load(open("'"$S"'"))["tabs"][1])'

# ───── 17. 服务器监控 ─────
echo; echo "==> 服务器监控"
run_app monitor 10 CONCH_OPEN_SESSIONS="密码登录" CONCH_TEST_SECRETS="password:pw@127.0.0.1:2224=$PASSWORD" CONCH_SHOW_MONITOR=1
S="$OUT/monitor-state.json"
check "监控在采集" "$S" 's["tabs"][0]["monitor"]["status"] == "running" and s["tabs"][0]["monitor"]["hostname"] == "mock-linux" and s["tabs"][0]["monitor"]["cores"] == 4'
check "CPU 曲线有数据" "$S" 's["tabs"][0]["monitor"]["cpuPoints"] >= 2 and 0 < s["tabs"][0]["monitor"]["cpu"] < 100'
check "内存和网速" "$S" '50 < s["tabs"][0]["monitor"]["memoryPercent"] < 80 and s["tabs"][0]["monitor"]["received"] > 0'
check "磁盘只列真实磁盘，百分比和 df 一致" "$S" 's["tabs"][0]["monitor"]["disks"] == ["/ 27%", "/data 85%"]'
check "进程列表" "$S" 's["tabs"][0]["monitor"]["processes"][:3] == ["java", "nginx", "sshd"]'
check "终端不受监控影响" "$OUT/monitor-0.txt" '"pw@mock$" in text and "@@CONCH@@" not in text'

run_app monitormac 5 CONCH_OPEN_SESSIONS="本机现代" CONCH_SHOW_MONITOR=1
check "非 Linux 服务器提示不支持" "$OUT/monitormac-state.json" 's["tabs"][0]["monitor"]["status"] == "unsupported: 这台服务器是 macOS，监控目前只支持 Linux"'

# ───── 18. 远程编辑 ─────
echo; echo "==> 远程编辑"
EDIT_DIR="$OUT/edit-remote"; rm -rf "$EDIT_DIR"; mkdir -p "$EDIT_DIR"
printf 'listen 80;\n' > "$EDIT_DIR/site.conf"
chmod 640 "$EDIT_DIR/site.conf"
run_app edit 8 CONCH_OPEN_SESSIONS="本机现代" CONCH_SHOW_FILES=1 CONCH_TEST_SFTP_PATH="$EDIT_DIR" \
  CONCH_TEST_EDIT="$EDIT_DIR/site.conf" CONCH_TEST_EDIT_APPEND='server_name example.test;\n' CONCH_TEST_EDIT_APPEND_DELAY=2
check "保存后自动传回服务器" "$EDIT_DIR/site.conf" 'text == "listen 80;\nserver_name example.test;\n"'
check "上传后保留了原来的权限" "" "oct(__import__('os').stat('$EDIT_DIR/site.conf').st_mode & 0o777) == '0o640'"
check "编辑状态是已上传" "$OUT/edit-state.json" '"site.conf: synced" in s["tabs"][0]["files"]["edits"]'

# 冲突：打开编辑之后服务器上的文件被别人改了，再保存时不覆盖
printf 'v1\n' > "$EDIT_DIR/conflict.txt"
( sleep 5; printf 'changed on server\n' > "$EDIT_DIR/conflict.txt" ) &
run_app editconflict 10 CONCH_OPEN_SESSIONS="本机现代" CONCH_SHOW_FILES=1 CONCH_TEST_SFTP_PATH="$EDIT_DIR" \
  CONCH_TEST_EDIT="$EDIT_DIR/conflict.txt" CONCH_TEST_EDIT_APPEND='my change\n' CONCH_TEST_EDIT_APPEND_DELAY=4.5 \
  CONCH_TEST_EDIT_CONFLICT=keep
check "发现冲突，没有覆盖服务器上的修改" "$EDIT_DIR/conflict.txt" 'text == "changed on server\n"'
check "编辑状态是冲突" "$OUT/editconflict-state.json" '"conflict.txt: conflict" in s["tabs"][0]["files"]["edits"]'

# ───── 19. 会话同步 ─────
echo; echo "==> 会话同步"
SYNC="$OUT/sync-folder"; rm -rf "$SYNC"; mkdir -p "$SYNC"
add_synced_session() {  # 模拟另一台 Mac 往同步文件夹里加一个会话（先写临时文件再改名，和同步盘一样）
  python3 - "$1/sessions.json" "$2" "$3" <<'PY'
import json, os, sys, uuid
path, name, group = sys.argv[1:4]
data = json.load(open(path)) if os.path.exists(path) else {"version": 1, "groups": [], "sessions": []}
data["sessions"].append({"id": str(uuid.uuid4()).upper(), "name": name, "group": group, "host": "10.1.1.1",
                         "port": 22, "username": "ops", "auth": "auto"})
if group and group not in data["groups"]:
    data["groups"].append(group)
json.dump(data, open(path + ".tmp", "w"), ensure_ascii=False)
os.replace(path + ".tmp", path)
PY
}
add_synced_session "$SYNC" "另一台 Mac 的服务器" "另一台 Mac"
run_app syncon 3 CONCH_SYNC_ENABLE="$SYNC"
check "打开同步后两边的会话合在一起" "$SYNC/sessions.json" 'len(s["sessions"]) == 14 and any(p["name"] == "另一台 Mac 的服务器" for p in s["sessions"])'
check "快捷命令也放进了同步文件夹" "$SYNC/quick-commands.json" 'len(s) >= 1'

# 另一台 Mac（同步已经打开）：运行中同步文件夹被别处改了，它自己同时也新建了一个分组
( sleep 3; add_synced_session "$SYNC" "第三台 Mac 刚加的" "" ) &
run_app syncb 7 CONCH_SYNC_DIR="$SYNC" CONCH_TEST_ADD_GROUP="B 新建的分组" CONCH_TEST_ADD_GROUP_DELAY=3.5
S="$OUT/syncb-state.json"
check "从同步文件夹读会话" "$S" 's["sessionsFile"].endswith("sync-folder/sessions.json") and "另一台 Mac 的服务器" in s["sessions"]'
check "别处的修改几秒内自动出现" "$S" '"第三台 Mac 刚加的" in s["sessions"]'
check "两边同时修改都留下了" "$SYNC/sessions.json" 'any(p["name"] == "第三台 Mac 刚加的" for p in s["sessions"]) and "B 新建的分组" in s["groups"]'

# 同步文件夹没挂上（移动硬盘、NAS 没连）：先用本机留的那份，回来后把这期间的修改并进去
OFFLINE="$OUT/sync-offline"; rm -rf "$OFFLINE"
( sleep 4; mkdir -p "$OFFLINE"; add_synced_session "$OFFLINE" "硬盘上原来就有的" "" ) &
run_app syncoffline 9 CONCH_SYNC_DIR="$OFFLINE" CONCH_TEST_ADD_GROUP="离线时新建的分组" CONCH_TEST_ADD_GROUP_DELAY=2
check "同步文件夹回来后自动合并" "$OFFLINE/sessions.json" 'len(s["sessions"]) == 14 and "离线时新建的分组" in s["groups"]'
check "合并后改回用同步文件夹" "$OUT/syncoffline-state.json" 'not s["waitingForSyncFolder"] and s["sessionsFile"].endswith("sync-offline/sessions.json")'

# ───── 20. 用保存的密码前验证（Touch ID）─────
echo; echo "==> 密码保护"
run_app authok 5 CONCH_OPEN_SESSIONS="密码登录,GBK 设备" CONCH_TEST_KEYCHAIN_SEED="password:pw@127.0.0.1:2224=$PASSWORD" \
  CONCH_REQUIRE_AUTH=1 CONCH_TEST_AUTH=allow
check "验证通过后用保存的密码登录" "$OUT/authok-state.json" 'len(s["tabs"]) == 2 and all(t["phase"] == "connected" for t in s["tabs"])'
check "两个标签页只验证了一次" "$OUT/authok-state.json" 's["authPrompts"] == 1'
run_app authdeny 5 CONCH_OPEN_SESSIONS="密码登录" CONCH_TEST_KEYCHAIN_SEED="password:pw@127.0.0.1:2224=$PASSWORD" \
  CONCH_REQUIRE_AUTH=1 CONCH_TEST_AUTH=deny CONCH_TEST_PROMPT_ANSWER="wrong-password"
check "取消验证就不用保存的密码" "$OUT/authdeny-state.json" 's["authPrompts"] == 1 and s["tabs"][0]["phase"].startswith("failed")'

# 身份验证不可用时也不能读取钥匙串，转为手动输入。
run_app authunavailable 5 CONCH_OPEN_SESSIONS="密码登录" CONCH_TEST_KEYCHAIN_SEED="password:pw@127.0.0.1:2224=$PASSWORD" \
  CONCH_REQUIRE_AUTH=1 CONCH_TEST_AUTH=unavailable CONCH_TEST_PROMPT_ANSWER="wrong-password"
check "系统无法验证身份时不使用保存的密码" "$OUT/authunavailable-state.json" 's["authPrompts"] == 1 and s["tabs"][0]["phase"].startswith("failed")'
check "无法验证身份时明确提示手动输入" "$OUT/authunavailable-0.txt" '"身份验证未通过或不可用" in text'

# ───── 界面改版：主题、环境标签 ─────
echo; echo "==> 界面主题和环境标签"
# 给测试数据里的分组打上环境标签（存在 sessions.json 里）
python3 - "$OUT/sessions.json" "$OUT/sessions-env.json" <<'PY'
import json, sys
library = json.load(open(sys.argv[1], encoding="utf-8"))
library["environments"] = {"测试/OpenSSH": "production", "测试/网络设备": "device"}
json.dump(library, open(sys.argv[2], "w", encoding="utf-8"), ensure_ascii=False)
PY
cp "$OUT/sessions.json" "$OUT/sessions-plain.json"
cp "$OUT/sessions-env.json" "$OUT/sessions.json"
run_app theme-env 6 CONCH_UI_THEME=environment CONCH_OPEN_SESSIONS="本机现代"
check "环境色主题配深色终端卡片" "$OUT/theme-env-state.json" 's["uiTheme"] == "environment" and s["theme"] == "conch-environment" and s["terminalBackground"] == "#1A1D23"'
check "分组的环境标签读出来了" "$OUT/theme-env-state.json" 's["environments"] == {"测试/OpenSSH": "production", "测试/网络设备": "device"}'
run_app theme-graphite 6 CONCH_UI_THEME=graphite CONCH_OPEN_SESSIONS="本机现代" CONCH_PANE_ACTIONS="h"
check "石墨主题配深色终端" "$OUT/theme-graphite-state.json" 's["uiTheme"] == "graphite" and s["theme"] == "conch-graphite" and s["terminalBackground"] == "#111216"'
check "石墨主题下分屏照常" "$OUT/theme-graphite-state.json" 's["layouts"] == ["H(0,1)"] and all(t["phase"] == "connected" for t in s["tabs"])'
run_app theme-glass 4 CONCH_UI_THEME=glass
check "玻璃主题配白底终端" "$OUT/theme-glass-state.json" 's["uiTheme"] == "glass" and s["theme"] == "conch-glass"'
cp "$OUT/sessions-plain.json" "$OUT/sessions.json"

# ───── 21. 真实交互：点击后的键盘焦点、拖动分屏、标签栏滚动、本机文件栏 ─────
# 这几项只有真的点、拖、滚、敲键盘才测得出来：用 open 启动（App 会到前台几秒），
# 测试脚本（见 TestScript.swift）往事件队列里放鼠标和键盘事件，和用户操作走同一条路。
# 每个 state 步骤记一行状态，汇总到 名字-steps.json，按步骤名检查
echo; echo "==> 交互（Conch 会到前台几秒，期间别动鼠标键盘）"
run_interactive() {
  local name="$1" script="$2"; shift 2
  local data="$OUT/$name-data"
  rm -rf "$data"; mkdir -p "$data"
  cp "$OUT/sessions.json" "$data/sessions.json"
  : > "$OUT/$name.jsonl"
  local pidfile="$OUT/$name.pid"
  rm -f "$pidfile"
  local args=(
    --env "CONCH_TEST_PID_FILE=$pidfile"
    --env "CONCH_DATA_DIR=$data" --env "CONCH_KEYCHAIN_SERVICE=$KEYCHAIN_SERVICE" --env CONCH_TRUST_NEW_HOSTS=1
    --env "SSH_AUTH_SOCK=$AGENT_SOCK" --env "CONCH_SSH_CONFIG=$OUT/ssh_config"
    --env "CONCH_TEST_SCRIPT=$script" --env "CONCH_TEST_SCRIPT_LOG=$OUT/$name.jsonl" --env CONCH_TEST_SCRIPT_DELAY=4
  )
  for kv in "$@"; do args+=(--env "$kv"); done
  # 测试 App 使用独立标识，且不恢复上次的测试窗口。
  open -n -W "${args[@]}" --stdout "$OUT/$name.log" --stderr "$OUT/$name.log" "$APP_BUNDLE" \
    --args -ApplePersistenceIgnoreState YES &
  local opener=$!
  for _ in $(seq 1 75); do
    kill -0 "$opener" 2>/dev/null || break
    sleep 1
  done
  if kill -0 "$opener" 2>/dev/null; then
    echo "[FAIL] $name 没有按时退出，结束测试实例"
    fail=$((fail + 1))
    # 只结束这个测试实例，不能误关用户另外打开的 Conch。
    if [ -s "$pidfile" ]; then
      local app_pid="$(cat "$pidfile")"
      case "$app_pid" in ''|*[!0-9]*) ;; *) kill "$app_pid" 2>/dev/null ;; esac
    fi
    kill "$opener" 2>/dev/null
  fi
  wait "$opener" 2>/dev/null
  python3 - "$OUT/$name.jsonl" "$OUT/$name-steps.json" <<'PY'
import json, sys
steps = {}
for line in open(sys.argv[1], encoding="utf-8"):
    if line.strip():
        line = json.loads(line)
        steps[line["step"]] = line
json.dump(steps, open(sys.argv[2], "w", encoding="utf-8"), ensure_ascii=False, indent=1)
PY
}

# 点过文件列表再点终端：GPU 绘制时点到的是终端上面的绘图层，以前焦点不会回到终端，打不了字
LOCAL_DIR="$OUT/local-files"; LOCAL_REMOTE="$OUT/local-remote"
rm -rf "$LOCAL_DIR" "$LOCAL_REMOTE"; mkdir -p "$LOCAL_DIR/子目录" "$LOCAL_REMOTE"
printf 'alpha\n' > "$LOCAL_DIR/alpha.txt"
printf 'hidden\n' > "$LOCAL_DIR/.hidden.cfg"
printf 'beta\n' > "$LOCAL_REMOTE/beta.txt"
run_interactive focus "activate;click:files;state:files;click:terminal;state:terminal;keys:1234\r;wait:1.5;state:typed;quit" \
  CONCH_OPEN_SESSIONS="本机现代" CONCH_SHOW_FILES=1 CONCH_TEST_SFTP_PATH="$LOCAL_REMOTE" CONCH_TEST_LOCAL_PATH="$LOCAL_DIR"
S="$OUT/focus-steps.json"
check "点了文件列表，键盘焦点在列表上" "$S" 's["files"]["firstResponder"] != "ConchTerminalView"'
check "再点终端（GPU 绘制），焦点回到终端" "$S" 's["terminal"]["terminalIsFirstResponder"] and s["terminal"]["metal"]'
check "接着敲键盘能输进终端" "$S" 'any("1234" in l for l in s["typed"]["bufferTail"])'

# 分屏：标题栏、拖到左边、拖到中间互换、拖分隔缝、拖到标签栏变新标签页、标题栏上的关闭按钮
run_interactive panes "activate;split:h;wait:2;state:split;drag:header:1>pane:0:left;state:moved;drag:header:0>pane:1;state:swapped;drag:divider:0>pane:0:left;state:resized;split:v;wait:2;state:three;drag:header:2>above;wait:1;state:detached;tab:0;wait:1;click:header:1:close;wait:1;state:closed;quit" \
  CONCH_OPEN_SESSIONS="本机现代"
S="$OUT/panes-steps.json"
check "分屏后每个分屏上面有标题栏" "$S" 's["split"]["layout"].startswith("H(") and len(s["split"]["headers"]) == 2'
check "拖标题栏放到另一个分屏的左边" "$S" 's["moved"]["layout"] == "H(%s,%s)" % tuple(reversed(s["split"]["layout"][2:-1].split(",")))'
check "拖到另一个分屏中间是互换位置" "$S" 's["swapped"]["layout"] == s["split"]["layout"]'
check "挪动、互换后终端马上排到新位置" "$S" 'all(int(s[k]["paneOrigins"][0].split(",")[0]) < int(s[k]["paneOrigins"][1].split(",")[0]) for k in ("moved", "swapped"))'
check "拖分隔缝调大小" "$S" 'int(s["resized"]["paneSizes"][0].split("x")[0]) < int(s["resized"]["paneSizes"][1].split("x")[0])'
check "拖到标签栏变成单独的标签页" "$S" 's["three"]["layout"].count(",") == 2 and s["detached"]["tabs"] == 2 and s["detached"]["selectedTab"] == 1 and "(" not in s["detached"]["layout"]'
check "标题栏上的关闭按钮关掉分屏" "$S" 's["closed"]["tabs"] == 2 and "(" not in s["closed"]["layout"] and s["closed"]["headers"] == []'
check "拖来拖去焦点一直在终端上" "$S" 'all(step["terminalIsFirstResponder"] for step in s.values())'

# 标签栏：标签多了能横向滚动，选中的标签页自动滚到看得见，鼠标滚轮也能左右翻
run_interactive tabstrip "activate;newtab;newtab;newtab;newtab;newtab;newtab;newtab;newtab;newtab;newtab;newtab;newtab;newtab;newtab;wait:1;state:many;tab:0;wait:1;state:first;wheel:3@tabbar;wait:0.6;state:wheel;quit"
S="$OUT/tabstrip-steps.json"
check "标签放不下时可以横向滚动" "$S" 's["many"]["tabs"] == 15 and s["many"]["tabStripOverflow"] is True'
check "新开的标签页自动滚到看得见的地方" "$S" 's["many"]["selectedTab"] == 14 and s["many"]["tabStripOffset"] > 0'
check "选第一个标签页时滚回开头" "$S" 's["first"]["tabStripOffset"] == 0'
check "鼠标滚轮可以左右翻标签" "$S" 's["wheel"]["tabStripOffset"] > 0'

# 本机文件栏：显示隐藏文件、双击本机文件上传、双击服务器文件下载、同名文件先问
run_interactive localfiles "activate;wait:1;state:start;hidden:local:on;wait:0.5;state:hidden;hidden:local:off;wait:0.5;dclick:localrow:1;wait:2;state:uploaded;dclick:remoterow:1;wait:2;state:downloaded;dclick:localrow:1;wait:1;state:conflict;sheetcancel;wait:0.5;state:cancelled;quit" \
  CONCH_OPEN_SESSIONS="本机现代" CONCH_SHOW_FILES=1 CONCH_TEST_SFTP_PATH="$LOCAL_REMOTE" CONCH_TEST_LOCAL_PATH="$LOCAL_DIR"
S="$OUT/localfiles-steps.json"
check "本机那一栏列出文件夹里的文件（不含隐藏文件）" "$S" 's["start"]["extra"]["local"].endswith("[子目录,alpha.txt]")'
check "本机那一栏可以显示隐藏文件" "$S" '".hidden.cfg" in s["hidden"]["extra"]["local"]'
check "双击本机文件上传到服务器" "$LOCAL_REMOTE/alpha.txt" 'text == "alpha\n"'
check "双击服务器文件下载到本机那一栏的文件夹" "$LOCAL_DIR/beta.txt" 'text == "beta\n"'
check "下载完本机那一栏自动刷新" "$S" '"beta.txt" in s["downloaded"]["extra"]["local"]'
check "服务器上有同名文件时先问要不要覆盖" "$S" '"已经有" in s["conflict"]["extra"].get("sheet", "") and "alpha.txt" in s["conflict"]["extra"]["sheet"]'
check "选取消就不传" "$S" 'len(s["cancelled"]["extra"]["transfers"].split(",")) == 2'

# ───── 22. 修复回归：连接归属、上传不建本地目录、下载目录错误 ─────
MISSING_REMOTE="$OUT/must-not-be-created"
BAD_DOWNLOAD="$OUT/not-a-directory"
printf 'a regular file\n' > "$BAD_DOWNLOAD"
run_interactive filesafety "activate;wait:1;uploadto:$LOCAL_DIR/alpha.txt>$MISSING_REMOTE;wait:2;state:uploadfailed;downloadto:$LOCAL_REMOTE/beta.txt>$BAD_DOWNLOAD;wait:1;state:downloadfailed;dropcheck;state:drops;quit" \
  CONCH_OPEN_SESSIONS="本机现代" CONCH_SHOW_FILES=1 CONCH_TEST_SFTP_PATH="$LOCAL_REMOTE" CONCH_TEST_LOCAL_PATH="$LOCAL_DIR"
S="$OUT/filesafety-steps.json"
check "上传不会在 Mac 上创建服务器目录" "" "not __import__('os').path.exists('$MISSING_REMOTE')"
check "不存在的远端目录明确报告上传失败" "$S" '"failed" in s["uploadfailed"]["extra"]["transfers"]'
check "下载目录无法创建时明确失败" "$S" '"无法创建下载目录" in s["downloadfailed"]["extra"]["transfers"]'
check "同一个 SFTP 连接的拖放可以解析" "$S" 's["drops"]["extra"]["sameConnectionDrop"] == "true"'
check "其他连接同名路径的拖放拒绝且给出原因" "$S" 's["drops"]["extra"]["foreignDropRejected"] == "true" and "另一个窗口" in s["drops"]["extra"]["dropMessage"]'
check "连接结束后旧拖放立即失效" "$S" 's["drops"]["extra"]["staleDropRejected"] == "true"'

# 返回终端后恢复键盘焦点，能继续输入。
run_interactive filefocus "activate;expandfiles;wait:1;state:shown;collapsefiles;wait:1;state:back;keys:67890\r;wait:1;state:typed;quit" \
  CONCH_OPEN_SESSIONS="本机现代" CONCH_SHOW_FILES=1
S="$OUT/filefocus-steps.json"
check "展开后返回终端自动恢复键盘焦点" "$S" '"sheet" in s["shown"]["extra"] and s["back"]["terminalIsFirstResponder"]'
check "返回终端后键盘输入正常" "$S" 'any("67890" in line for line in s["typed"]["bufferTail"])'

# 展开面板内的覆盖确认必须显示在当前面板上，取消后不产生传输。
run_interactive expandedoverwrite "activate;expandfiles;wait:1;uploadconfirm:$LOCAL_DIR/alpha.txt;wait:1;state:confirm;sheetcancel;wait:0.5;state:cancelled;collapsefiles;wait:1;state:back;quit" \
  CONCH_OPEN_SESSIONS="本机现代" CONCH_SHOW_FILES=1 CONCH_TEST_SFTP_PATH="$LOCAL_REMOTE" CONCH_TEST_LOCAL_PATH="$LOCAL_DIR"
S="$OUT/expandedoverwrite-steps.json"
check "展开面板里的覆盖确认可见" "$S" '"已经有" in s["confirm"]["extra"].get("nestedSheet", "")'
check "展开面板取消覆盖后不传输且可返回终端" "$S" 's["cancelled"]["extra"]["transfers"] == "" and s["back"]["terminalIsFirstResponder"]'

# 展开文件视图复用原连接、两栏和传输队列。
run_app expandedfiles 7 CONCH_OPEN_SESSIONS="本机现代" CONCH_SHOW_FILES=1 CONCH_EXPAND_FILES=1 \
  CONCH_TEST_SFTP_PATH="$LOCAL_REMOTE" CONCH_TEST_LOCAL_PATH="$LOCAL_DIR"
check "文件面板可以展开为左右对照" "$OUT/expandedfiles-state.json" 's["filesExpanded"] and s["fileSheetVisible"]'
check "展开文件面板不重连、不丢远端文件列表" "$OUT/expandedfiles-state.json" 'len(s["tabs"]) == 1 and s["tabs"][0]["phase"] == "connected" and s["tabs"][0]["files"]["status"] == "ready"'

printf '\n==> 结果：%d 个通过，%d 个失败（截图和导出文字在 %s）\n' "$pass" "$fail" "$OUT"
[ "$fail" -eq 0 ]
