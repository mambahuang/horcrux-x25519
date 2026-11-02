"""X25519 純量乘法的逐指令 golden model（M3，計畫書 5.3 節）。

建在 fe_mul_model.py 的 HorcruxAcc 與 fe_mul 之上，補齊 Montgomery ladder 需要的其他運算：
  fe_sq        平方：利用對稱性只用 55 條 macc；交叉項的 ×2 由軟體先乘在 rs1（不需新指令）
  fe_mul_a24   乘常數 a24 = 121665：每個 limb 一條 macc.s1
  fe_add/sub   一般 RV32 加減，再做一次進位，讓 limb 回到 A1 界限內
  fe_invert    z^(p-2)：254 次 fe_sq + 11 次 fe_mul
  fe_tobytes   化簡成 mod p 的唯一值再編碼
每條 macc 都檢查 A1 界限（rs1 與 N·rs2 < 2^31）與 ACC 溢位；
軟體運算的每個中間值都檢查是否放得進 uint32，對應之後的 C 實作。

測試向量取自 RFC 7748 原文（§5.2、§6.1），不是憑記憶寫的。

執行：
  python x25519_model.py               # 各運算的隨機測試 + RFC 7748 §5.2 / §6.1 + 統計
  python x25519_model.py --trace       # 印出一次 fe_sq 第 0、1 欄的指令與 ACC
  python x25519_model.py --iter 1000   # 用逐指令模型跑 §5.2 迭代 1000 次（約數分鐘）
"""

import argparse
import random

from fe_mul_model import (HorcruxAcc, P, OFFSET, WIDTH, MASK64, fe_mul, scale_factor,
                          to_limbs, from_limbs, print_trace)

A24 = 121665                       # RFC 7748 §5：(486662 - 2) / 4
MASK = [(1 << w) - 1 for w in WIDTH]
U32 = 1 << 32

# 2p 拆成 limb：fe_sub 先加 2p 再減，每個 limb 都不會變負數（C 端是 uint32_t）
TWO_P = [2 * ((1 << WIDTH[i]) - 1) for i in range(10)]
TWO_P[0] -= 2 * 18                 # p 的 limb 0 是 2^26 - 19，其餘都是全 1
assert from_limbs(TWO_P) == 2 * P

ZERO = [0] * 10
ONE = [1] + [0] * 9

# 每次 X25519 呼叫各種運算的次數，給統計用
OPS = {}


def _op(name):
    OPS[name] = OPS.get(name, 0) + 1


def _u32(h, what):
    """C 端的 limb 是 uint32_t：每個中間值都要 0 <= v < 2^32。"""
    for v in h:
        assert 0 <= v < U32, f"{what}: limb {v:#x} 放不進 uint32"
    return h


class FastAcc(HorcruxAcc):
    """給整個 X25519 用的 HorcruxAcc：結果與統計相同，只是快很多。

    A1 界限成立時，有號乘法器的結果等於無號乘積（fe_mul_model 開頭已驗證），
    所以這裡改用 Python 的 *，並且不保留 trace。A1 與 ACC 溢位的檢查照舊，一律 strict。
    """

    def __init__(self):
        super().__init__(strict=True, mul="signed")
        self.max_rs1_bits = 0

    def _log(self, op, args):
        self.count[op] = self.count.get(op, 0) + 1
        self.max_acc_bits = max(self.max_acc_bits, self.acc.bit_length())

    def macc(self, n, rs1, rs2):
        assert n in (1, 2, 19, 38)
        assert rs1 >= 0 and rs2 >= 0
        if not (n * rs2 < 2**31 and rs1 < 2**31):
            raise AssertionError(f"macc.s{n}: 違反 A1 界限（rs1 = {rs1:#x}，N·rs2 = {n * rs2:#x}）")
        self.max_operand_bits = max(self.max_operand_bits, (n * rs2).bit_length())
        self.max_rs1_bits = max(self.max_rs1_bits, rs1.bit_length())
        acc_sum = self.acc + rs1 * n * rs2
        if acc_sum > MASK64:
            raise AssertionError(f"macc.s{n}: ACC 溢位（{acc_sum.bit_length()} bit）")
        self.acc = acc_sum
        self._log(f"macc.s{n}", (rs1, rs2))


