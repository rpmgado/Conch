#!/bin/bash
# 打包成可以发给别人的安装文件：
#   build/Conch-<版本>.pkg  安装向导（推荐发这个）：双击后按“继续”“安装”，装进“应用程序”文件夹
#   build/Conch-<版本>.dmg  磁盘映像：打开后把 Conch 拖进“应用程序”
#
# 用法：scripts/package.sh
#
# 签名和公证（要 Apple 开发者账号，设置方法见 docs/DEVELOPMENT.md“签名和公证”）：
#   - 钥匙串里有“Developer ID Application”证书时，用它签名 App 和磁盘映像；
#     有“Developer ID Installer”证书时，用它签名安装包。
#     也可以用 CONCH_SIGN_IDENTITY、CONCH_INSTALLER_IDENTITY 指定证书名字。
#   - 设了 CONCH_NOTARY_PROFILE（xcrun notarytool store-credentials 存的名字）时，
#     再交给 Apple 公证，并把公证结果钉进 App、安装包和磁盘映像，离线也能通过检查。
#   - 没有证书时用 ad-hoc 签名：这台 Mac 上直接能装能用；别人第一次打开会被系统拦下，
#     要到“系统设置 → 隐私与安全性”里点“仍要打开”。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CACHE="${CONCH_BUILD_CACHE:-$ROOT/.build-cache}"

step() { printf '\n\033[1m==> %s\033[0m\n' "$1"; }
fail() { echo "$1" >&2; exit 1; }

# 钥匙串里第一个名字以 $2 开头的签名证书（只取名字）
find_identity() {
  security find-identity -v -p "$1" 2>/dev/null | sed -n "s/^.*\"\($2: .*\)\"\$/\1/p" | head -1 || true
}

APP_IDENTITY="${CONCH_SIGN_IDENTITY:-$(find_identity codesigning 'Developer ID Application')}"
PKG_IDENTITY="${CONCH_INSTALLER_IDENTITY:-$(find_identity basic 'Developer ID Installer')}"
NOTARY_PROFILE="${CONCH_NOTARY_PROFILE:-}"
if [ -n "$NOTARY_PROFILE" ] && { [ -z "$APP_IDENTITY" ] || [ -z "$PKG_IDENTITY" ]; }; then
  fail "公证要先在钥匙串里装好 Developer ID Application 和 Developer ID Installer 两个证书"
fi

CONCH_TESTING=0 "$ROOT/scripts/build.sh" release

APP="$ROOT/build/Conch.app"
PLIST="$APP/Contents/Info.plist"
if plutil -extract ConchTestBuild raw "$PLIST" >/dev/null 2>&1; then fail "不能打包测试 App"; fi
VERSION="$(plutil -extract CFBundleShortVersionString raw "$PLIST")"
BUILD="$(plutil -extract CFBundleVersion raw "$PLIST")"
BUNDLE_ID="$(plutil -extract CFBundleIdentifier raw "$PLIST")"
PKG="$ROOT/build/Conch-$VERSION.pkg"
DMG="$ROOT/build/Conch-$VERSION.dmg"
# 临时文件放在构建缓存里，不放进同步盘
WORK="$CACHE/package"
rm -rf "$WORK"
mkdir -p "$WORK"

# 交给 Apple 公证并等结果；没通过时打印 Apple 给的原因，停下
notarize() {
  local file="$1" result status id
  echo "公证 $(basename "$file")，一般要几分钟…"
  result="$(xcrun notarytool submit "$file" --keychain-profile "$NOTARY_PROFILE" --wait --output-format json)" || true
  status="$(printf '%s' "$result" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("status",""))' 2>/dev/null || true)"
  if [ "$status" != "Accepted" ]; then
    echo "$result" >&2
    id="$(printf '%s' "$result" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("id",""))' 2>/dev/null || true)"
    if [ -n "$id" ]; then xcrun notarytool log "$id" --keychain-profile "$NOTARY_PROFILE" >&2 || true; fi
    fail "公证没通过：$(basename "$file")"
  fi
  echo "公证通过"
}

