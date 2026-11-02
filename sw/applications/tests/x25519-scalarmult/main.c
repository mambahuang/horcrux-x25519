/**
 * @file main.c
 * @brief X25519 Test - full scalar multiplication on the M2/M3 ACC instructions
 *
 * 1. field 運算（fe_sq_hw / fe_mul_a24_hw / fe_add / fe_sub / 編碼 / fe_invert）
 *    對 sw/golden/gen_x25519.py 的 8 組向量。
 * 2. X25519 對 RFC 7748 §5.2 與 §6.1 的 7 組向量，每組計時。
 */

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "x25519.h"
#include "test_vectors.h"
#include "core_v_mini_mcu.h"
#include "csr.h"

static const uint32_t OFFSET[11] = {
    (51 * 0 + 1) / 2, // 0
    (51 * 1 + 1) / 2, // 26
    (51 * 2 + 1) / 2, // 51
    (51 * 3 + 1) / 2, // 77
    (51 * 4 + 1) / 2, // 102
    (51 * 5 + 1) / 2, // 128
    (51 * 6 + 1) / 2, // 153
    (51 * 7 + 1) / 2, // 179
    (51 * 8 + 1) / 2, // 204
    (51 * 9 + 1) / 2, // 230
    (51 * 10 + 1) / 2 // 255
};
static const uint32_t W[10] = {
    26, 25, 26, 25, 26,
    25, 26, 25, 26, 25
};
static const uint32_t MASK[10] = {
    0x3ffffff,0x1ffffff,0x3ffffff,0x1ffffff,0x3ffffff,
    0x1ffffff,0x3ffffff,0x1ffffff,0x3ffffff,0x1ffffff
};


static const uint32_t TWO_P[10] = {
    0x7ffffda, 0x3fffffe, 0x7fffffe, 0x3fffffe, 0x7fffffe,
    0x3fffffe, 0x7fffffe, 0x3fffffe, 0x7fffffe, 0x3fffffe
};

// ── 1. 純軟體 field 運算 ───────────────────────────
static void fe_carry(uint32_t h[10]) {
    uint32_t c;
    for (int i = 0; i < 10; i++) {
        c = h[i] >> W[i];
        h[i] &= MASK[i];
        if (i < 9) {
            h[i+1] += c;
        } else {
            h[0] += 19 * c;
        }
    }
    c = h[0] >> 26;  
    h[0] &= MASK[0]; 
    h[1] += c;

}
static void fe_add(uint32_t h[10], const uint32_t f[10], const uint32_t g[10]){
    for (int i = 0; i < 10; i++) {
        h[i] = f[i] + g[i];
    }
    fe_carry(h);
}
static void fe_sub(uint32_t h[10], const uint32_t f[10], const uint32_t g[10]){
    for (int i = 0; i < 10; i++) {
        h[i] = f[i] + TWO_P[i] - g[i];
    }
    fe_carry(h);
}
static void fe_cswap(uint32_t a[10], uint32_t b[10], uint32_t swap){
    uint32_t mask = -swap; // swap=1 → 0xffffffff；swap=0 → 0
    // 優化屏障：不產生指令，但讓 gcc 不知道 mask 只會是 0 或 0xffffffff。
    // 少了這行，gcc 會把下面的 and/xor 改寫成依 swap 跳轉的 beqz，
    // 執行時間就會洩漏私鑰的 bit（server 上量到不同私鑰差到約 5000 cycles）
    __asm__ volatile ("" : "+r"(mask));
    for (int i = 0; i < 10; i++) {
        uint32_t t = mask & (a[i] ^ b[i]);
        a[i] ^= t;
        b[i] ^= t;
    }
}

// ── 2. 編碼 ─────────────────────────────────────
static void fe_frombytes(uint32_t h[10], const uint8_t s[32]){
    uint32_t w[8];
    for (int i = 0; i < 8; i++) {               // 4 bytes → 1 word (little-endian)
        w[i] = (uint32_t)s[4*i]           | ((uint32_t)s[4*i+1] << 8)
             | ((uint32_t)s[4*i+2] << 16) | ((uint32_t)s[4*i+3] << 24);
    }
    w[7] &= 0x7fffffff;                         // RFC 7748: ignore bit 255
    for (int i = 0; i < 10; i++) {
        uint32_t idx = OFFSET[i] / 32, sh = OFFSET[i] % 32;
        uint32_t v = w[idx] >> sh;              // low part from this word
        if (sh + W[i] > 32)                     // straddles a word: take the rest from the next one
            v |= w[idx+1] << (32 - sh);
        h[i] = v & MASK[i];
    }
}
static void fe_tobytes(uint8_t s[32], const uint32_t h[10]){
    uint32_t t[10], w[8] = {0}, q, c;
    for (int i = 0; i < 10; i++) t[i] = h[i];

    // Step 1: carry twice → every limb fits its width, value < 2^255
    fe_carry(t);
    fe_carry(t);

    // Step 2: decide whether value ≥ p
    //   value ≥ p  ⇔  value + 19 ≥ 2^255
    //   so "add 19 and see whether it carries out of bit 255" — only the carries are computed, t is unchanged
    q = (t[0] + 19) >> 26;
    for (int i = 1; i < 10; i++) q = (t[i] + q) >> W[i];
    // q = 1 means value ≥ p, q = 0 means it's already < p

    // Step 3: if q = 1, subtract p: add 19, carry, drop bit 255 (= subtract 2^255)
    t[0] += 19 * q;
    for (int i = 0; i < 9; i++) { c = t[i] >> W[i]; t[i] &= MASK[i]; t[i+1] += c; }
    t[9] &= MASK[9];

    // Step 4: limbs → words (the reverse of frombytes)
    for (int i = 0; i < 10; i++) {
        uint32_t idx = OFFSET[i] / 32, sh = OFFSET[i] % 32;
        w[idx] |= t[i] << sh;
        if (sh + W[i] > 32) w[idx+1] |= t[i] >> (32 - sh);
    }
    // words → bytes
    for (int i = 0; i < 8; i++) {
        s[4*i] = w[i]; 
        s[4*i+1] = w[i] >> 8; 
        s[4*i+2] = w[i] >> 16; 
        s[4*i+3] = w[i] >> 24;
    }
}