# ---------------------------------------------------------------------------
# 用到 ACC 指令的運算
# ---------------------------------------------------------------------------

def mul(f, g, hw):
    _op("fe_mul")
    return fe_mul(f, g, hw)


def fe_sq(f, hw):
    """h = f^2 mod p。和 fe_mul 一樣逐欄累加，但 f_i·f_j 與 f_j·f_i 合併成一條。

    第 k 欄的 10 個 (i, j) 裡：
      i == j  對角項，macc(N, f_i, f_i)
      i <  j  交叉項，出現兩次 -> macc(N, 2·f_i, f_j)
      i >  j  已經併進 i < j 那一條，跳過
    合併後需要的倍數是 2N（×2、×4、×38、×76），但 scaler 只有 ×1、×2、×19、×38。
    做法是讓軟體先算 2·f_i 放在 rs1：rs1 不經過 scaler，只要 < 2^31（2·f_i 最多 27 bit），
    rs2 仍是 f_j 乘上 fe_mul 裡同樣的 N，界限和 fe_mul 完全相同。
    偶數欄 2 個對角項 + 4 個交叉項，奇數欄 5 個交叉項：共 5·6 + 5·5 = 55 條 macc。
    """
    _op("fe_sq")
    f2 = _u32([f[i] + f[i] for i in range(9)], "fe_sq 2·f_i")  # 9 條 RV32 add；f_9 不會在 rs1
    h = [0] * 10
    hw.acczero()
    for k in range(10):
        for i in range(10):
            j = (k - i) % 10
            if i == j:
                hw.macc(scale_factor(i, i), f[i], f[i])
            elif i < j:
                hw.macc(scale_factor(i, j), f2[i], f[j])
        h[k] = hw.accrd(WIDTH[k])
    # 收尾和 fe_mul 相同：>= 2^255 的部分 ×19 加回 h0，進位用 accrd 取出加到 h1
    h[0] = hw.accwrap(19, h[0])
    h[1] += hw.accrd(25)
    return h


def fe_mul_a24(f, hw):
    """h = 121665·f mod p。a24 是常數，沒有半 bit 的問題，第 k 欄只有 f_k·a24 一項。

    rs2 = a24 < 2^17、rs1 = f_k <= 26 bit，都在 A1 界限內。共 23 條協處理器指令。
    """
    _op("fe_mul_a24")
    h = [0] * 10
    hw.acczero()
    for k in range(10):
        hw.macc(1, f[k], A24)
        h[k] = hw.accrd(WIDTH[k])
    h[0] = hw.accwrap(19, h[0])
    h[1] += hw.accrd(25)
    return h


# ---------------------------------------------------------------------------
# 純軟體運算（RV32 指令）
# ---------------------------------------------------------------------------

def fe_carry(h):
    """進位一輪：limb 0..9 依序把超出寬度的部分進到下一個，limb 9 的進位 ×19 回到 limb 0，
    最後 limb 0 再進位一次到 limb 1。輸出 limb 1 最多 2^25（多 1），其餘都在寬度內，
    所以縮放後最大約 38·2^25 < 2^31，符合 A1。
    """
    h = _u32(list(h), "fe_carry 輸入")
    for i in range(10):
        c = h[i] >> WIDTH[i]
        h[i] &= MASK[i]
        if i < 9:
            h[i + 1] += c
        else:
            h[0] += 19 * c
    c = h[0] >> 26
    h[0] &= MASK[0]
    h[1] += c
    return _u32(h, "fe_carry 輸出")


def fe_add(f, g):
    _op("fe_add")
    return fe_carry([f[i] + g[i] for i in range(10)])


def fe_sub(f, g):
    """f - g：先加 2p 讓每個 limb 都是非負數，再進位。需要 g_i <= 2p_i，正規化的 limb 都成立。"""
    _op("fe_sub")
    h = [f[i] + TWO_P[i] - g[i] for i in range(10)]
    assert min(h) >= 0, "fe_sub：g 的 limb 太大，加 2p 後仍為負數"
    return fe_carry(h)


def cswap(swap, a, b):
    """C 端用 mask = 0 - swap、t = mask & (a ^ b) 做 constant-time 交換；這裡只看結果。"""
    return (b, a) if swap else (a, b)


