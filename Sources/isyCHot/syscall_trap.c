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
    g_stats.syscalls++;
    if (__builtin_expect(g_handler == 0, 0)) {
        return -38; // -ENOSYS
    }
    // 传递 cpu 指针到 handler
    return g_handler(a0, a1, a2, a3, a4, a5, syscall_nr, cpu);
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
    __isy_anchor_sink = (uintptr_t)&isy_request_exit;
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
__asm__(".no_dead_strip ___isy_request_exit");
#endif

// ---------- 核心 naked syscall trap ----------
#ifdef __aarch64__

// 协议: Linux ARM64 syscall: x8=nr, x0-x5=args, ret->x0
// 新实现: 构造 isy_cpu_state_t 在栈上, 保存完整寄存器上下文,
// 传递给 dispatch 函数, 从修改后的 CPU 状态恢复 (支持信号重定向).
// 步骤:
//   1. 分配 288 字节栈空间 (isy_cpu_state_t = 36*8 字节)
//   2. 保存 x0-x30 到 cpu->regs[0..30]
//   3. 保存 sp, pc(lr), pstate, syscall_nr 到 cpu 结构
//   4. x6=syscall_nr, x7=cpu 指针 -> 调用 dispatch
//   5. 从 cpu 结构恢复 x0-x30, sp, pc, pstate
//   6. 返回 (如果信号处理修改了 pc/sp, 则跳转到信号处理函数)
__attribute__((naked, used))
void __isy_syscall_trap(void) {
    __asm__ volatile(
        // 步骤 1: 分配 CPU state 空间 (36*8 = 288 字节, 对齐到 16)
        "sub sp, sp, #304\n"  // 288 + 16 对齐

        // 步骤 2: 保存 x0-x30 到 cpu->regs[0..30]
        "stp x0, x1, [sp, #0]\n"
        "stp x2, x3, [sp, #16]\n"
        "stp x4, x5, [sp, #32]\n"
        "stp x6, x7, [sp, #48]\n"
        "stp x8, x9, [sp, #64]\n"
        "stp x10, x11, [sp, #80]\n"
        "stp x12, x13, [sp, #96]\n"
        "stp x14, x15, [sp, #112]\n"
        "stp x16, x17, [sp, #128]\n"
        "stp x18, x19, [sp, #144]\n"
        "stp x20, x21, [sp, #160]\n"
        "stp x22, x23, [sp, #176]\n"
        "stp x24, x25, [sp, #192]\n"
        "stp x26, x27, [sp, #208]\n"
        "stp x28, x29, [sp, #224]\n"
        "str x30, [sp, #240]\n"       // lr -> regs[30]

        // 步骤 3: 保存 sp, pc, pstate, syscall_nr
        // 计算原始 sp (在分配 304 字节之前) = 当前 sp + 304
        "add x9, sp, #304\n"
        "str x9, [sp, #248]\n"         // cpu->sp = 原始 sp
        "str x30, [sp, #256]\n"        // cpu->pc = lr (返回地址)
        "mrs x9, NZCV\n"
        "str x9, [sp, #264]\n"         // cpu->pstate = NZCV
        "str x8, [sp, #272]\n"         // cpu->syscall_nr = x8

        // 步骤 4: 准备参数并调用 dispatch
        // x0-x5 已经是 args; x6 = syscall_nr; x7 = cpu 指针
        "mov x6, x8\n"                 // x6 = syscall_nr
        "mov x7, sp\n"                 // x7 = &cpu_state

        // 直接 bl 调用 C dispatch 函数
#if defined(__APPLE__) && defined(__MACH__)
        "bl ___isy_c_syscall_dispatch\n"
#else
        "bl __isy_c_syscall_dispatch\n"
#endif

        // 步骤 5: 从 cpu 结构恢复寄存器 (可能被信号处理修改)
        "ldp x0, x1, [sp, #0]\n"
        "ldp x2, x3, [sp, #16]\n"
        "ldp x4, x5, [sp, #32]\n"
        // x6, x7 不需要恢复 (由 dispatch 使用)
        "ldp x8, x9, [sp, #64]\n"
        "ldp x10, x11, [sp, #80]\n"
        "ldp x12, x13, [sp, #96]\n"
        "ldp x14, x15, [sp, #112]\n"
        "ldp x16, x17, [sp, #128]\n"
        "ldp x18, x19, [sp, #144]\n"
        "ldp x20, x21, [sp, #160]\n"
        "ldp x22, x23, [sp, #176]\n"
        "ldp x24, x25, [sp, #192]\n"
        "ldp x26, x27, [sp, #208]\n"
        "ldp x28, x29, [sp, #224]\n"
        "ldr x30, [sp, #240]\n"       // 恢复 lr

        // 检查 pc 是否被修改 (信号处理会设置 pc 为信号处理函数地址)
        "ldr x9, [sp, #256]\n"        // 读取 cpu->pc
        "cmp x9, x30\n"               // 比较 pc 和 lr
        "b.eq 0f\n"                   // 如果相同, 正常返回
        // pc 被修改: 跳转到信号处理函数
        "mov x30, x9\n"               // 设置 lr = 新 pc (信号处理函数)

        "0:\n"
        // 恢复 sp 并返回
        "add sp, sp, #304\n"
        "ret\n"
    );
}

