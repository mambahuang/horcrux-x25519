# 設計點：M1 + M2 擴充（x25519-ext）

`x25519-ext` 分支是 `baseline-dwmul` 加上三項修改：

- **M1**：`MODE_INT_RAW`，讀出原始 64-bit 乘積（`shared_multiplication_logic.sv`）
- **M2**：9 條 ACC 指令、64-bit `acc_q`、運算元端 ×{1, 2, 19, 38} 的 scaler（A1），以及 `accwrap` 的 ×{19, 5}（`multiplier_tree.sv`、`horcrux_pkg.sv`、`horcrux.sv`）
- **rs_valid 修正**：`id_stage` 等待 CORE-V-XIF 的 `rs_valid` 才接收指令。這是 bug fix，不屬於擴充本身，沒有 backport 到 baseline，成本由下方的分模組面積單獨列出

合成條件與 `reports/baseline-dwmul/`、`reports/baseline/` 相同：TSMC 40 nm `sc9_base_rvt`，ss / 125 °C，IO 15%（`TECH=tsmc40`），`KEEP_HIER=1`，1 GE = `NAND2_X1A_A9TR`（0.6804）。兩個設計點用的是同一份 `implementation/design_compiler` flow（兩分支間沒有差異），所以 baseline-dwmul 沒有重跑，直接與它已提交的報告比較。

約束沿用目前的設定，尚未與指導教授定案；定案後兩個設計點要用新約束一起重跑。

## 結果

| 週期 | baseline-dwmul | x25519-ext | 用途 |
| --- | --- | --- | --- |
| 12.6 ns | 收斂，132.1 kGE | 收斂，**135.2 kGE** | 面積增量（週期寬鬆，沒有為時序加大 cell） |
| 5.4 ns | slack +0.0001 ns，166.5 kGE | slack **−0.001 ns**，174.6 kGE | 在 baseline 的 Fmax 下比較時序 |
| 5.5 ns | （未跑） | 收斂，170.8 kGE | x25519-ext 確定收斂的最快點 |

## 面積增量（12.6 ns）：+3029 GE（+2.3%）

| 部分 | baseline-dwmul | x25519-ext | 差異 |
| --- | --- | --- | --- |
| 全晶片 | 132,150 GE | 135,179 GE | **+3029 GE** |
| `id_stage`（rs_valid 修正） | 1,059 | 1,081 | +22 |
| `u_shared_mul`（M1） | 26,146 | 26,493 | +347 |
| `multiplier_tree` 其餘部分（M2） | 15,579 | 18,298 | +2719 |
| 其他模組（keccak、sphincs、register 等，未修改） | 89,367 | 89,307 | −60 |

rs_valid 修正只有 22 GE，可以忽略；擴充（M1 + M2）約 **3.0 kGE**。

M2 新增的元件可以從 `resources.rpt` 對回 RTL：

| 元件 | RTL | 面積 |
| --- | --- | --- |
| `DP_OP_122J7_125_6749` | `wrap_v = rs1 + C·acc_q`（`multiplier_tree.sv:497`，`accwrap`） | 1087 GE |
| `add_x_17`（64-bit `DW01_add`） | `acc_sum = acc_q + 乘積`（`multiplier_tree.sv:496`，`macc`） | 725 GE |
| `DP_OP_156_153_1268` | ×19 scaler（`multiplier_tree.sv:486`） | 567 GE |
| `multiplier_tree` 本身的 cell | `acc_q` 的 64 個 flip-flop（noncombinational +427 GE）與 next-state / scaler mux（combinational +644 GE） | +1071 GE |

這四項合計約 3.45 kGE，比 `multiplier_tree` 的實際增量多，因為同一個模組裡未修改的部分也有變動，例如 `kyber_barrett_inst` 少了 394 GE，既有的 datapath 運算也被 DC 重新分組（`DP_OP` 編號改變）。未修改模組的這類變動約在 ±0.4 kGE 以內，是 DC 最佳化的雜訊範圍，讀數字時要一併考慮。

**`accwrap` 的硬體成本約 1.1 kGE，佔擴充的三分之一以上。** 計畫書的待決項目「`accwrap` 做成硬體或軟體」可以用這個數字，和 Poly1305 / `fe_mul` 用軟體收尾多出的指令數一起權衡。

## 時序：在 baseline 的 Fmax 下，兩者相差約 1 ps

在 5.4 ns 這個相同的目標週期下，baseline-dwmul 剛好收斂（+0.0001 ns），x25519-ext 差 0.001 ns，兩者都卡在邊緣，差距屬於 DC 的雜訊範圍。

最差路徑**沒有經過新加的 scaler 或 ACC**：

| 設計點 | 最差路徑 |
| --- | --- |
| baseline-dwmul | `id_stage` 的 `rs1` 暫存器 → 運算元 mux → `u_primary_mul`（`DW_mult_tc`）→ … → `result_o[7]` |
| x25519-ext | `id_stage` 的 `rs1` 暫存器 → 運算元 mux → `kyber_barrett_inst`（既有的 Kyber Barrett 約簡）→ `result_o[25]` |

兩條都是既有 PQC 運算的組合路徑，由 `rs1` 一路到輸出。scaler 位於 `rs2` 進入乘法器之前的路徑上，不在這次的最差路徑裡。`timing_worst.rpt` 只保留最差的一條路徑，所以無法得知經過 scaler 的路徑還剩多少 slack；若需要這個數字，要在 server 上對 scaler 的路徑另外 `report_timing`。

5.4 ns 的 174.6 kGE 不能拿來比較面積：這次 run 沒有收斂，DC 為了趕時序加大了 cell。面積請以 12.6 ns 的比較為準。

### 各自的 Fmax（以 0.1 ns 為網格）

| | baseline-dwmul | x25519-ext | 差異 |
| --- | --- | --- | --- |
| 收斂的最快週期 | 5.4 ns（185.2 MHz） | 5.5 ns（181.8 MHz） | 慢一格（1.9%） |
| 該週期的面積 | 166.5 kGE | 170.8 kGE | +4.3 kGE（+2.6%） |

「慢一格」是網格造成的：x25519-ext 在 5.4 ns 只差 1 ps，真正的差距遠小於 0.1 ns。報告時建議寫成「Fmax 與 baseline 相同（5.4 ns 時相差 1 ps）」，並附上這張表，而不是寫成「慢 1.9%」。各自 Fmax 的面積包含 DC 為趕時序加大的 cell，擴充本身的成本仍以 12.6 ns 的 +3029 GE 為準。

5.5 ns 這次的完整報告尚未放進本目錄，只有 summary 的數字。

## 待補

- 5.5 ns 的完整報告檔
- 5.2 ns：與 baseline-dwmul 的 5.2 ns（slack −0.028 ns）比較，確認真正的極限是否相同
- 經過 scaler 的路徑的 slack（需在 server 上另外 `report_timing`）
