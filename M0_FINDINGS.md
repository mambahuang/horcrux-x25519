# M0 Findings — x25519-ext Bring-Up & Baseline Characterization

Working notes from the M0 gate (repo bring-up) and the subsequent baseline
timing / DSP-forensics pass on `x25519-ext`. Environment setup issues and
their fixes are in `SETUP_NOTES.md`; this file is about what the RTL and
synthesis actually showed.

## Step 1 — Repo bring-up (gate: does it run at all?)

All three checklist items confirmed on the lab server (bare-metal, no
Docker — see `SETUP_NOTES.md` for every environment fix this took):

- **RTL simulation runs**: QuestaSim, `polito:vlsi:crheepto` `sim` target.
- **Toolchain builds the custom-ISA assembly**: CORE-V GCC compiles
  `keccak_coproc.S` and friends against `ARCH=rv32imfdc_zicsr_xcvbitmanip`.
- **Waveforms dump correctly**: `VCD_MODE=1` + a bounded `--max_cycles`
  produces a valid VCD (opened successfully in both GTKWave-less-nWave and
  nWave). Caution: uncapped `VCD_MODE=1` on the full SoC hierarchy
  (`cpu_subsystem_i` + `memory_subsystem_i` + `system_bus_i` +
  `coproc_wrapper_i`, full recursion depth) grows at roughly 0.7 MB/cycle
  in this design — an unbounded run filled a 1.2 TB shared filesystem.
  Always pass an explicit `--max_cycles` (or `FUSESOC_ARGS="--max_cycles=N"`
  via `questasim-run`, which doesn't forward `MAX_CYCLES` on its own).

Functional correctness cross-checked against the paper's published KAT
cycle counts (`sw/applications/pqc/optimized/KEM/...` tests, fixed
single-vector KATs, not randomized):

| Test | This run | README (100-KAT avg) | Note |
|---|---|---|---|
| ML-KEM-768 KeyGen/Encaps/Decaps | 260,388 / 288,498 / 426,258 | 260,000 / 289,000 / 426,000 | ~0.1-0.2% — effectively exact |
| HQC-1 KeyGen/Encaps/Decaps | 2,411,827 / 4,537,744 / 7,406,292 | 2,316,000 / 4,357,000 / 7,123,000 | consistently +4% across all three phases |

HQC's uniform +4% (not random noise — same direction and magnitude on
all three phases) is best explained by this repo's embedded test using a
single fixed KAT vector, vs. the paper's number likely averaging cycles
across many KAT vectors from a data-dependent (non-constant-time)
Reed-Solomon/Reed-Muller decoder. ML-KEM's NTT-based path is close to
constant-time, which is why it matches almost exactly. **Correctness
itself is not in question either way** — every KAT `memcmp` check passed
silently (no `ERROR: ... mismatch` printed) on all tested algorithms.

## Step 2 — Baseline synthesis + timing (Pynq-Z2, synthesis-only)

No FPGA board available; Vivado (2024.2, this machine, GUI) has no
UltraScale+ device files installed, so the ZCU104 target
(`xczu7ev-ffvc1156-2-e`) couldn't be used. Switched to the repo's other
wired FPGA target, **Pynq-Z2** (`xc7z020clg400-1` — confirmed installed).
This is a `synth_1`-only run (no place/route), using fusesoc/edalize's
generated project Tcl (`polito_vlsi_crheepto_0.tcl` /
`polito_vlsi_crheepto_0_synth.tcl`) — the full `.xpr` is reusable for a
real P&R pass later.

**Absolute numbers are not comparable to the paper's ZCU104 (ZU7EV, 16nm
UltraScale+, speed grade -2, DSP48E2) results** — Pynq-Z2 is a Z020
(28nm 7-series, speed grade -1, the slowest grade, DSP48E1). Only
same-platform, same-tool, same-constraint comparisons (this baseline vs.
a future modified version, both on this same Z020 setup) are valid.

### Timing summary

- Target clock: `clk_out1_xilinx_clk_wizard_clk_wiz_0_0` (Clock Wizard
  MMCM output), 15 MHz (period 66.667 ns).
- **WNS = -30.825 ns** (timing not met — expected for an unoptimized,
  pre-placement synthesis-only run; route delays are statistical
  estimates, real post-P&R numbers will likely be worse, not better).
- Critical path data delay: **97.231 ns** (logic 49.1% / route 50.9%) →
  naive fmax estimate ≈ **10.3 MHz** at synthesis stage.

### Critical path location

```
coproc_wrapper_i/horcrux_top_i/id_stage_i
  → multiplier_tree_inst/u_shared_mul/u_primary_mul   (unified_mul_32x32)
    accumulator85_in → accumulator1_in, ~28-30x CARRY4 ripple-carry chain
    → DSP48E1 (stage_a_result) produces the raw product
  → back into u_shared_mul's own Montgomery reduction
    (modp_tp / modp_tp__0, 2x DSP48E1 cascade via PCIN/PCOUT)
    → modp_sub_carry / modp_final_carry (more CARRY4)
  → leaves the coprocessor entirely
  → cv32e40px register file / APU dispatch / if_stage
  → destination: id_stage_i/alu_operand_b_ex_o_reg[23]
```

Delay breakdown by segment (approximate — post-synthesis hierarchy
boundaries blur under optimization, see DSP forensics below):

| Segment | Cumulative delay | Share |
|---|---|---|
| Source FF → multiplier input | ~4.1 ns | ~4% |
| **`unified_mul_32x32` (accumulator chain + DSP)** | ~4.1 → 70.4 ns (~66.3 ns) | **~68%** |
| `shared_multiplication_logic`'s own modular reduction | ~70.4 → 86 ns (~15.6 ns) | ~16% |
| cv32e40px datapath (register file/APU/if_stage) | ~86 → 95.6 ns (~9.6 ns) | ~10% |

