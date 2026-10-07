##########################################################################################
# HORCRUX ASIC synthesis - technology / run setup
#
# THIS IS THE ONLY FILE YOU SHOULD NORMALLY NEED TO EDIT.
#
# Everything below is either read from an environment variable (so the flow can be
# driven from the Makefile / a job scheduler) or falls back to a default. The
# defaults are library-agnostic: the flow takes the corner, operating condition and
# wire load from whatever .db you point it at. See `make libinfo`.
##########################################################################################

proc env_or {name default} {
  if {[info exists ::env($name)] && [string length $::env($name)] > 0} {
    return $::env($name)
  }
  return $default
}

# ---------------------------------------------------------------------------------------
# 0. Paths (needed by the rest of this file)
# ---------------------------------------------------------------------------------------
# Repository root, derived from this script's location. Note that dc_shell runs with
# its cwd set to the run directory, so nothing here may depend on the cwd.
set REPO_ROOT     [file normalize [file join [file dirname [info script]] .. ..]]
set DC_DIR        [file join $REPO_ROOT implementation design_compiler]

# ---------------------------------------------------------------------------------------
# 1. Technology library
# ---------------------------------------------------------------------------------------
# SYNOPSYS_SETUP points at your lab's synopsys.setup. It is sourced verbatim before
# anything else, so search_path / target_library / link_library / symbol_library /
# synthetic_library and all the hdlin_* switches come from there.
#
# If you keep synopsys.setup in this directory (implementation/design_compiler/) it is
# picked up automatically and you can just run `make synth`. Otherwise:
#
#   make synth SYNOPSYS_SETUP=/path/to/synopsys.setup
#
# A relative path is resolved against this directory, not against dc_shell's cwd --
# dc_shell runs inside the run directory, so "./synopsys.setup" would otherwise point
# at the wrong place. Same reason a .synopsys_dc.setup in the project root would not
# be found: DC only looks in $SYNOPSYS/admin/setup, $HOME and the cwd.
set SYNOPSYS_SETUP [env_or SYNOPSYS_SETUP ""]
if {[string length $SYNOPSYS_SETUP] == 0} {
  # Accept either name -- some people keep it as the dotfile DC would read itself.
  foreach _n {synopsys.setup .synopsys_dc.setup synopsys_dc.setup} {
    set _local_setup [file join $DC_DIR $_n]
    if {[file exists $_local_setup]} {
      set SYNOPSYS_SETUP $_local_setup
      break
    }
  }
} elseif {[file pathtype $SYNOPSYS_SETUP] ne "absolute"} {
  # Try the path as given (relative to cwd) first, then relative to this directory.
  if {![file exists $SYNOPSYS_SETUP]} {
    set _rel [file join $DC_DIR $SYNOPSYS_SETUP]
    if {[file exists $_rel]} { set SYNOPSYS_SETUP $_rel }
  }
}

# Alternative route: name the .db directly and let this script build the library
# variables. Leave empty when SYNOPSYS_SETUP already sets target_library.
set STD_CELL_DB   [env_or STD_CELL_DB   ""]

# Optional extras. Only used when STD_CELL_DB is set (otherwise your setup file owns
# these variables and this script does not touch them).
set EXTRA_DBS     [env_or EXTRA_DBS     ""]
set SYMBOL_LIB    [env_or SYMBOL_LIB    ""]

# Optional: Milkyway / TLUPlus for topographical mode. Leave empty for wire-load
# (non-topographical) synthesis.
set MW_REF_LIB    [env_or MW_REF_LIB    ""]
set MW_TECH_FILE  [env_or MW_TECH_FILE  ""]
set TLUPLUS_MAX   [env_or TLUPLUS_MAX   ""]
set TLUPLUS_MAP   [env_or TLUPLUS_MAP   ""]

