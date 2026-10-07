# HORCRUX 共用乘法器擴充計畫書（Hybrid TLS 1.3）

Oct 7, 2026 · @Charmander3011

## 1. 題目與定位

本論文在 HORCRUX 的 32-bit RISC-V ISE 上，設計一個共用乘法 datapath，同時服務 hybrid TLS 1.3 的握手（ML-KEM、ML-DSA、X25519）與資料層（Poly1305），並量化這個設計點的面積、延遲與功耗取捨。

暫定題名：面向混合式 TLS 1.3 的 RISC-V 共用乘法器設計：格密碼與偽梅森質數域運算之整合（A Shared Multiplier Datapath for Hybrid TLS 1.3 on RISC-V: Unifying Lattice and Pseudo-Mersenne Arithmetic）。

**定位：兩條路線往同一點收斂。** OTBN 從大數協處理器出發再加入 PQC，本論文從 PQC ISE 出發再加入多字整數運算，量化在 MCU 等級、32-bit 緊耦合規模下「PQC 優先」路線的成本。

| 設計 | 出發點 | 規模 / 耦合 | 單字模乘 | GF(2) | 多字質數域 |
| --- | --- | --- | --- | --- | --- |
| HORCRUX（Dolmeta et al., 2026） | PQC 優先 | 32×32，緊耦合 ISE | ✓ | ✓ | ✗ |
| OTBN + PQC 擴充（Abdulrahman et al.; Niederhagen & Pham） | 大數優先 | 64×64 / 256-bit WDR，獨立協處理器 | ✓ | ✗ | ✓（含 RSA） |
| Ahmad et al.（CiC 2026） | 通用多精度 ISE | 核心內乘法單元 | ✗ | ✗ | ✓ |
| **本設計** | PQC 優先 + 偽梅森多字 | 32×32，緊耦合 ISE | ✓ | 待定（GHASH） | ✓（2²⁵⁵−19、2¹³⁰−5） |

**涵蓋範圍**

| TLS 階段 | 原語 | 運算類別 | 路徑 |
| --- | --- | --- | --- |
| 握手 | ML-KEM | 單字模乘，q = 3329 | Montgomery（沿用 HORCRUX） |
| 握手 | ML-DSA（驗章） | 單字模乘，q = 8380417 | Montgomery（沿用 HORCRUX） |
| 握手 | X25519 | 多字整數，2²⁵⁵ − 19 | raw mul + MACC + fold |
| 資料層（每 16 bytes） | Poly1305 | 多字整數，2¹³⁰ − 5 | raw mul + MACC + fold |
| 資料層（可選） | GHASH | 多字 GF(2¹²⁸) | carry-less + Karatsuba |

**裁剪的理由。** TLS 的 X25519MLKEM768（RFC 10024）與 CNSA 2.0 都不需要 HQC 或 Falcon；在 hybrid 情境下，X25519 本身就是 lattice 出現古典攻擊時的備援。裁剪帶來的增益會用等功能的設計點單獨量測（第 6 節）。

**不做的事**

- 點運算以上的協定層（Montgomery ladder 由軟體實作，硬體只到 `fe_mul` / Poly1305 區塊）
- Ed25519 的群階取模與 SHA-512、P-256（Solinas 約簡和 2ᵏ−c 不同類）
- key isolation / on-chip combiner（已放棄）
- ChaCha20 本身（加法、旋轉、XOR，不經乘法器）

## 2. 指令分析：選方案 A（前置縮放）

方案 A 的 X25519 `fe_mul` 約 145 條指令、不需額外狀態；方案 B 不加硬體時約 205 條。兩者都已用 Python 位元精確模型驗證：3000 組隨機輸入（limb 刻意放寬 1 bit 模擬 lazy addition）結果與 2²⁵⁵−19、2¹³⁰−5 的參考值一致。

### 2.1 新增指令

共用一個 64-bit 內部累加器 ACC，採 product scanning（逐欄累加，進位自然留在 ACC）。

