# 发布准备 / Release preparation

## 构建基准

- Apple silicon / arm64；部署目标 macOS 14。
- 官方 Rust **1.99.1**，Cargo.lock 使用 `--locked`。
- Swift **6.4**；本机使用 Command Line Tools 27.2。CI 选择 Xcode 27.2。
- SwiftPM 使用 `--force-resolved-versions`，依赖由 `app/Package.resolved` 固定。
- CI 运行在 GitHub 官方 `xcode-27` Arm64 镜像。该标签目前属于预览镜像，升级镜像或 Xcode 后需要重新验证；[已核对的镜像清单](https://github.com/actions/runner-images/blob/main/images/macos/xcode-27-arm64-Readme.md)。

CI 配置已提供，但必须在仓库实际上传后查看 Actions 运行结果，不能把本地通过当成 GitHub 已通过。

## 发布流程

1. 检查 `git status`，把本次发布所需的新文件和修改一并提交。检查提交身份是否使用希望公开的邮箱；不自动重写历史。
2. 在干净检出目录运行 `scripts/ci.sh`。先运行 `CONCH_TESTING=1 scripts/build.sh`，再在可交互桌面运行 `scripts/app-e2e.sh`，并人工检查输入法、辅助功能和系统拖放。
3. 更新版本、CHANGELOG、README 的已知限制与验证范围。
4. 更新依赖时重新生成第三方说明：`scripts/third-party-notices.py`。
5. 运行 `scripts/package.sh`；生成 PKG、DMG 后在 `build/` 中执行 `shasum -a 256 Conch-版本.pkg Conch-版本.dmg`，发布校验值。
6. 在另一台支持范围内的 Mac 检查全新安装、覆盖升级、首次连接、本地网络权限与钥匙串提示。macOS 14 真机验证单独记录。
7. 建立对应 Git 标签（本次为 `v0.4.2`），创建正式 GitHub Release，上传安装包和 SHA-256。不要上传 `.session-archive`、`.build-cache`、真实会话或测试密钥。
8. 启用 GitHub 私密漏洞报告，让 SECURITY.md 中的入口实际可用。

自动工作流只做验证和保存 CI 日志，不自动发布 Release、推送代码或使用签名密钥。

## 签名和已知限制

未配置 Developer ID 时，App 使用 ad-hoc 签名，PKG 没有开发者签名，也没有 Apple 公证。发布页面必须说明首次安装可能需要用户手动允许；不能承诺所有系统上“双击无提示”。签名配置参见 [开发文档](DEVELOPMENT.md#签名和公证让别人双击就能装)。

SFTP 替换是文件级的，整个文件夹不是一个事务。标准 SFTP 服务器通过备份再改名完成替换，路径可能短暂不可见；网络中断时必须核对错误中列出的目标、临时文件及备份，不要盲目删除备份。覆盖需要目标目录写权限；不自动跟随符号链接。仅保留协议提供的 POSIX 权限和 UID/GID，ACL、扩展属性及硬链接关系不保证保留。同一次 App 运行中重试会复用临时文件并校验全部已有前缀；退出后没有持久化传输队列，临时文件位置仍可从错误信息取得。

会话同步不是跨 Mac 的分布式事务；真实双 Mac 同步、真实串口硬件、Touch ID 与老系统仍需实机验证。

## English summary

Use Rust 1.99.1, Swift 6.4/Xcode 27.2 and the committed lockfiles. CI uses the official `xcode-27` arm64 preview image and will run after the repository is uploaded. Run CI and desktop tests, review the commit identity that will be public, publish the release artifacts with SHA-256, and enable private vulnerability reporting. Never upload caches, private sessions, or test credentials. State the installer’s signing and notarization status. Remote SFTP replacement may need backup/rollback, and folder transfers are not atomic transactions.

正式 App 会忽略测试环境变量。仅显式测试构建启用测试钩子，产物为 `Conch-Test.app`，应用标识与钥匙串服务均独立；打包脚本强制使用正式构建。
