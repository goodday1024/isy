// syscall_trap.c - isy 核心创新点: SVC -> BL 替换后的 syscall 入口
//
// 工作原理:
//   1. ELF Loader 加载 Linux ARM64 ELF 到 mmap 的区域
//   2. Binary Patcher 扫描所有可执行段, 把 SVC #0 (0xd4000001) 替换为
//      BL __isy_syscall_trap (相对跳转, 范围 ±128MB)
//   3. Linux 代码作为函数指针被 isy_enter_linux 调用, 原生执行
//   4. 遇到原 SVC 位置时, 实际执行 BL __isy_syscall_trap, 陷入本函数
//   5. 本函数读取 x8 (syscall_nr) 与 x0-x5 (args), 通过函数指针间接
//      调用 C dispatch (LTO 可见的引用方式)
//   6. dispatch 再回调 Swift SyscallDispatcher, 完成实际 syscall
//   7. 返回值写入 x0, ret 回到 Linux 代码下一条指令
//
// LTO 兼容性:
//   naked 函数内的 "bl symbol" 汇编引用, 在 LTO (SPM 对 C target 做
//   -r -object_path_lto 预链接) 时不可见, 导致 symbol 被误消除.
//   解决方案: 用 volatile 全局函数指针 + adrp/ldr/blr 间接调用,
//   C 初始化代码对函数的取址是编译器可见的, LTO 不会消除.

#include "isy_hot.h"

// 全局 handler, 由 Swift 端通过 isy_set_syscall_handler 注册
static isy_syscall_handler_t g_handler = 0;

void isy_set_syscall_handler(isy_syscall_handler_t handler) {
    g_handler = handler;
}

// stats
isy_stats_t g_stats = {0, 0, 0};
const isy_stats_t *isy_get_stats(void) { return &g_stats; }
void isy_reset_stats(void) { g_stats.syscalls = g_stats.traps = g_stats.icache_flushes = 0; }

// ---------- C 端 dispatch ----------
// 注意: 签名必须与 isy_syscall_handler_t 完全一致 (7 个 uint64_t + isy_cpu_state_t*)
__attribute__((noinline))
static int64_t __isy_c_syscall_dispatch_impl(
    uint64_t a0, uint64_t a1, uint64_t a2,
    uint64_t a3, uint64_t a4, uint64_t a5,
    uint64_t syscall_nr,
    isy_cpu_state_t *cpu
) {
    (void)cpu;
    g_stats.syscalls++;
    if (__builtin_expect(g_handler == 0, 0)) {
        return -38; // -ENOSYS
    }
    return g_handler(a0, a1, a2, a3, a4, a5, syscall_nr, 0);
}

// 函数指针类型 (与 isy_syscall_handler_t 一致)
typedef int64_t (*isy_dispatch_fn_t)(
    uint64_t, uint64_t, uint64_t, uint64_t, uint64_t, uint64_t, uint64_t,
    isy_cpu_state_t*
);

// volatile 全局函数指针: 初始化时指向 dispatch 实现.
// volatile + used 双重保证, 防止 LTO 将其和被指向的函数一起消除.
__attribute__((used, visibility("default")))
volatile isy_dispatch_fn_t __isy_dispatch_fn = __isy_c_syscall_dispatch_impl;

// 获取 trap 函数地址 (供 BinaryPatcher 计算 BL 偏移)
uintptr_t isy_get_trap_address(void) {
    return (uintptr_t)&__isy_syscall_trap;
}

// 获取 dispatch 函数指针地址 (供 Swift 端验证, 不强制使用)
uintptr_t isy_get_dispatch_fn_address(void) {
    return (uintptr_t)&__isy_dispatch_fn;
}

#ifdef __aarch64__

// ---------- 核心 naked syscall trap ----------
// 协议: Linux ARM64 syscall: x8=nr, x0-x5=args, ret->x0
// 步骤: 保存 callee-saved -> x8->x6 -> 通过函数指针间接调用 dispatch
//       -> 恢复寄存器 -> ret
__attribute__((naked))
void __isy_syscall_trap(void) {
    __asm__ volatile(
        // 保存 callee-saved GPR (x19-x28, x29, x30)
        "stp x29, x30, [sp, #-16]!\n"
        "mov x29, sp\n"
        "stp x19, x20, [sp, #-16]!\n"
        "stp x21, x22, [sp, #-16]!\n"
        "stp x23, x24, [sp, #-16]!\n"
        "stp x25, x26, [sp, #-16]!\n"
        "stp x27, x28, [sp, #-16]!\n"
        // 保存 NEON callee-saved (q8-q15 = d8-d15, 128 bytes)
        "sub sp, sp, #128\n"
        "stp q8, q9, [sp, #0]\n"
        "stp q10, q11, [sp, #32]\n"
        "stp q12, q13, [sp, #64]\n"
        "stp q14, q15, [sp, #96]\n"

        // x8 (syscall_nr) -> x6 (第 7 个参数)
        // x7 -> 0 (NULL cpu 指针, 第 8 个参数)
        "mov x6, x8\n"
        "mov x7, #0\n"

        // 通过全局函数指针间接调用 dispatch (LTO 安全):
        // adrp + ldr 加载 __isy_dispatch_fn 的值到 x17 (IP1, caller-saved)
        // blr x17 间接调用, 返回值在 x0
        "adrp x17, __isy_dispatch_fn@PAGE\n"
        "ldr x17, [x17, __isy_dispatch_fn@PAGEOFF]\n"
        "blr x17\n"

        // 恢复 NEON callee-saved
        "ldp q14, q15, [sp, #96]\n"
        "ldp q12, q13, [sp, #64]\n"
        "ldp q10, q11, [sp, #32]\n"
        "ldp q8, q9, [sp, #0]\n"
        "add sp, sp, #128\n"
        // 恢复 callee-saved GPR
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
int isy_enter_linux(uintptr_t entry, isy_cpu_state_t *cpu, void *stack_base) {
    (void)stack_base;
    register uint64_t x0 asm("x0") = cpu->regs[0];
    register uint64_t x1 asm("x1") = cpu->regs[1];
    register uint64_t x2 asm("x2") = cpu->regs[2];
    register uint64_t x3 asm("x3") = cpu->regs[3];
    register uint64_t x4 asm("x4") = cpu->regs[4];
    register uint64_t x5 asm("x5") = cpu->regs[5];
    register uintptr_t x16 asm("x16") = entry;
    register uint64_t sp asm("sp") = cpu->sp;

    __asm__ volatile(
        "msr tpidr_el0, %x[tls]\n"
        "br x16\n"
        :
        : [tls] "r"(cpu->regs[18]),
          "r"(x0), "r"(x1), "r"(x2), "r"(x3),
          "r"(x4), "r"(x5), "r"(x16), "r"(sp)
        : "memory"
    );
    return (int)cpu->regs[0];
}

#else // !__aarch64__

void __isy_syscall_trap(void) { }

int isy_enter_linux(uintptr_t entry, isy_cpu_state_t *cpu, void *stack_base) {
    (void)entry; (void)cpu; (void)stack_base;
    return -1;
}

#endif // __aarch64__