| 指令 | 動作 | 備註 |
| --- | --- | --- |
| `acczero` | ACC ← 0 |  |
| `macc.sN rs1, rs2` | ACC ← ACC + rs1 × (N·rs2)，N ∈ {1, 2, 19, 38} | N 由軟體逐條選定 |
| `accrd.W rd` | rd ← ACC\[W−1:0\]；ACC ← ACC >> W，W ∈ {25, 26} | 自動帶進位 |
| `accwrap.C rd, rs1` | rd ← rs1 + C·ACC 的低位，C ∈ {19, 5}；ACC ← 進位 | 收尾用，可先用軟體代替 |

N = 2 來自 radix 2²⁵·⁵：兩個奇數索引的 25-bit limb 相乘差半個 bit。規則：i + j ≥ 10 → ×19，i、j 皆奇 → ×2。

### 2.2 X25519 `fe_mul` 指令序列（方案 A）

```
# 第 0 欄：h0 = f0g0 + 38f1g9 + 19f2g8 + 38f3g7 + ... + 38f9g1
acczero
macc.s1  f0, g0
macc.s38 f1, g9      # 奇×奇 ×2，繞回 ×19
macc.s19 f2, g8
...                  # 每欄 10 條
accrd.26 h0
# 第 1 欄
macc.s1  f0, g1
macc.s1  f1, g0
macc.s19 f2, g9
...
accrd.25 h1
...                  # 第 2~9 欄同理
accwrap.19 h0, h0    # ≥ 2^255 的部分 ×19 加回 h0，再進位到 h1
```

方案 B（後置折疊）先算完整 10×10 乘積得到 t0..t19，再做 h\_k = t\_k + 19·t\_{k+10}。20 個中間值加上 f、g 的 20 個暫存器超出 RV32 GPR，必須 spill 或在協處理器內放約 260-bit 緩衝。

### 2.3 指令數比較

| 項目 | A | B（軟體 spill） | B（硬體緩衝） |
| --- | --- | --- | --- |
| 載入 f, g | 20 | 20 | 20 |
| `macc` | 100 | 110 | 100 |
| `accrd` | 10 | 30 | 10 |
| spill / reload | 0 | 約 20 | 0 |
| 折疊與收尾 | 約 5 | 約 15 | 約 5 |
| 存回 h | 10 | 10 | 10 |
| **合計** | **約 145** | **約 205** | **約 145** |
| ACC 最大寬度（模型實測） | 61 bit | 57 bit | 57 bit |
| 額外硬體 | 運算元 ×{2,19,38} 單元 | 無 | 260-bit 緩衝 + ×19 |

`fe_sq` 可利用對稱性把 100 條 `macc` 降到約 55 條，屬純軟體優化。

### 2.4 Poly1305（每 16-byte 區塊）

r 在整個訊息固定，s\_j = 5·r\_j 由軟體預先算好；h、r、s 共 14 個暫存器放得下。所以 **Poly1305 不需要硬體縮放**，c = 5 只出現在收尾。

```
# h += m：切 16 bytes 成 5 個 26-bit limb、加 2^128 padding，約 20 條 RV32 指令
acczero
macc.s1 h0, r0
macc.s1 h1, s4
macc.s1 h2, s3
macc.s1 h3, s2
macc.s1 h4, s1
accrd.26 h0
...                  # 共 25 條 macc、5 條 accrd
accwrap.5 h0, h0
```

每區塊約 53 條指令（約 3.3 條/byte），ACC 最大 58 bit。

### 2.5 寬度陷阱：縮放放在哪一端

- ×38 只會乘在奇數索引的 25-bit limb 上，×19 乘在 26-bit limb 上。limb 嚴格正規化時，縮放後的運算元最大 19 × 2²⁶ ≈ 2³⁰·²⁵，模型實測 31 bit。
- 允許 lazy addition（limb 多 1 bit）時，縮放後達 32 bit。
- 關鍵限制來自 repo：`unified_mul_32x32` 是**有號**乘法器（b 做 sign extension，a 的 MSB 用減法），所以運算元必須 < 2³¹ 才會和無號乘法同值。

