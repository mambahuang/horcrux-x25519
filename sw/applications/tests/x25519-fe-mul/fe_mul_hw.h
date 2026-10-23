// 自動產生，請勿手改。重新產生：python sw/golden/gen_fe_mul.py
// 規則來源：sw/golden/fe_mul_model.py（funct7、scale_factor、limb 寬度）

#ifndef FE_MUL_HW_H
#define FE_MUL_HW_H

#include <stdint.h>

// M2 ACC 指令（opcode 0x3b、funct3 0x7），funct7 必須是常數，所以用 macro
#define ACCZERO()          asm volatile(".insn r 0x3b, 0x7, 0x60, x0, x0, x0")
#define MACC(f7, a, b)     asm volatile(".insn r 0x3b, 0x7, " #f7 ", x0, %0, %1" :: "r"(a), "r"(b))
#define ACCRD26(rd)        asm volatile(".insn r 0x3b, 0x7, 0x65, %0, x0, x0" : "=r"(rd))
#define ACCRD25(rd)        asm volatile(".insn r 0x3b, 0x7, 0x66, %0, x0, x0" : "=r"(rd))
#define ACCWRAP(f7, rd, a) asm volatile(".insn r 0x3b, 0x7, " #f7 ", %0, %1, x0" : "=r"(rd) : "r"(a))

