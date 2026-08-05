// arm64_helpers.c - ARM64 系统寄存器与缓存维护 helpers
//
// 这些函数用于:
//   1. TLS 切换: 进入 Linux 代码前保存 iOS TPIDR_EL0, 设置 Linux TLS;
//      syscall trap 时再恢复 (因为 syscall handler 是 iOS 端代码)
//   2. 计时器: 提供 Linux 的 clock_gettime 高精度时钟
//   3. I-cache 维护: patch 后必须 flush I-cache (自修改代码!)
//   4. D-cache clean: 用于 mmap MAP_SHARED 同步
//
// 非 arm64 平台全部为 stub.

#include "isy_hot.h"

#include <stdio.h>  // snprintf (isy_jit_status)

// ---------- ptrace (iOS JIT 启用) ----------
// iOS 上 MAP_JIT 要求进程设置 CS_DEBUGGED 标志.
// 这通常由调试器附加完成, 但我们也可以自己调用 ptrace(PT_TRACE_ME, 0).
// ptrace 在 iOS SDK 中未声明, 用 syscall 直接调用.
#if defined(__APPLE__) && defined(__MACH__)
#include <sys/syscall.h>
#include <unistd.h>
#include <errno.h>

#ifndef PT_TRACE_ME
#define PT_TRACE_ME 0
#endif

// SYS_ptrace 在 iOS 上存在但头文件未声明
#ifndef SYS_ptrace
#define SYS_ptrace 26
#endif
#endif

// ---------- iOS JIT 内存支持 ----------
// iOS 上执行运行时修改的代码必须使用 MAP_JIT 内存.
//
// 关键事实:
//   1. pthread_jit_write_protect_np 在 iOS SDK 的 libsystem_pthread.tbd 中
//      未导出, 导致 weak_import + asm label 仍然链接失败 ("symbol not found").
//      (它只在 macOS SDK 中可用, iOS 上是隐藏的私有符号)
//   2. dlsym(RTLD_DEFAULT, ...) 在 iOS 上也搜不到该私有符号.
//   3. iOS 17+ 上, 对于带 com.apple.security.cs.allow-jit entitlement 的应用,
//      MAP_JIT 内存可以自动 W<->X 切换, 无需显式调用 write-protect 函数.
//      (系统根据访问模式自动处理)
//
// 策略:
//   - iOS: 直接使用 MAP_JIT, 不调用 pthread_jit_write_protect_np
//          (依赖系统自动 W^X 切换)
//   - macOS: 用 dlsym 查找 pthread_jit_write_protect_np (hardened runtime 需要)
//   - Linux: 空操作
#if defined(__APPLE__) && defined(__MACH__)
#include <dlfcn.h>
#include <TargetConditionals.h>

#ifndef MAP_JIT
#define MAP_JIT 0x8000
#endif

typedef void (*isy_jit_write_protect_fn)(int);

// JIT 状态 (诊断用)
static int  isy_jit_wp_available = 0;   // 0=未初始化, 1=可用, -1=不可用
static const char *isy_jit_wp_source = "none";

static isy_jit_write_protect_fn isy_lookup_jit_write_protect(void) {
    static isy_jit_write_protect_fn func = NULL;
    static bool initialized = false;
    if (!initialized) {
        // iOS 上不查找 (符号未导出, 找不到也用不了)
        // 直接依赖 MAP_JIT 内存的自动 W^X 切换
#if !TARGET_OS_IPHONE
        // macOS: 用 dlsym 查找 (hardened runtime 需要)
        func = (isy_jit_write_protect_fn)dlsym(RTLD_DEFAULT, "pthread_jit_write_protect_np");
        if (func) {
            isy_jit_wp_available = 1;
            isy_jit_wp_source = "dlsym";
        } else {
            isy_jit_wp_available = -1;
            isy_jit_wp_source = "not_found";
        }
#else
        // iOS: write-protect 函数不可访问, 但 MAP_JIT 内存仍可用
        isy_jit_wp_available = -1;
        isy_jit_wp_source = "auto (iOS MAP_JIT)";
#endif
        initialized = true;
    }
    return func;
}

void isy_jit_write_protect(int enabled) {
    // enabled=1 -> 可执行 (R-X), enabled=0 -> 可写 (R-W)
    // iOS 上: 空操作 (MAP_JIT 内存自动切换)
    // macOS 上: 调用 dlsym 找到的函数
    isy_jit_write_protect_fn func = isy_lookup_jit_write_protect();
    if (func) {
        func(enabled);
    }
}

