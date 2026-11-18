// swift-tools-version: 6.0
//
// Conch 的 macOS 界面层。Rust 内核（../core）编译成静态库，由 scripts/build.sh
// 放到构建缓存目录（通过 CONCH_RUSTLIB_DIR 传进来）；UniFFI 生成的头文件和
// Swift 绑定也由 build.sh 拷进来，不要手改。

import PackageDescription

let rustLibDir = Context.environment["CONCH_RUSTLIB_DIR"] ?? (Context.packageDirectory + "/RustLib")

let package = Package(
    name: "Conch",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", from: "1.2.0"),
    ],
    targets: [
        // UniFFI 生成的 C 头文件 + modulemap，Swift 绑定通过它调用 Rust
        .target(name: "conch_coreFFI", path: "Sources/conch_coreFFI"),
        // 不依赖界面的部分：会话模型、ssh_config / Xshell 导入、快速连接解析、日志过滤、配色
        .target(name: "ConchKit", path: "Sources/ConchKit"),
        .executableTarget(
            name: "Conch",
            dependencies: [
                "ConchKit",
                "conch_coreFFI",
                .product(name: "SwiftTerm", package: "SwiftTerm"),
            ],
            path: "Sources/Conch",
            linkerSettings: [
                .unsafeFlags(["-L", rustLibDir]),
                .linkedLibrary("conch_core"),
                .linkedLibrary("iconv"),
            ]
        ),
        .testTarget(name: "ConchKitTests", dependencies: ["ConchKit"], path: "Tests/ConchKitTests"),
    ],
    // UniFFI 生成的绑定还没完全适配 Swift 6 的严格并发检查
    swiftLanguageModes: [.v5]
)
