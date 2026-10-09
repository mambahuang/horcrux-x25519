# M0′：HORCRUX 原版的 ASIC 合成基準（Design Compiler）

本目錄是計畫書里程碑 M0′ 的驗收產出：在 `baseline` 分支（`upstream/locket` 的 RTL，未作任何修改，加上 `implementation/design_compiler/` 的 DC flow）上合成 `horcrux_top_synth`，取得面積、時序與關鍵路徑。

- 合成日期：2026-10-07 至 2026-10-08，Synopsys DC，`compile_ultra` 加 incremental，`KEEP_HIER=1`
- 製程：TSMC 40 nm（CBDK_TSMC40_Arm f2.0），`sc9_base_rvt`
- 1 GE = `NAND2_X1A_A9TR`（面積 0.6804，庫的面積單位，下同）
- `compare.txt` 是全部 run 的總表；各子目錄為單次 run 的報告（見文末「檔案」）

## 結果

| 條件 | 收斂週期（Fmax） | 面積 | 真正的極限 | 代表 run |
| --- | --- | --- | --- | --- |
| ss / 125 °C，IO 15% | **12.6 ns（79.4 MHz）** | 187.1 kGE | 12.5 ns 只差 −0.022 | `12p6ns_20261007_163531` |
| tt / 25 °C，IO 15% | **7.4 ns（135.1 MHz）** | 178.1 kGE | 約 6.98 ns（6.8 ns 差 −0.142） | `7p4ns_20261008_101109` |
| tt / 25 °C，不約束 IO | **6.25 ns（160.0 MHz）** | 171.0 kGE | 約 5.83 ns（5.6 ns 差 −0.217） | `6p25ns_20261008_133101` |

「IO 15%」：輸入、輸出各預留 0.15 × 週期給 CV32E40PX 核心（`TECH=tsmc40` / `tsmc40tt`）。「不約束 IO」：`CONSTRAIN_IO=0`，只檢查暫存器到暫存器的路徑。

slack 剛好 +0.000 的 run 只代表在該目標下收斂：DC 達標後會改為縮小面積，所以真正的極限要從沒收斂的鄰近點推算（summary 的 `est. closure`）。

## 關鍵路徑：原版乘法器的 31 級加法鏈

所有條件下，最差路徑都經過 `multiplier_tree_inst/u_shared_mul/u_primary_mul`（`unified_mul_32x32`）：

- 有約束 IO 時：`id_stage` 的 `rs1`/`rs2` 暫存器 → 乘法器 → Montgomery → commit → `result_o`
- 不約束 IO 時：`rs1`/`rs2` 暫存器 → 乘法器 → `multiplier_tree_inst/reg_A`

原版 RTL 在同一個逐 bit 迴圈內，每一級都在 carry-less XOR 與整數加法之間選擇，DC 無法重組成乘法樹，只能照順序串接 31 個 `DW01_add`（`add_x_1` … `sub_x_31`）。以 ss、4.8 ns 那次的路徑（D = 9.61 ns）分解：

| 區段 | 延遲 | 占比 |
| --- | --- | --- |
| `id_stage` → 運算元 mux | 0.82 ns | 9% |
| **`u_primary_mul`（31 級加法鏈）** | **7.50 ns** | **78%** |
| `u_shared_mul` 後段（`DP_OP_45`） | 0.80 ns | 8% |
| `multiplier_tree` 結果 mux | 0.40 ns | 4% |
| commit → 輸出 | 0.09 ns | 1% |

面積上，`u_primary_mul` 在 12.6 ns 時佔 40,273（59.2 kGE），約為整個協處理器的 32%。

## 與 HORCRUX 原論文（65 nm、160 MHz）的關係

論文報告的 160 MHz 可以在 **tt corner 且不約束 IO** 的條件下重現（6.25 ns 收斂），而且大致就是這組條件下原版的上限。改用 worst-case corner（ss / 125 °C）並為核心預留 15% 週期，同一份 RTL 只到 79.4 MHz。由於協處理器的結果在 SoC 中與核心 writeback 同一週期使用，後者較接近實際整合後的 Fmax。

面積（171 kGE 對論文約 116 kGE）的差距尚未拆解，可能來源：hold 修正插入的 buffer（`FIX_HOLD=1`）、GE 的定義、wire load、合成範圍是否包含 XIF 邊界邏輯。

## 注意事項（論文引用前）

1. **約束隨週期縮放。** setup uncertainty（0.05 × P）與 IO delay（0.15 × P）都是週期的比例，週期越長扣得越多，會高估與較快設計（例如 `baseline-dwmul`）之間的差距。正式數字的約束待定案。
2. **ss corner 有 `max_transition` 違規，但不影響時序數字。** 收斂的 run 仍有上千條網路超過 flow 自訂的 `MAX_TRAN = 0.30 ns`（最差約 −0.07 ns，即 0.37 ns），集中在 `horcrux_register_inst` 的高扇出控制訊號；tt corner 只有個位數。已對照 `sc9_cln40g_base_rvt_ss_typical_max_0p81v_125c.lib` 確認：
   - 資料 pin 的 `max_transition` 為 0.762 ns，對應的延遲表（14,432 張）輸入 transition 也量測到 0.762 ns，因此這些網路的延遲是查表內插，不是外插。
   - 庫中較嚴的 0.381 ns 只出現在時脈類 pin：正反器 `CK`/`CKN`、latch `G`/`GN`、register file 的 `WWL*`（共 1,566 張表）。合成時時脈為理想網路（transition 0.10 ns），不受影響。

   0.30 ns 只是經驗值，比庫的限制更嚴；正式數字的 `MAX_TRAN` 建議改用 0.762 ns（庫的資料 pin 限制），與其他約束一起定案。見各 run 的 `constraint_summary.rpt`。
3. **`max_area` 與 `max_leakage_power` 的「違規」不是問題**：flow 設了 `set_max_area 0`，要求 DC 盡量縮面積，所以面積永遠標成違規。
4. **wire load** 為 `Medium`（`sc9` 庫），非實體佈局的估計值。

## 檔案

每個 `horcrux_top_synth_<週期>_<時間>/`：

| 檔案 | 內容 |
| --- | --- |
| `summary.rpt` | 合成條件、slack、收斂估計（較新的 run 才有）、面積與 kGE |
| `area.rpt` | `report_area -hierarchy`，各模組面積 |
| `timing_worst.rpt` | `timing_max.rpt` 的第一條（最差）路徑 |
| `qor.rpt` / `resources.rpt` / `power.rpt` | DC 的 QoR、DesignWare 元件選擇、粗估功耗 |
| `constraint_summary.rpt` | 各約束的違規網路數與最差 slack |

由 `make pack`（`implementation/design_compiler/pack_reports.sh`）從伺服器上的 `implementation/synthesis/` 打包；netlist、ddc、sdf、完整 log 未納入。
