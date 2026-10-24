/**
 * @file main.c
 * @brief Poly1305 block Test - Hardware (M2 ACC instructions)
 *
 * h = (h + m) * r mod 2^130-5 on the 20 vectors from sw/golden/gen_poly1305.py.
 * 硬體結果必須和 golden model 逐個 limb 相同。
 * 軟體基準尚未接上。
 */

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include "poly1305_hw.h"
#include "test_vectors.h"
#include "core_v_mini_mcu.h"
#include "csr.h"

// 不相等就印出 FAIL（回歸腳本靠大寫的 FAIL 判斷失敗）；相等回傳 1
static int check(const char *what, int idx, uint32_t got, uint32_t exp) {
    if (got != exp) {
        printf("[%s %d] FAIL: exp=0x%08lX got=0x%08lX\n", what, idx, exp, got);
        return 0;
    }
    return 1;
}

// 計算結果。h 是輸入也是輸出，所以先放入輸入 h，計算後就地更新成輸出
static uint32_t results_hw[POLY1305_N_VECTORS][5];

// 在計時之前把每組的輸入 h 複製進結果陣列
static void poly1305_hw_init(uint32_t results[][5]) {
    for (int i = 0; i < POLY1305_N_VECTORS; i++) {
        for (int j = 0; j < 5; j++) results[i][j] = poly1305_vectors[i].h[j];
    }
}

static void poly1305_hw_compute(uint32_t results[][5]) {
    for (int i = 0; i < POLY1305_N_VECTORS; i++) {
        poly1305_block_hw(results[i], poly1305_vectors[i].r, poly1305_vectors[i].s,
                          poly1305_vectors[i].m);
    }
}

static int poly1305_hw_verify(const uint32_t results[][5]) {
    int ok = 1;
    for (int i = 0; i < POLY1305_N_VECTORS; i++) {
        for (int j = 0; j < 5; j++) {
            ok &= check(poly1305_vectors[i].name, j, results[i][j], poly1305_vectors[i].h_out[j]);
        }
    }
    if (ok) printf("PASSED: Poly1305 block (Hardware)\n");
    return ok;
}

// 真正的 MAC 用法：h 從 0 開始，RFC 8439 §2.5.2 的 3 個區塊依序餵進去，
// 每一塊的輸出直接當作下一塊的輸入。向量 0..2 就是這 3 個區塊。
static int poly1305_hw_rfc_chain(void) {
    int ok = 1;
    uint32_t h[5] = {0, 0, 0, 0, 0};
    for (int n = 0; n < 3; n++) {
        const poly1305_vector_t *v = &poly1305_vectors[n];
        poly1305_block_hw(h, v->r, v->s, v->m);
        for (int j = 0; j < 5; j++) {
            ok &= check("rfc chain", n * 5 + j, h[j], v->h_out[j]);
        }
    }
    if (ok) printf("PASSED: Poly1305 RFC 8439 2.5.2 chained blocks (Hardware)\n");
    return ok;
}

int main(void) {
    int all_passed = 1;
    unsigned int cycles_hw = 0;

    // Initialize cycle counter
    CSR_CLEAR_BITS(CSR_REG_MCOUNTINHIBIT, 0x1);
    CSR_WRITE(CSR_REG_MCYCLE, 0);

    printf("   POLY1305 BLOCK TEST          \n");

    poly1305_hw_init(results_hw);
    CSR_WRITE(CSR_REG_MCYCLE, 0);
    poly1305_hw_compute(results_hw);
    CSR_READ(CSR_REG_MCYCLE, &cycles_hw);
    all_passed &= poly1305_hw_verify(results_hw);
    all_passed &= poly1305_hw_rfc_chain();
    printf("Hardware Cycles: %u\n", cycles_hw);

    if (all_passed) {
        printf("FINAL STATUS: ALL TESTS PASSED\n");
    } else {
        printf("FINAL STATUS: TEST FAILURE DETECTED\n");
    }

    return EXIT_SUCCESS;
}