def fe_frombytes(b):
    """32 bytes little-endian -> limb。X25519 必須忽略最高 bit（RFC 7748 §5）。

    值可能落在 [p, 2^255)（non-canonical），RFC 要求照樣接受；limb 正好切滿 255 bit，
    之後的運算本來就是 mod p，不需要先化簡。
    """
    return to_limbs(int.from_bytes(b, "little") & ((1 << 255) - 1))


def fe_tobytes(h):
    """化簡成 [0, p) 的唯一值，再編碼成 32 bytes。

    1. fe_carry 兩次：第一次後 limb 1 可能是 2^25，第二次把它進位掉。若第二次的進位一路傳到
       limb 9 再繞回，limb 0 原本只剩很小的值，加 19 也不會再溢出，所以兩次後每個 limb
       都 < 2^寬度，值 < 2^255。
    2. 值 >= p 等價於 值 + 19 >= 2^255：用一條進位鏈算出 q（0 或 1）。
    3. 加上 19·q 再進位，丟掉 bit 255，等於減掉 q·p。
    """
    h = fe_carry(fe_carry(h))
    assert all(h[i] <= MASK[i] for i in range(10)), "fe_tobytes：兩次進位後 limb 仍超出寬度"
    q = (h[0] + 19) >> 26
    for i in range(1, 10):
        q = (h[i] + q) >> WIDTH[i]
    h[0] += 19 * q
    for i in range(9):
        c = h[i] >> WIDTH[i]
        h[i] &= MASK[i]
        h[i + 1] += c
    h[9] &= MASK[9]
    v = from_limbs(h)
    assert v < P
    return v.to_bytes(32, "little")


def decode_scalar(k):
    """RFC 7748 §5 decodeScalar25519：清掉低 3 bit 與 bit 255，設 bit 254。"""
    k = bytearray(k)
    k[0] &= 248
    k[31] &= 127
    k[31] |= 64
    return int.from_bytes(k, "little")


# ---------------------------------------------------------------------------
# 模反元素與 ladder
# ---------------------------------------------------------------------------

def sq_n(f, n, hw):
    for _ in range(n):
        f = fe_sq(f, hw)
    return f


def fe_invert(z, hw):
    """z^(p-2) = z^(2^255 - 21)，費馬小定理。和 ref10 / curve25519-donna 相同的加法鏈：
    254 次平方、11 次乘法。註解裡 z^e 的 e 是目前累積的指數。
    """
    z2 = fe_sq(z, hw)                             # z^2
    z9 = mul(sq_n(z2, 2, hw), z, hw)              # z^8 · z = z^9
    z11 = mul(z9, z2, hw)                         # z^11
    z_5_0 = mul(fe_sq(z11, hw), z9, hw)           # z^22 · z^9 = z^(2^5 - 1)
    z_10_0 = mul(sq_n(z_5_0, 5, hw), z_5_0, hw)   # z^(2^10 - 1)
    z_20_0 = mul(sq_n(z_10_0, 10, hw), z_10_0, hw)
    z_40_0 = mul(sq_n(z_20_0, 20, hw), z_20_0, hw)
    z_50_0 = mul(sq_n(z_40_0, 10, hw), z_10_0, hw)
    z_100_0 = mul(sq_n(z_50_0, 50, hw), z_50_0, hw)
    z_200_0 = mul(sq_n(z_100_0, 100, hw), z_100_0, hw)
    z_250_0 = mul(sq_n(z_200_0, 50, hw), z_50_0, hw)  # z^(2^250 - 1)
    return mul(sq_n(z_250_0, 5, hw), z11, hw)     # z^(2^255 - 32 + 11) = z^(p - 2)