// ---------- iOS 上下文保存 (用于 isy_request_exit 恢复) ----------
// 在进入 Linux 代码前保存 iOS 的栈指针和帧指针,
// isy_request_exit 用它们恢复上下文并返回到 isy_enter_linux 的调用者.
static uint64_t g_isy_saved_ios_sp = 0;
static uint64_t g_isy_saved_ios_fp = 0;
static uint64_t g_isy_saved_ios_lr = 0;
static int      g_isy_exit_code = 0;

// ---------- 执行入口 ----------
// 进入 Linux 代码执行. 使用 blr x16 调用入口, 以便 Linux exit 后能返回.
// 当 Linux 进程调用 exit syscall 时, isy_request_exit 恢复 iOS 上下文
// 并跳转回本函数的返回点 (即 g_isy_saved_ios_lr).
int isy_enter_linux(uintptr_t entry, isy_cpu_state_t *cpu, void *stack_base) {
    (void)stack_base;
    g_isy_exit_code = 0;

    // 保存 iOS 上下文 (在进入 Linux 栈之前)
    __asm__ volatile(
        "mov %0, sp\n"
        "mov %1, x29\n"
        "mov %2, x30\n"
        : "=r"(g_isy_saved_ios_sp),
          "=r"(g_isy_saved_ios_fp),
          "=r"(g_isy_saved_ios_lr)
    );

    // 设置 Linux 寄存器
    register uint64_t x0 asm("x0") = cpu->regs[0];
    register uint64_t x1 asm("x1") = cpu->regs[1];
    register uint64_t x2 asm("x2") = cpu->regs[2];
    register uint64_t x3 asm("x3") = cpu->regs[3];
    register uint64_t x4 asm("x4") = cpu->regs[4];
    register uint64_t x5 asm("x5") = cpu->regs[5];
    register uintptr_t x16 asm("x16") = entry;
    register uint64_t sp asm("sp") = cpu->sp;

    // 跳转到 Linux 代码 (blr 设置 lr 为返回地址)
    __asm__ volatile(
        "msr tpidr_el0, %x[tls]\n"
        "blr x16\n"
        // 从 Linux 代码返回 (通过 isy_request_exit 恢复的上下文)
        "mov %[ret], x0\n"
        : [ret] "=r"(g_isy_exit_code)
        : [tls] "r"(cpu->regs[18]),
          "r"(x0), "r"(x1), "r"(x2), "r"(x3),
          "r"(x4), "r"(x5), "r"(x16), "r"(sp)
        : "memory", "x0"
    );

    return g_isy_exit_code;
}

// ---------- 请求退出 ----------
// 由 exit/exit_group syscall handler 调用.
// 恢复 iOS 上下文并返回到 isy_enter_linux 的调用者.
// 此函数不返回 (noreturn).
__attribute__((naked, used))
void isy_request_exit(int code) {
    (void)code;
    __asm__ volatile(
        // 恢复 iOS 栈指针和帧指针
        "mov sp, %[ios_sp]\n"
        "mov x29, %[ios_fp]\n"
        // 把退出码写入 x0
        "mov x0, %[exit_code]\n"
        // 跳回 isy_enter_linux 的调用者
        "ret %[ios_lr]\n"
        :
        : [ios_sp] "r"(g_isy_saved_ios_sp),
          [ios_fp] "r"(g_isy_saved_ios_fp),
          [ios_lr] "r"(g_isy_saved_ios_lr),
          [exit_code] "r"((uint64_t)(int64_t)code)
        : "memory"
    );
    __builtin_unreachable();
}

#else // !__aarch64__

void __isy_syscall_trap(void) { }

int isy_enter_linux(uintptr_t entry, isy_cpu_state_t *cpu, void *stack_base) {
    (void)entry; (void)cpu; (void)stack_base;
    return -1;
}

void isy_request_exit(int code) {
    (void)code;
    // 非 arm64 平台: 什么都不做 (永远不会被调用)
}

#endif // __aarch64__