| 選項 | 乘法器陣列 | 代價 |
| --- | --- | --- |
| A1：運算元端縮放 + 送入前正規化 | 完全不用改 `unified_mul_32x32` | ladder 每次加減後多一次進位 |
| A1′：運算元端縮放 + lazy limb | 要加無號模式，動到 M0 那條 66 ns 的累加鏈 | 乘法器陣列本身變複雜 |
| A2：乘積端縮放（64-bit shift-add） | 不動陣列，容許 lazy | shift-add 落在乘法器 → ACC 路徑上 |

先以 A1 實作：它讓 HORCRUX 的乘法器陣列一個 bit 都不用改，所有修改都在陣列外圍，面積增量最好歸因。等 DC baseline 確認關鍵路徑後，再評估 A2 能省下多少進位指令。（先前口頭討論說「38 × 2²⁷ 會超過 32 bit」高估了，以本節為準。）

以上都是指令數，不是 cycle 數；實際 cycle 取決於 CV-X-IF issue 延遲與 `macc` 能否每 cycle 發一條。

## 3. 架構

所有修改都在 `unified_mul_32x32` 外圍：前端多一個 scaler，後端多一條 64-bit 原始乘積路徑接 ACC。既有的 Montgomery 與 carry-less 路徑不變。

&#91;embedded content: shared\_multiplication\_logic 擴充後的資料路徑\]

一條 `macc` 走 scaler → 乘法器 → `MODE_INT_RAW` → ACC；`accrd` / `accwrap` 從 ACC 經結果 mux 回寫 GPR。H\_sub 設計點會再拿掉 Montgomery 的 mode 2·6 與 HQC raw 路徑（若不保留 GHASH）。

## 4. 訊號 spec

新增 9 條 R-type 指令、1 個乘法模式、1 個 64-bit ACC，全部落在 `multiplier_tree.sv` 與 `horcrux_pkg.sv`，乘法器陣列不變。以下依 `locket` 分支（2026-10-07 clone）的實際程式碼訂定。

### 4.1 指令編碼

沿用 HORCRUX 的 R-type 格式：opcode = 0x3B、funct3 = 111，以 funct7 區分。0x60–0x68 在現有 `CoproInstr` 表中未被使用。

| 指令 | funct7 | `horcrux_insn` | writeback | 讀 rs1 / rs2 | 動作 |
| --- | --- | --- | --- | --- | --- |
| `acczero` | 0x60 | `OP_ACCZERO` | 0 | – / – | ACC ← 0 |
| `macc.s1 rs1, rs2` | 0x61 | `OP_MACC_S1` | 0 | ✓ / ✓ | ACC ← ACC + rs1 × rs2 |
| `macc.s2 rs1, rs2` | 0x62 | `OP_MACC_S2` | 0 | ✓ / ✓ | ACC ← ACC + rs1 × 2·rs2 |
| `macc.s19 rs1, rs2` | 0x63 | `OP_MACC_S19` | 0 | ✓ / ✓ | ACC ← ACC + rs1 × 19·rs2 |
| `macc.s38 rs1, rs2` | 0x64 | `OP_MACC_S38` | 0 | ✓ / ✓ | ACC ← ACC + rs1 × 38·rs2 |
| `accrd.26 rd` | 0x65 | `OP_ACCRD26` | 1 | – / – | rd ← ACC\[25:0\]；ACC ← ACC >> 26 |
| `accrd.25 rd` | 0x66 | `OP_ACCRD25` | 1 | – / – | rd ← ACC\[24:0\]；ACC ← ACC >> 25 |
| `accwrap.19 rd, rs1` | 0x67 | `OP_ACCWRAP19` | 1 | ✓ / – | v = rs1 + 19·ACC；rd ← v\[25:0\]；ACC ← v >> 26 |
| `accwrap.5 rd, rs1` | 0x68 | `OP_ACCWRAP5` | 1 | ✓ / – | v = rs1 + 5·ACC；rd ← v\[25:0\]；ACC ← v >> 26 |

