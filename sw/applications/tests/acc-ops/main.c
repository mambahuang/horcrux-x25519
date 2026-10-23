// acc-ops: M2 directed test for the accumulator instructions.
//
// OP_ACCZERO        (funct7=0x60):      ACC = 0
// OP_MACC_S1/2/19/38 (funct7=0x61-0x64): ACC += rs1 * (N * rs2)
// OP_ACCRD_26/25    (funct7=0x65/0x66): rd = ACC[w-1:0]; ACC >>= w
// OP_ACCWRAP_19/5   (funct7=0x67/0x68): v = rs1 + C * ACC; rd = v[25:0]; ACC = v >> 26
//
// Directed checks first (acczero, each scale, carries, accwrap, rs_valid stall),
// then a timed random part: SW computes the 64-bit sums with uint64_t, HW with
// macc, and the HW sums are checked against SW.

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

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

// 不相等就印出 FAIL（回歸腳本靠大寫的 FAIL 判斷失敗）；相等回傳 1
static int check(const char *what, int idx, uint64_t got, uint64_t exp) {
    if (got != exp) {
        printf("[%s %d] FAIL: exp=0x%08lX_%08lX got=0x%08lX_%08lX\n", what, idx,
               (uint32_t)(exp >> 32), (uint32_t)exp,
               (uint32_t)(got >> 32), (uint32_t)got);
        return 0;
    }
    return 1;
}

// ========== Directed tests ==========

// 1. acczero：先放一些值進 ACC，歸零後應該讀到 0
static int test_acczero(void) {
    MACC(0x61, 5, 7);
    ACCZERO();
    return check("acczero", 0, read_acc(), 0);
}

// 2. 單一 macc.s1，用 limb 的最大值：26-bit × 25-bit
static int test_macc_s1(void) {
    uint32_t a = 0x3FFFFFF, b = 0x1FFFFFF;
    ACCZERO();
    MACC(0x61, a, b);
    return check("macc.s1", 0, read_acc(), (uint64_t)a * b);
}

// 3. 三種縮放倍數。N·b 要 < 2^31（A1 的界限），b 用 25 bit 時 38·b 約 1.27e9，在範圍內
static int test_macc_scaled(void) {
    uint32_t a = 0x3FFFFFF, b = 0x1FFFFFF;
    int ok = 1;
    ACCZERO(); MACC(0x62, a, b); ok &= check("macc.s2",  0, read_acc(), (uint64_t)a * (2  * b));
    ACCZERO(); MACC(0x63, a, b); ok &= check("macc.s19", 0, read_acc(), (uint64_t)a * (19 * b));
    ACCZERO(); MACC(0x64, a, b); ok &= check("macc.s38", 0, read_acc(), (uint64_t)a * (38 * b));
    return ok;
}

// 4. 連續 10 次累加：結果約 2^55，遠超過 32 bit，用來確認進位
static int test_accumulate(void) {
    uint32_t a = 0x3FFFFFF, b = 0x3FFFFFF;
    uint64_t exp = 0;
    ACCZERO();
    for (int i = 0; i < 10; i++) {
        MACC(0x61, a, b);
        exp += (uint64_t)a * b;
    }
    return check("accumulate", 0, read_acc(), exp);
}

static int test_accwrap(void) {
    uint32_t xa = 0x3FFFFFF, xb = 0x1FF;      // X = xa * xb，約 2^35
    uint32_t r  = 0x2ABCDEF;                  // rs1：一個 26-bit 的 limb
    uint64_t X  = (uint64_t)xa * xb;
    uint32_t rd;
    int ok = 1;

    // accwrap.19：v = r + 19·X；rd = v[25:0]；ACC = v >> 26
    ACCZERO(); MACC(0x61, xa, xb);
    ACCWRAP(0x67, rd, r);
    uint64_t v = r + 19 * X;
    ok &= check("accwrap.19 rd",  0, rd, v & 0x3FFFFFF);
    ok &= check("accwrap.19 acc", 0, read_acc(), v >> 26);

    // accwrap.5
    ACCZERO(); MACC(0x61, xa, xb);
    ACCWRAP(0x68, rd, r);
    v = r + 5 * X;
    ok &= check("accwrap.5 rd",  0, rd, v & 0x3FFFFFF);
    ok &= check("accwrap.5 acc", 0, read_acc(), v >> 26);
    return ok;
}

// volatile：強迫編譯器每次都真的去記憶體讀，不會先放在暫存器裡
static volatile uint32_t a_mem = 0x3FFFFFF, b_mem = 0x1FFFFFF;

static int test_stall(void) {
    uint64_t prod = (uint64_t)a_mem * b_mem;
    int ok = 1;

    // 一次：t2 剛載入，macc 送出時 rs_valid = 0，協處理器必須等
    ACCZERO();
    asm volatile(
        "lw t1, 0(%0)\n"
        "lw t2, 0(%1)\n"
        ".insn r 0x3b, 0x7, 0x61, x0, t1, t2\n"
        :: "r"(&a_mem), "r"(&b_mem) : "t1", "t2", "memory");
    ok &= check("stall x1", 0, read_acc(), prod);       // 如果累加了兩次，會得到 2·prod

    // 兩次，中間沒有任何間隔
    ACCZERO();
    asm volatile(
        "lw t1, 0(%0)\n"
        "lw t2, 0(%1)\n"
        ".insn r 0x3b, 0x7, 0x61, x0, t1, t2\n"
        ".insn r 0x3b, 0x7, 0x61, x0, t1, t2\n"
        :: "r"(&a_mem), "r"(&b_mem) : "t1", "t2", "memory");
    ok &= check("stall x2", 0, read_acc(), 2 * prod);
    return ok;
}

