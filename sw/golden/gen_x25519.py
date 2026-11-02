"""產生 x25519-scalarmult 測試用的 C 標頭檔。

輸出兩個檔案到 sw/applications/tests/x25519-scalarmult/：
  fe_hw.h          三個展開的硬體函式（共用同一組 ACC macro）：
                     fe_mul_hw()      113 條協處理器指令（和 x25519-fe-mul 的完全相同）
                     fe_sq_hw()        68 條，交叉項的 ×2 由軟體先乘在 rs1
                     fe_mul_a24_hw()   23 條，h = 121665·f
  test_vectors.h   兩組向量：
                     fe_op_vectors     各個 field 運算的位元精確預期值，ladder 出錯時用來找是哪個運算錯
                     x25519_vectors    RFC 7748 §5.2（2 組 + 迭代 1 次）與 §6.1（4 次呼叫）

規則全部從 fe_mul_model.py / x25519_model.py 匯入，不重抄。寫檔之前的檢查，任何一項失敗就不寫：
  1. fe_sq、fe_mul_a24 的指令序列在 HorcruxAcc 上重放，trace 必須和 golden 逐條相同；指令數 68、23
  2. 每組 field 運算向量都用 Python 大整數驗證 mod p
  3. 每組 X25519 向量都用逐指令模型重算，必須等於 RFC 7748 原文的值

軟體部分（fe_add / fe_sub / fe_carry、cswap、fe_invert、ladder、frombytes / tobytes）
不在這裡產生，照 x25519_model.py 的同名函式寫成 C。

執行：
  python sw/golden/gen_x25519.py
  python sw/golden/gen_x25519.py --seed 7 --out-dir <目錄>
"""

import argparse
import os
import random

from fe_mul_model import FUNCT7, P, WIDTH, HorcruxAcc, from_limbs, scale_factor, to_limbs
from gen_fe_mul import MACRO_LINES, build_program, c_limbs, check_program, emit_fe_mul_fn
from x25519_model import (A24, BASE_U, RFC_5_2, RFC_6_1, RFC_ITER, RFC_ITER_START, FastAcc,
                          fe_add, fe_invert, fe_mul_a24, fe_sq, fe_sub, fe_tobytes, max_fe,
                          rand_fe, run_x25519)

N_FE_VECTORS = 8
DEFAULT_OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                           "..", "applications", "tests", "x25519-scalarmult")


# ---------------------------------------------------------------------------
# 指令序列
# ---------------------------------------------------------------------------

def build_sq_program():
    """fe_sq 的指令序列，順序與 x25519_model.fe_sq 相同。macc 的 rs1 是 f_i 或 2·f_i。"""
    prog = [("acczero", {})]
    for k in range(10):
        for i in range(10):
            j = (k - i) % 10
            if i == j:
                prog.append(("macc", {"i": i, "j": j, "n": scale_factor(i, j), "k": k, "dbl": False}))
            elif i < j:
                prog.append(("macc", {"i": i, "j": j, "n": scale_factor(i, j), "k": k, "dbl": True}))
        prog.append(("accrd", {"w": WIDTH[k], "dst": f"h{k}", "k": k}))
    prog.append(("accwrap", {"c": 19, "dst": "h0", "src": "h0"}))
    prog.append(("accrd", {"w": 25, "dst": "carry", "k": None}))
    return prog


def build_a24_program():
    prog = [("acczero", {})]
    for k in range(10):
        prog.append(("macc", {"i": k, "n": 1, "k": k}))
        prog.append(("accrd", {"w": WIDTH[k], "dst": f"h{k}", "k": k}))
    prog.append(("accwrap", {"c": 19, "dst": "h0", "src": "h0"}))
    prog.append(("accrd", {"w": 25, "dst": "carry", "k": None}))
    return prog


def replay(prog, f, rs1_of, rs2_of):
    """在 HorcruxAcc 上執行 prog；rs1_of / rs2_of 把 macc 的參數換成運算元。"""
    hw = HorcruxAcc(strict=True, mul="signed")
    reg = {}
    for op, a in prog:
        if op == "acczero":
            hw.acczero()
        elif op == "macc":
            hw.macc(a["n"], rs1_of(f, a), rs2_of(f, a))
        elif op == "accrd":
            reg[a["dst"]] = hw.accrd(a["w"])
        elif op == "accwrap":
            reg[a["dst"]] = hw.accwrap(a["c"], reg[a["src"]])
    reg["h1"] += reg["carry"]
    return [reg[f"h{k}"] for k in range(10)], hw


