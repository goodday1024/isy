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

// ---------- iOS JIT 内存支持 ----------
// iOS 上执行运行时修改的代码必须使用 MAP_JIT + pthread_jit_write_protect_np.
//
// 关键问题: pthread_jit_write_protect_np 在 iOS SDK 头文件中被标记为
// __API_UNAVAILABLE(ios), 但符号在 libsystem_pthread.dylib 中确实存在.
//
// 解决方案:
//   1. 用 asm label ("_pthread_jit_write_protect_np") 绕过 SDK 头件的
//      unavailable 标记 (我们不 include <pthread.h>, 直接声明)
//   2. 用 weak_import 保证符号不存在时不会链接失败 (回退为 NULL)
//   3. dlsym 作为 macOS 的 fallback (iOS 上 dlsym 搜不到私有符号)
//
// 为什么 dlsym 在 iOS 上失败:
//   iOS 的 dlsym(RTLD_DEFAULT, ...) 只搜索 public exported symbols.
//   pthread_jit_write_protect_np 是私有符号, 不在 public export trie 中.
//   但 weak_import 在 link time 直接解析符号 (不走 dlsym), 所以能找到.
#if defined(__APPLE__) && defined(__MACH__)
#include <dlfcn.h>
#include <TargetConditionals.h>

#ifndef MAP_JIT
#define MAP_JIT 0x8000
#endif

// 用 asm label 声明符号, 绕过 SDK 头文件的 __API_UNAVAILABLE(ios) 标记.
// weak_import: 如果符号在 link library 中不存在, 运行时为 NULL (不会链接失败).
extern void isy_pthread_jit_write_protect_np(int enable)
    __attribute__((weak_import))
    __asm("_pthread_jit_write_protect_np");

typedef void (*isy_jit_write_protect_fn)(int);

// JIT 状态 (诊断用)
static int  isy_jit_wp_available = 0;   // 0=未初始化, 1=可用, -1=不可用
static const char *isy_jit_wp_source = "none";

static isy_jit_write_protect_fn isy_lookup_jit_write_protect(void) {
    static isy_jit_write_protect_fn func = NULL;
    static bool initialized = false;
    if (!initialized) {
        // Method 1: weak_import 符号 (link-time 解析, iOS 上能找到私有符号)
        if (isy_pthread_jit_write_protect_np != NULL) {
            func = isy_pthread_jit_write_protect_np;
            isy_jit_wp_available = 1;
            isy_jit_wp_source = "weak_import";
        }
        // Method 2: dlsym (macOS fallback, 或 iOS 上作为最后手段)
        if (!func) {
            func = (isy_jit_write_protect_fn)dlsym(RTLD_DEFAULT, "pthread_jit_write_protect_np");
            if (func) {
                isy_jit_wp_available = 1;
                isy_jit_wp_source = "dlsym";
            }
        }
        if (!func) {
            isy_jit_wp_available = -1;
            isy_jit_wp_source = "not_found";
        }
        initialized = true;
    }
    return func;
}

void isy_jit_write_protect(int enabled) {
    // enabled=1 -> 可执行 (R-X), enabled=0 -> 可写 (R-W)
    isy_jit_write_protect_fn func = isy_lookup_jit_write_protect();
    if (func) {
        func(enabled);
    }
    // 如果函数不可用 (无 entitlement), 静默忽略
}

int isy_map_jit_flag(void) {
#if TARGET_OS_IPHONE
    // iOS: 必须使用 MAP_JIT 才能执行运行时修改的代码.
    // 即使 pthread_jit_write_protect_np 不可用, MAP_JIT 内存也必须使用,
    // 否则 mprotect(PROT_EXEC) 会返回 EINVAL (这正是之前的启动失败原因).
    // 如果 write-protect 函数不可用, MAP_JIT 内存将无法执行 (会在执行时 crash),
    // 但至少错误信息会更明确.
    isy_jit_write_protect_fn func = isy_lookup_jit_write_protect();
    if (func != NULL) {
        return MAP_JIT;
    }
    // write-protect 函数不可用, MAP_JIT 也无法使用
    // 这种情况下 isy 无法在 iOS 上运行 Linux 代码
    return 0;
#else
    // macOS: 不需要 MAP_JIT (mprotect RX 即可, 但 hardened runtime 需要 entitlement)
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
             "platform=%s arch=%s map_jit=%d wp_fn=%s (available=%d)",
             platform, arch,
             isy_map_jit_flag(),
             isy_jit_wp_source,
             isy_jit_wp_available);
    return buf;
}
#else
// Linux/其他平台: 空操作
void isy_jit_write_protect(int enabled) { (void)enabled; }
int  isy_map_jit_flag(void) { return 0; }
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