# Operating conditions and wire load.
#
# Both default to EMPTY, which means "use whatever the library says". That is the
# right answer for a corner-specific .db -- e.g. sc9_cln40g_base_rvt_ss_typical_max_
# 0p81v_125c.db already *is* the slow corner, so naming it again with
# set_operating_conditions is redundant and just one more thing to get wrong.
#
# Set them only when your kit needs it. For the CBDK 0.13 um kit that is:
#   make synth OPCOND=slow OPCOND_LIBRARY=slow WIRE_LOAD_MODEL=tsmc13_wl10 WIRE_LOAD_LIB=slow
#
# Run `make libinfo` to see the operating condition and wire load model names your
# library actually defines. Many 40 nm and below libraries ship no wire load models
# at all -- leave WIRE_LOAD_MODEL empty there and, if you have the physical data,
# prefer `make synth-topo` over wire-load estimates.
set OPCOND          [env_or OPCOND          ""]
set OPCOND_LIBRARY  [env_or OPCOND_LIBRARY  ""]
set WIRE_LOAD_MODEL [env_or WIRE_LOAD_MODEL ""]
set WIRE_LOAD_LIB   [env_or WIRE_LOAD_LIB   ""]
set WIRE_LOAD_MODE  [env_or WIRE_LOAD_MODE  "top"]

# Reference cell used to convert area into gate equivalents (GE), so the result can
# be compared against a paper that used a different process node. Leave empty to
# auto-detect the smallest 2-input NAND (several naming conventions are tried); set
# it explicitly, e.g. NAND2_CELL="*/NAND2X1", if the guess is wrong for your library.
# `make libinfo` prints the candidates. If nothing matches, the GE line is omitted.
set NAND2_CELL    [env_or NAND2_CELL    ""]

# ---------------------------------------------------------------------------------------
# 2. Design under synthesis
# ---------------------------------------------------------------------------------------
#   horcrux_top_synth : full coprocessor (decode + datapath + commit), XIF flattened
#                       by implementation/design_compiler/rtl/horcrux_top_synth.sv.
#                       *** This is the block the paper characterises. ***
#   horcrux           : datapath only (Keccak, multiplier tree, sampler, SPHINCS+,
#                       Falcon FPR, Barrett). No SV interfaces at all -- use this if
#                       your DC version chokes on the internal if_xif.
set DESIGN_TOP    [env_or DESIGN_TOP    "horcrux_top_synth"]

# ---------------------------------------------------------------------------------------
# 3. Constraints
# ---------------------------------------------------------------------------------------
# Target clock period in ns.
#
# NOTE ON THE PAPER'S NUMBER: 160 MHz (6.25 ns) was measured on 65 nm CMOS, so it is
# only a sensible starting constraint on a comparable node. Measured here so far:
#   CBDK 0.13 um, slow corner : 13.9 ns (71.7 MHz) with IO_DELAY_FRAC=0.05
# Always use `make sweep` to find where the design actually lands on your library
# rather than assuming -- an unconverged run reports neither a usable fmax nor a
# usable area.
set CLK_PERIOD    [env_or CLK_PERIOD    "10.0"]
set CLK_NAME      "clk"
set CLK_PORT      "clk_i"
set RST_PORT      "rst_ni"

# Clock uncertainty (ns) - stands in for the clock-tree skew+jitter you have not
# built yet. 5% of the period is a reasonable pre-CTS guess.
set CLK_UNCERT    [env_or CLK_UNCERT    [expr {0.05 * $CLK_PERIOD}]]
# Hold uncertainty only has to cover clock skew, not jitter or design margin, so it
# is much smaller than the setup number. Using CLK_UNCERT for both is what produces
# a list of 20-30 ps pre-CTS hold violations that carry no information.
set CLK_UNCERT_HOLD [env_or CLK_UNCERT_HOLD [expr {0.2 * $CLK_UNCERT}]]
set CLK_LATENCY   [env_or CLK_LATENCY   [expr {0.10 * $CLK_PERIOD}]]
set CLK_TRAN      [env_or CLK_TRAN      "0.10"]

