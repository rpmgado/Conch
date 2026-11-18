#!/bin/bash
# CI / 本地发布前检查。不启动需要前台交互的 UI 测试。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
export PATH="$HOME/.cargo/bin:$PATH"
export CONCH_BUILD_CACHE="${CONCH_BUILD_CACHE:-$ROOT/.build-cache}"
export CARGO_TARGET_DIR="$CONCH_BUILD_CACHE/cargo"
export MACOSX_DEPLOYMENT_TARGET=14.0
mkdir -p build/ci-logs
scripts/build.sh release 2>&1 | tee build/ci-logs/build.log
scripts/app-tests.sh 2>&1 | tee build/ci-logs/models.log
scripts/third-party-notices.py --check
ci_temp="$(mktemp -d /private/tmp/conch-ci.XXXXXX)"
export TMPDIR="$ci_temp/"
cleanup() {
  scripts/test-sshd.sh stop > build/ci-logs/cleanup.log 2>&1 || true
  rm -rf "$ci_temp"
}
trap cleanup EXIT
scripts/test-sshd.sh start > build/ci-logs/server.log 2>&1
scripts/core-tests.sh --quick 2>&1 | tee build/ci-logs/core.log
codesign --verify --deep --strict build/Conch.app
[ "$(lipo -archs build/Conch.app/Contents/MacOS/Conch)" = arm64 ]
echo 'CI checks passed. Run scripts/app-e2e.sh separately in a desktop session.'