SQ_RS1 = lambda f, a: 2 * f[a["i"]] if a["dbl"] else f[a["i"]]
SQ_RS2 = lambda f, a: f[a["j"]]
A24_RS1 = lambda f, a: f[a["i"]]
A24_RS2 = lambda f, a: A24


def check_unary(prog, golden_fn, rs1_of, rs2_of, inputs, expect):
    for f in inputs:
        golden = HorcruxAcc(strict=True, mul="signed")
        h_ref = golden_fn(f, golden)
        h, hw = replay(prog, f, rs1_of, rs2_of)
        assert hw.trace == golden.trace, f"指令序列和 golden {golden_fn.__name__} 不一致"
        assert h == h_ref, f"重放結果和 golden {golden_fn.__name__} 不一致"
    total = sum(hw.count.values())
    assert total == expect, f"{golden_fn.__name__}：協處理器指令數 {total}，預期 {expect}"
    return hw.count


# ---------------------------------------------------------------------------
# 測試向量
# ---------------------------------------------------------------------------

def make_fe_vectors(seed):
    """每組一對 (f, g)，預期值全部取自 golden model（位元精確）。"""
    random.seed(seed)
    vecs = [("max", max_fe(), max_fe()),
            ("one, p-1", to_limbs(1), to_limbs(P - 1)),
            ("f < g", to_limbs(5), to_limbs(P - 3))]   # fe_sub 的結果是負數，要繞回 p
    while len(vecs) < N_FE_VECTORS:
        vecs.append((f"random {len(vecs) - 3}", rand_fe(), rand_fe()))

    out = []
    for name, f, g in vecs:
        fv, gv = from_limbs(f), from_limbs(g)
        sq, a24 = fe_sq(f, FastAcc()), fe_mul_a24(f, FastAcc())
        add, sub = fe_add(f, g), fe_sub(f, g)
        inv = fe_invert(f, FastAcc())
        for what, h, v in (("sq", sq, fv * fv), ("a24", a24, A24 * fv),
                           ("add", add, fv + gv), ("sub", sub, fv - gv),
                           ("inv", inv, pow(fv, P - 2, P))):
            assert from_limbs(h) % P == v % P, f"{name}: {what} mod p 錯誤"
        out.append({"name": name, "f": f, "g": g, "sq": sq, "a24": a24, "add": add, "sub": sub,
                    "f_bytes": fe_tobytes(f), "inv_bytes": fe_tobytes(inv)})
    return out


def make_x25519_vectors():
    v = RFC_6_1
    vecs = [("RFC 7748 5.2 #1", *RFC_5_2[0]),
            ("RFC 7748 5.2 #2", *RFC_5_2[1]),
            ("RFC 7748 5.2 iter 1", RFC_ITER_START, RFC_ITER_START, RFC_ITER[1]),
            ("RFC 7748 6.1 K_A = X25519(a, 9)", v["a"], BASE_U, v["K_A"]),
            ("RFC 7748 6.1 K_B = X25519(b, 9)", v["b"], BASE_U, v["K_B"]),
            ("RFC 7748 6.1 K = X25519(a, K_B)", v["a"], v["K_B"], v["K"]),
            ("RFC 7748 6.1 K = X25519(b, K_A)", v["b"], v["K_A"], v["K"])]
    for name, k, u, out in vecs:
        assert run_x25519(k, u)[0] == out, f"{name}：逐指令模型與 RFC 不符"
    return vecs


# ---------------------------------------------------------------------------
# C 輸出
# ---------------------------------------------------------------------------

BANNER = """\
// 自動產生，請勿手改。重新產生：python sw/golden/gen_x25519.py
// 規則來源：sw/golden/fe_mul_model.py、x25519_model.py
"""