`NbInstr` 由 57 改為 66。`horcrux_insn` 的內部 enum 值另取 0x50–0x58（與 funct7 無關，現有表也是兩套編號）。軟體端與現有測試相同，用 `.insn r 0x3b, 0x7, 0x61, x0, a0, a1` 呼叫。

### 4.2 `shared_multiplication_logic` 模式

| `mode_i` | 名稱 | 狀態 | `unified_mul_32x32` | 輸出 |
| --- | --- | --- | --- | --- |
| 0 | `MODE_DSA_MONT` | 既有 | 整數 | Montgomery |
| 1 | `MODE_KEM_MONT` | 既有 | 整數 | Montgomery |
| 2 | `MODE_FAL_MONT` | 既有（H\_sub 移除） | 整數 | Montgomery |
| **3** | **`MODE_INT_RAW`** | **新增** | 整數 | `res_hi_o:res_lo_o` = 64-bit 原始乘積 |
| 4 | `MODE_HQC_RAW` | 既有 | carry-less | 原始乘積 |
| 5 | `MODE_DSA_RED32` | 既有 | – | reduce32 |
| 6 | `MODE_MODP_MONT` | 既有（H\_sub 移除） | 整數 | Montgomery |

mode 3 原本落在 `default`，輸出只有 `full_prod[31:0]`；新增後兩個 32-bit 輸出都接原始乘積，不經 stage A/B 乘法器。這就是先前規劃的 `MODE_RAW_MUL`，改名以和 carry-less 的 RAW 區分。

### 4.3 `multiplier_tree` 內部新增訊號

| 訊號 | 寬度 | 類型 | 說明 |
| --- | --- | --- | --- |
| `acc_q` | 64 | reg | 累加器，與現有 `reg_A`/`reg_B` 同一個 `always_ff`、同一組 reset |
| `acc_en` | 1 | comb | `insn_i` 屬於 9 條新指令之一；作為 `acc_q` 的 enable，也是 clock gating 的條件 |
| `scale_sel` | 2 | comb | 00=×1、01=×2、10=×19、11=×38，由 `insn_i` 解碼 |
| `op_b_scaled` | 32 | comb | ×2 = `b<<1`；×19 = `(b<<4)+(b<<1)+b`；×38 = ×19 再 `<<1` |
| `raw_prod` | 64 | comb | `{mul_res_hi, mul_res_lo}`，mode 3 時有效 |
| `acc_sum` | 64 | comb | `acc_q + raw_prod` |
| `wrap_v` | 64 | comb | `rs1 + C·acc_q`，C ∈ {19, 5}，同樣用 shift-add |

運算元選擇：`OP_MACC_*` 時 `mul_op_a = multiplier_tree1_i`、`mul_op_b = op_b_scaled`、`mul_mode = 3'd3`。為了不讓 scaler 的加法器加長既有模式的路徑，`op_b_scaled` 只在 MACC 指令時被選入 `mul_op_b` 的 mux。

輸出：`accrd.*` 與 `accwrap.*` 經由 `result_o` 回寫，沿用 `horcrux.sv` 中 `out.rd1 = multiplier_tree_result` 的路徑，不需動 commit stage。

### 4.4 時序與正確性前提

- **每條指令只累加一次。** `id_stage` 把 `select_insn` 註冊一個 cycle 後送出，非 issue 時為 `none`，所以 `acc_en` 是單 cycle 脈衝。M1 的 testbench 要明確檢查 issue 被 stall 時不會重複累加。
- **運算元界限（A1）。** 送進 `macc` 的 rs1 ≤ 2²⁶、rs2 為正規化 limb，縮放後 < 2³¹，有號乘法器的結果與無號相同。golden model 對每條 `macc` 斷言此界限。
- **新路徑：** 乘法器 → 64-bit 加法器 → `acc_q`。它比既有 Montgomery 路徑（乘法器 → stage A 乘法 → stage B 乘法 → 減法）短，預期不會成為新的關鍵路徑，DC 結果出來後驗證。
- **ACC 是架構狀態。** 和現有 `reg_A`（BFNTTDH 依賴它）一樣，假設中斷服務程式不會在 `fe_mul` 中途使用這組指令；論文中明列此假設。

