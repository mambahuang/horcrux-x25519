"""產生 x25519-fe-mul 測試用的 C 標頭檔。

輸出兩個檔案到 sw/applications/tests/x25519-fe-mul/：
  fe_mul_hw.h      展開的 fe_mul_hw()：113 條協處理器指令，每條 macc 註明 i、j、N
  test_vectors.h   20 組 f、g，golden model 算出的位元精確預期 h，以及 f·g mod p 的 32-byte 編碼

規則（funct7、scale_factor、limb 寬度）全部從 fe_mul_model.py 匯入，不重抄。
寫檔之前會做兩項檢查，任何一項失敗就不寫：
  1. 要輸出的指令序列在 HorcruxAcc 上重放，trace 必須和 golden fe_mul() 逐條相同
  2. 每組向量的預期 h 都用 Python 大整數驗證 h ≡ f·g (mod p)

執行：
  python sw/golden/gen_fe_mul.py
  python sw/golden/gen_fe_mul.py --seed 7 --out-dir <目錄>
"""

import argparse
import os
import random

from fe_mul_model import (
    FUNCT7, P, WIDTH, HorcruxAcc, fe_mul, from_limbs, rand_limbs, scale_factor, to_limbs,
)

N_VECTORS = 20
DEFAULT_OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                           "..", "applications", "tests", "x25519-fe-mul")


# ---------------------------------------------------------------------------
# 指令序列：一份資料，同時拿來輸出 C 和在 golden model 上重放
# ---------------------------------------------------------------------------

def build_program():
    """回傳 fe_mul 的指令序列，每個元素是 (op, 參數 dict)。順序與 fe_mul_model.fe_mul 相同。"""
    prog = [("acczero", {})]
    for k in range(10):
        for i in range(10):
            j = (k - i) % 10
            prog.append(("macc", {"i": i, "j": j, "n": scale_factor(i, j), "k": k}))
        prog.append(("accrd", {"w": WIDTH[k], "dst": f"h{k}", "k": k}))
    prog.append(("accwrap", {"c": 19, "dst": "h0", "src": "h0"}))
    prog.append(("accrd", {"w": 25, "dst": "carry", "k": None}))
    return prog


def replay(prog, f, g):
    """在 HorcruxAcc 上執行 prog，回傳 (h, hw)。最後的 h1 += carry 是一般 RV32 add。"""
    hw = HorcruxAcc(strict=True, mul="signed")
    reg = {}
    for op, a in prog:
        if op == "acczero":
            hw.acczero()
        elif op == "macc":
            hw.macc(a["n"], f[a["i"]], g[a["j"]])
        elif op == "accrd":
            reg[a["dst"]] = hw.accrd(a["w"])
        elif op == "accwrap":
            reg[a["dst"]] = hw.accwrap(a["c"], reg[a["src"]])
    reg["h1"] += reg["carry"]
    return [reg[f"h{k}"] for k in range(10)], hw


def check_program(prog, inputs):
    """重放結果與 golden fe_mul 的 trace、輸出必須逐條相同。"""
    for f, g in inputs:
        golden = HorcruxAcc(strict=True, mul="signed")
        h_ref = fe_mul(f, g, golden)
        h, hw = replay(prog, f, g)
        assert hw.trace == golden.trace, "指令序列和 golden fe_mul 不一致"
        assert h == h_ref, "重放結果和 golden fe_mul 不一致"
    total = sum(hw.count.values())
    assert total == 113, f"協處理器指令數 {total}，預期 113"
    return hw.count


# ---------------------------------------------------------------------------
# 測試向量
# ---------------------------------------------------------------------------

