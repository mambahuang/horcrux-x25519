"""產生 poly1305-block 測試用的 C 標頭檔。

輸出兩個檔案到 sw/applications/tests/poly1305-block/：
  poly1305_hw.h    展開的 poly1305_block_hw()：33 條協處理器指令，每條 macc 註明 i、j、用 r 或 s
  test_vectors.h   20 組 (h, r, s, m)，golden model 算出的位元精確預期 h，以及 h mod p 的標準 limb

規則全部從 poly1305_model.py / fe_mul_model.py 匯入，不重抄。
寫檔之前會做三項檢查，任何一項失敗就不寫：
  1. 要輸出的指令序列在 HorcruxAcc 上重放，trace 必須和 golden poly1305_block() 逐條相同
  2. 每組向量的預期 h 都用 Python 大整數驗證 h ≡ (h + m)·r (mod p)
  3. RFC 8439 §2.5.2 的 3 組向量，預期 h mod p 必須等於 RFC 原文的 Acc

執行：
  python sw/golden/gen_poly1305.py
  python sw/golden/gen_poly1305.py --seed 7 --out-dir <目錄>
"""

import argparse
import os
import random

from fe_mul_model import FUNCT7, HorcruxAcc
from poly1305_model import (
    CLAMP, MASK26, P, RFC_ACCS, RFC_KEY, RFC_MSG, block_limbs, from_limbs, poly1305_block,
    split_key, to_limbs,
)

N_VECTORS = 20
DEFAULT_OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                           "..", "applications", "tests", "poly1305-block")


# ---------------------------------------------------------------------------
# 指令序列：一份資料，同時拿來輸出 C 和在 golden model 上重放
# ---------------------------------------------------------------------------

def build_program():
    """回傳區塊運算的指令序列，每個元素是 (op, 參數 dict)。順序與 poly1305_model.poly1305_block 相同。"""
    prog = [("acczero", {})]
    for k in range(5):
        for i in range(5):
            j = (k - i) % 5
            prog.append(("macc", {"i": i, "j": j, "use_s": i > k, "k": k}))
        prog.append(("accrd", {"dst": f"h{k}", "k": k}))
    prog.append(("accwrap", {"dst": "h0", "src": "h0"}))
    prog.append(("accrd", {"dst": "carry", "k": None}))
    return prog


def replay(prog, h, r, s, m):
    """在 HorcruxAcc 上執行 prog，回傳 (h, hw)。h + m 與最後的 h1 += carry 是一般 RV32 add。"""
    a = [h[i] + m[i] for i in range(5)]
    hw = HorcruxAcc(strict=True, mul="signed")
    reg = {}
    for op, x in prog:
        if op == "acczero":
            hw.acczero()
        elif op == "macc":
            hw.macc(1, a[x["i"]], (s if x["use_s"] else r)[x["j"]])
        elif op == "accrd":
            reg[x["dst"]] = hw.accrd(26)
        elif op == "accwrap":
            reg[x["dst"]] = hw.accwrap(5, reg[x["src"]])
    reg["h1"] += reg["carry"]
    return [reg[f"h{k}"] for k in range(5)], hw


def check_program(prog, inputs):
    """重放結果與 golden poly1305_block 的 trace、輸出必須逐條相同。"""
    for h, r, s, m in inputs:
        golden = HorcruxAcc(strict=True, mul="signed")
        h_ref = poly1305_block(h, r, s, m, golden)
        out, hw = replay(prog, h, r, s, m)
        assert hw.trace == golden.trace, "指令序列和 golden poly1305_block 不一致"
        assert out == h_ref, "重放結果和 golden poly1305_block 不一致"
    total = sum(hw.count.values())
    assert total == 33, f"協處理器指令數 {total}，預期 33"
    return hw.count


# ---------------------------------------------------------------------------
# 測試向量
# ---------------------------------------------------------------------------

def rand_bytes(n):
    return bytes(random.getrandbits(8) for _ in range(n))


