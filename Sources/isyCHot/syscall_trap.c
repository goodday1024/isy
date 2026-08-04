// syscall_trap.c - isy 核心创新点: SVC -> BL 替换后的 syscall 入口
//
// 工作原理:
//   1. ELF Loader 加载 Linux ARM64 ELF 到 mmap 的区域
//   2. Binary Patcher 扫描所有可执行段, 把 SVC #0 (0xd4000001) 替换为
//      BL __isy_syscall_trap (相对跳转, 范围 ±128MB)
//   3. Linux 代码作为函数指针被 isy_enter_linux 调用, 原生执行
//   4. 遇到原 SVC 位置时, 实际执行 BL __isy_syscall_trap, 陷入本函数
//   5. 本函数读取 x8 (syscall_nr) 与 x0-x5 (args), 调用 C dispatch
//   6. dispatch 再回调 Swift SyscallDispatcher, 完成实际 syscall
//   7. 返回值写入 x0, ret 回到 Linux 代码下一条指令
//
// 这就是 "近原生" 路径: 99.99% 指令直接跑在 ARM64 CPU 上, 只有 syscall
// 边界陷入翻译层. 不写可执行页 (只改 SVC 那 4 字节为 BL), 完全合规.
//
// 注意: BL 范围 ±128MB. 为保证可达, isy 加载 Linux 代码到与 isyCHot
// 同一映像附近的固定区域 (见 Memory.swift: ISY_LINUX_BASE).

#include "isy_hot.h"

// 全局 handler, 由 Swift 端通过 isy_set_syscall_handler 注册
static isy_syscall_handler_t g_handler = 0;

void isy_set_syscall_handler(isy_syscall_handler_t handler) {
    g_handler = handler;
}

// 获取 trap 函数地址 (供 BinaryPatcher 计算 BL 偏移)
uintptr_t isy_get_trap_address(void) {
    return (uintptr_t)&__isy_syscall_trap;
}

// stats: 非 static, 供 trap_dispatch.c 累加 traps 计数
isy_stats_t g_stats = {0, 0, 0};
const isy_stats_t *isy_get_stats(void) { return &g_stats; }
void isy_reset_stats(void) { g_stats.syscalls = g_stats.traps = g_stats.icache_flushes = 0; }

// ---------- C 端 dispatch (由 naked trap 函数调用) ----------
// 协议: x0-x5 已作为前 6 个参数, x8 通过 x6 传入 (见 trap 汇编)
__attribute__((visibility("default")))
int64_t __isy_c_syscall_dispatch(
    uint64_t a0, uint64_t a1, uint64_t a2,
    uint64_t a3, uint64_t a4, uint64_t a5,
    uint64_t syscall_nr,
    isy_cpu_state_t *cpu
) {
    g_stats.syscalls++;
    if (__builtin_expect(g_handler == 0, 0)) {
        // 未注册 handler, 返回 -ENOSYS
        return -38;
    }
    return g_handler(a0, a1, a2, a3, a4, a5, syscall_nr, cpu);
}

#ifdef __aarch64__