step "签名 Conch.app"
if [ -n "$APP_IDENTITY" ]; then
  codesign --force --options runtime --timestamp --sign "$APP_IDENTITY" "$APP"
  echo "签名证书：$APP_IDENTITY"
else
  echo "钥匙串里没有 Developer ID Application 证书，用 ad-hoc 签名（build.sh 已经签好）"
fi
codesign --verify --deep --strict "$APP"
SIGNATURE="$(codesign --display --verbose=1 "$APP" 2>&1)"
[[ "$SIGNATURE" == *runtime* ]] || fail "Conch.app 没有打开 hardened runtime，公证不会通过"
BIN="$APP/Contents/MacOS/Conch"
[ "$(lipo -archs "$BIN")" = "arm64" ] || fail "Conch.app 应该只有 Apple 芯片（arm64）的程序，现在是：$(lipo -archs "$BIN")"
# 只能依赖系统自带的库：指向构建缓存或 Homebrew 的库，换台 Mac 就打不开了
if otool -L "$BIN" | tail -n +2 | grep -vE '^[[:space:]]*(/usr/lib/|/System/Library/)'; then
  fail "Conch 依赖了上面这些系统以外的动态库，不能单独安装"
fi
# 要按 Info.plist 里的最低系统编译，否则老系统上打不开
MIN_MACOS="$(plutil -extract LSMinimumSystemVersion raw "$PLIST")"
MINOS="$(vtool -show-build "$BIN" | awk '$1 == "minos" { print $2; exit }')"
[ "$MINOS" = "$MIN_MACOS" ] || fail "Conch 按 macOS $MINOS 编译，和 Info.plist 写的 $MIN_MACOS 不一致"
echo "签名有效，打开了 hardened runtime，只依赖系统自带的库，按 macOS $MIN_MACOS 编译"
# 把安装向导文件里的 @占位符@ 换成这次打包的实际值
fill() {
  sed -e "s/@VERSION@/$VERSION/g" -e "s/@BUNDLE_ID@/$BUNDLE_ID/g" \
      -e "s/@MIN_MACOS@/$MIN_MACOS/g" -e "s/@MIN_MACOS_NAME@/${MIN_MACOS%.0}/g" "$1"
}

if [ -n "$NOTARY_PROFILE" ]; then
  step "公证 Conch.app"
  ditto -c -k --keepParent "$APP" "$WORK/Conch.zip"
  notarize "$WORK/Conch.zip"
  # 钉进 App 本身：从磁盘映像拖出来的 App 离线也能通过检查
  xcrun stapler staple -q "$APP"
fi

step "制作安装包（安装向导）"
mkdir -p "$WORK/root" "$WORK/resources"
ditto "$APP" "$WORK/root/Conch.app"
# 固定装到 /Applications/Conch.app：
# - BundleIsRelocatable：默认设置下，安装器发现别处（比如项目的 build 目录）已经有同一个 App 时，
#   会去升级那一份，结果“应用程序”文件夹里反而没有
# - BundleHasStrictIdentifier：默认要求原来那个 Conch.app 的标识一样才覆盖，否则把新版另放进
#   Conch.localized 文件夹。0.3 及以前的标识不一样，要直接覆盖；别的同名软件由安装向导的
#   检查拦下（见 distribution.xml）
pkgbuild --analyze --root "$WORK/root" "$WORK/component.plist" > /dev/null
for index in 0 1 2 3 4 5 6 7 8 9; do
  plutil -replace "$index.BundleIsRelocatable" -bool NO "$WORK/component.plist" 2>/dev/null || break
  plutil -replace "$index.BundleHasStrictIdentifier" -bool NO "$WORK/component.plist"
done
# 装完后清掉第一版安装包可能留下的 Conch.localized（见 scripts/installer/postinstall）
mkdir -p "$WORK/scripts"
fill "$ROOT/scripts/installer/postinstall" > "$WORK/scripts/postinstall"
chmod 755 "$WORK/scripts/postinstall"
pkgbuild --root "$WORK/root" --component-plist "$WORK/component.plist" --scripts "$WORK/scripts" \
  --identifier "$BUNDLE_ID" --version "$VERSION" --install-location /Applications \
  "$WORK/Conch-app.pkg" > /dev/null
