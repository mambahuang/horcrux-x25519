##########################################################################################
# HORCRUX ASIC synthesis - source file list
#
# Order matters: `analyze` compiles one file at a time, so every package and
# interface must be analyzed before the first module that references it.
#
# The module list mirrors the `horcrux_sv` fileset in hw/ip/coproc.core, which is
# the authoritative build list for the coprocessor. Note that cbd_eta.sv exists in
# hw/ip/coprocessors/ but is deliberately NOT in that fileset (nothing instantiates
# it), so it is not synthesized here either.
##########################################################################################

set COPROC   [file join $REPO_ROOT hw ip coprocessors]
set CV32E40X [file join $REPO_ROOT hw vendor x-heep hw vendor openhwgroup_cv32e40x rtl]

# ---- Packages (must come first) --------------------------------------------------------
set RTL_PKGS [list \
  [file join $CV32E40X include cv32e40x_pkg.sv]        \
  [file join $COPROC   include cv32e40px_pkg.sv]       \
  [file join $COPROC   include cv32e40px_core_v_xif_pkg.sv] \
  [file join $COPROC   include horcrux_pkg.sv]         \
  [file join $COPROC   keccak  pkg_keccak.sv]          \
]

# ---- CORE-V XIF interface --------------------------------------------------------------
# Only needed when DESIGN_TOP is horcrux_top_synth / horcrux_top / coproc_wrapper.
set RTL_IFACE [list \
  [file join $CV32E40X if_xif.sv] \
]

# ---- Design modules --------------------------------------------------------------------
set RTL_SRCS [list \
  [file join $COPROC sampler.sv]                        \
  [file join $COPROC keccak keccak_cu.sv]               \
  [file join $COPROC keccak keccak_dp.sv]               \
  [file join $COPROC keccak keccak_round_constants_gen.sv] \
  [file join $COPROC keccak keccak_round.sv]            \
  [file join $COPROC keccak keccak_f.sv]                \
  [file join $COPROC horcrux_register.sv]               \
  [file join $COPROC unified_mul_32x32.sv]              \
  [file join $COPROC shared_multiplication_logic.sv]    \
  [file join $COPROC fpr.sv]                            \
  [file join $COPROC multiplier_tree.sv]                \
  [file join $COPROC barrett.sv]                        \
  [file join $COPROC chain_lengths.sv]                  \
  [file join $COPROC sphincs_ops.sv]                    \
  [file join $COPROC commit_stage.sv]                   \
  [file join $COPROC id_stage.sv]                       \
  [file join $COPROC horcrux.sv]                        \
  [file join $COPROC horcrux_top.sv]                    \
  [file join $COPROC coproc_wrapper.sv]                 \
]

# ---- Synthesis-only boundary wrapper ---------------------------------------------------
set RTL_WRAPPER [list \
  [file join $DC_DIR rtl horcrux_top_synth.sv] \
]

# ---- Assemble, depending on the chosen top ---------------------------------------------
# `horcrux` is pure logic with packed-struct ports and needs neither if_xif nor the
# modules that consume it, so we can skip both and keep the analyze step clean.
if {$DESIGN_TOP eq "horcrux"} {
  set ANALYZE_FILES [concat $RTL_PKGS \
    [lsearch -all -inline -not -glob $RTL_SRCS "*commit_stage.sv"]]
  set ANALYZE_FILES [lsearch -all -inline -not -glob $ANALYZE_FILES "*id_stage.sv"]
  set ANALYZE_FILES [lsearch -all -inline -not -glob $ANALYZE_FILES "*horcrux_top.sv"]
  set ANALYZE_FILES [lsearch -all -inline -not -glob $ANALYZE_FILES "*coproc_wrapper.sv"]
} else {
  set ANALYZE_FILES [concat $RTL_PKGS $RTL_IFACE $RTL_SRCS $RTL_WRAPPER]
}

# Fail loudly and early rather than halfway through analyze.
set _missing {}
foreach f $ANALYZE_FILES {
  if {![file exists $f]} { lappend _missing $f }
}
if {[llength $_missing] > 0} {
  puts "ERROR: source files not found:"
  foreach f $_missing { puts "  $f" }
  exit 1
}