def emit_sq_fn(prog):
    L = ["// h = f^2 mod 2^255-19。和 fe_mul_hw 一樣逐欄累加，但 f_i·f_j 與 f_j·f_i 合併成一條：",
         "//   對角項 i == j：MACC(N, f_i, f_i)",
         "//   交叉項 i <  j：MACC(N, 2·f_i, f_j)，結果是 2N·f_i·f_j",
         "// 2N 可能是 4 或 76，scaler 沒有這兩個倍數，所以 ×2 由軟體先乘在 rs1（不經過 scaler，",
         "// 2·f_i 最多 27 bit < 2^31），rs2 的 N 和 fe_mul_hw 相同。共 55 條 macc，比 fe_mul 少 45 條。",
         "// h 全部算完才寫回，所以 h 可以和 f 是同一個陣列。",
         "static void fe_sq_hw(uint32_t h[10], const uint32_t f[10]) {",
         "    const uint32_t " + ", ".join(f"f{i} = f[{i}]" for i in range(10)) + ";",
         "    const uint32_t " + ", ".join(f"f{i}_2 = f{i} + f{i}" for i in range(9)) + ";",
         "    uint32_t " + ", ".join(f"h{i}" for i in range(10)) + ", carry;",
         "",
         "    ACCZERO();"]
    first = None
    for op, a in prog:
        if op == "macc":
            if a["k"] != first:
                first = a["k"]
                L += ["", f"    // 第 {a['k']} 欄 -> h{a['k']}（{WIDTH[a['k']]} bit）"]
            i, j, n = a["i"], a["j"], a["n"]
            f7 = FUNCT7[f"macc.s{n}"]
            rs1 = f"f{i}_2" if a["dbl"] else f"f{i}"
            what = f"交叉項，2N={2 * n}" if a["dbl"] else "對角項"
            L.append(f"    MACC({f7:#04x}, {rs1 + ',':<5} f{j});   // i={i} j={j}  N={n:<2}  {what}")
        elif op == "accrd" and a["k"] is not None:
            L.append(f"    ACCRD{a['w']}({a['dst']});")
        elif op == "accwrap":
            L += ["",
                  "    // 收尾和 fe_mul_hw 相同",
                  f"    ACCWRAP({FUNCT7['accwrap.19']:#04x}, {a['dst']}, {a['src']});"]
        elif op == "accrd":
            L += [f"    ACCRD{a['w']}({a['dst']});",
                  "    h1 += carry;"]
    L += ["",
          "    " + " ".join(f"h[{i}] = h{i};" for i in range(5)),
          "    " + " ".join(f"h[{i}] = h{i};" for i in range(5, 10)),
          "}"]
    return L


def emit_a24_fn(prog):
    L = [f"// h = {A24}·f mod 2^255-19（ladder 的 a24 = (486662 - 2) / 4，RFC 7748 §5）。",
         "// a24 是常數，第 k 欄只有 f_k·a24 一項，前一欄的進位已經在 ACC 裡。",
         "static void fe_mul_a24_hw(uint32_t h[10], const uint32_t f[10]) {",
         f"    const uint32_t a24 = {A24};",
         "    uint32_t " + ", ".join(f"h{i}" for i in range(10)) + ", carry;",
         "",
         "    ACCZERO();"]
    for op, a in prog:
        if op == "macc":
            L.append(f"    MACC({FUNCT7['macc.s1']:#04x}, f[{a['i']}], a24);")
        elif op == "accrd" and a["k"] is not None:
            L[-1] += f"  ACCRD{a['w']}({a['dst']});"
        elif op == "accwrap":
            L += [f"    ACCWRAP({FUNCT7['accwrap.19']:#04x}, {a['dst']}, {a['src']});"]
        elif op == "accrd":
            L += [f"    ACCRD{a['w']}({a['dst']});",
                  "    h1 += carry;"]
    L += ["",
          "    " + " ".join(f"h[{i}] = h{i};" for i in range(5)),
          "    " + " ".join(f"h[{i}] = h{i};" for i in range(5, 10)),
          "}"]
    return L


def emit_hw_header(mul_prog, sq_prog, a24_prog):
    L = [BANNER,
         "#ifndef FE_HW_H",
         "#define FE_HW_H",
         "",
         "#include <stdint.h>",
         "",
         *MACRO_LINES,
         "",
         *emit_fe_mul_fn(mul_prog),
         "",
         *emit_sq_fn(sq_prog),
         "",
         *emit_a24_fn(a24_prog),
         "",
         "#endif  // FE_HW_H",
         ""]
    return "\n".join(L)


def c_bytes(b):
    return "{" + ", ".join(f"0x{x:02x}" for x in b) + "}"


