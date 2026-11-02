# Golden model（`sw/golden/`）

x25519-ext 擴充指令的位元精確 Python 模型，以及由模型產生測試標頭檔的產生器。模型逐條模擬協處理器指令，每條 `macc` 都會檢查 A1 的運算元界限（縮放後 < 2³¹），並把結果和 Python 大整數的模運算比對。

只用到 Python 標準函式庫，不需要另外安裝套件。

## 檔案

| 檔案 | 用途 |
| --- | --- |
| [`fe_mul_model.py`](fe_mul_model.py) | X25519 `fe_mul`（mod 2²⁵⁵−19，10 個 limb，radix 2²⁵·⁵）。也定義 `HorcruxAcc`（ACC 的指令模型）、各指令的 funct7，給其他檔案共用 |
| [`x25519_model.py`](x25519_model.py) | 完整 X25519（M3）：`fe_sq`（68 條指令）、`fe_mul_a24`、`fe_add` / `fe_sub`、模反元素、Montgomery ladder、`fe_tobytes`。對 RFC 7748 §5.2 與 §6.1 的向量驗證 |
| [`poly1305_model.py`](poly1305_model.py) | Poly1305 區塊（mod 2¹³⁰−5，5 個 26-bit limb）。含 key clamp、`s_j = 5·r_j`、完整 MAC 參考實作，以及 RFC 8439 §2.5.2 的範例 |
| [`gen_fe_mul.py`](gen_fe_mul.py) | 產生 `tests/x25519-fe-mul/` 的 `fe_mul_hw.h` 和 `test_vectors.h` |
| [`gen_poly1305.py`](gen_poly1305.py) | 產生 `tests/poly1305-block/` 的 `poly1305_hw.h` 和 `test_vectors.h` |
| [`gen_x25519.py`](gen_x25519.py) | 產生 `tests/x25519-scalarmult/` 的 `fe_hw.h`（`fe_mul_hw` / `fe_sq_hw` / `fe_mul_a24_hw`）和 `test_vectors.h`（8 組 field 運算 + RFC 7748 的 7 組 X25519）。軟體部分（加減、編碼、模反元素、ladder）不產生，手寫在該測試的 `main.c` |

## 執行模型的自我測試

```sh
python sw/golden/fe_mul_model.py               # 3000 組隨機 + 1000 次連乘 + 統計（ACC 最大寬度等）
python sw/golden/fe_mul_model.py --trace       # 印出一次 fe_mul 第 0、1 欄的指令與 ACC
python sw/golden/fe_mul_model.py --lazy        # limb 多 1 bit 時 A1 出錯的次數

python sw/golden/x25519_model.py               # 各運算隨機測試 + RFC 7748 §5.2 / §6.1（約 2 秒）
python sw/golden/x25519_model.py --trace       # 印出一次 fe_sq 第 0、1 欄的指令與 ACC
python sw/golden/x25519_model.py --iter 1000   # §5.2 迭代 1000 次也用逐指令模型跑（約數分鐘）

python sw/golden/poly1305_model.py             # RFC 8439 §2.5.2 + 3000 組隨機 + 1000 個連續區塊
python sw/golden/poly1305_model.py --trace     # 印出一個區塊第 0、1 欄的指令與 ACC
```

## 重新產生測試標頭檔

```sh
python sw/golden/gen_fe_mul.py      # seed 25519，寫入 sw/applications/tests/x25519-fe-mul/
python sw/golden/gen_poly1305.py    # seed 1305，寫入 sw/applications/tests/poly1305-block/
python sw/golden/gen_x25519.py      # seed 7748，寫入 sw/applications/tests/x25519-scalarmult/
```

三個產生器都可以用 `--seed` 換亂數種子、`--out-dir` 改輸出目錄。產生的檔案開頭有「自動產生，請勿手改」，要改內容請改產生器再重新產生。

產生器寫檔之前會先做以下檢查，任何一項不過就停止，不寫檔：

- 把產生出來的指令序列逐條重放，ACC 的每一步都要和 golden model 相同
- 指令數：`fe_mul` 113 條、`fe_sq` 68 條、`fe_mul_a24` 23 條、Poly1305 區塊 33 條
- 每組向量的結果要等於 Python 大整數的模運算結果
- Poly1305：RFC 8439 §2.5.2 三個區塊的中間值要和 RFC 公布的值相同
- X25519：每組 RFC 7748 向量都要用逐指令模型重算一次，結果和 RFC 相同

重新產生後，測試的 cycle 數可能改變，要在 server 上重跑 `sh scripts/kat_regression.sh tests/<name>`，再手動更新 `scripts/kat_cycles.ref` 裡該測試的那幾行。
