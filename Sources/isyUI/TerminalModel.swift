// TerminalModel.swift - isy 终端模型
//
// 职责:
//   1. 维护终端文本缓冲 (通过 TerminalBuffer + ANSI 解析)
//   2. 处理用户输入 (回车提交, 方向键历史, Ctrl+C/D)
//   3. 桥接 isyCore ProcessManager: 把输入送到 Linux 进程 stdin, 把 stdout 追加到缓冲
//   4. demo 模式使用 BuiltinShell 提供完整 shell 体验
//
// 集成模式:
//   - 真实模式: connect(to: processManager) 后, 输入直接送 Linux 进程, 输出来自 syscall write(1)
//   - demo 模式: 使用 BuiltinShell 提供 30+ 命令, 管道, 重定向等功能

#if canImport(SwiftUI)
import Foundation
import SwiftUI
import isyCore

/// 终端会话状态
@MainActor
public final class TerminalModel: ObservableObject {

    /// 终端缓冲 (ANSI 解析)
    public let buffer: TerminalBuffer
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
    /// 进程状态
    @Published public var processState: String = "idle"
    /// 终端行更新触发器
    @Published public var linesVersion: Int = 0

    /// isy 进程管理器 (真实模式时非 nil)
    public var processManager: ProcessManager?
    /// demo 模式标志
    public var demoMode: Bool = true
    /// 内置 Shell (demo 模式)
    public var builtinShell: BuiltinShell?
    /// 最大输出行数
    public var maxLines: Int = 10000

    private let queue = DispatchQueue(label: "isy.terminal.io", qos: .userInitiated)

    public init(demoMode: Bool = true, rootfs: RootFS? = nil, cols: Int = 80, rows: Int = 24) {
        self.buffer = TerminalBuffer(cols: cols, rows: rows)
        self.demoMode = demoMode
        if demoMode {
            self.builtinShell = BuiltinShell(rootfs: rootfs)
            appendBanner()
        }
    }

    public var lines: [TerminalLine] {
        buffer.visibleLines()
    }

    public var attributedLines: [[AttributedCharacter]] {
        buffer.attributedLines()
    }

    private func appendBanner() {
        let banner = """
        \u{1B}[1;36misy 0.1.0-dev\u{1B}[0m - \u{1B}[32miOS System\u{1B}[0m
        \u{1B}[2m近原生 ARM64 Linux 用户态运行时 (load-time binary patching)\u{1B}[0m
        \u{1B}[2m输入 'help' 查看可用命令, 'isy' 查看 runtime 信息\u{1B}[0m

        """
        writeToBuffer(banner)
    }

    /// 连接真实 isy 进程管理器 (退出 demo 模式)
    public func connect(to pm: ProcessManager) {
        self.processManager = pm
        self.demoMode = false
        self.prompt = "$ "
        self.builtinShell = nil

        pm.eventHandler = { [weak self] event in
            DispatchQueue.main.async {
                self?.handleProcessEvent(event)
            }
        }
    }

    /// 断开连接
    public func disconnect() {
        processManager?.stop()
        processManager = nil
        demoMode = true
        prompt = "isy$ "
        builtinShell = BuiltinShell(rootfs: nil)
    }

    /// 处理进程事件
    private func handleProcessEvent(_ event: ProcessEvent) {
        switch event {
        case .stdout(let text):
            appendOutput(text)
        case .stderr(let text):
            appendOutput(text)
        case .stateChanged(let state):
            switch state {
            case .idle: processState = "idle"
            case .loading: processState = "loading"
            case .running: processState = "running"; isRunning = true
            case .exited(let code):
                processState = "exited(\(code))"
                isRunning = false
            case .failed(let msg):
                processState = "failed"
                isRunning = false
                writeToBuffer("\u{1B}[31m启动失败: \(msg)\u{1B}[0m\n")
            }
        case .patchComplete:
            break
        case .syscallTrace:
            break
        case .signalDelivered:
            break
        }
    }

