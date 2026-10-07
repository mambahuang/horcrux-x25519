# HORCRUX ASIC synthesis (Synopsys Design Compiler)

A self-contained DC flow for the HORCRUX coprocessor. It does **not** go through
FuseSoC, so it works even though the `rtl-xxxlib` fileset referenced by
`crheepto.core`'s `asic_synthesis` target was stripped from this repository.

Defaults target the CIC **CBDK_IC_Contest** kit (TSMC 0.13 µm, `slow` corner,
`tsmc13_wl10` wire load). Nothing is hard-coded to that kit — every value is a
variable — but the out-of-the-box settings match it.

## Quick start

Drop your `synopsys.setup` into this directory and it is found automatically:

```bash
cd implementation/design_compiler
cp /wherever/synopsys.setup .        # once

make synth
make report
less ../synthesis/last_output/report/timing_max.rpt
less ../synthesis/last_output/report/area.rpt
```

To keep it elsewhere, name it — a relative path is resolved against *this*
directory, not against `dc_shell`'s cwd:

```bash
make synth SYNOPSYS_SETUP=~/cad/synopsys.setup
```

The file is sourced verbatim inside `dc_shell`, so `search_path`,
`target_library`, `link_library`, `symbol_library`, `synthetic_library` and the
`hdlin_*` switches all come from it — exactly as if you had sourced it by hand
before `dc_syn.tcl`.

> **Why source it explicitly instead of relying on `.synopsys_dc.setup`?**
> The Makefile runs `dc_shell` *inside the run directory* so that DC's own logs
> stay with the run. DC only looks for `.synopsys_dc.setup` in
> `$SYNOPSYS/admin/setup`, `$HOME` and the current directory — so a copy sitting
> in `implementation/design_compiler/` would never be picked up on its own, and a
> relative `./synopsys.setup` would resolve against the run directory. Both cases
> are handled by resolving the path against this directory before `dc_shell`
> starts.

Interactive conveniences in your setup file (`sh_enable_line_editing`, `history`,
`alias`) can complain in batch mode, so it is sourced with `sh_continue_on_error`
temporarily relaxed. A genuinely broken setup is still caught: the flow aborts
immediately afterwards if `target_library` came out empty.

If you would rather not use a setup file at all, name the `.db` directly:

```bash
make synth STD_CELL_DB=/usr/cad/designkit/CBDK_IC_Contest_v2.1/SynopsysDC/db/slow.db
```

For a kit used across several design points, add a `TECH` preset to the Makefile
instead, so every branch is synthesized with identical library settings. Values on
the command line still override the preset:

```bash
make sweep TECH=tsmc40 PERIODS="4.8 4.6 4.5" MAX_CORES=1
```

Everything lands in `implementation/synthesis/<run_name>/`, with
`implementation/synthesis/last_output` symlinked to the newest run. That is the
layout `scripts/check_log_synth.sh` and the `postsynthesis-netlist` fileset in
`crheepto.core` already expect, so post-synthesis Questa simulation keeps working.

## How this maps onto your `dc_syn.tcl`

Your reference flow is reproduced, with each step made a variable:

| `dc_syn.tcl` line | Here |
|---|---|
| `set_host_options -max_cores 16` | `MAX_CORES` (default 4) |
| `analyze -format verilog` | `analyze -format sverilog`, one file at a time, ordered by `filelist.tcl` — this design is SystemVerilog with packages and an interface, so it cannot be a single `-format verilog` read |
| `set_operating_conditions -max_library slow -max slow` | `OPCOND` / `OPCOND_LIBRARY` (default `slow` / `slow`) |
| `set_wire_load_model -name tsmc13_wl10 -library slow` | `WIRE_LOAD_MODEL` / `WIRE_LOAD_LIB` (default `tsmc13_wl10` / `slow`) |
| `source ${DESIGN}.sdc` | `constraints.tcl`, driven by `CLK_PERIOD` and friends |
| `set_fix_hold [all_clocks]` | `FIX_HOLD` (default 1) |
| `set high_fanout_net_threshold 0` | `HIGH_FANOUT` (default 0) |
| `uniquify` | always |
| `set_fix_multiple_port_nets -all -buffer_constants` | `FIX_MPN` (default 1) |
| `compile_ultra` | `USE_ULTRA` (default 1), plus an optional `-incremental` pass |
| `write -format ddc / verilog`, `write_sdf -version 1.0` | always, into `netlist/` and `report/` |
| `report_area` / `report_timing` / `report_qor` | plus `report_constraint -all_violators`, `check_timing`, `check_design`, `report_register -level_sensitive`, `report_power`, and a one-screen `summary.rpt` |

## Files

| File | Purpose |
|---|---|
| `setup.tcl` | **The only file you normally edit.** Library setup, corner, clock period, compile options. Every variable can also be overridden from the make command line. |
| `filelist.tcl` | Ordered `analyze` list, mirroring the `horcrux_sv` fileset in `hw/ip/coproc.core`. |
| `constraints.tcl` | Operating conditions, wire load, clock, I/O delay, DRC. Writes a real `.sdc` at the end of the run. |
| `dc_script.tcl` | The flow itself. |
| `rtl/horcrux_top_synth.sv` | Boundary wrapper (see below). |
| `Makefile` | Driver. `make help` lists the targets. |