static void fe_sq_n(uint32_t h[10], const uint32_t f[10], int n){
    fe_sq_hw(h, f);                          // first squaring copies f into h
    for (int i = 1; i < n; i++) fe_sq_hw(h, h);
}

// ── 3. 模反元素：254 次 fe_sq_hw + 11 次 fe_mul_hw ──
static void fe_invert(uint32_t out[10], const uint32_t z[10]){
    uint32_t z2[10], z9[10], z11[10], z_10_0[10], z_50_0[10], t[10], u[10];

    fe_sq_hw(z2, z);                 // z^2
    fe_sq_n(t, z2, 2);               // z^8
    fe_mul_hw(z9, t, z);             // z^9
    fe_mul_hw(z11, z9, z2);          // z^11
    fe_sq_hw(t, z11);                // z^22
    fe_mul_hw(t, t, z9);             // t = z_5_0 (5 ones)

    fe_sq_n(z_10_0, t, 5);
    fe_mul_hw(z_10_0, z_10_0, t);    // z_10_0

    fe_sq_n(t, z_10_0, 10);
    fe_mul_hw(t, t, z_10_0);         // t = z_20_0

    fe_sq_n(u, t, 20);
    fe_mul_hw(t, u, t);              // t = z_40_0

    fe_sq_n(t, t, 10);
    fe_mul_hw(z_50_0, t, z_10_0);    // z_50_0 (keep it; needed again for 250)

    fe_sq_n(t, z_50_0, 50);
    fe_mul_hw(t, t, z_50_0);         // t = z_100_0

    fe_sq_n(u, t, 100);
    fe_mul_hw(t, u, t);              // t = z_200_0

    fe_sq_n(t, t, 50);
    fe_mul_hw(t, t, z_50_0);         // t = z_250_0

    fe_sq_n(t, t, 5);
    fe_mul_hw(out, t, z11);          // z^(2^255 - 21) = z^(p-2)

}


// ── 4. 主函式 ───────────────────────────────────
static void x25519(uint8_t out[32], const uint8_t k[32], const uint8_t u[32]){
    uint8_t e[32];
    memcpy(e, k, 32);     // 複製一份，不要改到呼叫者的 k（它是 const）
    e[0]  &= 248;         // 清掉最低 3 bit
    e[31] &= 127;         // 清掉 bit 255
    e[31] |= 64;          // 設定 bit 254

    uint32_t x1[10];
    fe_frombytes(x1, u);               // x1 = u（limb），整個 ladder 不變
    uint32_t x2[10] = {1};             // x2 = 1
    uint32_t z2[10] = {0};             // z2 = 0
    uint32_t x3[10];
    memcpy(x3, x1, sizeof x3);         // x3 = u
    uint32_t z3[10] = {1};             // z3 = 1

    uint32_t swap = 0;
    uint32_t k_t;
    uint32_t A[10], AA[10];
    uint32_t B[10], BB[10];
    uint32_t C[10], D[10], E[10], DA[10], CB[10], tmp[10];
    for (int i = 254; i >= 0; i--) {
        k_t = (e[i>>3] >> (i & 7)) & 1;
        swap ^= k_t;
        fe_cswap(x2, x3, swap);
        fe_cswap(z2, z3, swap);
        swap = k_t;
        fe_add(A, x2, z2);  // a = x2 + z2
        fe_sq_hw(AA, A);       // a = (x2 + z2)^2
        fe_sub(B, x2, z2);  // b = x2 - z2
        fe_sq_hw(BB, B);        // b = (x2 - z2)^2
        fe_sub(E, AA, BB);  // c = (x2 + z2)^2 - (x2 - z2)^2
        fe_add(C, x3, z3);  // c = x3 + z3
        fe_sub(D, x3, z3);  // d = x3 - z3
        fe_mul_hw(DA, D, A);  // da = d * a
        fe_mul_hw(CB, C, B);  // cb = c * b
        fe_add(x3, DA, CB);  // x3 = da + cb
        fe_sq_hw(x3, x3);  // x3 = (da + cb)^2
        fe_sub(z3, DA, CB);  // z3 = da - cb
        fe_sq_hw(z3, z3);  // z3 = (da - cb)^2
        fe_mul_hw(z3, z3, x1);  // z3 = x1 * (da - cb)^2
        fe_mul_hw(x2, AA, BB);  // x2 = aa * bb
        fe_mul_a24_hw(tmp, E);  // tmp = a24 * e
        fe_add(tmp, AA, tmp);   // tmp = aa + a24 * e
        fe_mul_hw(z2, E, tmp);  // z2 = e * (aa + a24 * e)
    }

    fe_cswap(x2, x3, swap);
    fe_cswap(z2, z3, swap);
    fe_invert(z2, z2);      // z2 = 1 / z2
    fe_mul_hw(x2, x2, z2);  // x2 = x2 / z2
    fe_tobytes(out, x2);
}