// h = f·g mod 2^255-19，radix 2^25.5（偶數 limb 26 bit、奇數 limb 25 bit）。
// product scanning：第 k 欄累加所有 i+j ≡ k (mod 10) 的 f_i·g_j，縮放 N 一律放在 g 這側：
//   i、j 皆奇 ×2；i+j>=10 ×19；兩者皆是 ×38。
// h 全部算完才寫回，所以 h 可以和 f 或 g 是同一個陣列。
static void fe_mul_hw(uint32_t h[10], const uint32_t f[10], const uint32_t g[10]) {
    const uint32_t f0 = f[0], f1 = f[1], f2 = f[2], f3 = f[3], f4 = f[4], f5 = f[5], f6 = f[6], f7 = f[7], f8 = f[8], f9 = f[9];
    const uint32_t g0 = g[0], g1 = g[1], g2 = g[2], g3 = g[3], g4 = g[4], g5 = g[5], g6 = g[6], g7 = g[7], g8 = g[8], g9 = g[9];
    uint32_t h0, h1, h2, h3, h4, h5, h6, h7, h8, h9, carry;

    ACCZERO();

    // 第 0 欄 -> h0（26 bit）
    MACC(0x61, f0, g0);   // i=0 j=0  N=1
    MACC(0x64, f1, g9);   // i=1 j=9  N=38  (i、j 皆奇，i+j>=10)
    MACC(0x63, f2, g8);   // i=2 j=8  N=19  (i+j>=10)
    MACC(0x64, f3, g7);   // i=3 j=7  N=38  (i、j 皆奇，i+j>=10)
    MACC(0x63, f4, g6);   // i=4 j=6  N=19  (i+j>=10)
    MACC(0x64, f5, g5);   // i=5 j=5  N=38  (i、j 皆奇，i+j>=10)
    MACC(0x63, f6, g4);   // i=6 j=4  N=19  (i+j>=10)
    MACC(0x64, f7, g3);   // i=7 j=3  N=38  (i、j 皆奇，i+j>=10)
    MACC(0x63, f8, g2);   // i=8 j=2  N=19  (i+j>=10)
    MACC(0x64, f9, g1);   // i=9 j=1  N=38  (i、j 皆奇，i+j>=10)
    ACCRD26(h0);

    // 第 1 欄 -> h1（25 bit）
    MACC(0x61, f0, g1);   // i=0 j=1  N=1
    MACC(0x61, f1, g0);   // i=1 j=0  N=1
    MACC(0x63, f2, g9);   // i=2 j=9  N=19  (i+j>=10)
    MACC(0x63, f3, g8);   // i=3 j=8  N=19  (i+j>=10)
    MACC(0x63, f4, g7);   // i=4 j=7  N=19  (i+j>=10)
    MACC(0x63, f5, g6);   // i=5 j=6  N=19  (i+j>=10)
    MACC(0x63, f6, g5);   // i=6 j=5  N=19  (i+j>=10)
    MACC(0x63, f7, g4);   // i=7 j=4  N=19  (i+j>=10)
    MACC(0x63, f8, g3);   // i=8 j=3  N=19  (i+j>=10)
    MACC(0x63, f9, g2);   // i=9 j=2  N=19  (i+j>=10)
    ACCRD25(h1);

    // 第 2 欄 -> h2（26 bit）
    MACC(0x61, f0, g2);   // i=0 j=2  N=1
    MACC(0x62, f1, g1);   // i=1 j=1  N=2   (i、j 皆奇)
    MACC(0x61, f2, g0);   // i=2 j=0  N=1
    MACC(0x64, f3, g9);   // i=3 j=9  N=38  (i、j 皆奇，i+j>=10)
    MACC(0x63, f4, g8);   // i=4 j=8  N=19  (i+j>=10)
    MACC(0x64, f5, g7);   // i=5 j=7  N=38  (i、j 皆奇，i+j>=10)
    MACC(0x63, f6, g6);   // i=6 j=6  N=19  (i+j>=10)
    MACC(0x64, f7, g5);   // i=7 j=5  N=38  (i、j 皆奇，i+j>=10)
    MACC(0x63, f8, g4);   // i=8 j=4  N=19  (i+j>=10)
    MACC(0x64, f9, g3);   // i=9 j=3  N=38  (i、j 皆奇，i+j>=10)
    ACCRD26(h2);

    // 第 3 欄 -> h3（25 bit）
    MACC(0x61, f0, g3);   // i=0 j=3  N=1
    MACC(0x61, f1, g2);   // i=1 j=2  N=1
    MACC(0x61, f2, g1);   // i=2 j=1  N=1
    MACC(0x61, f3, g0);   // i=3 j=0  N=1
    MACC(0x63, f4, g9);   // i=4 j=9  N=19  (i+j>=10)
    MACC(0x63, f5, g8);   // i=5 j=8  N=19  (i+j>=10)
    MACC(0x63, f6, g7);   // i=6 j=7  N=19  (i+j>=10)
    MACC(0x63, f7, g6);   // i=7 j=6  N=19  (i+j>=10)
    MACC(0x63, f8, g5);   // i=8 j=5  N=19  (i+j>=10)
    MACC(0x63, f9, g4);   // i=9 j=4  N=19  (i+j>=10)
    ACCRD25(h3);

    // 第 4 欄 -> h4（26 bit）
    MACC(0x61, f0, g4);   // i=0 j=4  N=1
    MACC(0x62, f1, g3);   // i=1 j=3  N=2   (i、j 皆奇)
    MACC(0x61, f2, g2);   // i=2 j=2  N=1
    MACC(0x62, f3, g1);   // i=3 j=1  N=2   (i、j 皆奇)
    MACC(0x61, f4, g0);   // i=4 j=0  N=1
    MACC(0x64, f5, g9);   // i=5 j=9  N=38  (i、j 皆奇，i+j>=10)
    MACC(0x63, f6, g8);   // i=6 j=8  N=19  (i+j>=10)
    MACC(0x64, f7, g7);   // i=7 j=7  N=38  (i、j 皆奇，i+j>=10)
    MACC(0x63, f8, g6);   // i=8 j=6  N=19  (i+j>=10)
    MACC(0x64, f9, g5);   // i=9 j=5  N=38  (i、j 皆奇，i+j>=10)
    ACCRD26(h4);

    // 第 5 欄 -> h5（25 bit）
    MACC(0x61, f0, g5);   // i=0 j=5  N=1
    MACC(0x61, f1, g4);   // i=1 j=4  N=1
    MACC(0x61, f2, g3);   // i=2 j=3  N=1
    MACC(0x61, f3, g2);   // i=3 j=2  N=1
    MACC(0x61, f4, g1);   // i=4 j=1  N=1
    MACC(0x61, f5, g0);   // i=5 j=0  N=1
    MACC(0x63, f6, g9);   // i=6 j=9  N=19  (i+j>=10)
    MACC(0x63, f7, g8);   // i=7 j=8  N=19  (i+j>=10)
    MACC(0x63, f8, g7);   // i=8 j=7  N=19  (i+j>=10)
    MACC(0x63, f9, g6);   // i=9 j=6  N=19  (i+j>=10)
    ACCRD25(h5);

    // 第 6 欄 -> h6（26 bit）
    MACC(0x61, f0, g6);   // i=0 j=6  N=1
    MACC(0x62, f1, g5);   // i=1 j=5  N=2   (i、j 皆奇)
    MACC(0x61, f2, g4);   // i=2 j=4  N=1
    MACC(0x62, f3, g3);   // i=3 j=3  N=2   (i、j 皆奇)
    MACC(0x61, f4, g2);   // i=4 j=2  N=1
    MACC(0x62, f5, g1);   // i=5 j=1  N=2   (i、j 皆奇)
    MACC(0x61, f6, g0);   // i=6 j=0  N=1
    MACC(0x64, f7, g9);   // i=7 j=9  N=38  (i、j 皆奇，i+j>=10)
    MACC(0x63, f8, g8);   // i=8 j=8  N=19  (i+j>=10)
    MACC(0x64, f9, g7);   // i=9 j=7  N=38  (i、j 皆奇，i+j>=10)
    ACCRD26(h6);

    // 第 7 欄 -> h7（25 bit）
    MACC(0x61, f0, g7);   // i=0 j=7  N=1
    MACC(0x61, f1, g6);   // i=1 j=6  N=1
    MACC(0x61, f2, g5);   // i=2 j=5  N=1
    MACC(0x61, f3, g4);   // i=3 j=4  N=1
    MACC(0x61, f4, g3);   // i=4 j=3  N=1
    MACC(0x61, f5, g2);   // i=5 j=2  N=1
    MACC(0x61, f6, g1);   // i=6 j=1  N=1
    MACC(0x61, f7, g0);   // i=7 j=0  N=1
    MACC(0x63, f8, g9);   // i=8 j=9  N=19  (i+j>=10)
    MACC(0x63, f9, g8);   // i=9 j=8  N=19  (i+j>=10)
    ACCRD25(h7);

    // 第 8 欄 -> h8（26 bit）
    MACC(0x61, f0, g8);   // i=0 j=8  N=1
    MACC(0x62, f1, g7);   // i=1 j=7  N=2   (i、j 皆奇)
    MACC(0x61, f2, g6);   // i=2 j=6  N=1
    MACC(0x62, f3, g5);   // i=3 j=5  N=2   (i、j 皆奇)
    MACC(0x61, f4, g4);   // i=4 j=4  N=1
    MACC(0x62, f5, g3);   // i=5 j=3  N=2   (i、j 皆奇)
    MACC(0x61, f6, g2);   // i=6 j=2  N=1
    MACC(0x62, f7, g1);   // i=7 j=1  N=2   (i、j 皆奇)
    MACC(0x61, f8, g0);   // i=8 j=0  N=1
    MACC(0x64, f9, g9);   // i=9 j=9  N=38  (i、j 皆奇，i+j>=10)
    ACCRD26(h8);

    // 第 9 欄 -> h9（25 bit）
    MACC(0x61, f0, g9);   // i=0 j=9  N=1
    MACC(0x61, f1, g8);   // i=1 j=8  N=1
    MACC(0x61, f2, g7);   // i=2 j=7  N=1
    MACC(0x61, f3, g6);   // i=3 j=6  N=1
    MACC(0x61, f4, g5);   // i=4 j=5  N=1
    MACC(0x61, f5, g4);   // i=5 j=4  N=1
    MACC(0x61, f6, g3);   // i=6 j=3  N=1
    MACC(0x61, f7, g2);   // i=7 j=2  N=1
    MACC(0x61, f8, g1);   // i=8 j=1  N=1
    MACC(0x61, f9, g0);   // i=9 j=0  N=1
    ACCRD25(h9);

    // ACC 剩下的是 >= 2^255 的部分：×19 加回 h0，進位留在 ACC
    ACCWRAP(0x67, h0, h0);
    // 取出剩下的進位，用一般 add 加到 h1（h1 可能略超過 25 bit，見 fe_mul_model.py）
    ACCRD25(carry);
    h1 += carry;

    h[0] = h0; h[1] = h1; h[2] = h2; h[3] = h3; h[4] = h4;
    h[5] = h5; h[6] = h6; h[7] = h7; h[8] = h8; h[9] = h9;
}

#endif  // FE_MUL_HW_H
