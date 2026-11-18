# Third-party software / 第三方软件

Conch 自有代码采用 MIT。依赖继续使用各自的许可证；不能把整个依赖树都视为 MIT。
Conch's own code is MIT-licensed. Dependencies retain their respective licenses.

完整的版本清单、源代码下载地址、许可表达式及版权文本见 [生成的许可证材料](docs/THIRD_PARTY_NOTICES.txt)。该文件会复制到 App 的 `Contents/Resources/ThirdPartyNotices.txt`。
The generated inventory includes source URLs and full notice texts and is bundled with the app.

- russh / russh-sftp: Apache-2.0.
- UniFFI: MPL-2.0. The exact-version source download links are included in the inventory. Conch does not modify the UniFFI source files.
- SwiftTerm, Tokio and other dependencies: see the exact declared licenses and texts in the inventory.
- Rust transitive dependencies are resolved for `aarch64-apple-darwin`; the inventory also includes build-time tools and SwiftPM dependencies.

更新依赖后运行 `scripts/third-party-notices.py`。CI 使用 `--check` 检查材料是否同步更新。少数 crate 包没有携带许可证文件；生成器使用相应标准许可全文，并保留源码头部版权信息与源码获取链接。多许可证包的可选许可选择也记录在清单里。

Run the generator after changing lockfiles. CI checks for drift. If a crate omits license files, the generator includes the applicable standard license text, source copyright lines, and the exact source URL.