def emit_vectors(fe_vecs, x_vecs, seed):
    L = [BANNER.rstrip("\n"),
         f"// fe_op_vectors 的隨機 seed：{seed}（--seed 可改）",
         "",
         "#ifndef TEST_VECTORS_H",
         "#define TEST_VECTORS_H",
         "",
         "#include <stdint.h>",
         "",
         "// 單一 field 運算的預期值，limb 欄位和 x25519_model.py 的同名函式逐個 limb 相同。",
         "// ladder 結果錯的時候，先用這組找出是哪個運算寫錯。",
         "typedef struct {",
         "    const char *name;",
         "    uint32_t f[10];",
         "    uint32_t g[10];",
         "    uint32_t sq[10];         // fe_sq(f)",
         "    uint32_t a24[10];        // fe_mul_a24(f)",
         "    uint32_t add[10];        // fe_add(f, g)，含進位",
         "    uint32_t sub[10];        // fe_sub(f, g)，先加 2p 再減，含進位",
         "    uint8_t  f_bytes[32];    // fe_tobytes(f)：化簡成 [0, p) 後的編碼",
         "    uint8_t  inv_bytes[32];  // fe_tobytes(fe_invert(f))；limb 只比 bytes，因為加法鏈可以不同",
         "} fe_op_vector_t;",
         "",
         f"#define FE_OP_N_VECTORS {len(fe_vecs)}",
         "",
         "static const fe_op_vector_t fe_op_vectors[FE_OP_N_VECTORS] = {"]
    for v in fe_vecs:
        L += [f'    {{"{v["name"]}",']
        L += [f"     {c_limbs(v[key])}," for key in ("f", "g", "sq", "a24", "add", "sub")]
        L += [f"     {c_bytes(v['f_bytes'])},",
              f"     {c_bytes(v['inv_bytes'])}}},"]
    L += ["};",
          "",
          "// RFC 7748 的 X25519 測試向量，值從 RFC 原文逐字複製（§5.2、§6.1）。",
          "// out = X25519(k, u)，三者都是 32-byte little-endian。",
          "typedef struct {",
          "    const char *name;",
          "    uint8_t k[32];",
          "    uint8_t u[32];",
          "    uint8_t out[32];",
          "} x25519_vector_t;",
          "",
          f"#define X25519_N_VECTORS {len(x_vecs)}",
          "",
          "static const x25519_vector_t x25519_vectors[X25519_N_VECTORS] = {"]
    for name, k, u, out in x_vecs:
        L += [f'    {{"{name}",',
              f"     {c_bytes(k)},",
              f"     {c_bytes(u)},",
              f"     {c_bytes(out)}}},"]
    L += ["};", "", "#endif  // TEST_VECTORS_H", ""]
    return "\n".join(L)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--seed", type=int, default=7748)
    ap.add_argument("--out-dir", default=DEFAULT_OUT)
    args = ap.parse_args()

    fe_vecs = make_fe_vectors(args.seed)
    inputs = [v["f"] for v in fe_vecs]
    mul_prog, sq_prog, a24_prog = build_program(), build_sq_program(), build_a24_program()
    check_program(mul_prog, [(v["f"], v["g"]) for v in fe_vecs])
    sq_count = check_unary(sq_prog, fe_sq, SQ_RS1, SQ_RS2, inputs, 68)
    a24_count = check_unary(a24_prog, fe_mul_a24, A24_RS1, A24_RS2, inputs, 23)
    x_vecs = make_x25519_vectors()

    os.makedirs(args.out_dir, exist_ok=True)
    files = {"fe_hw.h": emit_hw_header(mul_prog, sq_prog, a24_prog),
             "test_vectors.h": emit_vectors(fe_vecs, x_vecs, args.seed)}
    for name, text in files.items():
        with open(os.path.join(args.out_dir, name), "w", encoding="utf-8", newline="\n") as fp:
            fp.write(text)

    print(f"fe_sq 指令序列與 golden 一致：{sum(sq_count.values())} 條 {dict(sorted(sq_count.items()))}")
    print(f"fe_mul_a24 指令序列與 golden 一致：{sum(a24_count.values())} 條")
    print(f"{len(fe_vecs)} 組 field 運算向量，全部通過 mod p 驗證")
    print(f"{len(x_vecs)} 組 X25519 向量，逐指令模型與 RFC 7748 原文相符")
    print(f"已寫入 {os.path.normpath(args.out_dir)}：{', '.join(files)}")


if __name__ == "__main__":
    main()
