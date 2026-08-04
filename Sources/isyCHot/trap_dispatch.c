// trap_dispatch.c - 不能直通的 ARM64 指令的解释执行
//
// 在 ARM64 Linux -> iOS ARM64 路径上, 绝大多数指令可以原生执行, 但以下
// 指令必须特殊处理:
//
//   1. SVC #0          -> 替换为 BL __isy_syscall_trap (见 syscall_trap.c)
//   2. MRS <Xt>, sysreg -> 读系统寄存器. 关键: TPIDR_EL0 (TLS), CNTFRQ_EL0,
//                         CNTVCT_EL0 在 iOS 上行为不同, 必须 trap
//   3. MSR sysreg, <Xt> -> 写系统寄存器. 同上, TPIDR_EL0 写入需要拦截
//   4. BRK #imm        -> Linux 用作 trap/断点, 触发 SIGTRAP
//   5. DC ZVA          -> Data Cache Zero by VA (用户态可用但 iOS 限制)
//
// 策略 (避免依赖 Mach exception handler, 完全合规):
//   - SVC:    patch 为 BL (见 BinaryPatcher.swift)
//   - MRS/MSR: patch 为 BRK #imm, imm 编码原指令 32-bit 中的低 16 位
//              trap handler 解析原指令并模拟. 需要 Mach exception port
//              安装 (见 Emulator.swift 的 installExceptionHandler)
//   - BRK:    原生 BRK 在 iOS 上会触发 SIGTRAP, 用 signal() 捕获
//
// 本文件提供指令解释逻辑. trap 安装本身在 Swift 端 (Emulator.swift).

#include "isy_hot.h"

// stats 在 syscall_trap.c 中定义 (非 static, 供本文件累加 traps)
extern isy_stats_t g_stats;

// ARM64 指令编码常量
#define INSN_SVC_MASK     0xFFE0001F  // SVC #0 = 0xD4000001
#define INSN_SVC_VALUE    0xD4000001
#define INSN_MRS_MASK     0xFFF00000
#define INSN_MRS_VALUE    0xD5300000  // MRS <Xt>, <sysreg>
#define INSN_MSR_MASK     0xFFF00000
#define INSN_MSR_VALUE    0xD5100000  // MSR <sysreg>, <Xt>
#define INSN_BRK_MASK     0xFFE0001F
#define INSN_BRK_VALUE    0xD4200000

// 系统寄存器编码 (从 MRS/MSR 指令的 op0/op1/CRn/CRm/op2 提取)
// TPIDR_EL0:  op0=3 op1=3 CRn=13 CRm=0 op2=2
#define SYSREG_TPIDR_EL0  ((3<<11)|(3<<7)|(13<<3)|(0<<1)|2)  // 0x5E82
#define SYSREG_CNTFRQ_EL0 ((3<<11)|(3<<7)|(14<<3)|(0<<1)|0)  // 0x5E00
#define SYSREG_CNTVCT_EL0 ((3<<11)|(3<<7)|(14<<3)|(0<<1)|2)  // 0x5E02
#define SYSREG_NZCV       ((3<<11)|(3<<7)|(4<<3)|(2<<1)|0)   // 0x5A10
#define SYSREG_FPCR       ((3<<11)|(3<<7)|(4<<3)|(4<<1)|0)   // 0x5A20
#define SYSREG_FPSR       ((3<<11)|(3<<7)|(4<<3)|(4<<1)|1)   // 0x5A21

// 从 MRS/MSR 指令提取系统寄存器编码
static inline uint16_t decode_sysreg(uint32_t insn) {
    uint32_t op0 = (insn >> 19) & 0x1;   // 实际 op0 = 2 + bit, 这里取 bit 19
    uint32_t op1 = (insn >> 16) & 0x7;
    uint32_t crn = (insn >> 12) & 0xF;
    uint32_t crm = (insn >> 8) & 0xF;
    uint32_t op2 = (insn >> 5) & 0x7;
    // 完整 sysreg 编码 (与 Linux 的 <asm/sysreg.h> 一致)
    return (uint16_t)((op0 << 14) | (op1 << 11) | (crn << 7) | (crm << 3) | op2);
}

static inline uint8_t decode_rt(uint32_t insn) {
    return insn & 0x1F;
}

// 注意: trap 发生时, 原指令已经被 patch 为 BRK, 我们需要原始指令信息.
// 简化方案: BRK 的 imm16 编码原指令的低 16 位哈希, 通过查表恢复.
// 更可靠方案: patch 时记录 (pc -> 原指令) 映射, trap handler 查表.
// (见 BinaryPatcher.swift: PatchTable)
int isy_trap_dispatch(uint32_t insn, isy_cpu_state_t *cpu, uintptr_t fault_addr) {
    (void)fault_addr;
    g_stats.traps++;

    // MRS
    if ((insn & INSN_MRS_MASK) == INSN_MRS_VALUE) {
        uint8_t rt = decode_rt(insn);
        uint16_t reg = decode_sysreg(insn);
        uint64_t val = 0;
        switch (reg) {
            case SYSREG_TPIDR_EL0:
                // 返回 Linux TLS pointer (由 Emulator 维护)
                val = cpu->regs[18];  // 约定 regs[18] = TLS
                break;
            case SYSREG_CNTFRQ_EL0:
                val = isy_arm64_get_cntfrq();
                break;
            case SYSREG_CNTVCT_EL0:
                val = isy_arm64_get_cntvct();
                break;
            case SYSREG_NZCV:
                val = cpu->pstate & 0xF0000000ULL;
                break;
            default:
                // 其他系统寄存器: 返回 0 (用户态一般不可读)
                val = 0;
                break;
        }
        if (rt < 31) cpu->regs[rt] = val;
        cpu->pc += 4;
        return 0;
    }

    // MSR
    if ((insn & INSN_MSR_MASK) == INSN_MSR_VALUE) {
        uint8_t rt = decode_rt(insn);
        uint16_t reg = decode_sysreg(insn);
        uint64_t val = (rt < 31) ? cpu->regs[rt] : 0;
        switch (reg) {
            case SYSREG_TPIDR_EL0:
                cpu->regs[18] = val;  // 更新 Linux TLS
                break;
            case SYSREG_NZCV:
                cpu->pstate = (cpu->pstate & ~0xF0000000ULL) | (val & 0xF0000000ULL);
                break;
            default:
                // 忽略其他写入
                break;
        }
        cpu->pc += 4;
        return 0;
    }

    // BRK (Linux 主动断点) -> SIGTRAP
    if ((insn & INSN_BRK_MASK) == INSN_BRK_VALUE) {
        // 简化: 返回 -1 表示需要投递 SIGTRAP
        cpu->pc += 4;
        return -1;  // 由上层 Emulator 转为 SIGTRAP
    }

    // 未识别指令
    return -2;
}