def x25519(k_bytes, u_bytes, hw):
    """RFC 7748 §5 的 Montgomery ladder，逐行對應 RFC 的虛擬碼。"""
    k = decode_scalar(k_bytes)
    x1 = fe_frombytes(u_bytes)
    x2, z2, x3, z3 = ONE, ZERO, x1, ONE
    swap = 0
    for t in range(254, -1, -1):
        kt = (k >> t) & 1
        swap ^= kt
        x2, x3 = cswap(swap, x2, x3)
        z2, z3 = cswap(swap, z2, z3)
        swap = kt

        A = fe_add(x2, z2)
        AA = fe_sq(A, hw)
        B = fe_sub(x2, z2)
        BB = fe_sq(B, hw)
        E = fe_sub(AA, BB)
        C = fe_add(x3, z3)
        D = fe_sub(x3, z3)
        DA = mul(D, A, hw)
        CB = mul(C, B, hw)
        x3 = fe_sq(fe_add(DA, CB), hw)
        z3 = mul(x1, fe_sq(fe_sub(DA, CB), hw), hw)
        x2 = mul(AA, BB, hw)
        z2 = mul(E, fe_add(AA, fe_mul_a24(E, hw)), hw)

    x2, x3 = cswap(swap, x2, x3)
    z2, z3 = cswap(swap, z2, z3)
    return fe_tobytes(mul(x2, fe_invert(z2, hw), hw))


def x25519_ref(k_bytes, u_bytes):
    """同一個 ladder 直接用 Python 大整數 mod p 算，和 limb 表示法無關，用來交叉比對。"""
    k = decode_scalar(k_bytes)
    x1 = int.from_bytes(u_bytes, "little") & ((1 << 255) - 1)
    x2, z2, x3, z3, swap = 1, 0, x1, 1, 0
    for t in range(254, -1, -1):
        kt = (k >> t) & 1
        swap ^= kt
        if swap:
            x2, x3, z2, z3 = x3, x2, z3, z2
        swap = kt
        A, B = (x2 + z2) % P, (x2 - z2) % P
        AA, BB = A * A % P, B * B % P
        E = (AA - BB) % P
        C, D = (x3 + z3) % P, (x3 - z3) % P
        DA, CB = D * A % P, C * B % P
        x3 = (DA + CB) ** 2 % P
        z3 = x1 * (DA - CB) ** 2 % P
        x2 = AA * BB % P
        z2 = E * (AA + A24 * E) % P
    if swap:
        x2, x3, z2, z3 = x3, x2, z3, z2
    return (x2 * pow(z2, P - 2, P) % P).to_bytes(32, "little")


# ---------------------------------------------------------------------------
# RFC 7748 測試向量（原文 §5.2、§6.1，逐字複製）
# ---------------------------------------------------------------------------

H = bytes.fromhex
RFC_5_2 = [
    # (scalar, u, output)
    (H("a546e36bf0527c9d3b16154b82465edd62144c0ac1fc5a18506a2244ba449ac4"),
     H("e6db6867583030db3594c1a424b15f7c726624ec26b3353b10a903a6d0ab1c4c"),
     H("c3da55379de9c6908e94ea4df28d084f32eccf03491c71f754b4075577a28552")),
    # 這組 u 的最後一個 byte 是 0x93，最高 bit 為 1，順便測 fe_frombytes 有沒有忽略它
    (H("4b66e9d4d1b4673c5ad22691957d6af5c11b6421e0ea01d42ca4169e7918ba0d"),
     H("e5210f12786811d3f4b7959d0538ae2c31dbe7106fc03c3efc4cd549c715a493"),
     H("95cbde9476e8907d7aade45cb4b873f88b595a68799fa152e6f8f7647aac7957")),
]
# RFC 同時給了十進位的值：scalar 是 decodeScalar25519（clamp）之後的值，u 是遮掉最高 bit 後的值。
# 用它們交叉檢查上面的 hex 有沒有抄錯。
RFC_5_2_DECIMAL = [
    (31029842492115040904895560451863089656472772604678260265531221036453811406496,
     34426434033919594451155107781188821651316167215306631574996226621102155684838),
    (35156891815674817266734212754503633747128614016119564763269015315466259359304,
     8883857351183929894090759386610649319417338800022198945255395922347792736741),
]
RFC_ITER_START = H("0900000000000000000000000000000000000000000000000000000000000000")
RFC_ITER = {
    1: H("422c8e7a6227d7bca1350b3e2bb7279f7897b87bb6854b783c60e80311ae3079"),
    1000: H("684cf59ba83309552800ef566f2f4d3c1c3887c49360e3875f2eb94d99532c51"),
}
RFC_6_1 = {
    "a": H("77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a"),
    "K_A": H("8520f0098930a754748b7ddcb43ef75a0dbf3a0d26381af4eba4a98eaa9b4e6a"),
    "b": H("5dab087e624a8a4b79e17f8b83800ee66f3bb1292618b6fd1c2f8b27ff88e0eb"),
    "K_B": H("de9edb7d7b7dc1b4d35b61c2ece435373f8343c85b78674dadfc7e146f882b4f"),
    "K": H("4a5d9d5ba4ce2de1728e3bf480350f25e07e21c947d19e3376f09b3c1e161742"),
}
BASE_U = RFC_ITER_START   # u = 9


