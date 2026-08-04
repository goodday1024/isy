// SyscallDispatcher.swift - syscall 分发核心
//
// 数据流:
//   Linux 代码 (BL __isy_syscall_trap)
//     -> syscall_trap.c (naked, 保存寄存器, 把 x8 移到 x6)
//     -> __isy_c_syscall_dispatch (C 函数)
//     -> g_handler (C 函数指针, 由 Swift 通过 isy_set_syscall_handler 注册)
//     -> isy_swift_syscall_handler (@_cdecl Swift 函数, 本文件)
//     -> SyscallDispatcher.dispatch (查表)
//     -> 具体 handler (FileSyscalls / MemorySyscalls / ...)
//
// 每次 syscall 的额外开销: ~10-20 寄存器保存/恢复 + 1 次函数调用.
// 相比 Linux 真实 syscall (内核切换 ~100-200ns), 我们的开销更低 (无内核切换).
//
// 注意: SyscallDispatcher 必须在初始化时通过 isy_set_syscall_handler 注册
// 全局 C 回调. 全局 dispatcher 用 nonisolated(unsafe) 持有 (单线程执行期).

import Foundation
import isyCHot

/// syscall handler 函数类型
/// - Parameters: cpu, 6 个参数 (x0-x5)
/// - Returns: syscall 返回值 (负数表示 -errno)
public typealias SyscallHandler = (
    UnsafeMutablePointer<isy_cpu_state_t>,
    UInt64, UInt64, UInt64, UInt64, UInt64, UInt64
) -> Int64

/// syscall 分发器
public final class SyscallDispatcher: @unchecked Sendable {
    private var handlers: [Int32: SyscallHandler] = [:]
    public weak var process: LinuxProcess?

    /// 未实现 syscall 的默认行为: 返回 -ENOSYS
    public var unimplementedHandler: SyscallHandler = { _, _, _, _, _, _, _ in
        Errno.enosys.asSyscallReturn
    }

    /// 统计: 每个 syscall 调用次数 (调试/优化用)
    public private(set) var callCounts: [Int32: Int] = [:]

    public init(process: LinuxProcess? = nil) {
        self.process = process
    }

    /// 注册一个 syscall handler
    public func register(_ nr: LinuxSyscall, _ handler: @escaping SyscallHandler) {
        handlers[nr.rawValue] = handler
    }

    /// 注册一个原始 syscall 号的 handler (用于未在 LinuxSyscall enum 中定义的)
    public func registerRaw(_ nr: Int32, _ handler: @escaping SyscallHandler) {
        handlers[nr] = handler
    }

    /// 分发 syscall
    public func dispatch(
        nr: Int32,
        cpu: UnsafeMutablePointer<isy_cpu_state_t>,
        args: (UInt64, UInt64, UInt64, UInt64, UInt64, UInt64)
    ) -> Int64 {
        callCounts[nr, default: 0] += 1
        let h = handlers[nr] ?? unimplementedHandler
        return h(cpu, args.0, args.1, args.2, args.3, args.4, args.5)
    }

    /// 安装到 C 端: 把 isy_swift_syscall_handler 注册为全局 handler
    public func install() {
        isyGlobalDispatcher = self
        isy_set_syscall_handler(isySwiftSyscallBridge)
    }
}

// ---------- C -> Swift 桥 ----------
// 全局 dispatcher 指针. 用 nonisolated(unsafe) 因为 C 回调没有 actor 上下文.
// 在单执行线程前提下安全 (Linux 代码运行时不切线程, syscall 在同线程同步处理).

nonisolated(unsafe) private var isyGlobalDispatcher: SyscallDispatcher? = nil

/// @_cdecl 导出给 C 端的回调. 签名必须与 isy_syscall_handler_t 完全一致.
@_cdecl("isy_swift_syscall_handler")
public func isySwiftSyscallBridge(
    _ a0: UInt64, _ a1: UInt64, _ a2: UInt64,
    _ a3: UInt64, _ a4: UInt64, _ a5: UInt64,
    _ nr: UInt64,
    _ cpu: UnsafeMutablePointer<isy_cpu_state_t>!
) -> Int64 {
    guard let d = isyGlobalDispatcher else {
        return Errno.enosys.asSyscallReturn
    }

    // 在 syscall 处理前检查待处理信号
    if let proc = d.process, proc.pendingSignal != 0, cpu != nil {
        deliverSignalToCPU(proc: proc, cpu: cpu)
    }

    let result = d.dispatch(
        nr: Int32(truncatingIfNeeded: nr),
        cpu: cpu,
        args: (a0, a1, a2, a3, a4, a5)
    )

    // 在 syscall 处理后再次检查待处理信号
    if let proc = d.process, proc.pendingSignal != 0, cpu != nil {
        deliverSignalToCPU(proc: proc, cpu: cpu)
    }

    return result
}

/// 将待处理信号投递到 CPU 状态 (修改 CPU 上下文以跳转到信号处理函数)
private func deliverSignalToCPU(proc: LinuxProcess, cpu: UnsafeMutablePointer<isy_cpu_state_t>) {
    let sig = proc.pendingSignal
    proc.pendingSignal = 0

    guard let handler = proc.signalHandlers[sig], handler != 0 else {
        // SIG_DFL: 默认处理
        if sig == Signal.sigint.rawValue || sig == Signal.sigterm.rawValue || sig == Signal.sigkill.rawValue {
            // 终止进程
            proc.exited = true
            proc.exitCode = 128 + sig
            isy_request_exit(proc.exitCode)
        }
        return
    }
    if handler == 1 {
        // SIG_IGN: 忽略
        return
    }

    // 构造信号栈帧: 在栈上保存完整寄存器上下文
    let frameSize: UInt64 = 4096
    var newSp = cpu.pointee.sp - frameSize
    newSp &= ~UInt64(15)

    // 保存当前 CPU 状态到栈帧 (供 sigreturn 恢复)
    if let stackPtr = proc.addressSpace.hostPointer(for: VA(newSp), size: Int(frameSize)) {
        // 使用 withUnsafeMutablePointer 将 tuple regs 作为数组访问
        withUnsafeMutablePointer(to: &cpu.pointee.regs) { regsPtr in
            regsPtr.withMemoryRebound(to: UInt64.self, capacity: 31) { regs in
                var offset = 0
                for i in 0..<31 {
                    stackPtr.advanced(by: offset).assumingMemoryBound(to: UInt64.self).pointee = regs[i]
                    offset += 8
                }
            }
        }
        stackPtr.advanced(by: 31 * 8).assumingMemoryBound(to: UInt64.self).pointee = cpu.pointee.sp
        stackPtr.advanced(by: 32 * 8).assumingMemoryBound(to: UInt64.self).pointee = cpu.pointee.pc
        stackPtr.advanced(by: 33 * 8).assumingMemoryBound(to: UInt64.self).pointee = cpu.pointee.pstate
    }

    // 设置新的 CPU 状态: 跳转到信号处理函数
    withUnsafeMutablePointer(to: &cpu.pointee.regs) { regsPtr in
        regsPtr.withMemoryRebound(to: UInt64.self, capacity: 31) { regs in
            regs[0] = UInt64(bitPattern: Int64(sig))
            regs[1] = 0
            // lr = 信号处理返回地址 (指向 rt_sigreturn 或 trampoline)
            let restoreHandler = proc.signalHandlers[31] ?? 0
            regs[30] = restoreHandler != 0 ? restoreHandler : cpu.pointee.pc
        }
    }
    cpu.pointee.sp = newSp
    cpu.pointee.pc = handler
}
