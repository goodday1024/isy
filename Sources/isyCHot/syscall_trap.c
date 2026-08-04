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
// 符号防消除策略 (针对 Xcode archive 时 SPM Clang target 的
// -r -object_path_lto 预链接 LTO 问题):
//   1. naked 函数内使用 bl 直接调用, 由汇编器产生正确重定位
//   2. 被 bl 调用的函数标记为 __attribute__((used, noinline)) 且非 static
//   3. isy_runtime_anchor() 被 Swift 显式调用, 在 IR 层面引用所有关键符号
//      让 LTO 看到真实的 call graph 边
//   4. Apple 平台额外使用 .no_dead_strip 防止链接器 dead-strip
//   5. Package.swift 添加 -fno-lto 禁用 bitcode 生成

#include "isy_hot.h"

// Apple AArch64: C 符号有额外下划线前缀; Linux ELF: 无
#if defined(__APPLE__) && defined(__MACH__)
#  define ISY_CSYM(name) _##name
#  define ISY_ASM_BEGIN(name)
#  define ISY_NO_DEAD_STRIP(name) __asm__(".no_dead_strip $-_" #name)
#else
#  define ISY_CSYM(name) name
#  define ISY_NO_DEAD_STRIP(name)
#endif

// ---------- 全局状态 ----------
static isy_syscall_handler_t g_handler = 0;

void isy_set_syscall_handler(isy_syscall_handler_t handler) {
    g_handler = handler;
}

// stats
isy_stats_t g_stats = {0, 0, 0};
const isy_stats_t *isy_get_stats(void) { return &g_stats; }
void isy_reset_stats(void) { g_stats.syscalls = g_stats.traps = g_stats.icache_flushes = 0; }

// ---------- C 端 dispatch ----------
// 注意:
//   - 非 static: 导出为全局符号, 让链接器看到
//   - noinline: 防止被内联消除
//   - used: 标记为"被使用", 即使编译器没看到显式调用
//   - 签名与 isy_syscall_handler_t 一致: 7 uint64_t + isy_cpu_state_t*
__attribute__((noinline, used, visibility("default")))
int64_t __isy_c_syscall_dispatch(
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

// ---------- LTO 锚点: 被 Swift 显式调用, IR 层面引用所有关键符号 ----------
// 这个函数做三件事:
//   1. 作为 Swift -> C 的显式调用点, 创建编译器可见的引用
//   2. volatile 地读取关键符号地址, 防止 LTO 认为它们"未被使用"
//   3. 返回 trap 地址给 Swift (供 BinaryPatcher 使用)
volatile uintptr_t __isy_anchor_sink;  // volatile 全局, 防止优化掉

__attribute__((used, visibility("default")))
uintptr_t isy_runtime_anchor(void) {
    // volatile 写入: 编译器不能消除这些取值操作
    __isy_anchor_sink = (uintptr_t)&__isy_c_syscall_dispatch;
    __isy_anchor_sink = (uintptr_t)&isy_set_syscall_handler;
    __isy_anchor_sink = (uintptr_t)&isy_enter_linux;
    __isy_anchor_sink = (uintptr_t)&isy_get_stats;
    // 返回 trap 地址
    return (uintptr_t)&__isy_syscall_trap;
}

// 获取 trap 函数地址 (供 BinaryPatcher 计算 BL 偏移)
uintptr_t isy_get_trap_address(void) {
    return (uintptr_t)&__isy_syscall_trap;
}

// ---------- Apple 平台: .no_dead_strip 防止链接器 dead-strip ----------
// 注意: Apple 汇编器语法为 .no_dead_strip _symbol_name, 不需要 $ 前缀
#ifdef __APPLE__
__asm__(".no_dead_strip ___isy_syscall_trap");
__asm__(".no_dead_strip ___isy_c_syscall_dispatch");
__asm__(".no_dead_strip ___isy_anchor_sink");
#endif

// ---------- 核心 naked syscall trap ----------
#ifdef __aarch64__

// 协议: Linux ARM64 syscall: x8=nr, x0-x5=args, ret->x0
// 步骤: 保存 callee-saved -> x8->x6, x7=0 -> bl dispatch -> 恢复 -> ret
__attribute__((naked, used))
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
        // 保存 NEON callee-saved (q8-q15, 128 bytes)
        "sub sp, sp, #128\n"
        "stp q8, q9, [sp, #0]\n"
        "stp q10, q11, [sp, #32]\n"
        "stp q12, q13, [sp, #64]\n"
        "stp q14, q15, [sp, #96]\n"

        // x8 (syscall_nr) -> x6 (第 7 个参数)
        // x7 -> 0 (NULL cpu 指针, 第 8 个参数)
        "mov x6, x8\n"
        "mov x7, #0\n"

        // 直接 bl 调用 C dispatch 函数.
        // 编译器/汇编器会为 bl 产生重定位条目,
        // isy_runtime_anchor() 的显式引用确保 LTO 保留该符号.
        // Apple Mach-O: C 符号有 _ 前缀, 所以 __isy_c_syscall_dispatch -> ___isy_c_syscall_dispatch
        // Linux ELF: 无额外前缀, 直接用 __isy_c_syscall_dispatch
#if defined(__APPLE__) && defined(__MACH__)
        "bl ___isy_c_syscall_dispatch\n"
#else
        "bl __isy_c_syscall_dispatch\n"
#endif

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
