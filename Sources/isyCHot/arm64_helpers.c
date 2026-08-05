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

// ---------- iOS JIT 内存支持 ----------
// iOS 上执行运行时修改的代码必须使用 MAP_JIT + pthread_jit_write_protect_np.
// macOS (hardened runtime) 也支持但非强制. Linux 上为空操作.
#if defined(__APPLE__) && defined(__MACH__)
#include <pthread.h>
#include <TargetConditionals.h>

#ifndef MAP_JIT
#define MAP_JIT 0x8000
#endif

void isy_jit_write_protect(int enabled) {
    // enabled=1 -> 可执行 (R-X), enabled=0 -> 可写 (R-W)
    pthread_jit_write_protect_np(enabled);
}

int isy_map_jit_flag(void) {
#if TARGET_OS_IPHONE
    return MAP_JIT;  // iOS 必须使用 MAP_JIT
#else
    return 0;        // macOS 不需要 (mprotect RX 即可)
#endif
}
#else
// Linux/其他平台: 空操作
void isy_jit_write_protect(int enabled) { (void)enabled; }
int  isy_map_jit_flag(void) { return 0; }
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
