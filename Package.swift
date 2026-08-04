// swift-tools-version: 6.0
// isy - iOS System
// 近原生 ARM64 Linux 用户态运行时，基于 load-time binary patching
//
// 架构:
//   isyCore   跨平台 Swift 核心库 (ELF/Syscall/Memory 等纯逻辑, 可在 Linux 单测)
//   isyCHot   C 热点代码 (naked syscall trap / NEON / ARM64 helpers)
//             非 arm64 平台编译为 stub, 保证跨平台可编译
//             cSettings: -fno-lto 防止 xcodebuild archive 时 SPM Clang target
//             的 '-r -object_path_lto' 预链接消除 naked 函数引用的符号.
//             另外通过 isy_runtime_anchor() 被 Swift 显式调用来创建 IR 层面
//             的符号引用, 进一步防止 LTO 误判.
//   isyUI     SwiftUI 终端 UI
//   isycli    命令行宿主, 用于在 Linux/macOS 上跑核心逻辑基准测试
//   isyApp    iOS App target (SwiftUI Terminal UI), 仅在 Darwin/iOS 上构建 (Xcode 工程)

import PackageDescription

let package = Package(
    name: "isy",
    platforms: [
        .iOS(.v17),
        .macOS(.v13)
    ],
    products: [
        .library(name: "isyCore", targets: ["isyCore"]),
        .library(name: "isyCHot", targets: ["isyCHot"]),
        .library(name: "isyUI", targets: ["isyUI"])
    ],
    targets: [
        .target(
            name: "isyCHot",
            path: "Sources/isyCHot",
            publicHeadersPath: "include",
            cSettings: [
                .define("_GNU_SOURCE"),
                .define("ISY_BUILD", to: "1"),
                // 关键: 禁用 LTO bitcode 生成, 防止 SPM 的 '-r -object_path_lto'
                // 预链接步骤消除 naked 函数汇编中 bl 引用的符号.
                .unsafeFlags(["-fno-lto"])
            ]
        ),
        .target(
            name: "isyCore",
            dependencies: ["isyCHot"],
            path: "Sources/isyCore"
        ),
        .target(
            name: "isyUI",
            dependencies: ["isyCore"],
            path: "Sources/isyUI"
        ),
        .executableTarget(
            name: "isycli",
            dependencies: ["isyCore", "isyCHot"],
            path: "Sources/isycli"
        ),
        .testTarget(
            name: "isyCoreTests",
            dependencies: ["isyCore", "isyCHot"],
            path: "Tests/isyCoreTests"
        )
    ]
)