# 安装向导的页面：介绍、摘要和左下角的图标（图标由 scripts/make-icon.swift 生成）
for page in welcome.html conclusion.html; do
  fill "$ROOT/scripts/installer/$page" > "$WORK/resources/$page"
done
cp "$ROOT/scripts/installer/background.png" "$WORK/resources/"
fill "$ROOT/scripts/installer/distribution.xml" > "$WORK/distribution.xml"
if grep -q '@[A-Z_]*@' "$WORK/distribution.xml" "$WORK/resources/"*.html "$WORK/scripts/postinstall"; then
  fail "安装向导里还有没替换的 @占位符@"
fi
PKG_SIGN=()
if [ -n "$PKG_IDENTITY" ]; then PKG_SIGN=(--sign "$PKG_IDENTITY" --timestamp); fi
rm -f "$PKG"
productbuild --quiet --distribution "$WORK/distribution.xml" --resources "$WORK/resources" \
  --package-path "$WORK" ${PKG_SIGN[@]+"${PKG_SIGN[@]}"} "$PKG"
# 检查装进去的东西：Conch.app 签名完好，固定装到 /Applications/Conch.app，带着装完后的清理脚本
pkgutil --expand-full "$PKG" "$WORK/check"
codesign --verify --deep --strict "$WORK/check/Conch-app.pkg/Payload/Conch.app" || fail "安装包里的 Conch.app 签名不对"
INFO="$(cat "$WORK/check/Conch-app.pkg/PackageInfo")"
[[ "$INFO" == *'install-location="/Applications"'* && "$INFO" != *"<relocate>"* ]] || fail "安装包没有固定装到 /Applications"
[[ "$INFO" != *"<strict-identifier>"* ]] || fail "安装包遇到旧标识的 Conch 时不会覆盖"
[ -x "$WORK/check/Conch-app.pkg/Scripts/postinstall" ] || fail "安装包里没有 postinstall"
grep -q 'installation-check' "$WORK/check/Distribution" || fail "安装向导里没有同名软件的检查"
if [ -n "$PKG_IDENTITY" ]; then
  pkgutil --check-signature "$PKG" | sed -n '1,3p'
else
  echo "钥匙串里没有 Developer ID Installer 证书，安装包没有签名"
fi

step "制作磁盘映像"
STAGE="$WORK/dmg"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/Conch.app"
ln -s /Applications "$STAGE/应用程序"
rm -f "$DMG"
hdiutil create -quiet -volname "Conch $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO "$DMG"
hdiutil verify -quiet "$DMG"
if [ -n "$APP_IDENTITY" ]; then codesign --sign "$APP_IDENTITY" --timestamp "$DMG"; fi

if [ -n "$NOTARY_PROFILE" ]; then
  step "公证安装包和磁盘映像"
  for file in "$PKG" "$DMG"; do
    notarize "$file"
    xcrun stapler staple -q "$file"
  done
  step "按别人下载后的样子检查（Gatekeeper）"
  spctl --assess --type execute -vv "$APP"
  spctl --assess --type install -vv "$PKG"
  spctl --assess --type open --context context:primary-signature -vv "$DMG"
fi
rm -rf "$WORK"

size() { du -h "$1" | cut -f1 | tr -d ' '; }
echo
echo "完成：Conch ${VERSION}（构建 ${BUILD}，Apple 芯片，macOS $MIN_MACOS 以上）"
echo "  安装包    ${PKG}（$(size "$PKG")）"
echo "  磁盘映像  ${DMG}（$(size "$DMG")）"
if [ -n "$NOTARY_PROFILE" ]; then
  echo "已签名并通过 Apple 公证：别人下载后双击就能安装。"
else
  echo "没有经过 Apple 公证：在这台 Mac 上直接能装；发给别人时，对方第一次打开要到"
  echo "“系统设置 → 隐私与安全性”里点“仍要打开”。去掉这一步的办法见 docs/DEVELOPMENT.md“签名和公证”。"
fi