## Which top level?

`DESIGN_TOP` selects what gets synthesized:

- **`horcrux_top_synth`** (default) — the whole coprocessor: `id_stage` +
  `horcrux` datapath + `commit_stage`. This is the block the paper characterises.

  `horcrux_top` itself cannot be a DC top level, because its ports are
  SystemVerilog interface modports (`if_xif.coproc_issue`, …) and DC does not
  accept interfaces on the design boundary. `rtl/horcrux_top_synth.sv`
  instantiates `if_xif #(.X_NUM_RS(3))` internally — matching how
  `hw/ip/crheepto_top.sv.tpl:116` parameterises it — and re-exposes every signal
  as a packed port. It contains no logic, so the reported area and timing are
  those of `horcrux_top`.

- **`horcrux`** — the datapath only (Keccak, multiplier tree, `unified_mul_32x32`,
  sampler, SPHINCS+ ops, Falcon FPR, Barrett). Its ports are plain packed structs,
  so no interface is involved anywhere. Use this if your DC version has trouble
  with the internal `if_xif`, or if you want the datapath area on its own:

  ```bash
  make synth DESIGN_TOP=horcrux
  ```

Note that `hw/ip/coprocessors/cbd_eta.sv` is *not* synthesized: nothing
instantiates it, and it is likewise absent from the `horcrux_sv` fileset.

## Comparing against the paper — read this before quoting a number

The paper reports **160 MHz on 65 nm CMOS**. You are synthesizing on **0.13 µm**,
two full nodes back. Do not expect to reproduce that frequency, and do not treat
the gap as a bug in this RTL:

- **Frequency.** As a rule of thumb gate delay scales roughly with the node, so
  the same netlist on 0.13 µm typically lands somewhere near half the 65 nm
  frequency. That would put this design in the 70–90 MHz region, but that is an
  extrapolation, not a measurement — `make sweep` is what tells you the answer.
- **Area.** Raw µm² will be roughly 4× the 65 nm figure for identical logic, so
  the two numbers are not comparable at all as printed. The summary therefore also
  reports **gate equivalents** (`total cell area / NAND2 area`), which *is*
  comparable across nodes. If the auto-detected NAND2 is wrong for your library,
  set it explicitly: `make synth NAND2_CELL="*/NAND2X1"`.
- **Honest framing.** If you write this up, report it as "0.13 µm CBDK, X MHz,
  Y kGE" alongside the paper's "65 nm, 160 MHz" rather than presenting it as a
  reproduction attempt that fell short.

### Finding fmax

```bash
make sweep PERIODS="20 16 13 11 10 9 8"
```

Each period gets its own run directory; the target prints a comparison of all
summaries at the end. The real fmax is the smallest period whose `worst slack` is
still non-negative.

The `achieved period` line in `summary.rpt` (target period minus worst slack) is
only a first-order estimate — DC stops optimising once it meets the constraint, so
a run with large positive slack will understate what a tighter constraint could
reach. Trust the sweep, not the extrapolation.

## Other things to tighten before publishing

The defaults are tuned to get you a first result, not a sign-off result.

1. **`DRIVING_CELL` / `OUTPUT_LOAD`.** With `DRIVING_CELL` unset the flow drives
   the inputs with an ideal source, which flatters every input logic cone. Set it
   to a mid-strength buffer from the kit: `make synth DRIVING_CELL=<cell>`. Run
   `report_lib <libname>` in `dc_shell` if you do not know the cell names.
2. **`RST_FALSE_PATH`.** Defaults to 1, which waives recovery/removal checks on
   the async reset. Fine pre-CTS, not fine at tapeout.
3. **`FIX_HOLD`.** On by default to match your lab flow. It inserts buffers, so it
   inflates area a little; set `FIX_HOLD=0` if you want the leanest area number.
4. **Wire load vs topographical.** Wire-load mode ignores placement entirely. If
   you have Milkyway/TLUPlus files, `make synth-topo` with `MW_REF_LIB`,
   `MW_TECH_FILE` and `TLUPLUS_MAX` gives a much more honest delay estimate.
5. **Clock gating.** `CLOCK_GATING=1` needs an integrated clock-gating cell in the
   library; it will cut dynamic power noticeably on the 50×32 register file in
   `horcrux_register.sv`.

## Sanity checks the flow runs for you

- `check_design.rpt` — unconnected ports, multiple drivers.
- `check_timing.rpt` — unconstrained endpoints. If this lists many, your timing
  numbers are covering less of the design than you think.
- `registers.rpt` — `report_register -level_sensitive`. Should be empty; the
  coprocessor RTL infers no latches.
- `timing_loop.rpt` — combinational loops.
- `constraint.rpt` — `report_constraint -all_violators`, i.e. what is still broken
  after compile. Check this before believing `summary.rpt`.
- `scripts/check_log_synth.sh` is invoked automatically after each run and greps
  `synth.log` for errors and inferred latches.

## What this flow does not cover

Only the coprocessor. Synthesizing the full `crheepto_top` SoC additionally needs
SRAM macro `.db` files and a pad-cell library, neither of which is in this
repository (see the note in the top-level `README.md`). The PnR, dummy-fill, DRC
and LVS targets in the root `makefile` are likewise still stubs pointing at
directories that were never committed.