def make_vectors(seed):
    """固定邊界值 + 隨機值 + 連乘輸出（h1 可能略超過 25 bit，對應 ladder 的真實輸入）。"""
    random.seed(seed)
    max_limbs = [(1 << w) - 1 for w in WIDTH]
    vecs = [
        ("zero",        [0] * 10,           rand_limbs(False)),
        ("one",         to_limbs(1),        rand_limbs(False)),
        ("max x max",   max_limbs,          max_limbs),
        ("p-1 x p-1",   to_limbs(P - 1),    to_limbs(P - 1)),
    ]
    n_chain = 4
    for t in range(N_VECTORS - len(vecs) - n_chain):
        vecs.append((f"random {t}", rand_limbs(False), rand_limbs(False)))

    # 連乘：x <- x·y、y <- y·x 交替跑一段，再把當下的 (x, y) 當作向量
    x, y = rand_limbs(False), rand_limbs(False)
    for t in range(n_chain):
        for step in range(25):
            if step % 2 == 0:
                x = fe_mul(x, y, HorcruxAcc())
            else:
                y = fe_mul(y, x, HorcruxAcc())
        vecs.append((f"chain {t}", list(x), list(y)))

    out = []
    for name, f, g in vecs:
        h = fe_mul(f, g, HorcruxAcc(strict=True, mul="signed"))
        assert from_limbs(h) % P == from_limbs(f) * from_limbs(g) % P, f"{name}: mod p 錯誤"
        out.append((name, f, g, h))
    return out


# ---------------------------------------------------------------------------
# C 輸出
# ---------------------------------------------------------------------------

BANNER = """\
// 自動產生，請勿手改。重新產生：python sw/golden/gen_fe_mul.py
// 規則來源：sw/golden/fe_mul_model.py（funct7、scale_factor、limb 寬度）
"""


def macc_comment(i, j, n):
    why = []
    if i % 2 and j % 2:
        why.append("i、j 皆奇")
    if i + j >= 10:
        why.append("i+j>=10")
    return f"i={i} j={j}  N={n}" + (f"{' ' * (4 - len(str(n)))}({'，'.join(why)})" if why else "")


def emit_hw_header(prog):
    L = [BANNER,
         "#ifndef FE_MUL_HW_H",
         "#define FE_MUL_HW_H",
         "",
         "#include <stdint.h>",
         "",
         "// M2 ACC 指令（opcode 0x3b、funct3 0x7），funct7 必須是常數，所以用 macro",
         f'#define ACCZERO()          asm volatile(".insn r 0x3b, 0x7, {FUNCT7["acczero"]:#04x}, x0, x0, x0")',
         '#define MACC(f7, a, b)     asm volatile(".insn r 0x3b, 0x7, " #f7 ", x0, %0, %1" :: "r"(a), "r"(b))',
         f'#define ACCRD26(rd)        asm volatile(".insn r 0x3b, 0x7, {FUNCT7["accrd.26"]:#04x}, %0, x0, x0" : "=r"(rd))',
         f'#define ACCRD25(rd)        asm volatile(".insn r 0x3b, 0x7, {FUNCT7["accrd.25"]:#04x}, %0, x0, x0" : "=r"(rd))',
         '#define ACCWRAP(f7, rd, a) asm volatile(".insn r 0x3b, 0x7, " #f7 ", %0, %1, x0" : "=r"(rd) : "r"(a))',
         "",
         "// h = f·g mod 2^255-19，radix 2^25.5（偶數 limb 26 bit、奇數 limb 25 bit）。",
         "// product scanning：第 k 欄累加所有 i+j ≡ k (mod 10) 的 f_i·g_j，縮放 N 一律放在 g 這側：",
         "//   i、j 皆奇 ×2；i+j>=10 ×19；兩者皆是 ×38。",
         "// h 全部算完才寫回，所以 h 可以和 f 或 g 是同一個陣列。",
         "static void fe_mul_hw(uint32_t h[10], const uint32_t f[10], const uint32_t g[10]) {",
         "    const uint32_t " + ", ".join(f"f{i} = f[{i}]" for i in range(10)) + ";",
         "    const uint32_t " + ", ".join(f"g{i} = g[{i}]" for i in range(10)) + ";",
         "    uint32_t " + ", ".join(f"h{i}" for i in range(10)) + ", carry;",
         "",
         "    ACCZERO();",
         ]
    for op, a in prog:
        if op == "macc":
            if a["i"] == 0:
                k = a["k"]
                L += ["", f"    // 第 {k} 欄 -> h{k}（{WIDTH[k]} bit）"]
            f7 = FUNCT7[f"macc.s{a['n']}"]
            L.append(f"    MACC({f7:#04x}, f{a['i']}, g{a['j']});   // {macc_comment(a['i'], a['j'], a['n'])}")
        elif op == "accrd" and a["k"] is not None:
            L.append(f"    ACCRD{a['w']}({a['dst']});")
        elif op == "accwrap":
            L += ["",
                  "    // ACC 剩下的是 >= 2^255 的部分：×19 加回 h0，進位留在 ACC",
                  f"    ACCWRAP({FUNCT7['accwrap.19']:#04x}, {a['dst']}, {a['src']});"]
        elif op == "accrd":
            L += ["    // 取出剩下的進位，用一般 add 加到 h1（h1 可能略超過 25 bit，見 fe_mul_model.py）",
                  f"    ACCRD{a['w']}({a['dst']});",
                  "    h1 += carry;"]
    L += ["",
          "    " + " ".join(f"h[{i}] = h{i};" for i in range(5)),
          "    " + " ".join(f"h[{i}] = h{i};" for i in range(5, 10)),
          "}",
          "",
          "#endif  // FE_MUL_HW_H",
          ""]
    return "\n".join(L)


