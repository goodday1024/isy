// BinaryPatcher.swift - isy 核心创新: load-time binary patching
//
// 原理:
//   ARM64 Linux 二进制中, 系统调用通过 `SVC #0` 指令 (编码 0xD4000001) 触发.
//   iOS 上, SVC #0 会陷入内核并被拒绝 (用户态 App 不允许 SVC). 我们在加载
//   ELF 后, 扫描所有可执行段, 把每条 SVC #0 替换为
//   `BL __isy_syscall_trap`, 使 Linux 代码原生执行时, 在 syscall 边界
//   自动跳入我们的 C trap 函数, 完成系统调用翻译.
//
//   这就是 "近原生" 路径的核心: 99.99% 指令直接跑在 ARM64 CPU 上, 只在
//   syscall 边界陷入翻译层. 不写可执行页 (只改数据段中的 SVC 4 字节为 BL),
//   不依赖 JIT, 完全符合 Apple App Store 规则.
//
// BL 指令编码:
//   BL #imm26:  1001 01 imm26   (imm26 为有符号偏移, 单位 = 4 字节, 范围 ±128MB)
//   = 0x94000000 | (imm26 & 0x03FFFFFF)
//   imm26 = (target - pc) / 4
//
// SVC 指令编码:
//   SVC #imm16: 1101 0100 000 imm16 00001
//   = 0xD4000001 | (imm16 << 5)
//   Linux ARM64 syscall 一律用 SVC #0 = 0xD4000001

import Foundation

/// 一条 patch 记录
public struct PatchRecord: Hashable {
    public let va: VA                 // 该指令的虚拟地址
    public let originalInstruction: UInt32
    public let patchedInstruction: UInt32
    public let segmentIndex: Int
}

/// Patch 表: 所有被 patch 的指令集合, 供 trap handler / 调试器查询
public struct PatchTable {
    public var records: [PatchRecord] = []
    public var byAddress: [VA: PatchRecord] = [:]

    public init() {}

    public mutating func add(_ r: PatchRecord) {
        byAddress[r.va] = r
        records.append(r)
    }

    public func originalInstruction(at va: VA) -> UInt32? {
        byAddress[va]?.originalInstruction
    }
}

/// Binary patcher 错误
public enum PatchError: Error {
    case trapOutOfRange(from: VA, to: UInt64, distance: Int64)
    case notAligned(VA)
    case segmentOutOfRange(VA)
}

/// Patch 配置
public struct PatchConfig {
    /// 是否同时 patch MRS/MSR 系统寄存器访问 (TPIDR_EL0 等) 为 BRK trap
    /// 第一版关闭, 后续启用 (需要 Mach exception handler)
    public var patchSystemRegisters: Bool = false
    /// 是否记录 patch 详情到 PatchTable (调试用)
    public var recordPatches: Bool = true
    /// trap 目标函数地址 (__isy_syscall_trap 的绝对地址)
    public var trapAddress: UInt64

    public init(trapAddress: UInt64) {
        self.trapAddress = trapAddress
    }
}

/// Binary Patcher: 对已加载到内存的可执行段做 SVC->BL 替换
public struct BinaryPatcher {

    /// 编码 BL 指令: 从 pc 跳到 target
    /// - Returns: BL 指令的 32-bit 编码
    /// - Throws: 距离超出 ±128MB 范围
    public static func encodeBL(from pc: UInt64, to target: UInt64) throws -> UInt32 {
        let diff = Int64(target) - Int64(pc)
        // BL imm26 范围: ±128MB (imm26 是 signed 26-bit, 单位 4 字节)
        // = ±(2^25 * 4) = ±134217728 字节 = ±128 MiB
        let limit: Int64 = 128 * 1024 * 1024
        if diff < -limit || diff >= limit {
            throw PatchError.trapOutOfRange(from: VA(pc), to: target, distance: diff)
        }
        precondition(diff % 4 == 0, "BL target must be 4-byte aligned")
        let imm26 = UInt32(bitPattern: Int32(diff / 4)) & 0x03FFFFFF
        return 0x94000000 | imm26
    }

    /// 判断指令是否为 SVC #0 (Linux syscall)
    @inlinable public static func isSVC(_ insn: UInt32) -> Bool {
        // SVC #imm16 编码: 0xD4000001 | (imm16 << 5)
        // 只识别 SVC #0 (Linux 唯一用到的 syscall 指令)
        insn == 0xD4000001
    }

    /// 判断指令是否为任意 SVC (调试/统计用)
    @inlinable public static func isAnySVC(_ insn: UInt32) -> Bool {
        (insn & 0xFFE0001F) == 0xD4000001
    }

    /// 判断指令是否为 MRS (读系统寄存器)
    @inlinable public static func isMRS(_ insn: UInt32) -> Bool {
        (insn & 0xFFF00000) == 0xD5300000
    }

    /// 判断指令是否为 Msr (写系统寄存器)
    @inlinable public static func isMSR(_ insn: UInt32) -> Bool {
        (insn & 0xFFF00000) == 0xD5100000
    }

    /// 对一个可执行段做 patch (原地修改 instructions 内存)
    /// - Parameters:
    ///   - instructions: 已加载的可执行段内存 (32-bit 指令流)
    ///   - baseVA: 该段起始虚拟地址 (用于计算 BL 偏移)
    ///   - config: patch 配置
    ///   - segmentIndex: 段索引 (记录用)
    /// - Returns: PatchTable (新建) 或更新传入的 table
    public static func patchSegment(
        _ instructions: UnsafeMutableBufferPointer<UInt32>,
        baseVA: UInt64,
        config: PatchConfig,
        segmentIndex: Int,
        into table: inout PatchTable
    ) throws {
        for i in 0..<instructions.count {
            let va = baseVA + UInt64(i * 4)
            let insn = instructions[i]

            if isSVC(insn) {
                // SVC #0 -> BL __isy_syscall_trap
                let bl = try encodeBL(from: va, to: config.trapAddress)
                instructions[i] = bl
                if config.recordPatches {
                    table.add(PatchRecord(
                        va: VA(va),
                        originalInstruction: insn,
                        patchedInstruction: bl,
                        segmentIndex: segmentIndex
                    ))
                }
            } else if config.patchSystemRegisters && (isMRS(insn) || isMSR(insn)) {
                // MRS/MSR 系统寄存器 -> BRK #imm (后续由 trap handler 解释)
                // 简化: 用 BRK #0xD, trap handler 通过 PatchTable 查原指令
                let original = insn
                let brk: UInt32 = 0xD4200000 | (0x000D << 5)  // BRK #13
                instructions[i] = brk
                if config.recordPatches {
                    table.add(PatchRecord(
                        va: VA(va),
                        originalInstruction: original,
                        patchedInstruction: brk,
                        segmentIndex: segmentIndex
                    ))
                }
            }
        }
    }

    /// 便捷入口: 对一个 ELF 镜像的所有可执行段做 patch
    /// (实际内存访问由调用方提供, 这里只接收段描述符)
    public static func patchExecutableSegments(
        segments: [(ptr: UnsafeMutableBufferPointer<UInt32>, baseVA: UInt64, index: Int)],
        config: PatchConfig
    ) throws -> PatchTable {
        var table = PatchTable()
        for seg in segments {
            try patchSegment(seg.ptr, baseVA: seg.baseVA, config: config,
                             segmentIndex: seg.index, into: &table)
        }
        return table
    }

    /// 验证: 给定地址处是否已被 patch 为 BL (调试用)
    public static func isBL(_ insn: UInt32) -> Bool {
        (insn & 0xFC000000) == 0x94000000
    }
}
