// isy_hot.h - isy C 热点层公共接口
//
// 设计要点:
//  - 所有 ARM64 内联汇编用 #ifdef __aarch64__ 保护, 非 arm64 平台编译为 stub
//  - syscall_trap 是核心: Linux 代码经过 binary patching 后,
//    所有 SVC #0 被替换为 BL __isy_syscall_trap, 进入此函数即陷入 syscall
//  - dispatch_loop 用于解释执行需要 trap 的特殊指令 (MRS/MSR/BRK/DC/IC/AT)
//  - neon_bridge 提供 x86/Linux SIMD 桥接 (虽然 ARM64 Linux 也是 NEON, 但
//    仍提供向量化加速原语给上层 Swift 调用)

#ifndef ISY_HOT_H
#define ISY_HOT_H

#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

// ---------- CPU 状态 ----------
// 与 Linux ARM64 用户态可见寄存器对齐 (struct user_pt_regs)
// 在 arm64 上, 这个结构会被 syscall_trap 直接读写
typedef struct {
    uint64_t regs[31];   // x0-x30 (x30=lr)
    uint64_t sp;         // sp
    uint64_t pc;         // pc
    uint64_t pstate;     // PSTATE (NZCV/DAIF 等)
    uint64_t syscall_nr; // x8 的镜像, 供 C 端读取
} isy_cpu_state_t;

// ---------- syscall trap (核心入口) ----------
// naked 函数, 由被 patch 过的 Linux 代码通过 BL 调用
// 协议: x8 = Linux syscall number, x0-x5 = args, 返回值 -> x0
// 在非 arm64 平台此函数为 stub (永远不会被实际执行)
void __isy_syscall_trap(void);

// 获取 __isy_syscall_trap 的绝对地址 (供 BinaryPatcher 计算 BL 偏移)
uintptr_t isy_get_trap_address(void);

// 运行时锚点函数: 被 Swift 端在初始化时显式调用,
// 创建编译器可见的符号引用, 防止 Xcode archive LTO 时
// naked 函数汇编中 bl 的目标符号被误消除.
// 返回值等同于 isy_get_trap_address().
uintptr_t isy_runtime_anchor(void);

// C 端 syscall 分发回调, 由 syscall_trap 内部调用
// 参数顺序遵循 AAPCS64: x0-x5 -> arg0-arg5, x8 -> syscall_nr
// 返回值为 syscall 结果, 写回 x0
typedef int64_t (*isy_syscall_handler_t)(
    uint64_t arg0, uint64_t arg1, uint64_t arg2,
    uint64_t arg3, uint64_t arg4, uint64_t arg5,
    uint64_t syscall_nr,
    isy_cpu_state_t *cpu
);

// 注册 syscall 处理回调 (由 Swift 端在初始化时调用)
void isy_set_syscall_handler(isy_syscall_handler_t handler);

// ---------- 执行入口 ----------
// 进入被 patch 过的 Linux 代码执行
//   entry:   Linux 代码入口 (elf entry point 或 interpreter 入口)
//   cpu:     初始 CPU 状态 (栈指针/参数等已设置好)
//   stack_base: Linux 栈区域基址
// 返回: exit code (cpu->regs[0])
int isy_enter_linux(uintptr_t entry, isy_cpu_state_t *cpu, void *stack_base);

// 请求 Linux 进程退出 (由 exit/exit_group syscall handler 调用)
//   code: 退出码 (写入 cpu->regs[0])
// 此函数不会返回; 它恢复 iOS 上下文并跳转回 isy_enter_linux 的返回点.
__attribute__((noreturn))
void isy_request_exit(int code);

// ---------- 指令 trap 解释器 ----------
// 对不能直通的 ARM64 指令进行解释 (MRS/MSR/BRK/DC/IC/AT 等)
// 当 patcher 把这些指令替换为 BRK #imm 后, trap loop 会捕获并模拟
// 返回: 0=成功, 非 0=错误码
int isy_trap_dispatch(uint32_t insn, isy_cpu_state_t *cpu, uintptr_t fault_addr);

// ---------- NEON 向量化原语 ----------
// 提供给 Swift 上层的 SIMD 加速接口, 用于热点循环
// 在非 arm64 平台退化为标量实现
void isy_neon_memcpy256(void *dst, const void *src, size_t count);
void isy_neon_memset256(void *dst, uint8_t value, size_t count);
// 32x32 int32 矩阵转置 (NEON 实现, 8x4 块转置)
void isy_neon_transpose_i32_32x32(const int32_t *src, int32_t *dst);

// ---------- ARM64 系统寄存器 helpers ----------
// 在非 arm64 平台为 stub 返回 0
uint64_t isy_arm64_get_tpidr_el0(void);
void     isy_arm64_set_tpidr_el0(uint64_t value);
uint64_t isy_arm64_get_cntfrq(void);   // 计时器频率
uint64_t isy_arm64_get_cntvct(void);   // 虚拟计数器
void     isy_arm64_flush_icache(void *addr, size_t len);
void     isy_arm64_dc_cvau(void *addr, size_t len);  // D-cache clean to PoU

// ---------- 统计 ----------
typedef struct {
    uint64_t syscalls;
    uint64_t traps;
    uint64_t icache_flushes;
} isy_stats_t;

const isy_stats_t *isy_get_stats(void);
void isy_reset_stats(void);

#ifdef __cplusplus
}
#endif

#endif // ISY_HOT_H
