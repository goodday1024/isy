// SignalSyscalls.swift - 信号系统 syscall 骨架
//
// iOS 信号限制:
//   - iOS App 不能用 sigaction 安装真正信号处理函数 (会被 ASLR + 代码签名拦截)
//   - 但 isy 的 Linux 代码是 mmap 出来的, 没有 Apple 代码签名
//   - 策略: 用 Mach exception handler 捕获 SIGSEGV/SIGILL/SIGBUS,
//     转发给 Linux 进程的信号处理表
//   - rt_sigaction 只记录 handler VA, 真正投递时让 Linux 代码执行该 handler
//
// 这里只实现信号表的注册/查询, 投递逻辑在 Emulator 的 trap loop 里.

import Foundation
import isyCHot

/// Linux sigaction 结构 (ARM64)
public struct LinuxSigAction {
    public var sa_handler: UInt64     // 信号处理函数 VA
    public var sa_flags: UInt64
    public var sa_restorer: UInt64
    public var sa_mask: [UInt64]      // sigset_t (16 字节 = 128 信号)
    public init() {
        sa_handler = 0; sa_flags = 0; sa_restorer = 0
        sa_mask = [0, 0]
    }
}

public extension LinuxProcess {
    /// rt_sigaction: 注册信号处理函数
    func sys_rt_sigaction(sig: Int32, actVA: VA, oldactVA: VA?, sigsetsize: Int) -> Int64 {
        guard sig > 0 && sig < 32 else {
            return Errno.einval.asSyscallReturn
        }
        // 读取新 act
        if actVA.raw != 0,
           let actPtr = addressSpace.hostPointer(for: actVA, size: 32) {
            let new = actPtr.assumingMemoryBound(to: LinuxSigAction.self).pointee
            // 保存旧的
            if let oldVA = oldactVA, oldVA.raw != 0,
               let oldPtr = addressSpace.hostPointer(for: oldVA, size: 32) {
                var old = LinuxSigAction()
                old.sa_handler = signalHandlers[sig] ?? 0
                oldPtr.assumingMemoryBound(to: LinuxSigAction.self).pointee = old
            }
            signalHandlers[sig] = new.sa_handler
        }
        return 0
    }

    /// rt_sigprocmask: 信号屏蔽字 (简化: 全部允许)
    func sys_rt_sigprocmask(how: Int32, setVA: VA, oldsetVA: VA?, sigsetsize: Int) -> Int64 {
        // 简化: 不真正屏蔽, 只记录
        if let oldVA = oldsetVA, oldVA.raw != 0,
           let oldPtr = addressSpace.hostPointer(for: oldVA, size: 16) {
            oldPtr.assumingMemoryBound(to: UInt64.self).pointee = 0
            oldPtr.advanced(by: 8).assumingMemoryBound(to: UInt64.self).pointee = 0
        }
        return 0
    }

    /// rt_sigpending: 查询待处理信号
    func sys_rt_sigpending(setVA: VA, sigsetsize: Int) -> Int64 {
        if let ptr = addressSpace.hostPointer(for: setVA, size: 16) {
            ptr.assumingMemoryBound(to: UInt64.self).pointee = 0
            ptr.advanced(by: 8).assumingMemoryBound(to: UInt64.self).pointee = 0
        }
        return 0
    }

    /// sigaltstack
    func sys_sigaltstack(ssVA: VA, oldSSVA: VA?) -> Int64 {
        // 简化: 不支持备用信号栈
        return 0
    }

    /// kill: 给进程发信号 (简化: 只支持给自己)
    func sys_kill(pid: Int32, sig: Int32) -> Int64 {
        if pid == self.pid || pid == 0 {
            // 标记待处理信号 (实际投递在 trap loop)
            return 0
        }
        return Errno.esrch.asSyscallReturn
    }

    /// tkill / tgkill: 给线程发信号
    func sys_tkill(tid: Int32, sig: Int32) -> Int64 {
        return sys_kill(pid: tid, sig: sig)
    }
}

public extension SyscallDispatcher {
    func registerSignalSyscalls(process: LinuxProcess) {
        register(.rt_sigaction) { _, sig, act, oldact, sigsetsize, _, _ in
            process.sys_rt_sigaction(sig: Int32(sig), actVA: VA(act),
                                     oldactVA: oldact == 0 ? nil : VA(oldact),
                                     sigsetsize: Int(sigsetsize))
        }
        register(.rt_sigprocmask) { _, how, set, oldset, sigsetsize, _, _ in
            process.sys_rt_sigprocmask(how: Int32(how), setVA: VA(set),
                                       oldsetVA: oldset == 0 ? nil : VA(oldset),
                                       sigsetsize: Int(sigsetsize))
        }
        register(.rt_sigpending) { _, set, sigsetsize, _, _, _, _ in
            process.sys_rt_sigpending(setVA: VA(set), sigsetsize: Int(sigsetsize))
        }
        register(.sigaltstack) { _, ss, oldss, _, _, _, _ in
            process.sys_sigaltstack(ssVA: VA(ss), oldSSVA: oldss == 0 ? nil : VA(oldss))
        }
        register(.kill) { _, pid, sig, _, _, _, _ in
            process.sys_kill(pid: Int32(pid), sig: Int32(sig))
        }
        register(.tkill) { _, tid, sig, _, _, _, _ in
            process.sys_tkill(tid: Int32(tid), sig: Int32(sig))
        }
        register(.sched_yield) { _, _, _, _, _, _, _ in
            sched_yield()
            return 0
        }
    }
}