static int acc_directed(void) {
    int ok = 1;
    ok &= test_acczero();
    ok &= test_macc_s1();
    ok &= test_macc_scaled();
    ok &= test_accumulate();
    ok &= test_accwrap();
    ok &= test_stall();
    if (ok) printf("PASSED: ACC directed tests\n");
    return ok;
}

// ========== Random sums: SW vs HW ==========

#define N_ROUNDS 50   // 50 輪，每輪 10 條 macc
#define N_MACC   10

// 每輪 10 條 macc 的倍數固定為這個順序，四種都涵蓋。硬體端的 funct7 必須是常數，
// 固定順序才能寫成直線程式碼，計時範圍裡不會有選倍數的分支
static const uint32_t scale[N_MACC] = {1, 2, 19, 38, 1, 2, 19, 38, 1, 2};

static uint32_t rnd_a[N_ROUNDS][N_MACC], rnd_b[N_ROUNDS][N_MACC];
static uint64_t results_sw[N_ROUNDS], results_hw[N_ROUNDS];

static uint32_t rng_state = 0x2545F491;
static uint32_t xorshift32(void) {
    uint32_t x = rng_state;
    x ^= x << 13; x ^= x >> 17; x ^= x << 5;
    return rng_state = x;
}

// 輸入在計時之前先產生好
static void acc_gen_inputs(void) {
    for (int r = 0; r < N_ROUNDS; r++) {
        for (int k = 0; k < N_MACC; k++) {
            rnd_a[r][k] = xorshift32() & 0x3FFFFFF;   // 26 bit
            rnd_b[r][k] = xorshift32() & 0x1FFFFFF;   // 25 bit，38·b 仍 < 2^31
        }
    }
}

static void acc_sw_compute(uint64_t results[]) {
    for (int r = 0; r < N_ROUNDS; r++) {
        uint64_t acc = 0;
        for (int k = 0; k < N_MACC; k++) {
            acc += (uint64_t)rnd_a[r][k] * (scale[k] * rnd_b[r][k]);
        }
        results[r] = acc;
    }
}

static void acc_hw_compute(uint64_t results[]) {
    for (int r = 0; r < N_ROUNDS; r++) {
        const uint32_t *a = rnd_a[r], *b = rnd_b[r];
        ACCZERO();
        MACC(0x61, a[0], b[0]); MACC(0x62, a[1], b[1]);   // 倍數順序同 scale[]
        MACC(0x63, a[2], b[2]); MACC(0x64, a[3], b[3]);
        MACC(0x61, a[4], b[4]); MACC(0x62, a[5], b[5]);
        MACC(0x63, a[6], b[6]); MACC(0x64, a[7], b[7]);
        MACC(0x61, a[8], b[8]); MACC(0x62, a[9], b[9]);
        results[r] = read_acc();
    }
}

static int acc_hw_verify(const uint64_t hw[], const uint64_t sw[]) {
    int ok = 1;
    for (int r = 0; r < N_ROUNDS; r++) {
        ok &= check("random", r, hw[r], sw[r]);
    }
    if (ok) printf("PASSED: ACC random sums (Hardware vs Software)\n");
    return ok;
}

int main(void) {
    int all_passed = 1;
    unsigned int cycles_sw = 0;
    unsigned int cycles_hw = 0;

    // Initialize cycle counter
    CSR_CLEAR_BITS(CSR_REG_MCOUNTINHIBIT, 0x1);
    CSR_WRITE(CSR_REG_MCYCLE, 0);

    // 進度訊息：協處理器不認得指令時 core 會一直等，看 log 停在哪裡就知道卡在哪
    printf("   ACC-OPS TEST (M2 accumulator instructions)          \n");

    all_passed &= acc_directed();

    // SW 就是隨機部分的預期值，所以不能用 SW_TEST_ENABLED 關掉
    acc_gen_inputs();

    CSR_WRITE(CSR_REG_MCYCLE, 0);
    acc_sw_compute(results_sw);
    CSR_READ(CSR_REG_MCYCLE, &cycles_sw);
    printf("Software Cycles: %u\n\n", cycles_sw);

    CSR_WRITE(CSR_REG_MCYCLE, 0);
    acc_hw_compute(results_hw);
    CSR_READ(CSR_REG_MCYCLE, &cycles_hw);
    all_passed &= acc_hw_verify(results_hw, results_sw);
    printf("Hardware Cycles: %u\n", cycles_hw);

    printf("SW Cycles: %u | HW Cycles: %u\n", cycles_sw, cycles_hw);
    if (cycles_sw > 0) {
        printf("Speedup: %u.%02ux\n", cycles_sw / cycles_hw, ((cycles_sw * 100) / cycles_hw) % 100);
    }

    if (all_passed) {
        printf("FINAL STATUS: ALL TESTS PASSED\n");
    } else {
        printf("FINAL STATUS: TEST FAILURE DETECTED\n");
    }

    return EXIT_SUCCESS;
}
