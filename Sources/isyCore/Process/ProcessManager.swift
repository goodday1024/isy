// ProcessManager.swift - isy 进程执行管理
//
// 职责:
//   1. 在后台线程跑 Emulator.run() (不阻塞 UI)
//   2. 桥接 stdio: 把用户输入送到 Linux 进程 stdin, 把 stdout/stderr 回调到 UI
//   3. 管理 pipe fd: stdin/stdout/stderr 用 isy 内部 PipeEnd 实现
//   4. 信号投递: 把 UI 信号 (如 Ctrl+C) 转为 Linux 信号
//   5. 进程生命周期: 启动/退出/重启
//
// 线程模型:
//   - 主线程 (MainActor): UI 更新, 用户输入
//   - 后台线程 (isy.process): Emulator.run() 阻塞执行 Linux 代码
//   - 同步: 用串行 DispatchQueue + 缓冲队列, 避免锁

import Foundation
import isyCore
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// 进程状态
public enum ProcessState: Equatable, Sendable {
    case idle
    case loading
    case running
    case exited(code: Int32)
    case failed(String)
}

/// 进程事件 (通过 AsyncStream 投递给 UI)
public enum ProcessEvent: Sendable {
    case stdout(String)
    case stderr(String)
    case stateChanged(ProcessState)
    case patchComplete(records: Int)
    case syscallTrace(name: String, result: Int64)
}

/// 进程管理器 (在 Linux/macOS 测试环境也能跑, 用于验证 stdio 桥接)
public final class ProcessManager: @unchecked Sendable {

    public var emulator: Emulator?
    public var process: LinuxProcess?
    public private(set) var state: ProcessState = .idle

    /// stdin pipe (UI 写入, Linux 读取)
    public var stdinPipe: PipeEnd?
    /// stdout pipe (Linux 写入, UI 读取)
    public var stdoutPipe: PipeEnd?
    /// stderr pipe
    public var stderrPipe: PipeEnd?

    /// 事件回调 (UI 端设置). nonisolated(unsafe): 调用方保证不在执行期间更换
    nonisolated(unsafe) public var eventHandler: (@Sendable (ProcessEvent) -> Void)?

    /// 后台执行队列
    private let execQueue = DispatchQueue(label: "isy.process.exec", qos: .userInitiated)
    /// I/O 读取队列 (轮询 stdout pipe)
    private let ioQueue = DispatchQueue(label: "isy.process.io", qos: .userInitiated)
    private var ioTimer: DispatchSourceTimer?

    public init() {}

    /// 启动一个 Linux 进程 (加载 ELF + 执行)
    /// - Parameters:
    ///   - elfData: 主程序 ELF 字节
    ///   - argv: 参数
    ///   - envp: 环境变量
    public func start(elfData: Data, argv: [String] = [], envp: [String] = []) {
        updateState(.loading)
        execQueue.async { [weak self] in
            guard let self = self else { return }
            do {
                let emu = Emulator()
                self.emulator = emu
                self.process = emu.process
                self.setupStdio(process: emu.process)
                try emu.loadMain(elfData, argv: argv, envp: envp)
                self.eventHandler?(.patchComplete(records: emu.patchTable.records.count))
                self.startIOPolling()
                self.updateState(.running)
                let code = emu.run()
                self.stopIOPolling()
                self.updateState(.exited(code: code))
            } catch {
                self.updateState(.failed(String(describing: error)))
            }
        }
    }

    /// 发送输入到 Linux 进程 stdin
    public func sendInput(_ text: String) {
        guard let pipe = stdinPipe else { return }
        let bytes = Array(text.utf8)
        bytes.withUnsafeBufferPointer { buf in
            _ = pipe.write(from: UnsafeRawPointer(buf.baseAddress!), max: buf.count)
        }
    }

    /// 发送 Ctrl+C (SIGINT)
    public func sendInterrupt() {
        // TODO: 触发 Linux 进程的 SIGINT 信号投递
        sendInput("\u{03}")  // 简化: 直接送 Ctrl+C 字符
    }

    /// 停止进程
    public func stop() {
        // TODO: 通过 exit syscall 强制退出
        stopIOPolling()
        updateState(.exited(code: -1))
    }

    // MARK: - 内部
    private func setupStdio(process: LinuxProcess) {
        // 创建 stdin/stdout/stderr pipe
        let inPipe = PipeEnd(capacity: 65536)
        let outPipe = PipeEnd(capacity: 65536)
        let errPipe = PipeEnd(capacity: 65536)
        self.stdinPipe = inPipe
        self.stdoutPipe = outPipe
        self.stderrPipe = errPipe

        // Linux fd 0=stdin, 1=stdout, 2=stderr
        process.fdTable[0] = .pipe(inPipe)
        process.fdTable[1] = .pipe(outPipe)
        process.fdTable[2] = .pipe(errPipe)
        process.nextFd = 3
    }

    private func startIOPolling() {
        let timer = DispatchSource.makeTimerSource(queue: ioQueue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(20))
        timer.setEventHandler { [weak self] in
            self?.pollOutput()
        }
        timer.resume()
        ioTimer = timer
    }

    private func stopIOPolling() {
        ioTimer?.cancel()
        ioTimer = nil
        // 最后刷一次
        pollOutput()
    }

    private func pollOutput() {
        let bufSize = 4096
        var buf = [UInt8](repeating: 0, count: bufSize)
        let handler = eventHandler
        buf.withUnsafeMutableBufferPointer { ptr in
            if let out = stdoutPipe, out.count > 0 {
                let n = out.read(into: UnsafeMutableRawPointer(ptr.baseAddress!), max: bufSize)
                if n > 0 {
                    let bytes = Array(ptr[0..<Int(n)])
                    if let s = String(bytes: bytes, encoding: .utf8) {
                        DispatchQueue.main.async {
                            handler?(.stdout(s))
                        }
                    }
                }
            }
            if let err = stderrPipe, err.count > 0 {
                let n = err.read(into: UnsafeMutableRawPointer(ptr.baseAddress!), max: bufSize)
                if n > 0 {
                    let bytes = Array(ptr[0..<Int(n)])
                    if let s = String(bytes: bytes, encoding: .utf8) {
                        DispatchQueue.main.async {
                            handler?(.stderr(s))
                        }
                    }
                }
            }
        }
    }

    private func updateState(_ s: ProcessState) {
        state = s
        let handler = eventHandler
        DispatchQueue.main.async {
            handler?(.stateChanged(s))
        }
    }
}
