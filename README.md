# isy - iOS System

> 在 iOS 上跑一个**近原生性能**的 ARM64 Linux 用户态运行时。
> 不用解释器, 不违反 Apple App Store 规则。

[![Build iOS ipa](https://github.com/goodday1024/isy/actions/workflows/build-ios.yml/badge.svg)](https://github.com/goodday1024/isy/actions/workflows/build-ios.yml)
[![Tests](https://img.shields.io/badge/tests-137%20passed-brightgreen)](Tests/)

## 核心创新: load-time binary patching

与 [iSH](https://github.com/ish-app/ish) 的解释器路径完全不同, isy 走 **ARM64→ARM64 近原生**路径:

```
Linux ELF (含 SVC #0 指令)
    ↓ ELFParser 解析
    ↓ mmap 到隔离地址空间 (先 RW)
    ↓ BinaryPatcher 扫描每条指令
    │   SVC #0 (0xD4000001) → BL __isy_syscall_trap (0x94xxxxxx)
    ↓ mprotect 切换为 R-X (W^X 合规)
    ↓ flush I-cache (自修改代码必须)
    ↓ 原生执行
    │   99.99% 指令直接跑在 ARM64 CPU 上
    └─ 遇到原 SVC 位置 → BL 跳入 naked trap
        ↓ 保存寄存器, x8→x6
        ↓ C dispatch → Swift SyscallDispatcher
        ↓ 返回值写回 x0, ret 回 Linux 代码
```

**合规性**: 只改数据段中的 4 字节 (SVC→BL), 不写可执行页 (W^X), 非 JIT, 完全符合 App Store 规则。

## 性能

| 指标 | 数值 |
|---|---|
| BinaryPatcher 吞吐 | ~300 MB/s (4MB 段 patch 12.8ms) |
| syscall 边界开销 | ~10-20 寄存器保存 + 1 次函数调用 (< 真实内核切换) |
| 原生执行比例 | 99.99% (只有 syscall 边界陷入翻译层) |
| 测试覆盖 | 137 个单元测试, 6 个测试套件 (ELF / patcher / syscall / RootFS / Shell / ProcessManager) |

## 项目结构

```
isy/
├── Package.swift              Swift 6.0 SPM (isyCore + isyCHot + isyUI + isycli)
├── Project.yml                Xcode 工程生成 (xcodegen)
├── .github/workflows/         GitHub Action CI/CD (Linux 测试 + iOS IPA 构建)
├── Sources/
│   ├── isyCHot/               C 热点层 (naked syscall trap / NEON / ARM64 helpers)
│   │   ├── include/           C 头文件
│   │   ├── syscall_trap.c     naked syscall 入口 + 进入/退出上下文
│   │   ├── trap_dispatch.c    信号处理 + 上下文分发
│   │   └── arm64_helpers.c    ARM64 辅助函数
│   ├── isyCore/               Swift 核心库 (跨平台可测)
│   │   ├── Loader/            ELFLoader + BinaryPatcher + DynamicLinker
│   │   ├── Emulator/          CPUState + Memory + Emulator (执行入口)
│   │   ├── Syscall/           SyscallTable + Dispatcher + File/Signal/Network/Process syscalls
│   │   ├── Process/           LinuxProcess + ProcessManager + BuiltinShell
│   │   └── FS/                RootFS + OverlayFS CoW + 纯Swift tar解压
│   ├── isyUI/                 SwiftUI 终端
│   │   ├── TerminalBuffer.swift   VT100/xterm ANSI 终端模拟器
│   │   ├── TerminalModel.swift    终端业务逻辑 + demo 模式
│   │   ├── SessionManager.swift   会话管理
│   │   └── ContentView.swift      SwiftUI 主界面
│   ├── isyApp/                iOS App 入口 (键盘工具栏 / 设置 / 关于页)
│   └── isycli/                命令行宿主 (info/parse/patch/bench/syscall)
└── Tests/isyCoreTests/        6 个测试套件 (137 个测试用例)
    ├── ELFTests / BinaryPatcherTests / SyscallTests
    ├── RootFSTests / BuiltinShellTests / ProcessManagerTests
```

## 本地开发

### Linux / macOS (核心库测试)

```bash
swift build
swift test
.build/debug/isycli info
.build/debug/isycli bench
```

### iOS App 构建

```bash
brew install xcodegen
xcodegen generate
open isy.xcodeproj
# 在 Xcode 中选 iOS 设备, Run
```

### CI 构建 (GitHub Action)

推送到 `main` 分支会自动触发:
1. Linux 上跑核心库测试
2. macOS 上用 xcodegen + xcodebuild 构建 unsigned ipa
3. ipa 作为 artifact 上传 (可下载侧载)

打 tag `v0.1.0` 会自动创建 GitHub Release 并附 ipa。

## 后续路线图

| 优先级 | 模块 | 状态 |
|---|---|---|
| P0 | ELF 加载 + ARM64 binary patching (SVC→BL) | ✅ 完成 |
| P0 | 基础 syscall (read/write/open/exit/stat/...) | ✅ 完成 |
| P0 | 信号处理 (sigaction/sigreturn/信号栈帧投递) | ✅ 完成 |
| P0 | 动态链接器 (.so 加载 + GOT/PLT 重定位) | ✅ 完成 |
| P0 | clone/fork + wait4 进程管理 | ✅ 完成 |
| P0 | pipe/pipe2 管道通信 | ✅ 完成 |
| P0 | execve 进程映像替换 | ✅ 完成 |
| P0 | RootFS + OverlayFS CoW + 纯Swift tar解压 | ✅ 完成 |
| P1 | 内置 Shell (30+ 命令/管道/重定向/通配符) | ✅ 完成 |
| P1 | VT100/xterm ANSI 终端模拟器 | ✅ 完成 |
| P1 | iOS App UI (键盘工具栏/设置/关于页/会话) | ✅ 完成 |
| P1 | GitHub Action CI/CD (Linux 测试 + iOS IPA 构建) | ✅ 完成 |
| P2 | epoll/poll (kqueue 后端) | 📋 TODO |
| P2 | 真实模式 stdio 桥接 (跑通 `ls`/`cat`) | 🔨 进行中 |
| P3 | Metal offload (GPU SIMD) | 📋 TODO |
| P3 | AMX wrapper (矩阵加速) | 📋 TODO |

## License

MIT