// ---------- 核心 naked syscall trap ----------
// 协议对照:
//   Linux ARM64 syscall: x8=nr, x0-x5=args, ret->x0
//   AAPCS64 函数调用:   x0-x7=args, ret->x0
// 我们只需把 x8 移到一个参数寄存器位 (x6/x7), 然后调用 C dispatch
__attribute__((naked, section("__TEXT,__isytrap")))
void __isy_syscall_trap(void) {
    __asm__ volatile(
        // 保存调用者寄存器 (Linux 代码的 callee-saved 视角)
        // x19-x28, x29(fp), x30(lr), sp, q8-q15 (NEON callee-saved)
        "stp x29, x30, [sp, #-16]!\n"
        "mov x29, sp\n"
        "stp x19, x20, [sp, #-16]!\n"
        "stp x21, x22, [sp, #-16]!\n"
        "stp x23, x24, [sp, #-16]!\n"
        "stp x25, x26, [sp, #-16]!\n"
        "stp x27, x28, [sp, #-16]!\n"
        "sub sp, sp, #144\n"
        "stp q8, q9, [sp, #0]\n"
        "stp q10, q11, [sp, #32]\n"
        "stp q12, q13, [sp, #64]\n"
        "stp q14, q15, [sp, #96]\n"

        // 把 x8 (syscall_nr) 移到 x6 作为第 7 个参数
        // x0-x5 已是前 6 个参数
        "mov x6, x8\n"

        // 把当前 sp 也传给 C 端 (作为 cpu 指针的来源参考, 实际由
        // isy_enter_linux 维护一个 per-thread 的 cpu 指针, 见下)
        "mov x7, sp\n"

        // 调用 C dispatch
        "bl __isy_c_syscall_dispatch\n"

        // 返回值已在 x0, 恢复寄存器
        "ldp q14, q15, [sp, #96]\n"
        "ldp q12, q13, [sp, #64]\n"
        "ldp q10, q11, [sp, #32]\n"
        "ldp q8, q9, [sp, #0]\n"
        "add sp, sp, #144\n"
        "ldp x27, x28, [sp], #16\n"
        "ldp x25, x26, [sp], #16\n"
        "ldp x23, x24, [sp], #16\n"
        "ldp x21, x22, [sp], #16\n"
        "ldp x19, x20, [sp], #16\n"
        "ldp x29, x30, [sp], #16\n"
        "ret\n"
    );
}

// ---------- 执行入口 ----------
// 进入 Linux 代码. entry 是 patch 后的 Linux 函数地址.
// 我们设置 x0=argc, x1=argv, x2=envp, x3=auxv, sp=stack_top
// 然后用 BR x16 跳转. 返回时 (Linux 调 exit syscall) 由 Swift 端 longjmp 退出.
int isy_enter_linux(uintptr_t entry, isy_cpu_state_t *cpu, void *stack_base) {
    (void)stack_base;
    // 把 cpu 状态加载到寄存器 (argc/argv/envp/auxv 等)
    // 简化: 只设置 sp 和 x0 (argc). 完整实现见 Memory.swift 设置栈布局
    register uint64_t x0 asm("x0") = cpu->regs[0];
    register uint64_t x1 asm("x1") = cpu->regs[1];
    register uint64_t x2 asm("x2") = cpu->regs[2];
    register uint64_t x3 asm("x3") = cpu->regs[3];
    register uint64_t x4 asm("x4") = cpu->regs[4];
    register uint64_t x5 asm("x5") = cpu->regs[5];
    register uintptr_t x16 asm("x16") = entry;
    register uint64_t sp asm("sp") = cpu->sp;

    // 设置 TPIDR_EL0 (Linux TLS pointer)
    // 注意: 这会覆盖 iOS 自身的 TLS! 需要在 syscall trap 里 save/restore
    // 见 arm64_helpers.c 的 isy_tls_swap
    __asm__ volatile(
        "msr tpidr_el0, %x[tls]\n"
        "br x16\n"
        :
        : [tls] "r"(cpu->regs[18]),   // 约定: regs[18] = TLS pointer
          "r"(x0), "r"(x1), "r"(x2), "r"(x3),
          "r"(x4), "r"(x5), "r"(x16), "r"(sp)
        : "memory"
    );
    // 不会到这里 (Linux 代码通过 exit syscall 退出)
    return (int)cpu->regs[0];
}

#else // !__aarch64__

// 非 arm64 平台的 stub (永远不会真正执行, 仅保证可编译)
void __isy_syscall_trap(void) {
    // unreachable: 仅用于让链接器有符号
}

int isy_enter_linux(uintptr_t entry, isy_cpu_state_t *cpu, void *stack_base) {
    (void)entry; (void)cpu; (void)stack_base;
    return -1;  // 平台不支持
}

#endif // __aarch64__