    /// 提交当前输入 (用户按回车)
    public func submitInput() {
        let input = currentInput.trimmingCharacters(in: .newlines)
        writeToBuffer("\(prompt)\(input)\n")
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

    /// 发送 Ctrl+C (SIGINT)
    public func sendInterrupt() {
        if demoMode {
            writeToBuffer("^C\n")
        } else {
            processManager?.sendInterrupt()
            writeToBuffer("^C")
        }
    }

    /// 发送 Ctrl+D (EOF)
    public func sendEOF() {
        if demoMode {
            writeToBuffer("\u{1B}[2m(demo 模式: Ctrl+D 无效果)\u{1B}[0m\n")
        } else {
            processManager?.sendInput("\u{04}")
        }
    }

    /// 发送特殊字符 (Tab, 上下箭头等)
    public func sendSpecialChar(_ char: String) {
        if demoMode {
            // 在 demo 模式下, Tab 用于补全
            if char == "\t" {
                // 简单文件名补全
                currentInput = autoComplete(currentInput)
                return
            }
            currentInput += char
        } else {
            processManager?.sendInput(char)
        }
    }

    /// 插入特殊字符到输入
    public func insertText(_ text: String) {
        currentInput += text
    }

    /// 简单的文件名补全
    private func autoComplete(_ input: String) -> String {
        guard let shell = builtinShell else { return input }
        let parts = input.split(separator: " ")
        let lastPart = parts.last.map(String.init) ?? input
        let dir: String
        let prefix: String
        if lastPart.contains("/") {
            let p = (lastPart as NSString)
            dir = shell.env.hostPath(shell.env.resolve(p.deletingLastPathComponent))
            prefix = p.lastPathComponent
        } else {
            dir = shell.env.hostPath(shell.env.cwd)
            prefix = lastPart
        }

        guard let items = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return input }
        let matches = items.filter { $0.hasPrefix(prefix) }
        if matches.count == 1 {
            let completion = matches[0]
            if parts.count > 1 {
                let rest = parts.dropLast().joined(separator: " ")
                if lastPart.contains("/") {
                    let dirPart = (lastPart as NSString).deletingLastPathComponent
                    return rest + " " + dirPart + "/" + completion
                }
                return rest + " " + completion
            }
            return completion
        } else if matches.count > 1 {
            // 显示所有匹配
            writeToBuffer("\n\(matches.joined(separator: "  "))\n\(prompt)\(input)")
            return input
        }
        return input
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

    /// 追加输出
    public func appendOutput(_ text: String) {
        writeToBuffer(text)
    }

    /// 写入终端缓冲 (ANSI 解析)
    private func writeToBuffer(_ text: String) {
        buffer.write(text)
        linesVersion += 1
    }

    /// 清屏
    public func clearScreen() {
        buffer.reset()
        linesVersion += 1
    }

    /// 终端大小变更
    public func resizeTerminal(cols: Int, rows: Int) {
        buffer.resize(cols: cols, rows: rows)
        processManager?.sendWindowChange(rows: UInt16(rows), cols: UInt16(cols))
        linesVersion += 1
    }

    // MARK: - demo 模式命令执行 (使用 BuiltinShell)

    private func executeDemoCommand(_ raw: String) {
        isRunning = true
        let shell = self.builtinShell
        queue.async { [weak self] in
            guard let self = self else { return }
            let output: String
            if let shell = shell {
                output = shell.execute(raw)
            } else {
                output = "BuiltinShell not available"
            }
            let finalOutput = output.isEmpty ? "" : output + (output.hasSuffix("\n") ? "" : "\n")
            DispatchQueue.main.async {
                self.writeToBuffer(finalOutput)
                self.isRunning = false
            }
        }
    }

    // MARK: - 真实模式 (连接 isyCore)
    private func executeRealCommand(_ raw: String) {
        processManager?.sendInput(raw + "\n")
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