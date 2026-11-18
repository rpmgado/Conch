# 安全问题 / Security

目前只维护最新正式版本。Conch 不是终端、SSH 或密码学库的安全审计替代品。
Only the latest release receives fixes. Do not use legacy SSH algorithms or Telnet on untrusted networks.

## 私密报告 / Private reporting

仓库启用 GitHub 私密漏洞报告后，请在 **Security → Report a vulnerability** 报告。
若该入口尚未启用，可以先开一个仅说明“需要私密安全联系渠道”的 Issue；不要公开漏洞利用细节、真实主机、账号、日志、密码或密钥。

Use GitHub private vulnerability reporting when enabled. If unavailable, request a private contact channel in an issue without disclosing vulnerability details or sensitive information.

请提供：Conch 版本、macOS 版本、影响范围、最小复现步骤、预期行为及实际结果。仅在自有或获授权的测试环境中验证。
Include the version, affected behavior, and a minimal reproduction using systems you own or are authorized to test.

## 当前边界 / Current limitations

Touch ID 开关提供应用内身份验证，钥匙串项目仍采用系统默认访问控制；它不是每个项目独立的硬件访问控制策略。
The Touch ID option is an in-app authentication gate. Keychain items retain the system's default access control; per-item hardware-backed access policies are not implemented.


- 正式 App 忽略自动信任主机、模拟验证等测试环境变量；测试钩子只在独立测试构建中启用。
- 密码保存在 macOS 钥匙串；身份验证不可用或被拒绝时，不能读取保存的密码。
- SFTP 使用临时文件；部分服务器替换旧文件时需要备份和回滚，不保证路径全程原子可见。失败信息会给出恢复位置。
- 下载、上传及远程编辑需要对目标目录有相应写入权限。符号链接不自动递归传输；ACL、扩展属性及硬链接关系不保证保留。
- 会话同步使用普通文件夹，不提供跨 Mac 分布式事务；冲突副本保存在本机。
- 发布者尚未配置 Developer ID 和公证时，发布说明应注明安装包的签名与公证状态。

Saved passwords remain in Keychain. SFTP replacement may require a backup/rollback sequence on older servers. ACLs, extended attributes and hard-link relationships are not guaranteed to survive file replacement. Folder sync is not a distributed database. Release notes should state the signing and notarization status of the installer.
