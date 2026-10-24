"""Poly1305 區塊的逐指令 golden model（M2，計畫書 2.4 節）。

h = (h + m) · r mod 2^130 − 5，radix 2^26、5 個 limb。和 fe_mul 一樣用 product scanning，
但比較簡單：
  - 每欄 5 條 macc，全部是 macc.s1：繞回的項 2^130 ≡ 5 用 s_j = 5·r_j，由軟體預先算好，
    所以 Poly1305 不需要硬體縮放（計畫書 2.4 節）
  - 每欄都取 26 bit（accrd.26），最後用 accwrap.5 把 >= 2^130 的部分 ×5 加回 h0

ACC 指令組的模型（HorcruxAcc）、funct7 與 trace 都沿用 fe_mul_model.py。
區塊之外的部分（h + m 的 5 條 add、最後的完全約簡與 + s）是一般 RV32 軟體，
在這裡用 Python 大整數表示，不經過 ACC。

執行：
  python poly1305_model.py            # RFC 8439 §2.5.2 + 隨機測試 + 連續區塊 + 統計
  python poly1305_model.py --trace    # 印出一個區塊第 0、1 欄的指令與 ACC
"""

import argparse
import random

from fe_mul_model import HorcruxAcc, print_trace

P = 2**130 - 5
MASK26 = (1 << 26) - 1
CLAMP = 0x0ffffffc0ffffffc0ffffffc0fffffff


def to_limbs(x):
    return [(x >> (26 * i)) & MASK26 for i in range(5)]


def from_limbs(h):
    return sum(v << (26 * i) for i, v in enumerate(h))


def split_key(key):
    """32-byte one-time key -> (r 與 s_j 的 limb, s128)。r 先 clamp，s_j = 5·r_j 由軟體預先算好。"""
    r = int.from_bytes(key[:16], "little") & CLAMP
    s128 = int.from_bytes(key[16:], "little")
    r_limbs = to_limbs(r)
    return r_limbs, [5 * x for x in r_limbs], s128


def block_limbs(block):
    """16 bytes 以內的訊息區塊 -> m 的 limb。多出的 1 放在區塊結尾的下一個 byte（RFC 的 0x01 byte）。"""
    m = int.from_bytes(block, "little") + (1 << (8 * len(block)))
    return to_limbs(m)


# ---------------------------------------------------------------------------
# 區塊運算：硬體做的部分
# ---------------------------------------------------------------------------

def poly1305_block(h, r, s, m, hw):
    """h = (h + m) · r mod 2^130 − 5。h、r、s、m 都是 5 個 limb，s_j = 5·r_j。"""
    # h + m：一般 RV32 add，h_i + m_i 最多約 27 bit
    a = [h[i] + m[i] for i in range(5)]
    out = [0] * 5
    hw.acczero()
    for k in range(5):
        # 第 k 欄：i + j = k 用 r_j；i + j = k + 5 跨過 2^130，2^130 ≡ 5，改用 s_j = 5·r_j
        for i in range(5):
            j = (k - i) % 5
            hw.macc(1, a[i], r[j] if i <= k else s[j])
        out[k] = hw.accrd(26)
    # 欄 4 之後 ACC 裡剩下的是 >= 2^130 的部分，×5 加回 h0
    out[0] = hw.accwrap(5, out[0])
    # accwrap 的進位還在 ACC，取出後用一般 add 加到 h1，h1 因此可能略超過 26 bit
    out[1] += hw.accrd(26)
    return out


# ---------------------------------------------------------------------------
# 完整 MAC：區塊之外是軟體（M3），這裡只為了和 RFC 的 tag 對照
# ---------------------------------------------------------------------------

def poly1305_mac(key, msg, hw_factory=HorcruxAcc, trace=None):
    """回傳 (tag, 每個區塊之後的 h)。hw_factory 每個區塊建一個新的 HorcruxAcc。"""
    r, s, s128 = split_key(key)
    h = [0] * 5
    accs = []
    for off in range(0, len(msg), 16):
        hw = hw_factory()
        h = poly1305_block(h, r, s, block_limbs(msg[off:off + 16]), hw)
        accs.append(list(h))
        if trace is not None:
            trace.append(hw)
    tag = ((from_limbs(h) % P) + s128) % 2**128   # 完全約簡加上 s：軟體
    return tag.to_bytes(16, "little"), accs


def poly1305_ref(key, msg):
    """RFC 8439 §2.5.1 的大整數參考實作，回傳 (tag, 每個區塊之後的 Acc)。"""
    r = int.from_bytes(key[:16], "little") & CLAMP
    s = int.from_bytes(key[16:], "little")
    acc, accs = 0, []
    for off in range(0, len(msg), 16):
        block = msg[off:off + 16]
        acc = (acc + int.from_bytes(block, "little") + (1 << (8 * len(block)))) * r % P
        accs.append(acc)
    return ((acc + s) % 2**128).to_bytes(16, "little"), accs


