// neon_bridge.c - NEON 向量化加速原语
//
// 用途:
//   1. 给上层 Swift 提供热点 SIMD 原语 (memcpy/memset/矩阵转置)
//   2. 在 syscall 实现中加速大块 I/O (read/write 大缓冲)
//   3. 给 Metal 不可用场景提供 CPU 端 SIMD fallback
//
// 注意: ARM64 Linux 自身代码已经用 NEON 指令, 我们直通即可. 这里提供的是
// isy 运行时自身 (Swift/C 端) 使用的 SIMD 加速, 与 Linux 代码无关.
//
// 非 arm64 平台退化为标量实现, 保证可测试.

#include "isy_hot.h"
#include <string.h>

#ifdef __aarch64__
#include <arm_neon.h>
#endif

void isy_neon_memcpy256(void *dst, const void *src, size_t count) {
#ifdef __aarch64__
    uint8_t *d = (uint8_t *)dst;
    const uint8_t *s = (const uint8_t *)src;
    size_t i = 0;
    // 256-bit (32 字节) 一次拷贝, 用 4 个 64-bit NEON 寄存器
    for (; i + 32 <= count; i += 32) {
        uint8x16x2_t v = vld1q_u8_x2(s + i);
        vst1q_u8_x2(d + i, v);
    }
    if (i < count) {
        memcpy(d + i, s + i, count - i);
    }
#else
    memcpy(dst, src, count);
#endif
}

void isy_neon_memset256(void *dst, uint8_t value, size_t count) {
#ifdef __aarch64__
    uint8_t *d = (uint8_t *)dst;
    uint8x16_t v = vdupq_n_u8(value);
    size_t i = 0;
    for (; i + 32 <= count; i += 32) {
        vst1q_u8(d + i, v);
        vst1q_u8(d + i + 16, v);
    }
    if (i < count) {
        memset(d + i, value, count - i);
    }
#else
    memset(dst, value, count);
#endif
}

// 32x32 int32 矩阵转置: 用 4x4 块转置 + 8-wide NEON
// 32x32 = 1024 元素, 64 个 4x4 块
void isy_neon_transpose_i32_32x32(const int32_t *src, int32_t *dst) {
#ifdef __aarch64__
    for (int i = 0; i < 32; i += 4) {
        for (int j = 0; j < 32; j += 4) {
            // 加载 4x4 块
            int32x4x4_t m;
            m.val[0] = vld1q_s32(src + (i + 0) * 32 + j);
            m.val[1] = vld1q_s32(src + (i + 1) * 32 + j);
            m.val[2] = vld1q_s32(src + (i + 2) * 32 + j);
            m.val[3] = vld1q_s32(src + (i + 3) * 32 + j);
            // 4x4 转置
            int32x4x2_t t01 = vtrnq_s32(m.val[0], m.val[1]);
            int32x4x2_t t23 = vtrnq_s32(m.val[2], m.val[3]);
            int32x4x2_t out0 = vzipq_s32(t01.val[0], t23.val[0]);
            int32x4x2_t out1 = vzipq_s32(t01.val[1], t23.val[1]);
            // 写回转置后的 4x4 块到 dst[j..j+3][i..i+3]
            vst1q_s32(dst + (j + 0) * 32 + i, out0.val[0]);
            vst1q_s32(dst + (j + 1) * 32 + i, out0.val[1]);
            vst1q_s32(dst + (j + 2) * 32 + i, out1.val[0]);
            vst1q_s32(dst + (j + 3) * 32 + i, out1.val[1]);
        }
    }
#else
    for (int i = 0; i < 32; i++) {
        for (int j = 0; j < 32; j++) {
            dst[j * 32 + i] = src[i * 32 + j];
        }
    }
#endif
}