int isy_map_jit_flag(void) {
#if TARGET_OS_IPHONE
    // iOS: 必须使用 MAP_JIT 才能执行运行时修改的代码.
    // 即使 pthread_jit_write_protect_np 不可用, MAP_JIT 内存仍可用:
    // iOS 17+ 上带 com.apple.security.cs.allow-jit entitlement 时,
    // MAP_JIT 内存的 W/X 切换由系统自动处理.
    return MAP_JIT;
#else
    // macOS: 不需要 MAP_JIT (mprotect RX 即可)
    return 0;
#endif
}

// CS_DEBUGGED 状态: -1=未尝试, 0=失败, 1=成功
static int isy_jit_cs_debugged = -1;

int isy_enable_jit(void) {
#if defined(__APPLE__) && defined(__MACH__) && TARGET_OS_IPHONE
    if (isy_jit_cs_debugged != -1) {
        return isy_jit_cs_debugged ? 0 : -1;
    }
    // 调用 ptrace(PT_TRACE_ME, 0) 设置 CS_DEBUGGED 标志
    // 这是 MAP_JIT 在 iOS 上工作的必要条件
    // (iSH/UTM 等项目都用这种方式启用 JIT)
    errno = 0;
    long r = syscall(SYS_ptrace, PT_TRACE_ME, 0, 0, 0);
    if (r == 0) {
        isy_jit_cs_debugged = 1;
        return 0;
    }
    // ptrace 失败可能是因为: 无 get-task-allow entitlement, 或已在调试器下
    // 即使失败也继续, MAP_JIT 可能仍可用 (取决于 iOS 版本和签名方式)
    isy_jit_cs_debugged = 0;
    return -1;
#else
    isy_jit_cs_debugged = 1;  // 非 iOS 平台不需要
    return 0;
#endif
}

const char *isy_jit_status(void) {
    isy_lookup_jit_write_protect();  // 确保已初始化
    static char buf[256];
#if TARGET_OS_IPHONE
    const char *platform = "iOS";
#else
    const char *platform = "macOS";
#endif
#if defined(__aarch64__)
    const char *arch = "arm64";
#else
    const char *arch = "non-arm64";
#endif
    snprintf(buf, sizeof(buf),
             "platform=%s arch=%s map_jit=%d wp_fn=%s (available=%d) cs_debugged=%d",
             platform, arch,
             isy_map_jit_flag(),
             isy_jit_wp_source,
             isy_jit_wp_available,
             isy_jit_cs_debugged);
    return buf;
}
#else
// Linux/其他平台: 空操作
void isy_jit_write_protect(int enabled) { (void)enabled; }
int  isy_map_jit_flag(void) { return 0; }
int  isy_enable_jit(void) { return 0; }
const char *isy_jit_status(void) { return "platform=Linux map_jit=0 wp_fn=none"; }
#endif

#ifdef __aarch64__

uint64_t isy_arm64_get_tpidr_el0(void) {
    uint64_t v;
    __asm__ volatile("mrs %0, tpidr_el0" : "=r"(v));
    return v;
}

void isy_arm64_set_tpidr_el0(uint64_t value) {
    __asm__ volatile("msr tpidr_el0, %0" : : "r"(value));
}

uint64_t isy_arm64_get_cntfrq(void) {
    uint64_t v;
    __asm__ volatile("mrs %0, cntfrq_el0" : "=r"(v));
    return v;
}

uint64_t isy_arm64_get_cntvct(void) {
    uint64_t v;
    __asm__ volatile("mrs %0, cntvct_el0" : "=r"(v));
    return v;
}

void isy_arm64_flush_icache(void *addr, size_t len) {
    // D-cache clean to PoU, then I-cache invalidate to PoU, then DSB/ISB
    char *p = (char *)addr;
    char *end = p + len;
    // DC CVAU 对齐到 16 字节
    while (p < end) {
        __asm__ volatile("dc cvau, %0" : : "r"(p));
        p += 16;
    }
    __asm__ volatile("dsb ish");
    p = (char *)addr;
    while (p < end) {
        __asm__ volatile("ic ivau, %0" : : "r"(p));
        p += 16;
    }
    __asm__ volatile("dsb ish");
    __asm__ volatile("isb");
}

void isy_arm64_dc_cvau(void *addr, size_t len) {
    char *p = (char *)addr;
    char *end = p + len;
    while (p < end) {
        __asm__ volatile("dc cvau, %0" : : "r"(p));
        p += 16;
    }
    __asm__ volatile("dsb ish");
}

#else

uint64_t isy_arm64_get_tpidr_el0(void) { return 0; }
void     isy_arm64_set_tpidr_el0(uint64_t value) { (void)value; }
uint64_t isy_arm64_get_cntfrq(void) { return 1000000000ULL; /* 1GHz 默认 */ }
uint64_t isy_arm64_get_cntvct(void) { return 0; }
void     isy_arm64_flush_icache(void *addr, size_t len) { (void)addr; (void)len; }
void     isy_arm64_dc_cvau(void *addr, size_t len) { (void)addr; (void)len; }

#endif