def iterate(n, fn):
    """§5.2 第二種測試：k <- X25519(k, u)、u <- 舊的 k，重複 n 次。"""
    k = u = RFC_ITER_START
    for _ in range(n):
        k, u = fn(k, u), k
    return k


# ---------------------------------------------------------------------------
# 測試
# ---------------------------------------------------------------------------

def rand_fe():
    """隨機正規化 limb；limb 1 有時取 fe_mul 輸出可能的上限 2^25 + 2^13。"""
    f = [random.getrandbits(WIDTH[i]) for i in range(10)]
    if random.random() < 0.2:
        f[1] = (1 << 25) + random.getrandbits(13)
    return f


def max_fe():
    f = [MASK[i] for i in range(10)]
    f[1] = (1 << 25) + (1 << 13)
    return f


def check_field_ops(n):
    hw = FastAcc()
    for t in range(n):
        f, g = (max_fe(), max_fe()) if t == 0 else (rand_fe(), rand_fe())
        fv, gv = from_limbs(f), from_limbs(g)
        assert from_limbs(fe_sq(f, hw)) % P == fv * fv % P, "fe_sq 結果錯誤"
        assert from_limbs(fe_mul_a24(f, hw)) % P == fv * A24 % P, "fe_mul_a24 結果錯誤"
        for name, h, v in (("fe_add", fe_add(f, g), fv + gv), ("fe_sub", fe_sub(f, g), fv - gv)):
            assert from_limbs(h) % P == v % P, f"{name} 結果錯誤"
            assert all(h[i] <= MASK[i] for i in range(10) if i != 1) and h[1] <= 1 << 25, \
                f"{name} 輸出沒有正規化"
    return hw


def count_one(fn, *args):
    hw = HorcruxAcc()
    fn(*args, hw)
    return sum(hw.count.values()), dict(sorted(hw.count.items())), hw


def check_sq_chain(n):
    """平方的輸出直接當下一次的輸入，確認 h1 的小幅超出不會累積到破壞 A1 界限。"""
    f = rand_fe()
    v = from_limbs(f) % P
    hw = FastAcc()
    for step in range(n):
        f = fe_sq(f, hw)
        v = v * v % P
        assert from_limbs(f) % P == v, f"連續平方第 {step} 次結果錯誤"
    return hw


def check_tobytes():
    cases = [0, 1, 18, 19, P - 1, P, P + 1, P + 18, 2**255 - 1, 2 * P - 1]
    cases += [random.randrange(2**255) for _ in range(1000)]
    for v in cases:
        # 2^255 以上的值用 to_limbs 會被截掉，所以 limb 9 自己補上溢出的部分
        h = to_limbs(v % 2**255)
        h[9] += v >> 255 << 25
        assert fe_tobytes(h) == (v % P).to_bytes(32, "little"), f"fe_tobytes({v:#x}) 錯誤"
    # 每個 limb 都到 fe_carry 輸入的上限（2^27 左右）
    h = [(1 << (WIDTH[i] + 1)) - 1 for i in range(10)]
    assert fe_tobytes(h) == (from_limbs(h) % P).to_bytes(32, "little")
    return len(cases) + 1


def check_invert(n):
    hw = FastAcc()
    for _ in range(n):
        z = rand_fe()
        zv = from_limbs(z) % P
        if zv == 0:
            continue
        assert from_limbs(fe_invert(z, hw)) % P == pow(zv, P - 2, P), "fe_invert 結果錯誤"
    return hw


