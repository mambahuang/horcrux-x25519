/**
 * @file main.c
 * @brief X25519 fe_mul Test - Software (ref10) vs Hardware (M2 ACC instructions)
 *
 * h = f * g mod 2^255-19 on the 20 vectors from sw/golden/gen_fe_mul.py.
 * 硬體結果必須和 golden model 逐個 limb 相同；ref10 的 limb 是有號數，
 * 所以轉成 32-byte 編碼再比。
 */

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include "fe_mul_hw.h"
#include "fe_mul_ref10.h"
#include "test_vectors.h"
#include "core_v_mini_mcu.h"
#include "csr.h"

// Software test flag - set to 0 to skip SW tests, 1 to run SW+HW tests
#ifndef SW_TEST_ENABLED
#define SW_TEST_ENABLED 1
#endif

// 不相等就印出 FAIL（回歸腳本靠大寫的 FAIL 判斷失敗）；相等回傳 1
static int check(const char *what, int idx, uint32_t got, uint32_t exp) {
    if (got != exp) {
        printf("[%s %d] FAIL: exp=0x%08lX got=0x%08lX\n", what, idx, exp, got);
        return 0;
    }
    return 1;
}

// 計算結果。驗證時還要讀，所以編譯器不能把寫回結果的 store 刪掉
static fe results_sw[FE_MUL_N_VECTORS];
static uint32_t results_hw[FE_MUL_N_VECTORS][10];

static void fe_mul_sw_compute(fe results[]) {
    for (int i = 0; i < FE_MUL_N_VECTORS; i++) {
        fe_mul_ref10(results[i], (const int32_t *)fe_mul_vectors[i].f,
                                 (const int32_t *)fe_mul_vectors[i].g);
    }
}

static int fe_mul_sw_verify(const fe results[]) {
    int ok = 1;
    for (int i = 0; i < FE_MUL_N_VECTORS; i++) {
        uint8_t s[32];
        fe_tobytes_ref10(s, results[i]);
        for (int k = 0; k < 32; k++) {
            ok &= check("ref10", i * 32 + k, s[k], fe_mul_vectors[i].h_bytes[k]);
        }
    }
    if (ok) printf("PASSED: X25519 fe_mul (Software, ref10)\n");
    return ok;
}

static void fe_mul_hw_compute(uint32_t results[][10]) {
    for (int i = 0; i < FE_MUL_N_VECTORS; i++) {
        fe_mul_hw(results[i], fe_mul_vectors[i].f, fe_mul_vectors[i].g);
    }
}

static int fe_mul_hw_verify(const uint32_t results[][10]) {
    int ok = 1;
    for (int i = 0; i < FE_MUL_N_VECTORS; i++) {
        for (int j = 0; j < 10; j++) {
            ok &= check(fe_mul_vectors[i].name, j, results[i][j], fe_mul_vectors[i].h[j]);
        }
    }
    if (ok) printf("PASSED: X25519 fe_mul (Hardware)\n");
    return ok;
}

// 原地計算：ladder 會呼叫 fe_mul_hw(x, x, y)，輸出和輸入是同一個陣列
static int fe_mul_hw_in_place(void) {
    int ok = 1;
    for (int i = 0; i < FE_MUL_N_VECTORS; i++) {
        uint32_t x[10];
        for (int j = 0; j < 10; j++) x[j] = fe_mul_vectors[i].f[j];
        fe_mul_hw(x, x, fe_mul_vectors[i].g);
        for (int j = 0; j < 10; j++) {
            ok &= check("in-place", i * 10 + j, x[j], fe_mul_vectors[i].h[j]);
        }
    }
    if (ok) printf("PASSED: X25519 fe_mul in place (Hardware)\n");
    return ok;
}

int main(void) {
    int all_passed = 1;
    unsigned int cycles_sw = 0;
    unsigned int cycles_hw = 0;

    // Initialize cycle counter
    CSR_CLEAR_BITS(CSR_REG_MCOUNTINHIBIT, 0x1);
    CSR_WRITE(CSR_REG_MCYCLE, 0);

    printf("   X25519 FE_MUL TEST          \n");

#if SW_TEST_ENABLED
    CSR_WRITE(CSR_REG_MCYCLE, 0);
    fe_mul_sw_compute(results_sw);
    CSR_READ(CSR_REG_MCYCLE, &cycles_sw);
    all_passed &= fe_mul_sw_verify(results_sw);
    printf("Software Cycles: %u\n\n", cycles_sw);
#else
    printf("--- SOFTWARE TEST SKIPPED ---\n\n");
#endif

    CSR_WRITE(CSR_REG_MCYCLE, 0);
    fe_mul_hw_compute(results_hw);
    CSR_READ(CSR_REG_MCYCLE, &cycles_hw);
    all_passed &= fe_mul_hw_verify(results_hw);
    all_passed &= fe_mul_hw_in_place();
    printf("Hardware Cycles: %u\n", cycles_hw);

#if SW_TEST_ENABLED
    printf("SW Cycles: %u | HW Cycles: %u\n", cycles_sw, cycles_hw);
    if (cycles_sw > 0) {
        printf("Speedup: %u.%02ux\n", cycles_sw / cycles_hw, ((cycles_sw * 100) / cycles_hw) % 100);
    }
#endif

    if (all_passed) {
        printf("FINAL STATUS: ALL TESTS PASSED\n");
    } else {
        printf("FINAL STATUS: TEST FAILURE DETECTED\n");
    }

    return EXIT_SUCCESS;
}
