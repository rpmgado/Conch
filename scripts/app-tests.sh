#!/bin/bash
# 界面层的单元测试（ConchKit：会话模型、ssh_config / Xshell 导入、快速连接、日志过滤、配色）。
#
# 用法：scripts/app-tests.sh [swift test 的其他参数]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CACHE="${CONCH_BUILD_CACHE:-$ROOT/.build-cache}"
export CONCH_RUSTLIB_DIR="$CACHE/RustLib"

# 只装了命令行工具时，Swift Testing 的宏插件在 plugins/testing 子目录里，编译器默认找不到
EXTRA=()
TOOLCHAIN_BIN="$(dirname "$(xcrun --find swift)")"
TESTING_PLUGINS="$TOOLCHAIN_BIN/../lib/swift/host/plugins/testing"
if [ -d "$TESTING_PLUGINS" ]; then
  EXTRA+=(-Xswiftc -plugin-path -Xswiftc "$(cd "$TESTING_PLUGINS" && pwd)")
fi

cd "$ROOT/app"
swift test --force-resolved-versions --scratch-path "$CACHE/swiftpm" ${EXTRA[@]+"${EXTRA[@]}"} "$@"
