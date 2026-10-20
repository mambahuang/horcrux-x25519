#include <stdint.h>
#include <stdio.h>

#include "core_v_mini_mcu.h"
#include "csr.h"

#define ACCZERO()          asm volatile(".insn r 0x3b, 0x7, 0x60, x0, x0, x0")
#define MACC(f7, a, b)     asm volatile(".insn r 0x3b, 0x7, " #f7 ", x0, %0, %1" :: "r"(a), "r"(b))
#define ACCRD26(rd)        asm volatile(".insn r 0x3b, 0x7, 0x65, %0, x0, x0" : "=r"(rd))
#define ACCRD25(rd)        asm volatile(".insn r 0x3b, 0x7, 0x66, %0, x0, x0" : "=r"(rd))
#define ACCWRAP(f7, rd, a) asm volatile(".insn r 0x3b, 0x7, " #f7 ", %0, %1, x0" : "=r"(rd) : "r"(a))

static uint64_t read_acc(void) {
    uint32_t r0, r1, r2;
    ACCRD26(r0);   // bit  0..25，ACC >>= 26
    ACCRD26(r1);   // bit 26..51，ACC >>= 26
    ACCRD25(r2);   // bit 52..63（只剩 12 bit 有值），ACC >>= 25
    return (uint64_t)r0 | ((uint64_t)r1 << 26) | ((uint64_t)r2 << 52);
}

static int errors = 0;

// 不相等就印出 FAIL（回歸腳本靠大寫的 FAIL 判斷失敗），並記錄錯誤數
static void check(const char *what, int idx, uint64_t got, uint64_t exp) {
    if (got != exp) {
        printf("[%s %d] FAIL: exp=0x%08lX_%08lX got=0x%08lX_%08lX\n", what, idx,
               (uint32_t)(exp >> 32), (uint32_t)exp,
               (uint32_t)(got >> 32), (uint32_t)got);
        errors++;
    }
}

// 1. acczero：先放一些值進 ACC，歸零後應該讀到 0
static void test_acczero(void) {
    MACC(0x61, 5, 7);
    ACCZERO();
    check("acczero", 0, read_acc(), 0);
}

// 2. 單一 macc.s1，用 limb 的最大值：26-bit × 25-bit
static void test_macc_s1(void) {
    uint32_t a = 0x3FFFFFF, b = 0x1FFFFFF;
    ACCZERO();
    MACC(0x61, a, b);
    check("macc.s1", 0, read_acc(), (uint64_t)a * b);
}

// 3. 三種縮放倍數。N·b 要 < 2^31（A1 的界限），b 用 25 bit 時 38·b 約 1.27e9，在範圍內
static void test_macc_scaled(void) {
    uint32_t a = 0x3FFFFFF, b = 0x1FFFFFF;
    ACCZERO(); MACC(0x62, a, b); check("macc.s2",  0, read_acc(), (uint64_t)a * (2  * b));
    ACCZERO(); MACC(0x63, a, b); check("macc.s19", 0, read_acc(), (uint64_t)a * (19 * b));
    ACCZERO(); MACC(0x64, a, b); check("macc.s38", 0, read_acc(), (uint64_t)a * (38 * b));
}

// 4. 連續 10 次累加：結果約 2^55，遠超過 32 bit，用來確認進位
static void test_accumulate(void) {
    uint32_t a = 0x3FFFFFF, b = 0x3FFFFFF;
    uint64_t exp = 0;
    ACCZERO();
    for (int i = 0; i < 10; i++) {
        MACC(0x61, a, b);
        exp += (uint64_t)a * b;
    }
    check("accumulate", 0, read_acc(), exp);
}

