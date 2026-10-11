// int-raw-mul: M1 directed test for MODE_INT_RAW.
//
// OP_MULRAW_LO (funct7=0x69): rd = (rs1 * rs2)[31:0]
// OP_MULRAW_HI (funct7=0x6A): rd = (rs1 * rs2)[63:32]
// The product is SIGNED: unified_mul_32x32 multiplies in two's complement.

#include <stdint.h>
#include <stdio.h>

#include "core_v_mini_mcu.h"
#include "csr.h"   // CSR_READ / CSR_WRITE，用來讀 cycle 計數器

#define MULRAW_LO(rd, a, b) \
    asm volatile( \
        ".insn r 0x3b, 0x7, 0x69, %0, %1, %2" \
        : "=r"(rd) \
        : "r"(a), "r"(b) \
    )

#define MULRAW_HI(rd, a, b) \
    asm volatile( \
        ".insn r 0x3b, 0x7, 0x6A, %0, %1, %2" \
        : "=r"(rd) \
        : "r"(a), "r"(b) \
    )

static inline void mul_ref(uint32_t a, uint32_t b, uint32_t *lo, uint32_t *hi) {
    int64_t p = (int64_t)(int32_t)a * (int64_t)(int32_t)b;
    *lo = (uint32_t)p;
    *hi = (uint32_t)((uint64_t)p >> 32);
}

static const uint32_t edge[][2] = {
    {0, 0}, {1, 1}, {0xFFFFFFFF, 1},            // 0、1、-1
    {0xFFFFFFFF, 0xFFFFFFFF},                   // (-1)·(-1) = 1
    {0x7FFFFFFF, 0x7FFFFFFF},                   // 最大正數的平方
    {0x80000000, 0x80000000},                   // 最小負數的平方 = 2^62
    {0x80000000, 0x7FFFFFFF},                   // 異號
    {0x03FFFFFF, 0x4BFFFFB4},                   // fe_mul 的情況：26-bit limb × 38·(2^25−1)
    {0x12345678, 0x9ABCDEF0},                   // 一般值
};
#define N_EDGE (sizeof(edge) / sizeof(edge[0]))

static uint32_t rng_state = 0x2545F491;
static uint32_t xorshift32(void) {
    uint32_t x = rng_state;
    x ^= x << 13; 
    x ^= x >> 17; 
    x ^= x << 5;
    return rng_state = x;
}
#define N_RAND 200


int main(void) {
    static uint32_t a[N_EDGE + N_RAND], b[N_EDGE + N_RAND];
    static uint32_t hw_lo[N_EDGE + N_RAND], hw_hi[N_EDGE + N_RAND];
    const int n = N_EDGE + N_RAND;
    uint32_t sw_cycles, hw_cycles;
    int errors = 0;

    for (int i = 0; i < n; i++) {
        if (i < (int)N_EDGE) { a[i] = edge[i][0]; b[i] = edge[i][1]; }
        else                 { a[i] = xorshift32(); b[i] = xorshift32(); }
    }

    CSR_CLEAR_BITS(CSR_REG_MCOUNTINHIBIT, 0x1);   // 啟動 cycle 計數器

    // 軟體：用 RV32 的 mul/mulh 算 64-bit 乘積
    uint32_t sw_lo, sw_hi, sink = 0;
    CSR_WRITE(CSR_REG_MCYCLE, 0);
    for (int i = 0; i < n; i++) { mul_ref(a[i], b[i], &sw_lo, &sw_hi); sink ^= sw_lo ^ sw_hi; }
    CSR_READ(CSR_REG_MCYCLE, &sw_cycles);

    // 硬體：每組兩條指令
    CSR_WRITE(CSR_REG_MCYCLE, 0);
    for (int i = 0; i < n; i++) {
        MULRAW_LO(hw_lo[i], a[i], b[i]);
        MULRAW_HI(hw_hi[i], a[i], b[i]);
    }
    CSR_READ(CSR_REG_MCYCLE, &hw_cycles);
    for (int i = 0; i < n; i++) {
        uint32_t lo, hi;
        mul_ref(a[i], b[i], &lo, &hi);
        if (hw_lo[i] != lo || hw_hi[i] != hi) {
            printf("[HW] Test %3d FAIL: a=0x%08lX b=0x%08lX exp=0x%08lX_%08lX got=0x%08lX_%08lX\n",
                   i, a[i], b[i], hi, lo, hw_hi[i], hw_lo[i]);
            errors++;
        }
    }

    printf("Software Cycles: %u\n", sw_cycles);
    printf("Hardware Cycles: %u\n", hw_cycles);
    printf("SW Cycles: %u | HW Cycles: %u\n", sw_cycles, hw_cycles);
    printf("Checked %d products (sink=%08lX)\n", n, sink);

    if (errors == 0) printf("FINAL STATUS: ALL TESTS PASSED\n");
    else             printf("FINAL STATUS: TEST FAILURE DETECTED (%d)\n", errors);
    return 0;
}