// ── 5. 測試 ─────────────────────────────────────
// 不相等就印出 FAIL（回歸腳本靠大寫的 FAIL 判斷失敗）；相等回傳 1
static int check_limbs(const char *op, const char *name,
                       const uint32_t got[10], const uint32_t exp[10]) {
    for (int j = 0; j < 10; j++) {
        if (got[j] != exp[j]) {
            printf("[%s] %s FAIL: limb %d exp=0x%08lX got=0x%08lX\n", name, op, j,
                   (unsigned long)exp[j], (unsigned long)got[j]);
            return 0;
        }
    }
    return 1;
}

static int check_bytes(const char *op, const char *name,
                       const uint8_t got[32], const uint8_t exp[32]) {
    for (int j = 0; j < 32; j++) {
        if (got[j] != exp[j]) {
            printf("[%s] %s FAIL: byte %d exp=0x%02X got=0x%02X\n", name, op, j, exp[j], got[j]);
            return 0;
        }
    }
    return 1;
}

// 第 1 步：每個 field 運算各自比對 golden，ladder 出錯時可以知道是哪個函式
static int test_field_ops(void) {
    int ok = 1;
    for (int i = 0; i < FE_OP_N_VECTORS; i++) {
        const fe_op_vector_t *v = &fe_op_vectors[i];
        uint32_t h[10];
        uint8_t s[32];

        fe_sq_hw(h, v->f);       ok &= check_limbs("fe_sq_hw", v->name, h, v->sq);
        fe_mul_a24_hw(h, v->f);  ok &= check_limbs("fe_mul_a24_hw", v->name, h, v->a24);
        fe_add(h, v->f, v->g);   ok &= check_limbs("fe_add", v->name, h, v->add);
        fe_sub(h, v->f, v->g);   ok &= check_limbs("fe_sub", v->name, h, v->sub);

        // 原地：ladder 和 fe_invert 都會呼叫 fe_sq_hw(t, t)
        memcpy(h, v->f, sizeof h);
        fe_sq_hw(h, h);          ok &= check_limbs("fe_sq_hw in place", v->name, h, v->sq);

        fe_tobytes(s, v->f);     ok &= check_bytes("fe_tobytes", v->name, s, v->f_bytes);
        fe_frombytes(h, v->f_bytes);
        fe_tobytes(s, h);        ok &= check_bytes("fe_frombytes", v->name, s, v->f_bytes);
        fe_invert(h, v->f);
        fe_tobytes(s, h);        ok &= check_bytes("fe_invert", v->name, s, v->inv_bytes);
    }
    if (ok) printf("PASSED: field ops (%d vectors)\n", FE_OP_N_VECTORS);
    return ok;
}

// 第 2 步：RFC 7748 §5.2 / §6.1，每組各自計時。ladder 是 constant time，
// 所以每組的 cycle 數應該幾乎相同
static int test_x25519(void) {
    int ok = 1;
    for (int i = 0; i < X25519_N_VECTORS; i++) {
        const x25519_vector_t *v = &x25519_vectors[i];
        uint8_t out[32];
        unsigned int cycles = 0;

        CSR_WRITE(CSR_REG_MCYCLE, 0);
        x25519(out, v->k, v->u);
        CSR_READ(CSR_REG_MCYCLE, &cycles);

        ok &= check_bytes("x25519", v->name, out, v->out);
        printf("X25519 vector %d Cycles: %u\n", i, cycles);
    }
    if (ok) printf("PASSED: X25519 RFC 7748 (%d vectors)\n", X25519_N_VECTORS);
    return ok;
}

int main(void) {
    int all_passed = 1;

    // Initialize cycle counter
    CSR_CLEAR_BITS(CSR_REG_MCOUNTINHIBIT, 0x1);
    CSR_WRITE(CSR_REG_MCYCLE, 0);

    printf("   X25519 SCALARMULT TEST      \n");

    all_passed &= test_field_ops();
    all_passed &= test_x25519();

    if (all_passed) {
        printf("FINAL STATUS: ALL TESTS PASSED\n");
    } else {
        printf("FINAL STATUS: TEST FAILURE DETECTED\n");
    }

    return EXIT_SUCCESS;
}