def c_limbs(v):
    return "{" + ", ".join(f"0x{x:07x}" for x in v) + "}"


def emit_vectors(vecs, seed):
    L = [BANNER.rstrip("\n"),
         f"// 隨機向量的 seed：{seed}（--seed 可改）",
         "// 預期值 h 取自 golden fe_mul（位元精確，含 h1 的進位），並已用大整數驗證 h ≡ f·g (mod p)。",
         "",
         "#ifndef TEST_VECTORS_H",
         "#define TEST_VECTORS_H",
         "",
         "#include <stdint.h>",
         "",
         "typedef struct {",
         "    const char *name;",
         "    uint32_t f[10];",
         "    uint32_t g[10];",
         "    uint32_t h[10];         // 預期輸出，和 golden fe_mul 逐個 limb 相同",
         "    uint8_t  h_bytes[32];   // f·g mod p 的標準編碼（little-endian），給 limb 表示法不同的實作比對",
         "} fe_mul_vector_t;",
         "",
         f"#define FE_MUL_N_VECTORS {len(vecs)}",
         "",
         "static const fe_mul_vector_t fe_mul_vectors[FE_MUL_N_VECTORS] = {"]
    for name, f, g, h in vecs:
        b = (from_limbs(f) * from_limbs(g) % P).to_bytes(32, "little")
        L += [f'    {{"{name}",',
              f"     {c_limbs(f)},",
              f"     {c_limbs(g)},",
              f"     {c_limbs(h)},",
              "     {" + ", ".join(f"0x{x:02x}" for x in b) + "}},"]
    L += ["};", "", "#endif  // TEST_VECTORS_H", ""]
    return "\n".join(L)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--seed", type=int, default=25519)
    ap.add_argument("--out-dir", default=DEFAULT_OUT)
    args = ap.parse_args()

    prog = build_program()
    vecs = make_vectors(args.seed)
    count = check_program(prog, [(f, g) for _, f, g, _ in vecs])

    os.makedirs(args.out_dir, exist_ok=True)
    files = {"fe_mul_hw.h": emit_hw_header(prog), "test_vectors.h": emit_vectors(vecs, args.seed)}
    for name, text in files.items():
        with open(os.path.join(args.out_dir, name), "w", encoding="utf-8", newline="\n") as fp:
            fp.write(text)

    print(f"指令序列與 golden fe_mul 一致：{sum(count.values())} 條 {dict(sorted(count.items()))}")
    print(f"{len(vecs)} 組向量，全部通過 mod p 驗證")
    print(f"h1 最大值 {max(h[1] for *_, h in vecs):#x}（> 0x1ffffff 表示有向量覆蓋到 h1 超過 25 bit）")
    print(f"已寫入 {os.path.normpath(args.out_dir)}：{', '.join(files)}")


if __name__ == "__main__":
    main()