# Input/output delay as a fraction of the period, i.e. how much of the cycle the
# surrounding logic (the CV32E40Px core) is assumed to consume.
set IO_DELAY_FRAC [env_or IO_DELAY_FRAC "0.30"]

# Boundary electrical environment. Leave DRIVING_CELL empty to fall back to an
# ideal driver plus a fixed load -- fine for a first-order area/fmax number,
# optimistic for sign-off. Pick a mid-strength buffer from your library; run
# `report_lib <libname>` in dc_shell if you do not know the cell names.
set DRIVING_CELL  [env_or DRIVING_CELL  ""]
set DRIVING_PIN   [env_or DRIVING_PIN   ""]
set OUTPUT_LOAD   [env_or OUTPUT_LOAD   "0.05"]
set MAX_FANOUT    [env_or MAX_FANOUT    "16"]
set MAX_TRAN      [env_or MAX_TRAN      "0.30"]

# Async reset: recovery/removal checks are normally waived pre-CTS.
set RST_FALSE_PATH [env_or RST_FALSE_PATH "1"]

# ---------------------------------------------------------------------------------------
# 4. Compile options
# ---------------------------------------------------------------------------------------
set MAX_CORES     [env_or MAX_CORES     "4"]

# 1 = compile_ultra, 0 = plain compile -map_effort high.
set USE_ULTRA     [env_or USE_ULTRA     "1"]

# Keep the module hierarchy so report_area -hierarchy gives you a per-block
# breakdown (Keccak vs multiplier vs sampler ...). Set to 0 to let DC ungroup
# freely, which usually buys a little timing at the cost of readable reports.
set KEEP_HIER     [env_or KEEP_HIER     "1"]

# Clock gating needs an integrated clock-gating cell in the library. Off by
# default because the cell name is PDK specific.
set CLOCK_GATING  [env_or CLOCK_GATING  "0"]

# Second incremental pass. Costs runtime, usually recovers some negative slack.
set INCREMENTAL   [env_or INCREMENTAL   "1"]

# Retiming across pipeline registers. Off by default: it makes the netlist much
# harder to correlate with the RTL hierarchy.
set RETIME        [env_or RETIME        "0"]

# CBDK dc_syn.tcl idioms, on by default to match your lab's reference flow:
#   set_fix_hold [all_clocks]                      -> hold fixing during compile
#   set_fix_multiple_port_nets -all -buffer_constants
#   set high_fanout_net_threshold 0
# FIX_HOLD adds buffers, so it inflates area slightly. Turn it off (FIX_HOLD=0) if
# you want the leanest possible area number for a paper.
set FIX_HOLD      [env_or FIX_HOLD      "1"]
set FIX_MPN       [env_or FIX_MPN       "1"]
set HIGH_FANOUT   [env_or HIGH_FANOUT   "0"]

# Name rules applied by change_names before writing the netlist. "verilog" is the
# safest for post-synthesis simulation. Your synopsys.setup also defines a custom
# "name_rule"; pass CHANGE_NAMES_RULES=name_rule to use it instead.
set CHANGE_NAMES_RULES [env_or CHANGE_NAMES_RULES "verilog"]

# ---------------------------------------------------------------------------------------
# 5. Output paths  (REPO_ROOT / DC_DIR are set in section 0)
# ---------------------------------------------------------------------------------------
# Output goes to implementation/synthesis/<run>/, with last_output pointing at the
# newest run. That is the layout scripts/check_log_synth.sh already expects.
set RUN_NAME      [env_or RUN_NAME      "${DESIGN_TOP}_[format %s [clock format [clock seconds] -format %Y%m%d_%H%M%S]]"]
set OUT_ROOT      [file join $REPO_ROOT implementation synthesis]
set OUT_DIR       [file join $OUT_ROOT $RUN_NAME]
set REPORT_DIR    [file join $OUT_DIR report]
set NETLIST_DIR   [file join $OUT_DIR netlist]
