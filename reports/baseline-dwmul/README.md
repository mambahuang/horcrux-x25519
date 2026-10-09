# 設計點：乘法器改寫為 DesignWare（baseline-dwmul）

`baseline-dwmul` 分支與 `baseline` 只差一個檔案：`hw/ip/coprocessors/unified_mul_32x32.sv` 換成 M0 FPGA 階段的改寫版（commit `6c9f3e9`，tag `m0-fpga`）。整數路徑改寫為 `$signed(a_i) * $signed(b_i)`，carry-less 路徑保留原本的 XOR 迴圈，兩者最後以 mux 選擇。這個改寫在 M0 已用 equivalence testbench 與 KAT 回歸確認與原版功能相同。

合成條件與 `reports/baseline/` 相同（TSMC 40 nm `sc9_base_rvt`，`KEEP_HIER=1`，1 GE = `NAND2_X1A_A9TR`），比較時請一併閱讀該目錄的 README，尤其是「注意事項」。

這是額外的設計點，不取代 baseline：計畫書的主線保持乘法器陣列不變，以便把擴充的成本歸因清楚。

## 結果

| 條件 | 收斂週期（Fmax） | 面積 | 真正的極限 | 代表 run |
| --- | --- | --- | --- | --- |
| ss / 125 °C，IO 15% | **5.4 ns（185.2 MHz）** | 166.5 kGE | 約 5.23 ns（5.2 ns 差 −0.025） | `5p4ns_20261007_165645` |
| ss / 125 °C，IO 15%，與 baseline 同頻 | 12.6 ns | **132.1 kGE** | — | `12p6ns_20261008_092058` |
| tt / 25 °C，IO 15% | **3.3 ns（303.0 MHz）** | 150.1 kGE | 約 3.01 ns（3.0 ns 差 −0.008） | `3p3ns_20261008_101103` |
| tt / 25 °C，不約束 IO | **≤ 2.6 ns（≥ 384.6 MHz）** | 148.3 kGE | 尚未找到（2.6 ns 仍收斂） | `2p6ns_20261008_145132` |

5.4 ns 與 3.3 ns 同時是該條件下「收斂的最快點」與「面積 × 時間最低的點」。

## 與 baseline 的對照

| 比較 | baseline | baseline-dwmul | 差異 |
| --- | --- | --- | --- |
| ss、IO 15%，各自 Fmax | 12.6 ns / 187.1 kGE | 5.4 ns / 166.5 kGE | 快 2.33 倍、小 11% |
| ss、IO 15%，同頻 12.6 ns | 187.1 kGE | 132.1 kGE | 小 29%（−55.0 kGE） |
| 面積 × 時間（ss、各自 Fmax） | 2357 | 899 | 好 2.62 倍 |
| tt、IO 15%，各自 Fmax | 7.4 ns / 178.1 kGE | 3.3 ns / 150.1 kGE | 快 2.24 倍、小 16% |
| tt、不約束 IO | 6.25 ns / 171.0 kGE | ≤ 2.6 ns / 148.3 kGE | 快 2.4 倍以上 |

**面積差幾乎全部來自乘法器。** 同頻 12.6 ns 時，`u_primary_mul` 在 baseline 是 40,273（59.2 kGE），在 dwmul 是 7,214（10.6 kGE），相差 48.6 kGE，佔整體差距 55.0 kGE 的 88%。

## DC 推論出的乘法器

`resources.rpt` 中 `unified_mul_32x32` 只剩一個元件：

| Cell | Module | 參數 | 實作 |
| --- | --- | --- | --- |
| `mult_x_1` | `DW_mult_tc` | `a_width=32`, `b_width=32` | `pparch (area,speed)`，`mult_arch: benc_radix4` |

即 32×32 二補數乘法器，Radix-4 Booth 編碼的 partial-product 架構。原版那 31 個 `DW01_add` 完全消失。

## 關鍵路徑：換到 Montgomery 約簡

以 ss、5.0 ns 那次（D = 4.12 ns）分解：

| 區段 | 延遲 | 占比 | baseline（ss、4.8 ns） |
| --- | --- | --- | --- |
| `id_stage` → 運算元 mux | 0.68 ns | 16% | 0.82 ns |
| `u_primary_mul`（`DW_mult_tc`） | 0.74 ns | 18% | 7.50 ns |
| stage A（`mult_x_3`） | 0.46 ns | 11% | — |
| stage B 乘法 + 減法（`DP_OP_45`） | 1.73 ns | 42% | 0.80 ns |
| 結果 mux + commit → 輸出 | 0.51 ns | 12% | 0.49 ns |

乘法器從 7.5 ns 降到約 0.74 ns（這條路徑用到的是乘積的低位元，完整 64-bit 乘積的高位元會較慢），瓶頸換成 Montgomery 的 stage A → stage B → 減法。Fmax 改由演算法結構決定，而非 RTL 寫法。

不約束 IO 時（tt），最差路徑為 `rs3` 暫存器 → `multiplier_tree_inst/reg_A`；tt、IO 15%、4.0 ns 那次的最差路徑則是 Falcon `fpr_inst` 內的暫存器到暫存器路徑。

## 注意事項

與 `reports/baseline/README.md` 相同，另外：

- ss 的 run 也有 `max_transition` 違規（5.4 ns 時 510 條網路，最差 −0.13 ns，即 0.43 ns），tt 只有個位數。和 baseline 一樣，0.43 ns 仍低於庫對資料 pin 的限制與延遲表的量測上限 0.762 ns，延遲是查表內插，不影響時序數字（理由見 `baseline` 分支 `reports/baseline/README.md` 的注意事項 2）。
- 「各自 Fmax」的面積包含 DC 為趕時序而加大的 cell；只看乘法器寫法本身的面積差，應以同頻的比較為準。
