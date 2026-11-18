# 参与 Conch / Contributing

Conch 面向 Apple 芯片 Mac 的 SSH 与网络设备运维场景，欢迎提交小而聚焦的改动。
Conch is an SSH client for macOS on Apple silicon. Small, focused contributions are welcome.

## 开发 / Development

1. 使用官方 rustup 工具链和 Xcode 27.2 / Command Line Tools 27.2（Swift 6.4）。Rust 版本见 `core/rust-toolchain.toml`。
2. 运行 `scripts/build.sh`，再用 `open build/Conch.app` 启动。
3. Rust 代码在 `core/src/`，纯 Swift 模型在 `app/Sources/ConchKit/`，UI 在 `app/Sources/Conch/`。
4. 不要手改 `Generated/`、FFI 头文件或提交 `.build-cache/`、`.session-archive/`、安装包和个人会话数据。

Use the official rustup toolchain and Swift 6.4. Run `scripts/build.sh`. Generated bindings and local caches must not be committed.

## 验证 / Validation

```bash
scripts/ci.sh              # 构建、模型单元测试、本机核心场景、许可证与架构检查
scripts/test-sshd.sh start
CONCH_TESTING=1 scripts/build.sh  # 独立测试 App / isolated test app
scripts/app-e2e.sh         # 需要桌面会话，会将测试 App 切到前台
scripts/test-sshd.sh stop
```

UI 测试使用独立数据目录和测试钥匙串，不要改成使用真实服务器或密码。文件传输修改要验证失败、取消、覆盖和权限；认证修改要验证拒绝和不可用路径。UI 修改附上使用示例数据的截图。

Run `scripts/ci.sh` before a pull request. UI tests require a desktop session. Cover failures as well as successful operations, especially for transfers and authentication. Use demo data in screenshots.

## 提交 PR / Pull requests

说明触发场景、修改后的行为和验证结果。修 Bug 时提供可复现步骤；功能请求先说明用户遇到的问题。保持现有原生架构和 macOS 14 部署目标。不要顺带升级依赖或混入无关格式化。

Describe the trigger, resulting behavior, and validation. Keep changes focused. Preserve the native architecture and macOS 14 deployment target. Include your own work under the repository's MIT license; keep third-party notices intact.

安全问题请按照 [SECURITY.md](SECURITY.md) 报告。