static void test_accwrap(void) {
    uint32_t xa = 0x3FFFFFF, xb = 0x1FF;      // X = xa * xb，約 2^35
    uint32_t r  = 0x2ABCDEF;                  // rs1：一個 26-bit 的 limb
    uint64_t X  = (uint64_t)xa * xb;
    uint32_t rd;

    // accwrap.19：v = r + 19·X；rd = v[25:0]；ACC = v >> 26
    ACCZERO(); MACC(0x61, xa, xb);
    ACCWRAP(0x67, rd, r);
    uint64_t v = r + 19 * X;
    check("accwrap.19 rd",  0, rd, v & 0x3FFFFFF);
    check("accwrap.19 acc", 0, read_acc(), v >> 26);

    // accwrap.5
    ACCZERO(); MACC(0x61, xa, xb);
    ACCWRAP(0x68, rd, r);
    v = r + 5 * X;
    check("accwrap.5 rd",  0, rd, v & 0x3FFFFFF);
    check("accwrap.5 acc", 0, read_acc(), v >> 26);
}

// volatile：強迫編譯器每次都真的去記憶體讀，不會先放在暫存器裡
static volatile uint32_t a_mem = 0x3FFFFFF, b_mem = 0x1FFFFFF;

static void test_stall(void) {
    uint64_t prod = (uint64_t)a_mem * b_mem;

    // 一次：t2 剛載入，macc 送出時 rs_valid = 0，協處理器必須等
    ACCZERO();
    asm volatile(
        "lw t1, 0(%0)\n"
        "lw t2, 0(%1)\n"
        ".insn r 0x3b, 0x7, 0x61, x0, t1, t2\n"
        :: "r"(&a_mem), "r"(&b_mem) : "t1", "t2", "memory");
    check("stall x1", 0, read_acc(), prod);       // 如果累加了兩次，會得到 2·prod

    // 兩次，中間沒有任何間隔
    ACCZERO();
    asm volatile(
        "lw t1, 0(%0)\n"
        "lw t2, 0(%1)\n"
        ".insn r 0x3b, 0x7, 0x61, x0, t1, t2\n"
        ".insn r 0x3b, 0x7, 0x61, x0, t1, t2\n"
        :: "r"(&a_mem), "r"(&b_mem) : "t1", "t2", "memory");
    check("stall x2", 0, read_acc(), 2 * prod);
}

static uint32_t rng_state = 0x2545F491;
static uint32_t xorshift32(void) {
    uint32_t x = rng_state;
    x ^= x << 13; x ^= x >> 17; x ^= x << 5;
    return rng_state = x;
}

#define N_ROUNDS 50   // 50 輪，每輪 10 條 macc

static void test_random(void) {
    for (int round = 0; round < N_ROUNDS; round++) {
        uint64_t exp = 0;
        ACCZERO();
        for (int i = 0; i < 10; i++) {
            uint32_t a = xorshift32() & 0x3FFFFFF;   // 26 bit
            uint32_t b = xorshift32() & 0x1FFFFFF;   // 25 bit，38·b 仍 < 2^31
            switch (xorshift32() & 3) {              // 隨機選一種倍數
                case 0: MACC(0x61, a, b); exp += (uint64_t)a * b;        break;
                case 1: MACC(0x62, a, b); exp += (uint64_t)a * (2 * b);  break;
                case 2: MACC(0x63, a, b); exp += (uint64_t)a * (19 * b); break;
                case 3: MACC(0x64, a, b); exp += (uint64_t)a * (38 * b); break;
            }
        }
        check("random", round, read_acc(), exp);
    }
}

int main(void) {
    uint32_t hw_cycles = 0;

    printf("acc-ops: M2 accumulator instructions\n");   // 進度訊息，卡住時才知道停在哪

    test_acczero();
    test_macc_s1();
    test_macc_scaled();
    test_accumulate();
    test_accwrap();
    test_stall();

    // 只計時隨機測試，cycle 數會被抽進參考檔
    CSR_CLEAR_BITS(CSR_REG_MCOUNTINHIBIT, 0x1);
    CSR_WRITE(CSR_REG_MCYCLE, 0);
    test_random();
    CSR_READ(CSR_REG_MCYCLE, &hw_cycles);
    printf("Hardware Cycles: %u\n", hw_cycles);

    if (errors == 0) printf("FINAL STATUS: ALL TESTS PASSED\n");
    else             printf("FINAL STATUS: TEST FAILURE DETECTED (%d)\n", errors);
    return 0;
}