# ---------------------------------------------------------------------------
# 測試
# ---------------------------------------------------------------------------

# RFC 8439 §2.5.2，數值直接抄自 RFC 原文
RFC_KEY = bytes.fromhex("85d6be7857556d337f4452fe42d506a8"
                        "0103808afb0db2fd4abff6af4149f51b")
RFC_MSG = b"Cryptographic Forum Research Group"
RFC_ACCS = [0x2c88c77849d64ae9147ddeb88e69c83fc,
            0x2d8adaf23b0337fa7cccfb4ea344b30de,
            0x28d31b7caff946c77c8844335369d03a7]
RFC_TAG = bytes.fromhex("a8061dc1305136c6c22b8baf0c0127a9")


def check_rfc():
    tag_ref, accs_ref = poly1305_ref(RFC_KEY, RFC_MSG)
    assert accs_ref == RFC_ACCS and tag_ref == RFC_TAG, "大整數參考實作和 RFC 不符"
    tag, accs = poly1305_mac(RFC_KEY, RFC_MSG)
    for n, (h, want) in enumerate(zip(accs, RFC_ACCS)):
        assert from_limbs(h) % P == want, f"RFC 區塊 {n + 1}：Acc 不符"
    assert tag == RFC_TAG, "RFC tag 不符"


def rand_key():
    return bytes(random.getrandbits(8) for _ in range(32))


def run_random(n):
    """隨機 key、隨機 h（含進位後略超過 26 bit 的 h1）、隨機完整或不完整區塊。"""
    stats = {"max_acc_bits": 0, "max_operand_bits": 0, "count": {}}
    for _ in range(n):
        r, s, _ = split_key(rand_key())
        h = [random.getrandbits(26) for _ in range(5)]
        h[1] += random.getrandbits(14)          # accwrap 進位加到 h1 後的情況
        block = bytes(random.getrandbits(8) for _ in range(random.randint(1, 16)))
        m = block_limbs(block)
        hw = HorcruxAcc(strict=True, mul="signed")
        out = poly1305_block(h, r, s, m, hw)
        want = (from_limbs(h) + from_limbs(m)) * from_limbs(r) % P
        assert from_limbs(out) % P == want, "區塊結果錯誤"
        stats["max_acc_bits"] = max(stats["max_acc_bits"], hw.max_acc_bits)
        stats["max_operand_bits"] = max(stats["max_operand_bits"], hw.max_operand_bits)
        stats["count"] = hw.count
    return stats


def run_chain(n_blocks):
    """一則 n_blocks 個區塊的長訊息：輸出直接餵回下一個區塊，和大整數參考逐區塊比對。"""
    key = rand_key()
    msg = bytes(random.getrandbits(8) for _ in range(16 * n_blocks - 5))   # 最後一塊不完整
    tag_ref, accs_ref = poly1305_ref(key, msg)
    tag, accs = poly1305_mac(key, msg)
    for n, (h, want) in enumerate(zip(accs, accs_ref)):
        assert from_limbs(h) % P == want, f"連續區塊第 {n} 塊錯誤"
    assert tag == tag_ref
    return [max(h[i] for h in accs).bit_length() for i in range(5)]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("-n", type=int, default=3000, help="隨機區塊數")
    ap.add_argument("--chain", type=int, default=1000, help="連續區塊數")
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--trace", action="store_true", help="印出一個區塊的前兩欄")
    args = ap.parse_args()
    random.seed(args.seed)

    check_rfc()
    print("RFC 8439 §2.5.2：3 個區塊的 Acc 與 tag 全部相符")

    if args.trace:
        traces = []
        poly1305_mac(RFC_KEY, RFC_MSG[:16], trace=traces)
        print()
        print_trace(traces[0])
        print()

    st = run_random(args.n)
    total = sum(st["count"].values())
    print(f"{args.n} 組隨機區塊完成（A1，有號乘法器，全部結果正確）")
    print(f"  每個區塊的協處理器指令：{total} 條 {dict(sorted(st['count'].items()))}")
    print(f"  加上 h + m 的 add（5）、h1 的 add（1）約 {total + 6} 條，另有 load / store")
    print(f"  ACC 最大寬度：{st['max_acc_bits']} bit")
    print(f"  運算元最大寬度：{st['max_operand_bits']} bit（rs2 = r 或 s，A1 上限 31）")

    bits = run_chain(args.chain)
    print(f"\n連續 {args.chain} 個區塊（輸出直接餵回，最後一塊不完整）：全部結果與 tag 正確")
    print(f"  輸出 limb 最大寬度：{bits}")


if __name__ == "__main__":
    main()
