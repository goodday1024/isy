// TerminalModel.swift - isy 终端模型
//
// 职责:
//   1. 维护终端文本缓冲 (行 + 光标位置)
//   2. 处理用户输入 (回车提交, 方向键历史)
//   3. 桥接 isyCore Emulator: 把输入送到 Linux 进程 stdin, 把 stdout 追加到缓冲
//   4. 解析 ANSI 转义序列 (颜色/光标移动) -> AttributedString
//
// 集成模式:
//   - 真实模式: connect(to: Emulator) 后, 输入直接送 Linux 进程, 输出来自 syscall write(1)
//   - demo 模式: 内置 echo/help/ls/uname 等命令, 用于 UI 独立预览 (无 rootfs 时)
//
// 注意: isyCore 的 Emulator.run() 是同步阻塞的. 真实模式下需要:
//   - 后台线程跑 Emulator.run()
//   - 主线程通过 DispatchQueue.main 更新 UI
//   - 用管道/缓冲区在两线程间传 I/O

#if canImport(SwiftUI)
import Foundation
import SwiftUI
import isyCore

/// 终端会话状态
@MainActor
public final class TerminalModel: ObservableObject {

    /// 终端行 (已提交的输出 + 当前输入行)
    @Published public var lines: [TerminalLine] = []
    /// 当前输入缓冲 (未提交)
    @Published public var currentInput: String = ""
    /// 命令历史
    @Published public private(set) var history: [String] = []
    /// 历史浏览位置 (nil = 当前输入)
    @Published public var historyIndex: Int? = nil
    /// 是否正在执行命令
    @Published public var isRunning: Bool = false
    /// 提示符
    @Published public var prompt: String = "isy$ "

    /// isy 进程 (真实模式时非 nil)
    public var process: LinuxProcess?
    /// demo 模式标志
    public var demoMode: Bool = true

    private let queue = DispatchQueue(label: "isy.terminal.io", qos: .userInitiated)

    public init(demoMode: Bool = true) {
        self.demoMode = demoMode
        if demoMode {
            lines.append(TerminalLine(text: "isy 0.1.0-dev - iOS System", style: .title))
            lines.append(TerminalLine(text: "近原生 ARM64 Linux 用户态运行时 (load-time binary patching)", style: .dim))
            lines.append(TerminalLine(text: "输入 'help' 查看可用命令, 'isy' 查看 runtime 信息", style: .dim))
            lines.append(TerminalLine(text: ""))
        }
    }

    /// 连接真实 isy 进程 (退出 demo 模式)
    public func connect(to process: LinuxProcess) {
        self.process = process
        self.demoMode = false
        self.prompt = "isy:\(process.cwd)$ "
    }

    /// 提交当前输入 (用户按回车)
    public func submitInput() {
        let input = currentInput
        lines.append(TerminalLine(text: prompt + input, style: .prompt))
        if !input.isEmpty {
            history.append(input)
        }
        historyIndex = nil
        currentInput = ""

        if demoMode {
            executeDemoCommand(input)
        } else {
            executeRealCommand(input)
        }
    }

    /// 从历史中选取
    public func navigateHistory(_ direction: HistoryDirection) {
        guard !history.isEmpty else { return }
        switch direction {
        case .up:
            let idx = historyIndex ?? history.count
            if idx > 0 {
                historyIndex = idx - 1
                currentInput = history[historyIndex!]
            }
        case .down:
            guard let idx = historyIndex else { return }
            if idx < history.count - 1 {
                historyIndex = idx + 1
                currentInput = history[historyIndex!]
            } else {
                historyIndex = nil
                currentInput = ""
            }
        }
    }

