# M0 摘要

`x25519-ext` 分支。完整證據與方法在 `M0_FINDINGS.md`，環境設定在 `SETUP_NOTES.md`，
合成報告與腳本在 `reports/m0_followup/`。

---

## 一、M0 的目標

兩層：

1. **Gate** —— 這個 repo 跑不跑得動（模擬、工具鏈、波形）
2. **Baseline characterization** —— 在動手加 X25519 指令（M1）之前，先確認現有設計的
   瓶頸在哪、新指令會不會撞上它

第二層決定 M1 的風險輪廓：新路徑若繞開瓶頸則風險低；若共用則 gate 要嚴、且須先做
結構改善。

---

## 二、Bring-up gate：全部通過

| 項目 | 結果 |
|---|---|
| RTL 模擬 | ✅ QuestaSim，`polito:vlsi:crheepto` sim target |
| 自訂 ISA 工具鏈 | ✅ CORE-V GCC，`rv32imfdc_zicsr_xcvbitmanip` |
| 波形 dump | ✅ 但**必須加 `--max_cycles`** |
| 功能正確性 | ✅ KAT cycle 數與論文對照 |

**波形的坑**：全 SoC 階層無上限 dump 約 **0.7 MB/cycle**，一次沒設限的執行**塞爆了
1.2 TB 的共用檔案系統**。`questasim-run` 不會自動轉發 `MAX_CYCLES`，要用
`FUSESOC_ARGS="--max_cycles=N"`。

**KAT 對照**：ML-KEM-768 與論文差 0.1–0.2%（實質相同）；HQC-1 三個階段一致高 4%
——方向與幅度一致、非雜訊，推測是本 repo 用單一固定 KAT 向量，而論文取多向量平均
（HQC 的 Reed-Solomon/Reed-Muller 解碼非等時）。**兩者的 `memcmp` 檢查都通過，正確性
本身沒有疑慮。**

---

## 三、Baseline：瓶頸在 `multiplier_tree`

因當時 Vivado 未安裝 UltraScale+ device files，改用 repo 另一個既有 target
**Pynq-Z2**（`xc7z020clg400-1`）。

- Critical path **97.231 ns**，WNS **−30.825 ns**，2,658 個 failing endpoints
- 路徑起於協處理器 decode，穿過 `multiplier_tree`，終於 CPU 的 ALU operand 暫存器

**分段拆解**（本次工作的核心量測）：

| 段落 | 延遲 | 佔比 |
|---|---|---|
| decode / operand mux | 5.679 ns | 5.8% |
| **raw `a×b`（`unified_mul_32x32`）** | **59.504 ns** | **61.2%** |
| Montgomery reduction | 23.528 ns | 24.2% |
| cv32e40px 尾段 | 8.521 ns | 8.8% |

---

## 四、關鍵發現

### 瓶頸的成因不是架構，是一行 RTL 寫法

`unified_mul_32x32` 把模式選擇 `carryless_mode_i` 寫在**累加迴圈內部**，使 32 級中
每一級都成為「XOR 結果 vs ADD 結果」的 mux。Vivado 無法將其辨識為乘法，只能用
LUT+CARRY4 搭出 29 級漣波鏈。

結果：**raw `a×b` 佔 critical path 的 61%、乘法器樹面積的 94%，而設計中推論出的
11 顆 DSP 沒有一顆用在它身上**——全在 Montgomery 段。

對照組就在同一個檔案裡：`stage_a_result` 寫成單純的 `assign x = a * b`，同樣是
32×32，用一顆 DSP **只要 3.841 ns**。手寫陣列要 **59.504 ns**——**差 15.5 倍**。

### 介入：把兩個模式拆成獨立運算式

```systemverilog
assign int_prod = $signed(a_i) * $signed(b_i);   // 可推論成 DSP
// carry-less XOR 陣列維持不變
assign prod_o = carryless_mode_i ? cl_prod : int_prod;
```

11 行新增、19 行刪除。**架構性質完全保留**：資料路徑仍共享、仍單週期、仍同時支援
整數與 GF(2)。

### 結果

**Post-route**（`xcau25p-2`，16nm / −2 / DSP48E2 / CARRY8 —— 與論文平台同世代）：

| | Before | After |
|---|---|---|
| **可達 fmax** | **≈ 39.5 MHz** | **≈ 69.1 MHz** |
| Data path delay | 25.458 ns | 14.464 ns |
| LUT | 6,031 | **3,731** |
| DSP48E2 | 11 | 15 |

**−42.9% 延遲、+74.9% fmax、−38.1% 面積**，且為真實 placed & routed 結果
（650 個 site location、零 `unplaced`）。

**全 SoC 合成**（Pynq-Z2）：critical path 97.231 → **47.905 ns**，
WNS −30.825 → **+15.696 ns**，failing endpoints 2,658 → **0**。

分段對照顯示 **Montgomery 段前後完全相同（23.528 ns，小數點後三位一致）**——因為
那部分 RTL 沒動。全部改善都來自 raw multiply。

