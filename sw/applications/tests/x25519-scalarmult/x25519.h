#include "fe_hw.h"            // 產生的：fe_mul_hw / fe_sq_hw / fe_mul_a24_hw

// ── 1. 純軟體 field 運算 ───────────────────────────
static void fe_carry(uint32_t h[10]);                 // 進位一輪
static void fe_add(uint32_t h[10], const uint32_t f[10], const uint32_t g[10]);
static void fe_sub(uint32_t h[10], const uint32_t f[10], const uint32_t g[10]);
static void fe_cswap(uint32_t a[10], uint32_t b[10], uint32_t swap);

// ── 2. 編碼 ─────────────────────────────────────
static void fe_frombytes(uint32_t h[10], const uint8_t s[32]);
static void fe_tobytes(uint8_t s[32], const uint32_t h[10]);

// ── 3. 模反元素：254 次 fe_sq_hw + 11 次 fe_mul_hw ──
static void fe_invert(uint32_t out[10], const uint32_t z[10]);

// ── 4. 主函式 ───────────────────────────────────
static void x25519(uint8_t out[32], const uint8_t k[32], const uint8_t u[32]);