def make_vectors(seed):
    """RFC 8439 §2.5.2 的 3 個區塊 + 邊界值 + 隨機值 + 長訊息中段的區塊。"""
    random.seed(seed)
    vecs = []

    # RFC 8439 §2.5.2：3 個區塊依序串接，每一組的輸入 h 是上一組的輸出
    r, s, _ = split_key(RFC_KEY)
    h = [0] * 5
    for n, off in enumerate(range(0, len(RFC_MSG), 16)):
        m = block_limbs(RFC_MSG[off:off + 16])
        vecs.append((f"rfc8439 block {n + 1}", list(h), r, s, m))
        h = poly1305_block(h, r, s, m, HorcruxAcc())

    # 邊界值
    r, s, _ = split_key(rand_bytes(32))
    vecs.append(("zero h, 1-byte block", [0] * 5, r, s, block_limbs(b"\x00")))
    r_max = to_limbs(CLAMP)                                     # clamp 後 r 的最大值
    h_max = [MASK26, MASK26 + 0x3fff, MASK26, MASK26, MASK26]   # h1 含上一塊的進位
    vecs.append(("max h, max r, 0xff block", h_max, r_max, [5 * x for x in r_max],
                 block_limbs(b"\xff" * 16)))

    # 隨機 key、隨機 h、隨機完整區塊
    n_chain = 4
    for t in range(N_VECTORS - len(vecs) - n_chain):
        r, s, _ = split_key(rand_bytes(32))
        h = [random.getrandbits(26) for _ in range(5)]
        vecs.append((f"random {t}", h, r, s, block_limbs(rand_bytes(16))))

    # 長訊息中段的區塊：h 是前面區塊的真實輸出
    r, s, _ = split_key(rand_bytes(32))
    h = [0] * 5
    for t in range(n_chain):
        for _ in range(25):
            h = poly1305_block(h, r, s, block_limbs(rand_bytes(16)), HorcruxAcc())
        vecs.append((f"chain {t}", list(h), r, s, block_limbs(rand_bytes(16))))

    out = []
    for name, h, r, s, m in vecs:
        h_out = poly1305_block(h, r, s, m, HorcruxAcc(strict=True, mul="signed"))
        want = (from_limbs(h) + from_limbs(m)) * from_limbs(r) % P
        assert from_limbs(h_out) % P == want, f"{name}: mod p 錯誤"
        out.append((name, h, r, s, m, h_out))

    for n, want in enumerate(RFC_ACCS):
        assert from_limbs(out[n][5]) % P == want, f"rfc8439 block {n + 1}：和 RFC 的 Acc 不符"
    return out


# ---------------------------------------------------------------------------
# C 輸出
# ---------------------------------------------------------------------------

BANNER = """\
// 自動產生，請勿手改。重新產生：python sw/golden/gen_poly1305.py
// 規則來源：sw/golden/poly1305_model.py（區塊運算）、fe_mul_model.py（funct7）
"""


def emit_hw_header(prog):
    s_used = sorted({x["j"] for op, x in prog if op == "macc" and x["use_s"]})
    L = [BANNER,
         "#ifndef POLY1305_HW_H",
         "#define POLY1305_HW_H",
         "",
         "#include <stdint.h>",
         "",
         "// M2 ACC 指令（opcode 0x3b、funct3 0x7），funct7 必須是常數，所以用 macro",
         f'#define ACCZERO()          asm volatile(".insn r 0x3b, 0x7, {FUNCT7["acczero"]:#04x}, x0, x0, x0")',
         '#define MACC(f7, a, b)     asm volatile(".insn r 0x3b, 0x7, " #f7 ", x0, %0, %1" :: "r"(a), "r"(b))',
         f'#define ACCRD26(rd)        asm volatile(".insn r 0x3b, 0x7, {FUNCT7["accrd.26"]:#04x}, %0, x0, x0" : "=r"(rd))',
         '#define ACCWRAP(f7, rd, a) asm volatile(".insn r 0x3b, 0x7, " #f7 ", %0, %1, x0" : "=r"(rd) : "r"(a))',
         "",
         "// h = (h + m)·r mod 2^130-5，radix 2^26、5 個 limb。",
         "// product scanning：第 k 欄累加 a_i·r_j（i+j = k）與 a_i·s_j（i+j = k+5），a = h + m。",
         "// 跨過 2^130 的項用 s_j = 5·r_j（由呼叫端預先算好），所以全部是 macc.s1，不需要硬體縮放。",
         f"// s0 永遠用不到：i > k 時 j = k-i+5 只會是 {', '.join(map(str, s_used))}。",
         "// h 全部算完才寫回，所以呼叫端可以直接傳同一個 h 進來更新。",
         "static void poly1305_block_hw(uint32_t h[5], const uint32_t r[5], const uint32_t s[5],",
         "                              const uint32_t m[5]) {",
         "    // h + m：一般 RV32 add，結果最多約 27 bit",
         "    const uint32_t " + ", ".join(f"a{i} = h[{i}] + m[{i}]" for i in range(5)) + ";",
         "    const uint32_t " + ", ".join(f"r{i} = r[{i}]" for i in range(5)) + ";",
         "    const uint32_t " + ", ".join(f"s{j} = s[{j}]" for j in s_used) + ";",
         "    uint32_t " + ", ".join(f"h{i}" for i in range(5)) + ", carry;",
         "",
         "    ACCZERO();",
         ]
    f7 = FUNCT7["macc.s1"]
    for op, x in prog:
        if op == "macc":
            if x["i"] == 0:
                L += ["", f"    // 第 {x['k']} 欄 -> h{x['k']}（26 bit）"]
            i, j = x["i"], x["j"]
            if x["use_s"]:
                note = f"i={i} j={j}  a{i}·s{j}（i+j={i + j}，跨過 2^130，×5 已在 s{j} 裡）"
                L.append(f"    MACC({f7:#04x}, a{i}, s{j});   // {note}")
            else:
                L.append(f"    MACC({f7:#04x}, a{i}, r{j});   // i={i} j={j}  a{i}·r{j}")
        elif op == "accrd" and x["k"] is not None:
            L.append(f"    ACCRD26({x['dst']});")
        elif op == "accwrap":
            L += ["",
                  "    // ACC 剩下的是 >= 2^130 的部分：×5 加回 h0，進位留在 ACC",
                  f"    ACCWRAP({FUNCT7['accwrap.5']:#04x}, {x['dst']}, {x['src']});"]
        elif op == "accrd":
            L += ["    // 取出剩下的進位，用一般 add 加到 h1（h1 可能略超過 26 bit）",
                  f"    ACCRD26({x['dst']});",
                  "    h1 += carry;"]
    L += ["",
          "    " + " ".join(f"h[{i}] = h{i};" for i in range(5)),
          "}",
          "",
          "#endif  // POLY1305_HW_H",
          ""]
    return "\n".join(L)