---

## 五、驗證

| 層級 | 內容 | 結果 |
|---|---|---|
| 模組等價 | 152,816 向量（corner case 全交叉、逐 rank 單 bit、50k 隨機、獨立 golden model） | 0 不符 |
| SoC 模擬 | 12 個 directed/NTT 測試，皆有軟硬體交叉比對 | 全部 PASS |
| KAT | ML-KEM-768、HQC-1 各三階段 cycle 數 | **與基線逐 cycle 完全相同** |

最後一項最關鍵：純組合改動不應影響延遲週期，而在 1,530 萬 cycle 的 KAT 上確實
一個都沒差。

---

## 六、對論文論點的意義

論文（Section IV-D）將完整版 42 MHz vs 無乘法器樹 125 MHz 的 3 倍落差，歸因於
「單週期 butterfly 整合 pre-processing、modular reduction、post-processing」的
**刻意架構取捨**。

量測顯示這個歸因**只對了一部分**：

| | 延遲 | 本次改動移除？ |
|---|---|---|
| Modular reduction（論文所述的整合） | 23.528 ns | **否**，完全不變 |
| Raw `a×b` | 59.504 ns | **是**，降至約 16 ns |

**架構整合的成本確如論文所述；但 raw multiply 的 59.5 ns 是另一回事，移除它不需
放棄該取捨想換取的任何性質，面積反而下降。** 論文自己的 ASIC 數據（65nm、160 MHz）
與此一致——ASIC 綜合器沒有 DSP 硬塊可以錯過。

**佐證**：未修改的乘法器樹在 16nm/−2 上單獨 route 得到 **≈39.5 MHz**，與論文
完整設計的 **42 MHz** 相差約 6%。兩個獨立來源在相近矽製程上吻合，是首次有
post-route 證據支持「此模組決定系統頻率」。

---

## 七、修正了 M0 自己的四個結論

誠實記錄，因為這些都曾寫進 `M0_FINDINGS.md`：

| 原結論 | 修正 |
|---|---|
| `stage_a_result` 是 raw multiply | 它是 **Montgomery 商數乘法**，位於 raw product **之後** |
| Barrett 單元從 netlist 中消失 | **一直都在**（329 個 net、113 個 cell）且功能正確。M0 只查 `get_cells`，而識別名保留在 `get_nets` |
| DSP 推論是面積槓桿、非時序槓桿 | **相反**。因為 DSP 從未用於 critical path 上的 raw multiply，量不到時序影響 |
| 已取得 routed 報告 | 那些檔案標示 `Routed` 但含 **2,126 個 `unplaced`、零 site location**，實為 pre-placement 估計 |

---

## 八、附帶發現

- **`tests/falcon-montg` 的指令編碼與解碼器不符**：`funct7=0x02` 解碼為
  `OP_CBD3`，被送往 CBD 取樣器而非乘法器，19 個硬體向量全錯。**改動前後完全相同**
  （已用 A/B 確認），是既有問題。**經 Barrett 查證後確認這是孤立案例，不是系統性
  模式。**
- `pqc/.../falcon-512` 無法連結：`.text` 超出記憶體 19,232 bytes。
- M0 的 Vivado 專案被留在 OOC 實驗的中間狀態（top 設為 `multiplier_tree`），
  直接 `launch_runs synth_1` 會合成裸模組而非 SoC。

---

## 九、限制

- 全 SoC 的數字仍是 **post-synthesis 估計**；post-route 只涵蓋乘法器樹模組。
- **ZU7EV（論文 part）從未合成過。** 原因不是缺板子——合成與 P&R 不需要實體硬體
  ——而是**免費版 Vivado ML Standard 不含 Zynq UltraScale+ MPSoC，需 Enterprise
  授權**。可循校園 XUP 授權或 AMD 30 天評估授權取得。
- 因此 **「42 → 69 MHz」的外推沒有做也不應做**：需假設系統其他部分不會先成為瓶頸。
- Falcon 的覆蓋依賴 `falcon-ntt` / `falcon-intt`（`falcon-montg` 與 falcon-512
  皆因既有問題無法貢獻）。

---

## 十、待決定（需要指導）

1. **M1 要建在改過的 RTL 還是原版上？**
   - 改版：timing gate 24.4 ns、餘裕充足，但論文 baseline 變成「修改過的已發表設計」
   - 原版：與論文一致，但帶著已知瓶頸做 M1（gate 73.7 ns，時序仍違反）

2. **這個修改要定位成 M1 的前置分析，還是獨立貢獻？**
   它有 post-route、同世代平台的證據，且直接對話論文 Section IV-D 的核心論證。
   若 M0 原本被定義為「不修改設計的純量測」，則此改動已超出 M0 範圍。

3. **是否申請 Vivado Enterprise 授權？** 這是驗證論文 42 MHz、以及取得全 SoC
   post-route 數字的唯一途徑。