**`unified_mul_32x32`'s ripple-carry accumulator chain is the dominant
contributor** — confirms the "long accumulation chain" hypothesis, and
specifically points at the chain's structure (not the DSP multiply
itself) as the target for any pipelining/restructuring work.

### ⚠️ Methodology correction: OOC timing must be run under real constraint pressure

The first OOC pass (`synth_design` → **then** `create_clock` →
`report_timing`, no `opt_design`) is invalid for anything beyond
utilization: with no clock defined *during* `synth_design`, Vivado
optimizes for area only, and a clock added afterward just measures
whatever structural delay happened to fall out — it never drove any
timing-aware decision. `report_clocks` on that design confirmed
`Design State: Synthesized` (never `Optimized`), i.e. `opt_design`
never ran.

**Symptom this caused**: that unconstrained run's worst path was
`b1_reg_reg[1]/C → reg_A_reg[*]/D` — the HQC Karatsuba XOR-accumulator
registers (`b1_reg`/`reg_A`, declared in `multiplier_tree.sv` as
"Store a_hi, b_hi from KARATS_2" / "Accumulator registers for
intermediate XOR results") — all 20 of the top-20 reported paths shared
this exact source/destination pattern. This is a *different* logical
path from the raw-multiply/Montgomery path found in the main SoC-level
analysis above, and it turned out to be an artifact.

**Corrected flow** (`create_clock` before `opt_design`, plus
`set_max_delay -from [all_inputs] -to [all_outputs]` to also catch pure
combinational port-to-port paths that a register-to-register clock
alone won't check):

```tcl
synth_design -top multiplier_tree -part xc7z020clg400-1 -mode out_of_context [-max_dsp 0]
create_clock -period 20.000 -name clk [get_ports clk_i]
set_max_delay 20.000 -from [all_inputs] -to [all_outputs]
opt_design
report_timing -delay_type max -max_paths 10 -file <...>
report_utilization -file <...>
```

Under real pressure, the worst path changed again — to
`multiplier_tree1_i[0] (input port) → result_o[11] (output port)`, a
pure combinational path with **no register in between at all**. Tracing
its full body confirms it is **the same logical path** as the SoC-level
critical path found above: accumulator chain (`accumulator82_in[2]` →
`accumulator1_in[29]`) → `stage_a_result` DSP48E1 (raw multiply) →
`modp_tp`/`modp_tp__0` DSP48E1 cascade via `PCOUT[47]`→`PCIN[47]`
(Montgomery reduction) → `modp_sub_carry`/`modp_final_carry` → `result_o`.

**This is a good outcome, not a bad one**: two independent synthesis
contexts (full SoC, and OOC-isolated-with-real-pressure) converge on the
identical bottleneck. It also directly answers whether "raw multiply"
and "Montgomery reduction" are separate concerns: **they are not** — in
this RTL they sit back-to-back in one unbroken combinational cone (no
register between `stage_a_result`'s product and `modp_tp`'s reduction
input), so any future pipelining fix has to treat both stages together.

Corrected DSP-vs-LUT table (now under genuine timing pressure, see next
section) still shows the same conclusion as the uncorrected run — see
below.

### ⚠️ Known limitation: could not get genuine post-route numbers for the OOC module

All numbers above (and in the DSP-vs-LUT table below) are still
**post-synthesis estimates** — `route delay` is a statistical model, not
real routing, and logic-level delay is real but route-level delay is
not. Confirmed the split is roughly 50/50 (baseline: logic 50.5% / route
49.5%; `-max_dsp 0`: logic 45.9% / route 54.1%), so this is a real
concern, not a minor one — a genuine post-route number could shift
things.

Tried three independent, standard, documented techniques to get
`multiplier_tree` through `place_design`/`route_design` in OOC mode, and
all three hit the identical class of failure
(`ERROR: [Place 30-188] UnBuffered IOs: clk_i has ... loads`, later
recurring as `ERROR: [DRC PLIO-5]` even post-route):

1. `set_property HD.CLK_SRC BUFGCTRL_X0Y1 [get_ports clk_i]` alone.
2. A manual OOC-only wrapper explicitly instantiating a `BUFG` primitive
   between `clk_i` and `multiplier_tree`, combined with (1).
3. AMD's own documented fix, `set_property CLOCK_BUFFER_TYPE BUFG
   [get_nets -of_objects [get_ports clk_i]]` before `opt_design` (per
   [UG912](https://docs.amd.com/r/2023.2-English/ug912-vivado-properties/CLOCK_BUFFER_TYPE)) —
   `opt_design` did auto-insert its own BUFG (`clk_i_BUFG_inst`) this
   time, but the exact same "unbuffered load" complaint recurred at the
   post-route DRC stage instead of at `place_design`.

Also tried and ruled out: full-SoC place/route instead of OOC — not
viable, the full SoC's 95,135 LUT usage exceeds the Z020's 53,200 LUT
capacity outright (179% over), so `place_design` would fail on capacity
before even reaching this clock-buffering issue.

**Conclusion**: this is a genuine, specific Vivado/OOC-flow limitation
for a bare submodule with its own clock port, not something resolvable
by looking up documented properties — it would need either (a) someone
with hands-on Xilinx OOC-flow debugging experience, or (b) building a
proper wrapper that includes the same real clock-generation
infrastructure (Clock Wizard MMCM + BUFG) the full SoC already uses
successfully in Step 2, rather than a bare `BUFG`-only stand-in. Not
pursued further given the effort already spent — **the numbers in this
document should be read as synthesis-level estimates, corroborated by
three independent analyses converging on the same critical path and the
same DSP-vs-LUT conclusion, but not confirmed post-route.**

## Step 3 — DSP forensics

### Is `unified_mul_32x32` actually alive?

`report_utilization -hierarchical` shows `u_primary_mul`
(`unified_mul_32x32`) with **0 LUT / 0 FF / 0 DSP** — but
`get_cells -hier -filter {NAME =~ "*u_primary_mul*"}` returns hundreds of
live cells (`difference_carry`, `falcon_sum_carry`, `modp_sub_carry`,
`reg_B_reg`, `stage_a_result`, all prefixed `u_shared_mul/u_primary_mul/`).

**Resolution**: these are two different accounting methods. Synthesis
dissolved the `unified_mul_32x32` ↔ `shared_multiplication_logic`
hierarchy boundary (no `keep_hierarchy` on the instance), so
utilization-by-hierarchy — which groups by real cell-hierarchy objects —
has nowhere to attribute resources for a boundary that no longer exists
as a distinct object. The flattened leaf cells retain the original RTL
path as a naming convention, which is why a plain string search still
finds them. **The logic is fully alive and dominates `u_shared_mul`'s
LUT/CARRY usage; only the module boundary was optimized away.**

### The 11 DSPs

Confirmed via OOC synthesis of `multiplier_tree` standalone
(`xc7z020clg400-1`, out-of-context) — **11 DSP48E1, identical to the
count seen in the full-SoC build**, so these are entirely self-contained
within `multiplier_tree` and not influenced by anything else in the SoC.

All 11 live under `u_shared_mul` directly (not `u_primary_mul` — same
flattening as above):

| Instance names | Count | Role |
|---|---|---|
| `stage_a_result`, `__0`, `__1` | 3 | raw multiply (Karatsuba-shaped: 3 not 4) |
| `stage_b_result`, `__0`, `__1`, `__2` | 4 | raw multiply, second operand path |
| `modp_tp`, `__0`, `__1`, `__2` | 4 | Montgomery reduction (confirmed via a real `PCOUT[47] → PCIN[47]` 48-bit cascade in the Step 2 critical-path trace) |

3 + 4 + 4 = 11, matches exactly. This directly explains the paper's
Table V "+11 DSP" line for the PQ-ALU row: it's the multiplier tree's
raw-multiply DSPs plus its own Montgomery-reduction DSPs, cascaded via
DSP48E1's native PCIN/PCOUT chaining — not a generic inferred multiply.

**This overturns the "hand-written partial-product array maps to LUT"
assumption.** Vivado's synthesizer performs DSP inference on recognized
arithmetic patterns regardless of RTL coding style (explicit
gate-level adder array or not) — the tool remapped the accumulation
onto DSP48E1 anyway.

### DSP vs. LUT trade-off (OOC, `multiplier_tree`, `xc7z020clg400-1`)

**Corrected numbers, under real timing pressure** (`create_clock` +
`set_max_delay` + `opt_design` — see methodology note above; the
uncorrected run's numbers were 5,852/9,097 LUT and 88.3/88.8 ns, close
enough that the conclusion is unchanged, but these are the trustworthy
ones):

| | Baseline (DSP inference on) | `-max_dsp 0` (forced to LUT) | Δ |
|---|---|---|---|
| Slice LUTs | 5,845 | 8,777 | **+2,932 (+50.2%)** |
| Slice Registers | 128 | 128 | 0 |
| DSP48E1 | 11 | 0 | −11 |
| Critical path data delay | 93.795 ns | 94.237 ns | **+0.442 ns (negligible)** |
| Logic Levels | 107 (CARRY4=54, DSP48E1=3) | 116 (CARRY4=60, no DSP) | +9 |

**DSP inference here is an area optimization, not a timing one — and
this conclusion now survives genuine timing-driven optimization on both
sides**, not just an unconstrained/no-pressure comparison. Removing all
11 DSPs costs +50% LUTs but barely moves the critical path (same CARRY4
ripple chain either way — DSP or no DSP, the chain just gets slightly
longer without DSP support absorbing part of it). The DSP-vs-LUT area
trade-off (11 DSP ↔ 2,932 LUT) can be argued independently of the
timing-critical-path argument — they don't interact, so neither weakens
the other in the writeup.

### Open question: Barrett reduction (`kyber_barrett_inst`)

`get_cells -hier -filter {NAME =~ "*barrett*"}` → **zero matches**,
anywhere in the synthesized netlist. Unlike `unified_mul_32x32` (flattened
but alive), this is a genuine absence — no residual cells at all.

RTL-side, the wiring is legitimate: `multiplier_tree.sv`'s
`case (insn_i)` selects `result_o = barrett_result` for
`OP_BARRETT | OP_BARRETT_HQC | OP_BARRETT_HQC3 | OP_BARRETT_HQC5`, gated
on a genuine runtime signal (`insn_i`), not a constant — this should not
be provably unreachable by simple constant propagation.

**Leading hypothesis**: the actual issue is upstream of
`multiplier_tree.sv` — `id_stage_i`'s decode/dispatch logic may never
actually produce these opcode values on `insn_i` for this particular
build (opcode encoding collision, or these instructions not fully wired
end-to-end yet), which Vivado's whole-netlist static analysis can detect
and eliminate even though the local RTL "looks" complete. **Not yet
traced — would need to follow `id_stage.sv`'s decoder for these four
opcodes to confirm.**

## Housekeeping / repo-adjacent notes

- Two real bugs found and fixed upstream on `origin/x25519-ext` during
  bring-up (see `git log`): null `files:`/`depend:` keys in ~30 vendored
  lowRISC `.core` files (fusesoc ≥2.2 schema-validates them away
  silently), and a missing `hw/vendor/x-heep/sw/CMakeLists.txt` that was
  never committed.
- `questasim-waves` / `SIM_VCD` in the top-level `makefile` are hardcoded
  to the `sim_postsynthesis-modelsim` path — broken for the regular
  `sim-modelsim` RTL-sim flow this repo is mostly used for. Worked around
  manually each time; not yet fixed upstream.
- `make app`'s final copy step (`find $(XHEEP_DIR)/sw/build/ ...`)
  intermittently loses the `$(XHEEP_DIR)` expansion in one specific
  recipe-line context — root cause not found, manual copy works around
  it (see `SETUP_NOTES.md`).

## Suggested next steps

- [ ] Trace `id_stage.sv` decode logic for `OP_BARRETT*` to explain the
      zero-cell result.
- [ ] Re-run OOC synthesis with pipelining/restructuring of the
      `unified_mul_32x32` accumulator chain (the ~68%-of-critical-path
      contributor) and re-check both timing and the DSP/LUT trade-off
      table above still hold.
- [ ] If a real fmax number matters for the writeup: run `place_design` +
      `route_design` on the Pynq-Z2 baseline for a true post-P&R number
      (synthesis-only numbers here are pre-placement estimates).
- [ ] X-HEEP minimal config (fewer memory banks / peripherals) to see if
      the full SoC fits under Z020's 53,200 LUT / 140 BRAM — explicitly
      lower priority; the OOC results above don't depend on this.

---

# M0 Follow-Up — Task 1: decomposition of the "66 ns" segment

Resolved entirely from the existing M0 reports; no re-synthesis was needed.
Primary evidence: `build/pynq-z2-vivado/reports/baseline/timing_max20.rpt`
(full SoC, `Design State: Synthesized`, WNS −30.825 ns), path 1 of 20.
Extract preserved at `reports/m0_followup/task1_soc_critical_path_extract.rpt`;
hierarchy data at `reports/m0_followup/task1_ooc_util_hier.rpt`.

## The ordering anomaly was a mislabelling, not an anomaly

There are **two structurally distinct multipliers** on this path, and Step 3's
DSP-forensics table named the wrong one "raw multiply":

- **`u_primary_mul` (`unified_mul_32x32`)** computes the raw `full_prod = a×b`
  as a hand-rolled shift-and-add array. **Zero DSPs.** This is the ~59.5 ns
  segment.
- **`stage_a_result`** is a *second, smaller* multiply — `full_prod_low × QINV`,
  the Montgomery **quotient-digit** multiply. It is DSP-mapped and sits
  **downstream** of the completed raw product.

The report shows this directly: `u_shared_mul/full_prod[31]` completes at
**63.590 ns**, then drives `u_shared_mul/A[14]` (the `stage_a_result` DSP48E1
input) at 64.513 ns. So the real ordering is *multiply → then a second multiply
for reduction*, which is entirely ordinary. Nothing accumulates before
multiplying; **the accumulation IS the multiplication.**

This also corrects the Step 2 segment boundary: `unified_mul_32x32` ends at
63.590 ns, not 70.4 ns — the earlier figure had absorbed the DSP and its
carry chain into the multiplier's share.

## Segment table (full-SoC critical path, 97.231 ns total)

| # | Segment | Range (ns) | Delay | Share | Cells | `MODE_RAW_MUL` |
|---|---|---|---|---|---|---|
| S0 | insn decode → operand/mode mux | −1.593 → 4.086 | 5.679 | 5.8% | FDCE, 2×LUT6, 2×LUT4, LUT2 | **shared** |
| S1 | `unified_mul_32x32` partial-product + accumulate array (**the raw a×b multiply**) | 4.086 → 63.590 | **59.504** | **61.2%** | 31×CARRY4, 17×LUT5, 14×LUT6 | **shared** |
| S2 | Montgomery reduction (`stage_a_result` → `modp_tp` cascade → `modp_sub`/`modp_final`) | 63.590 → 87.116 | 23.528 | 24.2% | 3×DSP48E1, 15×CARRY4, 5×LUT2, 2×LUT3, 2×LUT6 | **Montgomery-only** |
| S3 | cv32e40px RF / `if_stage` → destination FF | 87.116 → 95.637 | 8.521 | 8.8% | 4×CARRY4, 8×LUT6, 2×LUT2, LUT5, MUXF7 | **shared** |

Logic/route split per segment (ns): S0 1.262/4.417 · S1 26.596/32.908 ·
S2 16.131/7.397 · S3 3.783/4.738. **No cell in S1 is carry-less-specific and
none is Montgomery-specific** — the whole segment is on the integer multiply
path.

## Deliverable: the M1 timing gate number

**S0 + S1 + S3 = 5.679 + 59.504 + 8.521 = `73.7 ns`**

against the 97.231 ns baseline — a saving of 23.5 ns (24.2%), entirely from
skipping S2.

Caveats: assumes the new output-mux case costs ~0 (the existing
`MODE_HQC_RAW` bypass at `shared_multiplication_logic.sv:216-219` establishes
the pattern); S0 may grow slightly from one more decode branch; and this
remains a pre-placement estimate on the same statistical route model as
everything else in this document.

**This is the "mostly shared" outcome.** `MODE_RAW_MUL` inherits 61% of the
existing critical path with no way around it — the M1 gate must be strict, and
accumulator restructuring moves up in priority. Note also that **73.7 ns still
violates the SoC's 66.667 ns clock by ~7 ns**, so adding `MODE_RAW_MUL` alone
does not reach closure; it only reduces the existing violation.

## Which candidate explanation was right

| Hypothesis | Verdict |
|---|---|
| 1. carry-less GF(2) accumulation path | **Wrong.** The chain is CARRY4 — integer carry-propagate. The XOR variant is not on this path, which is why the CARRY4 objection raised in the task doc had no answer: the premise was false |
| 2. Karatsuba pre-adds | **Wrong.** `a1_reg`/`b1_reg` are registered and feed a 32-bit XOR *upstream* of the array (`multiplier_tree.sv:151-152`) |
| 3. DSP48E1 pre-adder spilling to fabric | **Wrong.** No DSP appears anywhere in S1 |
| 4. Operand assembly / limb alignment | **Closest, but imprecise** — it is the partial-product array itself |

**Actual answer:** the 32-iteration `for` loop at
`hw/ip/coprocessors/unified_mul_32x32.sv:26-46`. Each iteration's
`accumulator += partial_products[i]` synthesizes to one LUT+CARRY4 rank.
Vivado versioned the 32 blocking assignments to `accumulator` as
`accumulator1…accumulator85` (step of 3), and the critical path walks 29 of
them **diagonally — one bit position per rank**:

```
partial_products85_in[1] → accumulator82_in[2] → accumulator79_in[3]
  → … → accumulator4_in[28] → accumulator1_in[29]
```

at a near-constant **~1.98 ns per rank** (LUT5/6 0.301 + net ~0.66 +
CARRY4 0.566 + net 0.452). That is the textbook O(n) ripple of an
unpipelined shift-add array multiplier.

## The raw multiply uses zero DSPs — and that is the actionable finding

From `reports/m0_followup/task1_ooc_util_hier.rpt` (OOC, hierarchy preserved,
unlike the flattened SoC build):

| Instance | Module | LUTs | DSPs |
|---|---|---|---|
| `multiplier_tree` (total) | — | 8,777 | 0 |
| `u_shared_mul` own logic | `shared_multiplication_logic` | 2,970 | 0 |
| `u_primary_mul` | `unified_mul_32x32` | **5,804** | **0** |

That report is from the `-max_dsp 0` run. **The baseline split was
subsequently measured directly** (see Experiment 1 below, which re-ran the OOC
baseline with `report_utilization -hierarchical`): `u_primary_mul` = 5,414 LUT
/ 0 DSP, `u_shared_mul`'s own logic = 357 LUT / 11 DSP, top = 4 LUT.
*(An earlier revision of this section inferred ≈5,804 / ≈41 — superseded by
the measurement.)*

Two consequences:

1. **`u_primary_mul` is ~94% of the baseline's LUT area** (5,414 of 5,775) as
   well as 61% of the critical path. The multiplier tree is, to a first
   approximation, just this one array.
2. **The 11 DSPs never touch `a×b`.** They serve Montgomery reduction only.
   This sharpens Step 3's conclusion: DSP inference is not merely "an area
   lever not a timing lever" — it never applied to the dominant multiply at all.

**Why no DSP inference happened:** `carryless_mode_i` is tested *inside* the
loop body, so every accumulate rank is a mode-muxed add/XOR. Vivado cannot
pattern-match that to a multiplier and must build the shared array in fabric.
**The GF(2) mode is what costs the integer mode its DSP mapping.**

## Highest-value M1 experiment

*(Proposed here, then carried out — see Experiment 1 below. Predictions kept
as written for comparison against what actually happened; the area prediction
turned out to be wrong in the favourable direction.)*

`stage_a_result` — written as a plain `assign x = a * b` — performs a 32×32 in
**3.841 ns** on one DSP48E1. The hand-rolled array performs the same 32×32 in
**59.504 ns**. Separating the two modes into independent expressions should
recover that:

```systemverilog
assign int_prod = $signed(a_i) * $signed(b_i);   // DSP-inferable
// carry-less XOR array unchanged
assign prod_o = carryless_mode_i ? cl_prod : int_prod;
```

Expected: S1 collapses from ~59.5 ns to well under 10 ns. Costs: the XOR array
stays in fabric (area), plus a 64-bit output mux, plus DSP count rises. This
benefits **every integer mode** (ML-KEM, ML-DSA, Falcon, MODP), not just
X25519 — so it should be tried before, or alongside, any pipelining work.

## Incidental finding relevant to Task 3

`build/pynq-z2-vivado/reports/ooc/ooc_baseline_routed*.rpt` carry
`Design State: Routed`, but they are **not genuine post-route results**:

- Delay figures are byte-identical to the pre-placement `Optimized` run
  (93.795 ns; logic 47.395 / route 46.400; 107 logic levels).
- The report contains **2,126 `unplaced` annotations and zero site locations**
  (`SLICE_X…` / `DSP48_X…`).

So place/route did not actually run, consistent with the
`[Place 30-188]` / `[DRC PLIO-5]` failures documented above. **M0's "no genuine
post-route numbers" conclusion stands** — but the mislabelled file is a trap:
93.795 ns must not be cited as a post-route figure.

---

# Experiment 1 — splitting the integer / carry-less paths (CONFIRMED)

Tests the Task 1 hypothesis that the in-loop `carryless_mode_i` mux is what
blocks DSP inference on the raw multiply. Both configurations synthesised in
the same session with the same script
(`reports/m0_followup/exp1_dsp_split.tcl`, M0's corrected OOC flow, Vivado
2024.2, `xc7z020clg400-1`).

## The change

`hw/ip/coprocessors/unified_mul_32x32.sv` — the 32-iteration shared accumulate
loop was replaced by two independent expressions with the mode mux moved to
the output:

```systemverilog
logic signed [63:0] int_prod;
assign int_prod = $signed(a_i) * $signed(b_i);   // DSP-inferable

logic [63:0] cl_prod;                             // GF(2) XOR array, unchanged
always_comb begin
    cl_prod = '0;
    for (int i = 0; i < 32; i++)
        if (a_i[i]) cl_prod ^= ({32'b0, b_i} << i);
end

assign prod_o = carryless_mode_i ? cl_prod : int_prod;
```

## Results

| | Before | After | Δ |
|---|---|---|---|
| **Critical path (OOC)** | 93.953 ns | **44.921 ns** | **−49.03 ns (−52.2%)** |
| **Slice LUTs** | 5,775 | **4,113** | **−1,662 (−28.8%)** |
| DSP48E1 | 11 | 15 | +4 |
| Slice Registers | 128 | 128 | 0 |
| Logic Levels | 109 (CARRY4=56, DSP=3) | 57 (CARRY4=32, DSP=5) | −52 |
| `u_primary_mul` LUT | 5,414 | 3,575 | −1,839 |
| **`u_primary_mul` DSP** | **0** | **4** | **+4** |

The four new DSPs are `u_shared_mul/u_primary_mul/int_prod{,__0,__1,__2}` —
the raw `a×b` multiply is now DSP-mapped, which it never was before.

**The hypothesis is confirmed: the in-loop mode mux was the sole obstacle to
DSP inference.** Nothing else about the module changed.

**Area went *down*, not up.** The Task 1 write-up predicted an area cost; that
was wrong. The original shared array had to carry a per-rank mux between an
XOR result and an ADD result, so it paid for both modes at every one of 32
ranks. Splitting them deletes that overhead: the integer half moves entirely
into DSPs, and the carry-less half becomes a pure XOR array with no carry
logic. The 3,575 LUTs remaining in `u_primary_mul` are the GF(2) multiplier,
which HQC genuinely needs.

The critical path is still shaped S1 → S2, but S1 has collapsed: it now runs
input → `int_prod` DSP cascade (`int_prod__1` PCOUT → `int_prod__2` PCIN) →
`int_prod_carry` CARRY4 → `full_prod[30]` → `stage_a_op1[30]` → Montgomery.
**Montgomery reduction is now the dominant share of a much smaller total.**

## Functional equivalence

Verified before claiming the result: `reports/m0_followup/exp1_tb_equiv.sv`
instantiates the rewritten module alongside the original
(`exp1_unified_mul_ref.sv`, extracted from git) and compares outputs over

- the full 16×16 cross product of corner cases (0, ±1, `7FFFFFFF`,
  `80000000`, `FFFFFFFF`, alternating patterns, …), both modes;
- all 32×32 single-bit operand combinations, both modes — exercises every
  partial-product rank in isolation;
- 50,000 randomised vectors, both modes;
- an independent golden `$signed(a)*$signed(b)` model, to rule out both
  implementations being wrong in the same way.

```
EQUIVALENCE PASS  (152816 checks, 0 mismatches)
```

Run with `xvlog -sv` / `xelab` / `xsim` (Vivado 2024.2).

## Full-SoC RTL simulation (QuestaSim 2025.2_2, lab server)

Module-level equivalence was then confirmed end-to-end by re-running the
directed tests and KATs against the modified RTL in the real SoC.

| Test | Path exercised | SW cycles | HW cycles | Result |
|---|---|---|---|---|
| `tests/karats` | carry-less (`cl_prod`), `OP_KARATS_1/2/3` | 2,634 | 8 | PASS |
| `tests/mq-montymul` | integer, `MODE_MODP_MONT` | 360 | 114 | PASS |
| `tests/kyber-montg` | integer, `MODE_KEM_MONT` | 291 | 246 | PASS |
| `tests/dilithium-montg` | integer, `MODE_DSA_MONT` | 608 | 245 | PASS |
| `tests/kyber-ntt` | integer, butterfly traffic | 20,627 | 10,975 | PASS |
| `tests/kyber-intt` | integer, butterfly traffic | 29,604 | 11,406 | PASS |
| `tests/dilithium-ntt` | integer, butterfly traffic | 48,486 | 17,403 | PASS |
| `tests/dilithium-intt` | integer, butterfly traffic | 55,534 | 19,517 | PASS |
| `tests/falcon-ntt` | integer, `MODE_FAL_MONT` | 1,652 | 994 | PASS |
| `tests/falcon-intt` | integer, `MODE_FAL_MONT` | 2,076 | 1,206 | PASS |

`karats` and the `*-montg` / `*-ntt` tests each cross-check the hardware
result against a software reference implementation, so these are correctness
checks, not just liveness checks.

**KAT cycle counts are identical to the M0 baseline, to the cycle:**

| KAT | M0 baseline (KeyGen/Encaps/Decaps) | After the change |
|---|---|---|
| ML-KEM-768 | 260,388 / 288,498 / 426,258 | **260,388 / 288,498 / 426,258** |
| HQC-1 | 2,411,827 / 4,537,744 / 7,406,292 | **2,411,827 / 4,537,744 / 7,406,292** |

This is the decisive check. The rewrite is purely combinational — no pipeline
stage was added or removed — so latency must be unchanged, and it is, across
14.4 M cycles of HQC (the heaviest user of the carry-less path) and 975 K
cycles of ML-KEM. ML-DSA-65 also ran clean (789,880 / 6,176,971 / 913,085);
M0 recorded no baseline for it.

Two tests could not contribute, for reasons unrelated to this change:

- **`tests/falcon-montg` fails identically before and after** — same 19
  failures, same `got` values, same cycle counts, same simulation end time
  (50,867,040 ns). Confirmed by reverting the RTL and re-running. See the
  separate finding below.
- **`pqc/optimized/DS/FALCON/falcon-512` does not link**: `region 'ram0'
  overflowed by 19232 bytes`. The application is too large for the current
  X-HEEP memory configuration, so no binary is produced. A linker overflow
  cannot be caused by an RTL edit. Falcon's datapath is covered by
  `falcon-ntt` / `falcon-intt` regardless.

**Methodological note for anyone repeating this:** two build/simulation jobs
must never run concurrently in the same working tree. They share
`hw/vendor/x-heep/sw/build/main.elf`, `build/sw/app/main.hex`, and the
ModelSim `work` library; running a background KAT sweep alongside a foreground
directed-test loop produced three spurious failures (`Failed to find design
unit 'tb_top'`, a phantom `BUILD FAILED`) that all disappeared on a serial
re-run. Relatedly, a stale `build/sw/app/main.hex` will be silently re-simulated
if `make app` fails — one falcon-512 run reported ML-DSA-65's cycle counts
verbatim before this was caught. Delete `build/sw/app/main.*` between tests and
check the timestamp, not just existence.

## Verdict

The rewrite is functionally equivalent at both module and system level, halves
the critical path at OOC and SoC level alike, and reduces LUT count at both.
No correctness regression was found in any test that runs.

The defensible claim is **not** "a broken design was fixed" — the design is not
broken, and on the paper's own platform it meets the frequency the paper
reports. It is narrower and better supported: *the paper attributes the
multiplier tree's 3× frequency penalty to a deliberate architectural
trade-off; on this platform roughly two thirds of that penalty is instead an
RTL-coding artifact that blocks DSP inference, and removing it costs none of
the properties the trade-off was made to buy.* Confirming that on ZU7EV is the
outstanding work.

---

# Incidental finding — `tests/falcon-montg` issues an instruction that never reaches the multiplier

Found while running the Experiment 1 regression; **pre-existing, unrelated to
any change made here.** All 19 of its hardware vectors fail, before and after.

The test's inline assembly is:

```c
#define MONTG_FALCON(dest, a) \
    asm volatile ( \
        "addi t0, %[r1], 0\n" \
        ".insn r 0x3b, 0x7, 0x2, %[rd], t0, x0 \n" \
        ...
```

`funct7 = 0x02`, `funct3 = 0x7`, `opcode = 0x3b`. In
`hw/ip/coprocessors/include/horcrux_pkg.sv:225` that encoding decodes to:

```systemverilog
instr: 32'b0000010_00000_00000_111_00000_0111011,  // (comment left blank)
resp : '{ ... insn: OP_CBD3, ... },
opcode : CBD
```

**It is dispatched to the CBD (centered binomial distribution) sampler, not to
`multiplier_tree`.** The instruction never reaches `shared_multiplication_logic`,
let alone `unified_mul_32x32`.

The other Montgomery tests, which all pass, use encodings in the MQMUL block:

| Test | funct7 | Decodes to | Unit | Result |
|---|---|---|---|---|
| `tests/mq-montymul` | `0x10` | `OP_MQMULF` | MULTIPLIER_TREE | PASS |
| `tests/kyber-montg` | `0x11` | `OP_MQMULK` | MULTIPLIER_TREE | PASS |
| `tests/dilithium-montg` | `0x12` | `OP_MQMULD` | MULTIPLIER_TREE | PASS |
| `tests/falcon-montg` | **`0x02`** | **`OP_CBD3`** | **CBD** | FAIL (19/19) |

Corroborating evidence: the observed `got` values are 1, 0, 7, −6, 0, 0, 0, 0,
1, 2, 0, 0, 0, 0, 1, 0, 1, −6, 6 — small integers in a narrow band, which is
what a CBD sampler emits, not what a Montgomery reduction emits.

The test also passes `rs2 = x0`, so even with the correct `0x10` encoding it
would compute `full_prod = a × 0 = 0`; a pure reduction needs `rs2 = 1`.

**This is the same class of issue as the open Barrett question in Step 3** — an
instruction in the published design that is not wired through end to end. Worth
confirming whether a dedicated single-operand Falcon Montgomery-reduce
instruction was intended and dropped, or whether the test simply has the wrong
encoding, before reporting upstream.

## Full-SoC synthesis — the design now meets timing

The OOC numbers above are not comparable to the SoC's 97.231 ns, so M0's SoC
flow was re-run on a copy of its project (`pynq-z2-vivado-exp1`, original left
untouched) with the same report command.

| Main clock domain (`clk_out1_…clk_wiz_0_0`, 66.667 ns) | M0 baseline | After |
|---|---|---|
| **WNS** | **−30.825 ns** | **+15.696 ns** |
| TNS | −75,386.570 ns | **0.000 ns** |
| **Failing endpoints** | **2,658** / 84,875 | **0** / 84,875 |
| Worst reg-to-reg path | 97.231 ns | **47.905 ns** |
| Logic levels on that path | 110 (CARRY4=50, DSP=3) | 61 (CARRY4=29, DSP=5) |

**On this platform the design closes timing for the first time.** All 2,658
failing endpoints M0 recorded are gone, and no multiplier path appears anywhere
in the 20 worst paths.

**Scope, stated precisely, because it is easy to overclaim here.** This is
Pynq-Z2 (`xc7z020clg400-1`, 28 nm, speed grade −1), post-synthesis, against the
66.667 ns clock the repo's build scripts generate. It is *not* the paper's
platform and says nothing directly about the paper's reported numbers — see
the comparison section below. Pynq-Z2 was only ever a proxy: the design does
not fit on it in either configuration.

The one remaining violation, `spi_slave_sck_io` → GPIO sync register
(−4.785 ns, 2 logic levels, IBUF+LUT2), is a pre-existing I/O constraint issue
— it appears in M0's baseline summary too, merely masked by the −30.825 ns
coprocessor path. Hold timing is byte-identical either way (WHS −0.202 ns,
8 failing endpoints), so this change does not touch it.

SoC area: **95,135 → 92,513 LUT (−2,622)**, FF and BRAM unchanged, DSP 20 → 24.

### Segment comparison on the same path

Same destination register (`alu_operand_b_ex_o_reg[23]`) in both:

| Segment | M0 baseline | After | Δ |
|---|---|---|---|
| Decode/mux + raw multiply (S0+S1) | 65.183 ns | **16.006 ns** | **−49.18 ns** |
| Montgomery reduction (S2) | 23.528 ns | 23.528 ns | 0.000 |
| cv32e40px tail (S3) | 8.521 ns | 8.371 ns | −0.15 |
| **Total** | **97.231 ns** | **47.905 ns** | **−49.33 ns (−50.7%)** |

S2 comes out **identical to three decimals**, which is the expected result: the
Montgomery RTL was not touched. The entire saving is in the raw multiply,
a 4.1× speedup on that segment, and it matches the OOC prediction
(−49.03 ns) almost exactly.

### Revised M1 gate

Task 1's gate of 73.7 ns was computed against the old RTL. Recomputed here,
`MODE_RAW_MUL` = S0 + S1 + S3 = 16.006 + 8.371 = **24.4 ns**, comfortably
inside the 66.667 ns budget.

**Montgomery reduction is now the dominant segment** — 23.528 ns of a 47.905 ns
path, 49% — so it is the target for any further optimisation work, and the
"long accumulation chain" hypothesis that drove M0 is now fully retired.

## Relation to the paper's reported frequency

The paper reports, on ZCU104 (Zynq UltraScale+, Vivado 2022.2):

| Configuration | fmax | Source |
|---|---|---|
| HORCRUX **without** the unified multiplier tree | 125 MHz | Section VI-B |
| HORCRUX **complete** | **42 MHz** | Table VI, last row |
| ASIC, 65 nm CMOS | 160 MHz | Section VI-C |

42 MHz is the lowest figure in Table VI; the other works cited there sit
between 100 and 270 MHz. The paper addresses this directly and attributes the
3× penalty to a deliberate architectural decision (Section IV-D):

> integrating pre-processing, modular reduction, and post-processing into a
> single-cycle butterfly creates the primary frequency bottleneck of the
> architecture. This long combinatorial path was a conscious design trade-off
> to prioritize a shareable, area-efficient datapath over peak operating
> frequency.

**The measurements above suggest that attribution is only partly right.** The
paper correctly identifies the multiplier tree as the bottleneck, but the
segment breakdown splits the cost in two:

| | Delay (M0 baseline) | Removed by this change? |
|---|---|---|
| Modular reduction — the integration the paper describes | 23.528 ns | **No** — identical after |
| Raw `a×b` | 59.504 ns | **Yes** — down to ~16 ns |

The architectural integration costs what the paper says it costs. The raw
multiply's 59.5 ns is a separate matter: it comes from the mode mux sitting
inside the accumulate loop, and removing it **does not give up any of the
properties the trade-off was made to buy** — the datapath is still shared,
still single-cycle, still serves both integer and GF(2) modes. Area went down,
not up. On this platform roughly two thirds of the measured penalty was not a
trade-off at all.

The paper's own ASIC result is consistent with this reading: at 65 nm the same
RTL reaches 160 MHz, which is what one would expect if the FPGA penalty came
from failed DSP inference and a LUT/CARRY4 ripple structure rather than from
the algorithm — an ASIC synthesiser has no DSP hard blocks to miss and will
restructure the conditional-add chain into a carry-save tree.

**What cannot be claimed from this work.** Everything here is Pynq-Z2
(Z020, 28 nm, −1), post-synthesis, Vivado 2024.2. The paper's 42 MHz is ZU7EV
(16 nm, −2), presumably post-implementation, Vivado 2022.2. The ~10-11 MHz
measured here is in the expected range for a part 2.5-3.5× slower, so the two
are not in conflict — but the 2.03× path improvement measured here **must not
be extrapolated to "42 → 85 MHz"**. DSP-based and LUT-based paths do not scale
alike across devices, and no ZU7EV synthesis has been run: this machine has no
UltraScale+ device files installed (`get_parts xczu*` returns 0; only artix7,
kintex7, spartan7 and zynq are present).

Installing UltraScale+ device support would settle it — it is an installer
step, not a hardware purchase, and needs no physical board. It would allow a
same-part comparison against the paper's 42 MHz, a reproducibility check of
that number, and, since ZCU104 has ~230 K LUTs, a full place-and-route the
Z020 can never support.

## Caveats

- **Still pre-placement.** These are synthesis estimates on the same
  statistical route model as everything else in this document; a positive WNS
  at synthesis is not a guarantee post-route. The SoC also does not fit on the
  Z020 (92,513 LUT vs 53,200, 256 BRAM vs 140), so P&R cannot be run to check.
  The logic/route split did shift from 50.6/49.4 to 63.1/36.9, so
  proportionally more of the remaining delay is real logic rather than
  estimate.
- **`tests/falcon-montg` and the falcon-512 KAT contribute nothing** — both
  fail for pre-existing reasons documented above, so Falcon coverage rests on
  `falcon-ntt` / `falcon-intt`.
- DSP usage rises 11 → 15 in the multiplier tree (20 → 24 across the SoC, of
  the Z020's 220). Not a constraint here, but it scales with instantiation
  count.
- **M0's project was left mid-experiment.** `pynq-z2-vivado`'s `synth_1` has
  its top set to `multiplier_tree` and an OOC wrapper source that no longer
  exists still in the fileset, both left over from the Step 3 OOC work. A plain
  `launch_runs synth_1` therefore synthesises the bare module, not the SoC —
  `reports/m0_followup/exp1_soc_synth.tcl` resets both. Anyone reproducing M0's
  SoC baseline will hit this.