def c_limbs(v):
    return "{" + ", ".join(f"0x{x:08x}" for x in v) + "}"


def emit_vectors(vecs, seed):
    L = [BANNER.rstrip("\n"),
         f"// 隨機向量的 seed：{seed}（--seed 可改）",
         "// 預期值 h_out 取自 golden poly1305_block（位元精確，含 h1 的進位），",
         "// 並已用大整數驗證 h_out ≡ (h + m)·r (mod p)；rfc8439 的 3 組另外和 RFC 8439 §2.5.2 的 Acc 對過。",
         "",
         "#ifndef TEST_VECTORS_H",
         "#define TEST_VECTORS_H",
         "",
         "#include <stdint.h>",
         "",
         "typedef struct {",
         "    const char *name;",
         "    uint32_t h[5];        // 輸入累加器",
         "    uint32_t r[5];        // clamp 後的 r",
         "    uint32_t s[5];        // s_j = 5·r_j",
         "    uint32_t m[5];        // 訊息區塊，含結尾的 1",
         "    uint32_t h_out[5];    // 預期輸出，和 golden poly1305_block 逐個 limb 相同",
         "    uint32_t h_canon[5];  // h_out mod p 的標準 limb（每個 26 bit、值 < p），給 limb 表示法不同的實作比對",
         "} poly1305_vector_t;",
         "",
         f"#define POLY1305_N_VECTORS {len(vecs)}",
         "",
         "static const poly1305_vector_t poly1305_vectors[POLY1305_N_VECTORS] = {"]
    for name, h, r, s, m, h_out in vecs:
        L += [f'    {{"{name}",',
              f"     {c_limbs(h)},",
              f"     {c_limbs(r)},",
              f"     {c_limbs(s)},",
              f"     {c_limbs(m)},",
              f"     {c_limbs(h_out)},",
              f"     {c_limbs(to_limbs(from_limbs(h_out) % P))}}},"]
    L += ["};", "", "#endif  // TEST_VECTORS_H", ""]
    return "\n".join(L)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--seed", type=int, default=1305)
    ap.add_argument("--out-dir", default=DEFAULT_OUT)
    args = ap.parse_args()

    prog = build_program()
    vecs = make_vectors(args.seed)
    count = check_program(prog, [(h, r, s, m) for _, h, r, s, m, _ in vecs])

    os.makedirs(args.out_dir, exist_ok=True)
    files = {"poly1305_hw.h": emit_hw_header(prog), "test_vectors.h": emit_vectors(vecs, args.seed)}
    for name, text in files.items():
        with open(os.path.join(args.out_dir, name), "w", encoding="utf-8", newline="\n") as fp:
            fp.write(text)

    print(f"指令序列與 golden poly1305_block 一致：{sum(count.values())} 條 {dict(sorted(count.items()))}")
    print(f"{len(vecs)} 組向量，全部通過 mod p 驗證；rfc8439 的 3 組和 RFC 8439 §2.5.2 相符")
    # 輸出 h1 = 26 bit + 幾十以內的進位，要剛好溢出的機率約百萬分之一，所以改由輸入覆蓋
    print(f"h1 輸入最大值 {max(v[1][1] for v in vecs):#x}（> 0x3ffffff：有向量的 h1 含上一塊的進位）")
    print(f"已寫入 {os.path.normpath(args.out_dir)}：{', '.join(files)}")


if __name__ == "__main__":
    main()
