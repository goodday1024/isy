// swift-tools-version: 6.0
// isy - iOS System
// 近原生 ARM64 Linux 用户态运行时，基于 load-time binary patching
//
// 架构:
//   isyCore   跨平台 Swift 核心库 (ELF/Syscall/Memory 等纯逻辑, 可在 Linux 单测)
//   isyCHot   C 热点代码 (threaded dispatch loop / NEON 直通 / ARM64 helpers)
//             非 arm64 平台编译为 stub, 保证跨平台可编译
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
                .define("ISY_BUILD", to: "1")
            ]
        ),
        .target(
            name: "isyCore",
            dependencies: ["isyCHot"],
            path: "Sources/isyCore",
            swiftSettings: [
                .unsafeFlags(["-O", "-whole-module-optimization"], .when(configuration: .release))
            ]
        ),
        .target(
            name: "isyUI",
            dependencies: ["isyCore"],
            path: "Sources/isyUI"
        ),
        .executableTarget(
            name: "isycli",
            dependencies: ["isyCore"],
            path: "Sources/isycli"
        ),
        .testTarget(
            name: "isyCoreTests",
            dependencies: ["isyCore"],
            path: "Tests/isyCoreTests"
        )
    ]
)