    /// 追加输出 (供 Emulator 回调)
    public func appendOutput(_ text: String, style: TerminalLineStyle = .normal) {
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            lines.append(TerminalLine(text: String(line), style: style))
        }
    }

    // MARK: - demo 模式命令执行
    private func executeDemoCommand(_ raw: String) {
        let parts = raw.split(separator: " ").map(String.init)
        guard let cmd = parts.first?.lowercased(), !cmd.isEmpty else { return }
        isRunning = true

        queue.async { [weak self] in
            let output: [String]
            switch cmd {
            case "help":
                output = [
                    "isy 内置命令 (demo 模式):",
                    "  help     显示此帮助",
                    "  isy      显示 isy 运行时信息",
                    "  ls       列出虚拟目录",
                    "  uname    显示系统信息",
                    "  echo     回显参数",
                    "  bench    跑 BinaryPatcher 微基准",
                    "  clear    清屏",
                    "  exit     退出 (iOS App 上不可用)",
                    "",
                    "真实模式 (连接 isyCore Emulator) 下, 此处显示 Linux 进程输出.",
                ]
            case "isy":
                output = [
                    "isy 0.1.0-dev - iOS System",
                    "  架构: ARM64 Linux -> iOS ARM64 近原生",
                    "  核心创新: load-time binary patching (SVC #0 -> BL __isy_syscall_trap)",
                    "  执行模型: 99.99% 指令原生执行, 仅 syscall 边界陷入翻译层",
                    "  合规性: 不写可执行页 (W^X), 非 JIT, 符合 App Store 规则",
                    "  性能: patch 吞吐 ~300 MB/s, syscall 开销 < 真实内核切换",
                ]
            case "ls":
                output = ["bin   etc   lib   root  tmp   usr   var", "dev   home  proc  sbin  sys   opt"]
            case "uname":
                output = ["Linux isy 5.15.0-isy #1 aarch64 aarch64 aarch64 GNU/Linux"]
            case "echo":
                output = [parts.dropFirst().joined(separator: " ")]
            case "bench":
                let throughput = self?.runPatcherBenchDemo() ?? 0
                output = [
                    "BinaryPatcher 微基准 (1M 指令, 1% SVC):",
                    String(format: "  吞吐: %.1f MB/s", throughput),
                    String(format: "  等效: 10MB ELF patch 耗时 %.1f ms", 10 * 1024 / Double(throughput)),
                ]
            case "clear":
                DispatchQueue.main.async { self?.lines.removeAll() }
                return
            case "exit":
                output = ["exit: 在真实模式下退出当前 shell"]
            default:
                output = ["\(cmd): command not found (demo 模式, 输入 help 查看可用命令)"]
            }
            DispatchQueue.main.async {
                for line in output {
                    self?.lines.append(TerminalLine(text: line, style: .output))
                }
                self?.isRunning = false
            }
        }
    }

    /// demo 模式 patcher 基准
    private func runPatcherBenchDemo() -> Double {
        let count = 1_000_000
        var insns = [UInt32](repeating: 0xD503201F, count: count)
        for i in stride(from: 0, to: count, by: 100) { insns[i] = 0xD4000001 }
        let config = PatchConfig(trapAddress: 0x10000)
        let start = Date()
        do {
            try insns.withUnsafeMutableBufferPointer { ptr in
                var table = PatchTable()
                try BinaryPatcher.patchSegment(ptr, baseVA: 0x400000, config: config,
                                               segmentIndex: 0, into: &table)
            }
        } catch { return 0 }
        let elapsed = Date().timeIntervalSince(start)
        return Double(count * 4) / 1024 / 1024 / elapsed
    }

    // MARK: - 真实模式 (连接 isyCore)
    private func executeRealCommand(_ raw: String) {
        // 真实模式下: 把命令送到 Linux 进程的 stdin (通过 pipe fd)
        // 当前骨架: 调用 isyCore Emulator 执行. 完整实现需要:
        //   1. 把 raw + "\n" 写到 process 的 stdin fd
        //   2. Linux shell (busybox/bash) 读取并执行
        //   3. shell 的 stdout 通过 write(1) 回调 appendOutput
        // 这里预留接口, 实际 I/O 桥接在 ProcessManager.swift 完成
        appendOutput("(真实模式待启用: 需要加载 Linux rootfs + shell ELF)", style: .dim)
    }
}

/// 终端行 (带样式)
public struct TerminalLine: Identifiable, Hashable {
    public let id = UUID()
    public let text: String
    public let style: TerminalLineStyle

    public init(text: String, style: TerminalLineStyle = .normal) {
        self.text = text
        self.style = style
    }
}

/// 终端行样式
public enum TerminalLineStyle: Hashable {
    case normal
    case prompt
    case output
    case title
    case dim
    case error
    case success
}

public enum HistoryDirection {
    case up, down
}

#endif // canImport(SwiftUI)