def run_x25519(k, u):
    """跑一次 X25519，回傳結果與這一次的統計。"""
    OPS.clear()
    hw = FastAcc()
    out = x25519(k, u, hw)
    return out, hw, dict(OPS)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("-n", type=int, default=3000, help="各運算的隨機測試組數")
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--trace", action="store_true", help="印出一次 fe_sq 的前兩欄")
    ap.add_argument("--iter", type=int, default=1, choices=(1, 1000),
                    help="§5.2 迭代測試用逐指令模型跑幾次（1000 次約數分鐘）")
    args = ap.parse_args()
    random.seed(args.seed)

    if args.trace:
        _, _, hw = count_one(fe_sq, rand_fe())
        print_trace(hw)
        print()

    # 1. 各運算單獨測
    for name, fn, args_ in (("fe_mul", fe_mul, (rand_fe(), rand_fe())),
                            ("fe_sq", fe_sq, (rand_fe(),)),
                            ("fe_mul_a24", fe_mul_a24, (rand_fe(),))):
        total, cnt, _ = count_one(fn, *args_)
        print(f"{name:<11} 每次 {total:>3} 條協處理器指令 {cnt}")
    hw = check_field_ops(args.n)
    print(f"\nfe_sq / fe_mul_a24 / fe_add / fe_sub：{args.n} 組（含 limb 全滿）全部正確，"
          f"fe_add / fe_sub 輸出都已正規化")
    hw = check_sq_chain(1000)
    print(f"連續平方 1000 次：全部正確，rs1 最寬 {hw.max_rs1_bits} bit、"
          f"N·rs2 最寬 {hw.max_operand_bits} bit（A1 上限 31）")
    print(f"fe_tobytes：{check_tobytes()} 個值（含 0、p-1、p、p+1、2^255-1）化簡正確")
    check_invert(20)
    print("fe_invert：20 組與 pow(z, p-2, p) 相同")

    # 2. RFC 7748
    for i, ((k, u, out), (kd, ud)) in enumerate(zip(RFC_5_2, RFC_5_2_DECIMAL)):
        assert decode_scalar(k) == kd, "RFC 向量抄錯：scalar 與十進位不符"
        assert from_limbs(fe_frombytes(u)) == ud, "RFC 向量抄錯：u 與十進位不符"
        assert x25519_ref(k, u) == out, f"x25519_ref 與 RFC §5.2 第 {i + 1} 組不符"
        got, hw, ops = run_x25519(k, u)
        assert got == out, f"x25519 與 RFC §5.2 第 {i + 1} 組不符"
    print(f"\nRFC 7748 §5.2 單次向量 2 組：x25519 與 x25519_ref 都相符")

    assert iterate(1, x25519_ref) == RFC_ITER[1]
    assert iterate(1000, x25519_ref) == RFC_ITER[1000]
    print("RFC 7748 §5.2 迭代 1 次、1000 次：x25519_ref 相符")
    assert iterate(args.iter, lambda k, u: run_x25519(k, u)[0]) == RFC_ITER[args.iter]
    print(f"RFC 7748 §5.2 迭代 {args.iter} 次：x25519（逐指令模型）相符")

    v = RFC_6_1
    assert run_x25519(v["a"], BASE_U)[0] == v["K_A"]
    assert run_x25519(v["b"], BASE_U)[0] == v["K_B"]
    assert run_x25519(v["a"], v["K_B"])[0] == v["K"]
    assert run_x25519(v["b"], v["K_A"])[0] == v["K"]
    print("RFC 7748 §6.1 Diffie-Hellman：K_A、K_B 與雙方算出的 K 都相符")

    # 3. 一次 X25519 的統計（取最後一次 §6.1 的呼叫）
    _, hw, ops = run_x25519(v["b"], v["K_A"])
    total = sum(hw.count.values())
    print(f"\n一次 X25519：")
    print(f"  運算次數：{dict(sorted(ops.items()))}")
    print(f"  協處理器指令：{total} 條 {dict(sorted(hw.count.items()))}")
    print(f"  rs1 最寬 {hw.max_rs1_bits} bit、N·rs2 最寬 {hw.max_operand_bits} bit"
          f"（A1 上限 31）、ACC 最寬 {hw.max_acc_bits} bit")


if __name__ == "__main__":
    main()
