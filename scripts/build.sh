#!/bin/bash
# 一键构建：Rust 内核 → UniFFI 生成 Swift 绑定 → SwiftPM 编译 → 打包 build/Conch.app
#
# 用法：scripts/build.sh [release|debug]
# 依赖：rustup 的官方 Rust 工具链（见 core/rust-toolchain.toml）、Swift 工具链（Xcode 或 Command Line Tools 都行）
# 只编 Apple 芯片（arm64）版本。
#
# 编译中间产物放在项目内的 .build-cache（已加入 Git 忽略），随项目一起搬迁；
# 可以用 CONCH_BUILD_CACHE 指定其他缓存位置，最终 App 在 build/Conch.app。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${1:-release}"
TESTING="${CONCH_TESTING:-0}"
SWIFT_FLAGS=()
if [ "$TESTING" = 1 ]; then SWIFT_FLAGS=(-Xswiftc -DCONCH_TESTING); fi
CACHE="${CONCH_BUILD_CACHE:-$ROOT/.build-cache}"
export CARGO_TARGET_DIR="$CACHE/cargo"
SWIFT_SCRATCH="$CACHE/swiftpm"
# Package.swift 从这里找 Rust 静态库
export CONCH_RUSTLIB_DIR="$CACHE/RustLib"
# App 的最低系统版本（和 Info.plist 的 LSMinimumSystemVersion、Package.swift 的 platforms 一致），
# Rust 和里面的 C 代码（aws-lc）按它编译
export MACOSX_DEPLOYMENT_TARGET=14.0

step() { printf '\n\033[1m==> %s\033[0m\n' "$1"; }

# Rust 用 rustup 的官方工具链：它的标准库按老系统编译，App 才能在 macOS 14 上运行。
# Homebrew 的 Rust 标准库按本机系统版本编译，链接时会报 “built for newer macOS”，老系统上可能打不开
if [ -x "$HOME/.cargo/bin/rustup" ]; then
  export PATH="$HOME/.cargo/bin:$PATH"
else
  echo "需要 rustup 的官方 Rust 工具链。安装（不改终端设置，和 Homebrew 的 Rust 互不影响）：" >&2
  echo "  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --no-modify-path --default-toolchain none" >&2
  exit 1
fi

step "编译 Rust 内核"
cd "$ROOT/core"
cargo build --locked --release -p conch_core

step "生成 Swift 绑定"
BINDINGS="$CARGO_TARGET_DIR/swift-bindings"
rm -rf "$BINDINGS"
cargo run --locked --release -q -p uniffi-bindgen --bin uniffi-bindgen-swift -- \
  "$CARGO_TARGET_DIR/release/libconch_core.dylib" "$BINDINGS" \
  --swift-sources --headers --modulemap \
  --module-name conch_coreFFI --modulemap-filename module.modulemap

mkdir -p "$ROOT/app/Sources/conch_coreFFI/include" "$ROOT/app/Sources/Conch/Generated" "$CONCH_RUSTLIB_DIR"
cp "$BINDINGS/conch_coreFFI.h" "$BINDINGS/module.modulemap" "$ROOT/app/Sources/conch_coreFFI/include/"
cp "$BINDINGS/conch_core.swift" "$ROOT/app/Sources/Conch/Generated/"
# 只放静态库：目录里如果同时有 .dylib，链接器会优先选动态库
cp "$CARGO_TARGET_DIR/release/libconch_core.a" "$CONCH_RUSTLIB_DIR/"

step "编译 Swift 界面（${CONFIG}）"
cd "$ROOT/app"
swift build --force-resolved-versions -c "$CONFIG" --scratch-path "$SWIFT_SCRATCH" ${SWIFT_FLAGS[@]+"${SWIFT_FLAGS[@]}"}
BIN_DIR="$(swift build --force-resolved-versions -c "$CONFIG" --scratch-path "$SWIFT_SCRATCH" ${SWIFT_FLAGS[@]+"${SWIFT_FLAGS[@]}"} --show-bin-path)"

step "打包 Conch.app"
APP="$ROOT/build/Conch.app"
if [ "$TESTING" = 1 ]; then APP="$ROOT/build/Conch-Test.app"; fi
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Conch" "$APP/Contents/MacOS/Conch"
cp "$ROOT/app/Info.plist" "$APP/Contents/Info.plist"
if [ "$TESTING" = 1 ]; then
  plutil -replace CFBundleIdentifier -string com.conch.gado.tests "$APP/Contents/Info.plist"
  plutil -replace CFBundleDisplayName -string "Conch Tests" "$APP/Contents/Info.plist"
  plutil -insert ConchTestBuild -bool YES "$APP/Contents/Info.plist"
fi
# 图标由 scripts/make-icon.swift 生成，改图形时才需要重新生成
cp "$ROOT/app/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
# 构建号用提交次数，每提交一次加一（“关于 Conch”里显示成 0.4.0 (5) 这样）
BUILD_NUMBER="$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 1)"
plutil -replace CFBundleVersion -string "$BUILD_NUMBER" "$APP/Contents/Info.plist"
# SwiftPM 依赖的资源包（如果有）放进 Resources，Bundle.module 能找到
for bundle in "$BIN_DIR"/*.bundle; do
  [ -e "$bundle" ] && cp -R "$bundle" "$APP/Contents/Resources/"
done
# 把开源许可证和依赖版权说明放进 App；公开分发时也随二进制提供。
"$ROOT/scripts/third-party-notices.py" --check
cp "$ROOT/LICENSE" "$APP/Contents/Resources/LICENSE.txt"
cp "$ROOT/docs/THIRD_PARTY_NOTICES.txt" "$APP/Contents/Resources/ThirdPartyNotices.txt"
# ad-hoc 签名，并打开 hardened runtime（公证要求的运行时保护），
# 让本地测试和发给别人的版本跑在一样的限制下；有 Developer ID 证书时 package.sh 会重新签名
codesign --force --options runtime --sign - "$APP" > /dev/null

echo
echo "完成：$APP"
echo "运行：open \"$APP\""
