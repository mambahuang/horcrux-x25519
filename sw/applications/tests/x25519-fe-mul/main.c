#include <stdint.h>
#include <stdio.h>

#include "core_v_mini_mcu.h"
#include "csr.h"

#include "fe_mul_hw.h"
#include "test_vectors.h"

static int errors = 0;

static void check(const char *what, int idx, uint32_t got, uint32_t exp) {
    if (got != exp) {
        printf("[%s %d] FAIL: exp=0x%08lX got=0x%08lX\n", what, idx, exp, got);
        errors++;
    }
}

// 計時迴圈的輸出。計時結束後還要拿來比對，所以編譯器不能把寫回 h 的 store 刪掉
static uint32_t out[FE_MUL_N_VECTORS][10];

// 原地計算：ladder 會呼叫 fe_mul_hw(x, x, y)，輸出和輸入是同一個陣列
static void test_in_place(void) {
    for (int i = 0; i < FE_MUL_N_VECTORS; i++) {
        uint32_t x[10];
        for (int j = 0; j < 10; j++) x[j] = fe_mul_vectors[i].f[j];
        fe_mul_hw(x, x, fe_mul_vectors[i].g);
        for (int j = 0; j < 10; j++) check("in-place", i * 10 + j, x[j], fe_mul_vectors[i].h[j]);
    }
}

int main(void) {
    uint32_t hw_cycles = 0;

    printf("x25519-fe-mul test\n");

    // 1. 計時：迴圈裡只有 fe_mul_hw，不比對、不 printf
    CSR_CLEAR_BITS(CSR_REG_MCOUNTINHIBIT, 0x1);
    CSR_WRITE(CSR_REG_MCYCLE, 0);
    for (int i = 0; i < FE_MUL_N_VECTORS; i++) {
        fe_mul_hw(out[i], fe_mul_vectors[i].f, fe_mul_vectors[i].g);
    }
    CSR_READ(CSR_REG_MCYCLE, &hw_cycles);
    printf("Hardware Cycles: %lu\n", hw_cycles);

    // 2. 比對：驗證的就是上面被計時的那一次計算
    for (int i = 0; i < FE_MUL_N_VECTORS; i++) {
        for (int j = 0; j < 10; j++) {
            check(fe_mul_vectors[i].name, j, out[i][j], fe_mul_vectors[i].h[j]);
        }
    }

    // 3. 原地計算
    test_in_place();

    if (errors == 0) printf("FINAL STATUS: ALL TESTS PASSED\n");
    else             printf("FINAL STATUS: TEST FAILURE DETECTED (%d)\n", errors);
    return 0;
}