## 5. HORCRUX repo 修改步驟

修改集中在 5 個檔案，順序是「先量 baseline、再改 RTL、最後裁剪」，每一步都有可驗收的產出。

### 5.1 會動到的檔案（`hw/ip/coprocessors/`）

| 檔案 | 行數 | 修改內容 |
| --- | --- | --- |
| `include/horcrux_pkg.sv` | 1069 | `horcrux_insn` 新增 9 個 enum；`CoproInstr` 新增 9 筆（funct7 0x60–0x68）；`NbInstr` 57 → 66；`opcode_t` 沿用 `MULTIPLIER_TREE` |
| `shared_multiplication_logic.sv` | 237 | 新增 `MODE_INT_RAW = 3'd3`，輸出 mux 加一個 case |
| `multiplier_tree.sv` | 444 | 運算元 mux 加 MACC 分支、scaler、`acc_q` 及其更新邏輯、`result_o` 的 accrd/accwrap 分支 |
| `horcrux.sv` | 307 | `case (insn_i)` 的回寫表加入 accrd/accwrap，讓 `out.rd1` 取 `multiplier_tree_result` |
| `unified_mul_32x32.sv` | 47 | **A1 不改**；只有走 A1′ 才加無號模式 |

軟體與測試：`sw/applications/tests/` 下每個測試是一個目錄加 `main.c`，以 `.insn r 0x3b, 0x7, <funct7>, ...` 內嵌組語呼叫（見 `dilithium-montg/main.c`）。新測試照同樣格式放在 `tests/x25519-fe-mul/`、`tests/poly1305-block/`；功耗測試放在 `tests-power/`，沿用 `scripts/get_power_res_postsynth.sh`。

### 5.2 分支

- `origin` = `mambahuang/HORCRUX_test`，`upstream` = `vlsi-lab/HORCRUX` 的 `locket`
- `baseline`：不改 RTL，只加 DC 設定與報告，打 tag `m0-dc-baseline`
- `x25519-ext`：主線修改（H\_full + 偽梅森路徑）
- `hybrid-sub`：從 `x25519-ext` 分出，移除 Falcon / HQC 路徑，做 Pareto 設計點

### 5.3 里程碑

1. **M0′ — DC baseline。** 用 repo 內建的 `make synthesis`（fusesoc `asic_synthesis` target，Design Compiler）在 90nm 合成未修改的 `locket`，換算 GE，找出 ASIC 上的關鍵路徑。驗收：`reports/baseline/` 有 area、timing、QoR 報告；確認 66 ns 累加鏈在 ASIC 上是否仍是瓶頸。
2. **M1 — `MODE_INT_RAW`。** 只改 `shared_multiplication_logic.sv`，先用一條暫時的測試指令讀出原始乘積。驗收：既有 KAT 全過，新模式結果與 golden model 一致，面積差可量。
3. **M2 — ACC 指令組。** 加入 9 條指令與 `acc_q`。驗收：`fe_mul` 與 Poly1305 區塊通過 RFC 7748 / RFC 8439 測試向量與 Python golden model；stall 時不重複累加。
4. **M3 — 完整軟體。** X25519 scalar mult（Montgomery ladder，含 `fe_sq` 對稱優化）與 Poly1305 MAC。驗收：完整測試向量通過，記錄 cycle 數。
5. **M4 — 評估。** 合成 H\_full、H\_sub、本設計（含 / 不含 carry-less）四個設計點，PTPX 功耗三組對照（第 6 節）。
6. **M5 — 撰寫。**

### 5.4 驗證資產

- Python golden model：本計畫書第 2 節的位元精確模型，擴充成逐指令輸出 ACC 狀態，供 testbench 比對
- 測試向量：RFC 7748（X25519）、RFC 8439（Poly1305）
- 回歸：每次 RTL 修改都重跑 repo 既有的 ML-KEM / ML-DSA KAT，確保 PQC 功能不退步

