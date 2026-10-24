// 自動產生，請勿手改。重新產生：python sw/golden/gen_poly1305.py
// 規則來源：sw/golden/poly1305_model.py（區塊運算）、fe_mul_model.py（funct7）

#ifndef POLY1305_HW_H
#define POLY1305_HW_H

#include <stdint.h>

// M2 ACC 指令（opcode 0x3b、funct3 0x7），funct7 必須是常數，所以用 macro
#define ACCZERO()          asm volatile(".insn r 0x3b, 0x7, 0x60, x0, x0, x0")
#define MACC(f7, a, b)     asm volatile(".insn r 0x3b, 0x7, " #f7 ", x0, %0, %1" :: "r"(a), "r"(b))
#define ACCRD26(rd)        asm volatile(".insn r 0x3b, 0x7, 0x65, %0, x0, x0" : "=r"(rd))
#define ACCWRAP(f7, rd, a) asm volatile(".insn r 0x3b, 0x7, " #f7 ", %0, %1, x0" : "=r"(rd) : "r"(a))

// h = (h + m)·r mod 2^130-5，radix 2^26、5 個 limb。
// product scanning：第 k 欄累加 a_i·r_j（i+j = k）與 a_i·s_j（i+j = k+5），a = h + m。
// 跨過 2^130 的項用 s_j = 5·r_j（由呼叫端預先算好），所以全部是 macc.s1，不需要硬體縮放。
// s0 永遠用不到：i > k 時 j = k-i+5 只會是 1, 2, 3, 4。
// h 全部算完才寫回，所以呼叫端可以直接傳同一個 h 進來更新。
static void poly1305_block_hw(uint32_t h[5], const uint32_t r[5], const uint32_t s[5],
                              const uint32_t m[5]) {
    // h + m：一般 RV32 add，結果最多約 27 bit
    const uint32_t a0 = h[0] + m[0], a1 = h[1] + m[1], a2 = h[2] + m[2], a3 = h[3] + m[3], a4 = h[4] + m[4];
    const uint32_t r0 = r[0], r1 = r[1], r2 = r[2], r3 = r[3], r4 = r[4];
    const uint32_t s1 = s[1], s2 = s[2], s3 = s[3], s4 = s[4];
    uint32_t h0, h1, h2, h3, h4, carry;

    ACCZERO();

    // 第 0 欄 -> h0（26 bit）
    MACC(0x61, a0, r0);   // i=0 j=0  a0·r0
    MACC(0x61, a1, s4);   // i=1 j=4  a1·s4（i+j=5，跨過 2^130，×5 已在 s4 裡）
    MACC(0x61, a2, s3);   // i=2 j=3  a2·s3（i+j=5，跨過 2^130，×5 已在 s3 裡）
    MACC(0x61, a3, s2);   // i=3 j=2  a3·s2（i+j=5，跨過 2^130，×5 已在 s2 裡）
    MACC(0x61, a4, s1);   // i=4 j=1  a4·s1（i+j=5，跨過 2^130，×5 已在 s1 裡）
    ACCRD26(h0);

    // 第 1 欄 -> h1（26 bit）
    MACC(0x61, a0, r1);   // i=0 j=1  a0·r1
    MACC(0x61, a1, r0);   // i=1 j=0  a1·r0
    MACC(0x61, a2, s4);   // i=2 j=4  a2·s4（i+j=6，跨過 2^130，×5 已在 s4 裡）
    MACC(0x61, a3, s3);   // i=3 j=3  a3·s3（i+j=6，跨過 2^130，×5 已在 s3 裡）
    MACC(0x61, a4, s2);   // i=4 j=2  a4·s2（i+j=6，跨過 2^130，×5 已在 s2 裡）
    ACCRD26(h1);

    // 第 2 欄 -> h2（26 bit）
    MACC(0x61, a0, r2);   // i=0 j=2  a0·r2
    MACC(0x61, a1, r1);   // i=1 j=1  a1·r1
    MACC(0x61, a2, r0);   // i=2 j=0  a2·r0
    MACC(0x61, a3, s4);   // i=3 j=4  a3·s4（i+j=7，跨過 2^130，×5 已在 s4 裡）
    MACC(0x61, a4, s3);   // i=4 j=3  a4·s3（i+j=7，跨過 2^130，×5 已在 s3 裡）
    ACCRD26(h2);

    // 第 3 欄 -> h3（26 bit）
    MACC(0x61, a0, r3);   // i=0 j=3  a0·r3
    MACC(0x61, a1, r2);   // i=1 j=2  a1·r2
    MACC(0x61, a2, r1);   // i=2 j=1  a2·r1
    MACC(0x61, a3, r0);   // i=3 j=0  a3·r0
    MACC(0x61, a4, s4);   // i=4 j=4  a4·s4（i+j=8，跨過 2^130，×5 已在 s4 裡）
    ACCRD26(h3);

    // 第 4 欄 -> h4（26 bit）
    MACC(0x61, a0, r4);   // i=0 j=4  a0·r4
    MACC(0x61, a1, r3);   // i=1 j=3  a1·r3
    MACC(0x61, a2, r2);   // i=2 j=2  a2·r2
    MACC(0x61, a3, r1);   // i=3 j=1  a3·r1
    MACC(0x61, a4, r0);   // i=4 j=0  a4·r0
    ACCRD26(h4);

    // ACC 剩下的是 >= 2^130 的部分：×5 加回 h0，進位留在 ACC
    ACCWRAP(0x68, h0, h0);
    // 取出剩下的進位，用一般 add 加到 h1（h1 可能略超過 26 bit）
    ACCRD26(carry);
    h1 += carry;

    h[0] = h0; h[1] = h1; h[2] = h2; h[3] = h3; h[4] = h4;
}

#endif  // POLY1305_HW_H
