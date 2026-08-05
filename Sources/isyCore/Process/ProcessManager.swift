// ProcessManager.swift - isy 进程执行管理 (完整实现: 信号投递 + 进程调度)
//
// 职责:
//   1. 在后台线程跑 Emulator.run() (不阻塞 UI)
//   2. 桥接 stdio: 把用户输入送到 Linux 进程 stdin, 把 stdout/stderr 回调到 UI
//   3. 管理 pipe fd: stdin/stdout/stderr 用 isy 内部 PipeEnd 实现
//   4. 信号投递: 把 UI 信号 (如 Ctrl+C) 设为 LinuxProcess.pendingSignal,
//      在 syscall 边界由 SyscallDispatcher 投递到 CPU 上下文
//   5. 进程生命周期: 启动/退出/重启
//   6. 多进程调度: 管理多个 LinuxProcess, 模拟 fork/clone
//
// 线程模型:
//   - 主线程 (MainActor): UI 更新, 用户输入
//   - 后台线程 (isy.process): Emulator.run() 阻塞执行 Linux 代码
//   - 同步: 用串行 DispatchQueue + 缓冲队列, 避免锁

import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif
import isyCHot

// MARK: - 进程状态 & 事件

public enum ProcessState: Equatable, Sendable {
    case idle
    case loading
    case running
    case exited(code: Int32)
    case failed(String)
}

public enum ProcessEvent: Sendable {
    case stdout(String)
    case stderr(String)
    case stateChanged(ProcessState)
    case patchComplete(records: Int)
    case syscallTrace(name: String, result: Int64)
    case signalDelivered(sig: Int32)
}

// MARK: - 进程管理器

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

    /// 子进程列表
    public private(set) var childProcesses: [ProcessManager] = []

    /// 后台执行队列
    private let execQueue = DispatchQueue(label: "isy.process.exec", qos: .userInitiated)
    /// I/O 读取队列
    private let ioQueue = DispatchQueue(label: "isy.process.io", qos: .userInitiated)
    private var ioTimer: DispatchSourceTimer?

    public init() {}

    // MARK: - 进程启动

    /// 启动一个 Linux 进程 (加载 ELF + 执行)
    public func start(elfData: Data, argv: [String] = [], envp: [String] = []) {
        start(elfData: elfData, argv: argv, envp: envp, rootfs: nil)
    }

    /// 启动进程 (带 rootfs)
    public func start(elfData: Data, argv: [String] = [], envp: [String] = [], rootfs: RootFS?) {
        updateState(.loading)
        execQueue.async { [weak self] in
            guard let self = self else { return }
            var phase = "init"
            do {
                let emu = Emulator()
                self.emulator = emu
                self.process = emu.process
                self.setupStdio(process: emu.process)
                if let rfs = rootfs {
                    emu.process.rootfs = rfs
                }
                phase = "loadMain"
                try emu.loadMain(elfData, argv: argv, envp: envp)
                self.eventHandler?(.patchComplete(records: emu.patchTable.records.count))
                phase = "run"
                self.startIOPolling()
                self.updateState(.running)
                let code = emu.run()
                self.stopIOPolling()
                self.updateState(.exited(code: code))
            } catch {
                let elfSize = elfData.count
                let jitStatus = String(cString: isy_jit_status())
                let msg: String
                if let elfErr = error as? ELFError {
                    msg = "[\(phase)] ELF数据=\(elfSize)字节 \(elfErr.description)\n JIT状态: \(jitStatus)"
                } else if let memErr = error as? MemoryError {
                    msg = "[\(phase)] ELF数据=\(elfSize)字节 \(memErr.description)\n JIT状态: \(jitStatus)"
                } else {
                    msg = "[\(phase)] ELF数据=\(elfSize)字节 \(String(describing: error))\n JIT状态: \(jitStatus)"
                }
                self.updateState(.failed(msg))
            }
        }
    }

    // MARK: - 信号管理

    /// 投递信号到进程 (设置 pendingSignal, 在 syscall 边界投递)
    public func sendSignal(_ sig: Int32) {
        process?.pendingSignal = sig
        DispatchQueue.main.async {
            self.eventHandler?(.signalDelivered(sig: sig))
        }
    }

    /// 发送 SIGINT (Ctrl+C)
    public func sendInterrupt() {
        sendSignal(Signal.sigint.rawValue)
    }

    /// 发送 SIGTERM
    public func sendTerminate() {
        sendSignal(Signal.sigterm.rawValue)
    }

    /// 发送 SIGKILL
    public func sendKill() {
        sendSignal(Signal.sigkill.rawValue)
    }

    /// 发送 SIGWINCH (终端大小变化)
    public func sendWindowChange(rows: UInt16, cols: UInt16) {
        process?.terminalRows = rows
        process?.terminalCols = cols
        sendSignal(Signal.sigwinch.rawValue)
    }

    // MARK: - I/O 管理

    /// 发送输入到 Linux 进程 stdin
    public func sendInput(_ text: String) {
        guard let pipe = stdinPipe else { return }
        let bytes = Array(text.utf8)
        bytes.withUnsafeBufferPointer { buf in
            _ = pipe.write(from: UnsafeRawPointer(buf.baseAddress!), max: buf.count)
        }
    }

    /// 停止进程
    public func stop() {
        sendKill()
        stopIOPolling()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.updateState(.exited(code: -1))
        }
    }

    // MARK: - 子进程管理

    /// 创建子进程 (模拟 fork)
    public func forkChild() -> ProcessManager {
        let child = ProcessManager()
        childProcesses.append(child)
        return child
    }

    /// 等待子进程退出
    public func waitForChild(pid: Int32) -> Int32? {
        // 轮询子进程状态
        for child in childProcesses {
            if let proc = child.process, proc.pid == pid, proc.exited {
                return proc.exitCode
            }
        }
        return nil
    }

    // MARK: - 内部

    private func setupStdio(process: LinuxProcess) {
        let inPipe = PipeEnd(capacity: 65536)
        let outPipe = PipeEnd(capacity: 65536)
        let errPipe = PipeEnd(capacity: 65536)
        self.stdinPipe = inPipe
        self.stdoutPipe = outPipe
        self.stderrPipe = errPipe

        process.fdTable[0] = .pipe(inPipe)
        process.fdTable[1] = .pipe(outPipe)
        process.fdTable[2] = .pipe(errPipe)
        process.nextFd = 3
    }

    private func startIOPolling() {
        let timer = DispatchSource.makeTimerSource(queue: ioQueue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(16))  // ~60fps
        timer.setEventHandler { [weak self] in
            self?.pollOutput()
        }
        timer.resume()
        ioTimer = timer
    }

    private func stopIOPolling() {
        ioTimer?.cancel()
        ioTimer = nil
        pollOutput()  // 最后刷一次
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