## 6. 評估方法

主指標是相對「HORCRUX + 獨立 X25519 IP」的面積增量；裁剪帶來的增益和設計本身的增益用等功能設計點分開量。

### 6.1 設計點

| 設計點 | 分支 | 量到的是什麼 |
| --- | --- | --- |
| H\_full：HORCRUX `locket` 原版 | `baseline` | 參考基準 |
| H\_full + 偽梅森路徑 | `x25519-ext` | 加入多字整數運算的面積增量（主結果） |
| H\_sub：裁到 ML-KEM + ML-DSA | `hybrid-sub`（不含新指令） | 裁剪本身的增益 |
| 本設計，不含 carry-less | `hybrid-sub` | hybrid suite 設計點 |
| 本設計，含 carry-less | `hybrid-sub` | 保留 GHASH 的額外成本 |

### 6.2 指標

- 面積：GE（除以該製程 NAND2 面積），與 HORCRUX 論文的 65nm 約 116 kGE 比較；製程差異在論文中明列
- Fmax 與延遲（cycle × 週期）；ATP 同時報「各自最高頻率」與「相同頻率」兩種
- amortized ATP：修正 Complete paper Table VIII 重複計算共用面積的問題
- 握手：X25519 scalar mult、ML-KEM / ML-DSA 的 cycle 數
- 資料層：Poly1305 cycles/byte；整個 ChaCha20-Poly1305 的加速另列，ChaCha20 不受益
- 部分積利用率：沿用 Niederhagen & Pham 的分析方式

### 6.3 功耗流程（PrimeTime PX）

1. 兩個版本用相同 DC 設定、製程與時脈限制合成
2. 每個 PQC 演算法用同一組測試程式跑 gate-level 模擬，輸出 VCD（RTL SAIF 抓不到乘法樹的 glitch）
3. PTPX time-based 模式分析總功耗與 `shared_multiplication_logic` 層級功耗
4. 三組對照：baseline、擴充版不加 gating、擴充版以 `acc_en` 做 clock gating 並在 scaler 輸入做 operand isolation
5. 漏電功耗分開報告，90nm 與 40nm 各一份

測試程式優先沿用 repo 的 `sw/applications/tests-power/`，baseline 數字可與論文 Table VII 交叉驗證。

## 7. 風險與待決事項

最大的不確定性是 ASIC 上的關鍵路徑位置，它決定 A1 / A2 的選擇與 M1 的時序關卡，所以 M0′ 排在第一。

### 7.1 風險

| 風險 | 影響 | 對策 |
| --- | --- | --- |
| ASIC 關鍵路徑與 FPGA 不同 | M0 的 66 ns 分析失效 | M0′ 先在 DC 重做 baseline 再動 RTL |
| scaler 加長 MACC 路徑 | Fmax 下降 | 只在 MACC 時選入 mux；必要時改 A2 或把 scaler 移到前一級 |
| ACC 在 stall 時重複累加 | 結果錯誤 | M2 testbench 專門測 stall |
| 實驗室無 65nm | 無法直接比面積 | 一律以 GE 比較，製程差異明列 |
| 裁剪的增益被誤歸因 | 口試被質疑 | H\_sub 設計點單獨量 |
| 工作量 | 時程 | Ed25519、P-256、ChaCha20、key isolation 已排除 |

### 7.2 待決事項

- [ ] 是否保留 carry-less（GHASH）：以 M4 兩個設計點的面積差決定
- [ ] A1 或 A2：M0′ 之後決定
- [ ] `accwrap` 做成硬體或軟體：M2 時比較指令數
- [ ] 核對 HORCRUX 論文 Table VI 的 42 / 125 MHz，並釐清與 M0 量到約 97 ns 的差距
- [ ] 嘗試在 Vivado 補裝 XCZU7EV 元件檔，做與原論文同家族的 OOC 對照
- [ ] 與指導教授確認本計畫書範圍
