"""X25519 fe_mul 的逐指令 golden model（方案 A：運算元端縮放，A1）。

每條指令都對應計畫書 4.1 節的一條 R-type 指令，並標出它在 RTL 裡走的路徑，
用途有兩個：
  1. 學習：看懂 radix 2^25.5 的 fe_mul 怎麼拆成 acczero / macc / accrd / accwrap。
  2. 驗證：之後擴充成逐指令輸出 ACC 狀態，給 testbench 比對（計畫書 5.4 節）。

執行：
  python fe_mul_model.py               # 3000 組隨機測試 + 統計
  python fe_mul_model.py --trace       # 印出一次 fe_mul 第 0、1 欄的指令與 ACC
  python fe_mul_model.py --lazy        # limb 多 1 bit：A1 出錯的次數，以及 A1′/A2 需要的寬度
  python fe_mul_model.py --chain 5000  # 連乘次數（預設 1000），模擬 ladder 把輸出餵回輸入
"""

import argparse
import random

P = 2**255 - 19

# limb i 的起始 bit = ceil(25.5 * i)：偶數 limb 26 bit、奇數 limb 25 bit
OFFSET = [(51 * i + 1) // 2 for i in range(11)]  # OFFSET[10] = 255
WIDTH = [OFFSET[i + 1] - OFFSET[i] for i in range(10)]  # 26,25,26,25,...

# funct7 編碼（計畫書 4.1 節）
FUNCT7 = {
    "acczero": 0x60,
    "macc.s1": 0x61, "macc.s2": 0x62, "macc.s19": 0x63, "macc.s38": 0x64,
    "accrd.26": 0x65, "accrd.25": 0x66,
    "accwrap.19": 0x67, "accwrap.5": 0x68,
}

# 每條指令在 multiplier_tree.sv 裡經過的硬體（學習用註解，會印在 trace 裡）
HW_PATH = {
    "acczero":  "acc_q <= 0",
    "macc.s1":  "rs2 -> u_primary_mul(mode 3 MODE_INT_RAW) -> acc_sum -> acc_q",
    "macc.s2":  "rs2<<1 -> u_primary_mul(mode 3) -> acc_sum -> acc_q",
    "macc.s19": "(rs2<<4)+(rs2<<1)+rs2 -> u_primary_mul(mode 3) -> acc_sum -> acc_q",
    "macc.s38": "((rs2<<4)+(rs2<<1)+rs2)<<1 -> u_primary_mul(mode 3) -> acc_sum -> acc_q",
    "accrd.26": "rd <= acc_q[25:0]（result_o）; acc_q <= acc_q >> 26",
    "accrd.25": "rd <= acc_q[24:0]（result_o）; acc_q <= acc_q >> 25",
    "accwrap.19": "wrap_v = rs1 + 19*acc_q; rd <= wrap_v[25:0]; acc_q <= wrap_v >> 26",
    "accwrap.5":  "wrap_v = rs1 + 5*acc_q;  rd <= wrap_v[25:0]; acc_q <= wrap_v >> 26",
}

MASK32 = (1 << 32) - 1
MASK64 = (1 << 64) - 1


def unified_mul_32x32(a, b):
    """位元精確對應 unified_mul_32x32.sv（整數模式）。

    b 做 sign extension，a 的 MSB 那一項用減的 -> 二補數有號乘法。
    回傳 64-bit 無號表示（就是 prod_o 的 bit pattern）。
    """
    b_sext = b - (1 << 32) if b >> 31 else b
    acc = 0
    for i in range(32):
        if (a >> i) & 1:
            pp = b_sext << i
            acc = acc + pp if i < 31 else acc - pp  # 第 31 項：signed MSB
    return acc & MASK64


def unsigned_mul_32x32(a, b):
    """A1′（乘法器加無號模式）或 A2（乘積端縮放）下的乘積：一般的無號乘法。

    A2 是 N·(rs1·rs2)，數值上等於 rs1·(N·rs2)，所以兩者共用這個模型。
    """
    return (a & MASK32) * (b & MASK32)


class HorcruxAcc:
    """ACC 指令組的架構狀態模型：一個 64-bit acc_q 加上統計與 trace。

    mul="signed"   ：A1，直接用 repo 的有號 unified_mul_32x32（位元精確）
    mul="unsigned" ：A1′ / A2，乘法器的結果等於無號乘積
    """

    def __init__(self, strict=True, mul="signed"):
        assert mul in ("signed", "unsigned")
        self.acc = 0
        self.mul = mul
        self.strict = strict          # True：違反 A1 界限或 ACC 溢位就丟例外
        self.violations = 0           # strict=False 時累計 A1 界限違反次數
        self.overflows = 0            # strict=False 時累計 ACC 溢位次數
        self.max_acc_bits = 0
        self.max_operand_bits = 0
        self.count = {}
        self.trace = []               # (mnemonic, operands, acc_after)

    def _log(self, op, args):
        self.count[op] = self.count.get(op, 0) + 1
        self.max_acc_bits = max(self.max_acc_bits, self.acc.bit_length())
        self.trace.append((op, args, self.acc))

    def _check(self, cond, msg, counter="violations"):
        if cond:
            return
        if self.strict:
            raise AssertionError(msg)
        setattr(self, counter, getattr(self, counter) + 1)

    def acczero(self):
        self.acc = 0
        self._log("acczero", ())

    def macc(self, n, rs1, rs2):
        assert n in (1, 2, 19, 38)
        scaled = (n * rs2) & MASK32  # scaler 輸出只有 32 bit（op_b_scaled）
        self.max_operand_bits = max(self.max_operand_bits, (n * rs2).bit_length())
        # A1 前提（計畫書 4.4）：兩個運算元都 < 2^31，有號乘法器才等於無號乘法。
        # A1′ / A2 用無號乘積，沒有這個限制，所以只在 signed 模式下檢查。
        if self.mul == "signed":
            self._check(n * rs2 < 2**31, f"macc.s{n}: N*rs2 = 2^{(n*rs2).bit_length()} 超過 31 bit")
            self._check(rs1 < 2**31, f"macc.s{n}: rs1 超過 31 bit")
        else:
            # A1′ 的 scaler 輸出（op_b_scaled）仍然只有 32 bit；A2 沒有這個限制
            self._check(n * rs2 < 2**32, f"macc.s{n}: N*rs2 超過 32 bit，A1′ 放不下")
        if self.mul == "signed":
            raw_prod = unified_mul_32x32(rs1, scaled)  # MODE_INT_RAW：{res_hi, res_lo}
        else:
            raw_prod = unsigned_mul_32x32(rs1, n * rs2)
        # acc_sum 是 64-bit 加法器：必須在截到 64 bit「之前」檢查是否溢位
        acc_sum = self.acc + raw_prod
        self._check(acc_sum < 2**64, f"macc.s{n}: ACC 溢位（{acc_sum.bit_length()} bit）",
                    counter="overflows")
        self.acc = acc_sum & MASK64
        self._log(f"macc.s{n}", (rs1, rs2))

    def accrd(self, w):
        assert w in (25, 26)
        rd = self.acc & ((1 << w) - 1)
        self.acc >>= w
        self._log(f"accrd.{w}", ())
        return rd

    def accwrap(self, c, rs1):
        assert c in (19, 5)
        v = rs1 + c * self.acc
        # wrap_v 在 RTL 裡也是 64 bit
        self._check(v < 2**64, f"accwrap.{c}: wrap_v 溢位（{v.bit_length()} bit）",
                    counter="overflows")
        rd = v & ((1 << 26) - 1)
        self.acc = (v & MASK64) >> 26
        self._log(f"accwrap.{c}", (rs1,))
        return rd


# ---------------------------------------------------------------------------
# 欄位與 limb 轉換
# ---------------------------------------------------------------------------

def to_limbs(x):
    return [(x >> OFFSET[i]) & ((1 << WIDTH[i]) - 1) for i in range(10)]


def from_limbs(h):
    return sum(h[i] << OFFSET[i] for i in range(10))


def scale_factor(i, j):
    """f_i * g_j 落在第 (i+j) mod 10 欄時要乘的常數 N。

    - i、j 皆奇：OFFSET[i] + OFFSET[j] = OFFSET[i+j] + 1，差半個 bit 兩次 -> ×2
    - i + j >= 10：超過 2^255，用 2^255 ≡ 19 (mod p) 繞回 -> ×19
    """
    n = 1
    if i % 2 == 1 and j % 2 == 1:
        n *= 2
    if i + j >= 10:
        n *= 19
    return n


# ---------------------------------------------------------------------------
# fe_mul：product scanning，一欄一欄累加，進位自然留在 ACC
# ---------------------------------------------------------------------------

def fe_mul(f, g, hw):
    """h = f * g mod p，f、g、h 都是 10 個 limb。縮放一律放在 rs2（g 這一側）。"""
    h = [0] * 10
    hw.acczero()
    for k in range(10):
        # 第 k 欄：所有 (i, j) 滿足 i + j ≡ k (mod 10)
        for i in range(10):
            j = (k - i) % 10
            hw.macc(scale_factor(i, j), f[i], g[j])
        h[k] = hw.accrd(WIDTH[k])  # 偶數欄取 26 bit，奇數欄取 25 bit
    # 欄 9 之後 ACC 裡剩下的是 >= 2^255 的部分，×19 加回 h0
    h[0] = hw.accwrap(19, h[0])
    # accwrap 的進位還在 ACC，用 accrd 取出再以一般 RV32 add 加到 h1。
    # h1 因此可能略超過 25 bit，但不會破壞 A1 界限：欄 9 的和 < 10·19·2^52 ≈ 2^59.6，
    # accrd.25 之後 ACC < 2^34.6，wrap_v = h0 + 19·ACC < 2^39，進位 < 2^13，
    # 所以 h1 < 2^25 + 2^13，×38 後約 1.276e9 < 2^31（餘裕約 1.68 倍）。
    # 連乘測試（run_chain）實測 h1 最大 0x1ffd41e，與此一致。
    carry = hw.accrd(25)
    h[1] += carry
    return h


# ---------------------------------------------------------------------------
# 之後要補的部分（對應計畫書里程碑）
# ---------------------------------------------------------------------------

def fe_sq(f, hw):
    """TODO（M3）：利用 f_i*f_j = f_j*f_i 對稱性，把 100 條 macc 降到約 55 條。

    提示：非對角項要 ×2，可以合併進 scale_factor（N 會出現 ×4、×76，
    要決定是改軟體預先加倍運算元，還是擴充 scaler 支援的常數）。
    """
    raise NotImplementedError


def poly1305_block(h, r, s, m, hw):
    """TODO（M2）：radix 2^26、5 個 limb，s_j = 5*r_j 由軟體預先算好。

    結構和 fe_mul 相同：acczero、每欄 5 條 macc.s1、accrd.26，最後 accwrap.5。
    """
    raise NotImplementedError


# ---------------------------------------------------------------------------
# 測試與示範
# ---------------------------------------------------------------------------

def rand_limbs(lazy):
    """隨機正規化 limb；lazy=True 時每個 limb 多 1 bit，模擬 ladder 的 lazy addition。"""
    extra = 1 if lazy else 0
    return [random.getrandbits(WIDTH[i] + extra) for i in range(10)]


def print_trace(hw, columns=2):
    print(f"{'#':>3}  {'指令':<11} {'funct7':<6} {'operands':<26} {'ACC 之後':<20} 硬體路徑")
    col = 0
    for n, (op, args, acc) in enumerate(hw.trace):
        ops = ", ".join(hex(a) for a in args)
        print(f"{n:>3}  {op:<11} {FUNCT7[op]:#04x}   {ops:<26} {acc:#018x}  {HW_PATH[op]}")
        if op.startswith("accrd"):
            col += 1
            if col >= columns:
                print("     ...（其餘欄位同理）")
                break


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("-n", type=int, default=3000, help="隨機測試組數")
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--trace", action="store_true", help="印出一次 fe_mul 的前兩欄")
    ap.add_argument("--lazy", action="store_true", help="limb 多 1 bit，檢查 A1 界限")
    ap.add_argument("--chain", type=int, default=1000, help="連乘測試的次數")
    args = ap.parse_args()
    random.seed(args.seed)

    # 先確認乘法器模型：< 2^31 時有號 = 無號，>= 2^31 時不同
    a, b = 2**31 - 1, 2**31 - 1
    assert unified_mul_32x32(a, b) == a * b
    a, b = 2**31, 3
    print(f"unified_mul(2^31, 3) = {unified_mul_32x32(a, b):#018x}，"
          f"無號應為 {a * b:#018x} -> 這就是 A1 要求運算元 < 2^31 的原因\n")

    if args.trace:
        hw = HorcruxAcc()
        fe_mul(rand_limbs(False), rand_limbs(False), hw)
        print_trace(hw)
        print()

    if not args.lazy:
        s = run_random(args.n, lazy=False, mul="signed", strict=True, seed=args.seed)
        print(f"{args.n} 組測試完成（A1，有號乘法器，全部結果正確）")
        print_stats(s)
    else:
        # 同一批輸入跑兩次：A1 會出錯，A1′ / A2 才是 lazy limb 真正需要的寬度
        a1 = run_random(args.n, lazy=True, mul="signed", strict=False, seed=args.seed)
        print(f"{args.n} 組（lazy limb）在 A1（有號乘法器）下：")
        print(f"  A1 界限違反 {a1['violations']} 次，fe_mul 結果錯誤 {a1['wrong']} / {args.n} 組"
              " -> lazy limb 不能用 A1")
        a2 = run_random(args.n, lazy=True, mul="unsigned", strict=True, seed=args.seed)
        print(f"同一批輸入在 A1′ / A2（無號乘積）下：全部結果正確")
        print_stats(a2)

    # Montgomery ladder 會把 fe_mul 的輸出直接當成下一次的輸入（兩個運算元都是），
    # 而 h1 在 accwrap 的進位加回後可能超過 25 bit。連乘檢查 A1 界限與結果是否仍成立。
    c = run_chain(args.chain)
    print(f"\n連乘 {args.chain} 次（輸出直接當下一次兩個運算元，A1，strict）：全部結果正確")
    print(f"  輸出 limb 最大寬度：{c['limb_bits']}（正規化為 26/25 交錯）")
    print(f"  h1 最大值：{c['max_h1']:#x}，×38 後 {38 * c['max_h1']:#x}"
          f"（A1 上限 2^31 = {2**31:#x}，餘裕 {2**31 / (38 * c['max_h1']):.2f} 倍）")
    print(f"  ACC 最大寬度：{c['max_acc_bits']} bit")


def run_random(n, lazy, mul, strict, seed):
    """n 組隨機輸入；回傳統計。strict=False 時違反界限只計數，並另外計算結果錯誤的組數。"""
    stats = {"violations": 0, "overflows": 0, "wrong": 0,
             "max_acc_bits": 0, "max_operand_bits": 0, "count": {}}
    random.seed(seed)  # lazy 的兩種模式用同一批輸入，才能直接比較
    for _ in range(n):
        f, g = rand_limbs(lazy), rand_limbs(lazy)
        hw = HorcruxAcc(strict=strict, mul=mul)
        h = fe_mul(f, g, hw)
        ok = from_limbs(h) % P == from_limbs(f) * from_limbs(g) % P
        if strict:
            assert ok, "fe_mul 結果錯誤"
        stats["wrong"] += not ok
        stats["violations"] += hw.violations
        stats["overflows"] += hw.overflows
        stats["max_acc_bits"] = max(stats["max_acc_bits"], hw.max_acc_bits)
        stats["max_operand_bits"] = max(stats["max_operand_bits"], hw.max_operand_bits)
        stats["count"] = hw.count
    return stats


def run_chain(steps):
    """x <- fe_mul(x, y)、y <- fe_mul(y, x) 交替，輸出餵回兩個運算元。"""
    x, y = rand_limbs(False), rand_limbs(False)
    xv, yv = from_limbs(x) % P, from_limbs(y) % P
    out = {"limb_bits": [0] * 10, "max_h1": 0, "max_acc_bits": 0}
    for step in range(steps):
        hw = HorcruxAcc(strict=True, mul="signed")
        if step % 2 == 0:
            x = fe_mul(x, y, hw)
            xv = xv * yv % P
            h, hv = x, xv
        else:
            y = fe_mul(y, x, hw)
            yv = yv * xv % P
            h, hv = y, yv
        assert from_limbs(h) % P == hv, f"連乘第 {step} 次結果錯誤"
        out["limb_bits"] = [max(b, v.bit_length()) for b, v in zip(out["limb_bits"], h)]
        out["max_h1"] = max(out["max_h1"], h[1])
        out["max_acc_bits"] = max(out["max_acc_bits"], hw.max_acc_bits)
    return out


def print_stats(s):
    total = sum(s["count"].values())
    print(f"  每次 fe_mul 的協處理器指令：{total} 條 {dict(sorted(s['count'].items()))}")
    print(f"  加上 load f,g（20）、store h（10）、add（1）約 {total + 31} 條（計畫書估約 145）")
    print(f"  ACC 最大寬度：{s['max_acc_bits']} bit（64-bit ACC 溢位 {s['overflows']} 次）")
    print(f"  縮放後運算元最大寬度：{s['max_operand_bits']} bit")


if __name__ == "__main__":
    main()
