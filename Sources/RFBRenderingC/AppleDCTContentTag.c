#include "RFBRenderingC.h"
#include <string.h>

// XXH64，按 xxHash 规范实现。只跑在小端的 Apple 平台上（同 AppleDCTKernel）。
#define PRIME1 0x9E3779B185EBCA87ULL
#define PRIME2 0xC2B2AE3D27D4EB4FULL
#define PRIME3 0x165667B19E3779F9ULL
#define PRIME4 0x85EBCA77C2B2AE63ULL
#define PRIME5 0x27D4EB2F165667C5ULL

static inline uint64_t rotl64(uint64_t value, int bits) {
    return (value << bits) | (value >> (64 - bits));
}

static inline uint64_t read64(const uint8_t *bytes) {
    uint64_t value;
    memcpy(&value, bytes, sizeof value);
    return value;
}

static inline uint32_t read32(const uint8_t *bytes) {
    uint32_t value;
    memcpy(&value, bytes, sizeof value);
    return value;
}

static inline uint64_t round64(uint64_t accumulator, uint64_t input) {
    return rotl64(accumulator + input * PRIME2, 31) * PRIME1;
}

static inline uint64_t merge64(uint64_t accumulator, uint64_t value) {
    return (accumulator ^ round64(0, value)) * PRIME1 + PRIME4;
}

uint64_t rfb_xxh64(const void *data, size_t length, uint64_t seed) {
    const uint8_t *bytes = data;
    const uint8_t *const end = bytes + length;
    uint64_t hash;
    if (length >= 32) {
        uint64_t v1 = seed + PRIME1 + PRIME2;
        uint64_t v2 = seed + PRIME2;
        uint64_t v3 = seed;
        uint64_t v4 = seed - PRIME1;
        do {
            v1 = round64(v1, read64(bytes));
            v2 = round64(v2, read64(bytes + 8));
            v3 = round64(v3, read64(bytes + 16));
            v4 = round64(v4, read64(bytes + 24));
            bytes += 32;
        } while ((size_t)(end - bytes) >= 32);
        hash = rotl64(v1, 1) + rotl64(v2, 7) + rotl64(v3, 12) + rotl64(v4, 18);
        hash = merge64(hash, v1);
        hash = merge64(hash, v2);
        hash = merge64(hash, v3);
        hash = merge64(hash, v4);
    } else {
        hash = seed + PRIME5;
    }
    hash += (uint64_t)length;
    while ((size_t)(end - bytes) >= 8) {
        hash = rotl64(hash ^ round64(0, read64(bytes)), 27) * PRIME1 + PRIME4;
        bytes += 8;
    }
    if ((size_t)(end - bytes) >= 4) {
        hash = rotl64(hash ^ ((uint64_t)read32(bytes) * PRIME1), 23) * PRIME2 + PRIME3;
        bytes += 4;
    }
    while (bytes < end) {
        hash = rotl64(hash ^ (*bytes * PRIME5), 11) * PRIME1;
        bytes += 1;
    }
    hash ^= hash >> 33;
    hash *= PRIME2;
    hash ^= hash >> 29;
    hash *= PRIME3;
    hash ^= hash >> 32;
    return hash;
}

// 最高位留给纯色块，0 留给「内容未知」。
static inline uint64_t finish_tag(uint64_t hash) {
    uint64_t tag = hash & 0x7FFFFFFFFFFFFFFFULL;
    return tag == 0 ? 1 : tag;
}

uint64_t rfb_apple_dct_coefficient_tag(
    const int8_t map[99], int16_t dc_y, int16_t dc_cb, int16_t dc_cr) {
    uint8_t buffer[105];
    const int16_t dc[3] = {dc_y, dc_cb, dc_cr};
    memcpy(buffer, map, 99);
    memcpy(buffer + 99, dc, sizeof dc);
    return finish_tag(rfb_xxh64(buffer, sizeof buffer, 1));
}

uint64_t rfb_apple_dct_two_color_tag(uint32_t first, uint32_t second, uint64_t mask) {
    uint8_t buffer[16];
    memcpy(buffer, &first, 4);
    memcpy(buffer + 4, &second, 4);
    memcpy(buffer + 8, &mask, 8);
    return finish_tag(rfb_xxh64(buffer, sizeof buffer, 2));
}
