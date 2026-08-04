// CPUState.swift - ARM64 CPU 状态抽象
//
// 与 isy_hot.h 的 isy_cpu_state_t 对应. 在 arm64 平台上, 这个结构可以直接
// 被 C 端 syscall_trap 读写; 在非 arm64 平台上, 仅作为逻辑模型存在 (供测试).
//
// 寄存器约定 (与 Linux ARM64 用户态一致):
//   regs[0..30]  = x0-x30 (x30 = lr)
//   regs[18]     = TLS pointer (Linux TPIDR_EL0, 我们复用此 slot 暂存)
//   sp           = 栈指针
//   pc           = 程序计数器
//   pstate       = 处理器状态 (NZCV/DAIF 等)
//   syscallNr    = x8 的镜像, 供 C 端读取 (因为 x8 不在 AAPCS64 参数位)

import Foundation
import isyCHot

public final class CPUState {
    /// 底层 C 结构 (与 isy_cpu_state_t 二进制兼容)
    public var raw: isy_cpu_state_t

    public init() {
        raw = isy_cpu_state_t(
            regs: (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0),
            sp: 0, pc: 0, pstate: 0, syscall_nr: 0
        )
    }

    // 寄存器访问 (subscript)
    @inlinable public subscript(_ idx: Int) -> UInt64 {
        get {
            precondition(idx >= 0 && idx < 31, "reg index out of range")
            return withUnsafePointer(to: &raw.regs) { ptr -> UInt64 in
                ptr.withMemoryRebound(to: UInt64.self, capacity: 31) { p in p[idx] }
            }
        }
        set {
            precondition(idx >= 0 && idx < 31, "reg index out of range")
            withUnsafeMutablePointer(to: &raw.regs) { ptr in
                ptr.withMemoryRebound(to: UInt64.self, capacity: 31) { p in p[idx] = newValue }
            }
        }
    }

    // 便捷访问
    @inlinable public var x0: UInt64 { get { self[0] } set { self[0] = newValue } }
    @inlinable public var x1: UInt64 { get { self[1] } set { self[1] = newValue } }
    @inlinable public var x2: UInt64 { get { self[2] } set { self[2] = newValue } }
    @inlinable public var x3: UInt64 { get { self[3] } set { self[3] = newValue } }
    @inlinable public var x4: UInt64 { get { self[4] } set { self[4] = newValue } }
    @inlinable public var x5: UInt64 { get { self[5] } set { self[5] = newValue } }
    @inlinable public var x8: UInt64 { get { self[8] } set { self[8] = newValue } }
    @inlinable public var lr: UInt64 { get { self[30] } set { self[30] = newValue } }
    @inlinable public var sp: UInt64 {
        get { raw.sp } set { raw.sp = newValue }
    }
    @inlinable public var pc: UInt64 {
        get { raw.pc } set { raw.pc = newValue }
    }
    @inlinable public var tls: UInt64 {
        get { self[18] } set { self[18] = newValue }
    }
    @inlinable public var syscallNr: UInt64 {
        get { raw.syscall_nr } set { raw.syscall_nr = newValue }
    }

    // NZCV 标志位
    @inlinable public var n: Bool { (raw.pstate & 0x80000000) != 0 }
    @inlinable public var z: Bool { (raw.pstate & 0x40000000) != 0 }
    @inlinable public var c: Bool { (raw.pstate & 0x20000000) != 0 }
    @inlinable public var v: Bool { (raw.pstate & 0x10000000) != 0 }

    /// 重置为初始状态
    public func reset() {
        for i in 0..<31 { self[i] = 0 }
        sp = 0; pc = 0; raw.pstate = 0; syscallNr = 0; tls = 0
    }

    /// 转储 (调试用)
    public func dump() -> String {
        var s = ""
        for i in 0..<31 {
            s += String(format: "x%-2d=0x%016llx ", i, self[i])
            if (i + 1) % 4 == 0 { s += "\n" }
        }
        s += String(format: "sp =0x%016llx pc =0x%016llx\n", sp, pc)
        s += String(format: "pstate=0x%016llx tls=0x%016llx syscall=%llu\n",
                    raw.pstate, tls, syscallNr)
        return s
    }
}
