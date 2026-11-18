# Changelog / 更新记录

## 0.4.2 — 2026-11-18

- SFTP writes to temporary files, preserves originals on read failure/cancellation, validates resume prefixes, and uses backup/rollback for remote replacement.
- Saved credentials are denied when device authentication is unavailable.
- Connection settings are prioritized; advanced options are collapsible and protocol controls have distinct accessible labels.
- File panels have explicit local/remote titles, selection counts, and an expanded side-by-side view.
- Production labels remain visible across themes; sidebar density and settings readability improve.
- Commands from the compose bar follow its selected destination even when terminal broadcast input is enabled.
- Locked dependency builds, CI workflow, contribution/security guidance, issue templates and bundled third-party notices.

- 修复覆盖传输失败清空原文件、续传只比较大小及身份验证不可用时放行的问题。
- 优化表单、文件对照、生产环境提示、侧边栏密度及设置可读性。
- 撰写栏按所选范围发送命令，即使终端同步输入已开启。
- 补齐正式发布所需的构建验证与协作说明。

详细实现与验证见 [0.4.2 修复记录](docs/FIXES-0.4.2.md)。

已知限制见[中文 README](README.zh-CN.md)和[安全说明](SECURITY.md)。
See the [English README](README.md) and [security policy](SECURITY.md) for known limitations.

## 0.4.1 — 2026-11-17

Focus, tab scrolling, pane controls, local file browser, offline session reconciliation, command quoting, and connection-scoped drag handling. See [detailed notes](docs/FIXES-0.4.1.md).
