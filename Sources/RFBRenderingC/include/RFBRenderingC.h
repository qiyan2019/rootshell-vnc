#ifndef RFB_RENDERING_C_H
#define RFB_RENDERING_C_H

#include <stddef.h>
#include <stdint.h>

/// Decode three 8x8 Apple DCT coefficient planes to 64 native BGRA pixels.
void rfb_apple_dct_tile_bgra(
    uint32_t output[64],
    const int16_t coefficients[192],
    const uint16_t luma_quantization[64],
    const uint16_t chroma_quantization[64]);

/// XXH64。内容标识判错的后果是跳过写入、屏幕留下旧内容，所以要收尾混合好的哈希。
uint64_t rfb_xxh64(const void *data, size_t length, uint64_t seed);

/// 一块系数的内容标识，保证非零且最高位为 0。
/// 系数由 `map` 加三个平面的 DC 唯一确定（DC 可能超出 Int8，`map` 里存的是截断值）。
uint64_t rfb_apple_dct_coefficient_tag(
    const int8_t map[99], int16_t dc_y, int16_t dc_cb, int16_t dc_cr);

/// 双色块的内容标识。`mask` 从高字节到低字节依次是第 0–7 行，置位的像素取 `first`。
uint64_t rfb_apple_dct_two_color_tag(uint32_t first, uint32_t second, uint64_t mask);

#endif
