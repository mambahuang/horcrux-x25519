## Task 5 -- genuine post-route area/timing for the HORCRUX coprocessor alone,
## on the Pynq-Z2 part.
##
## Rationale: the full SoC is 95,135 LUTs on a 53,200-LUT Z020 and can never be
## placed, which is why every M0 SoC number is a synthesis estimate. horcrux_top
## on its own is ~21.7 kLUT / 4.5 kFF / 11 DSP -- about 41% of the Z020 -- so it
## fits comfortably and CAN be placed and routed here, no UltraScale+ device
## files required.
##
##   vivado -mode batch -source reports/m0_followup/task5_pnr_horcrux_z020.tcl \
##          -tclargs <tag> <period_ns> [<unified_mul_rtl>]
##
## Run from the repo root. Default period 45 ns (the post-fix SoC critical path
## is 47.905 ns, so this is tight but not absurd for the coprocessor alone).

set tag    [expr {[llength $argv] > 0 ? [lindex $argv 0] : "horcrux"}]
set period [expr {[llength $argv] > 1 ? [lindex $argv 1] : 45.0}]

## <unified_mul_rtl> swaps in a different unified_mul_32x32.sv so the M0
## before/after multiplier change can be compared at coprocessor level:
##   before: reports/m0_followup/task5_unified_mul_before.sv  (6c9f3e9^)
##   after : hw/ip/coprocessors/unified_mul_32x32.sv          (the default)
set mulrtl [expr {[llength $argv] > 2 ? [lindex $argv 2] : "hw/ip/coprocessors/unified_mul_32x32.sv"}]

set part   xc7z020clg400-1
set outdir reports/m0_followup
file mkdir $outdir

# Packages first, then the interface, then the coprocessor RTL in the order
# hw/ip/coproc.core lists it, then the harness.
set srcs {
    hw/vendor/x-heep/hw/vendor/openhwgroup_cv32e40x/rtl/include/cv32e40x_pkg.sv
    hw/ip/coprocessors/include/cv32e40px_pkg.sv
    hw/ip/coprocessors/include/cv32e40px_core_v_xif_pkg.sv
    hw/vendor/x-heep/hw/vendor/openhwgroup_cv32e40x/rtl/if_xif.sv
    hw/ip/coprocessors/include/horcrux_pkg.sv
    hw/ip/coprocessors/sampler.sv
    hw/ip/coprocessors/keccak/pkg_keccak.sv
    hw/ip/coprocessors/keccak/keccak_cu.sv
    hw/ip/coprocessors/keccak/keccak_dp.sv
    hw/ip/coprocessors/keccak/keccak_round_constants_gen.sv
    hw/ip/coprocessors/keccak/keccak_round.sv
    hw/ip/coprocessors/keccak/keccak_f.sv
    hw/ip/coprocessors/horcrux_register.sv
__MULRTL__
    hw/ip/coprocessors/shared_multiplication_logic.sv
    hw/ip/coprocessors/fpr.sv
    hw/ip/coprocessors/multiplier_tree.sv
    hw/ip/coprocessors/barrett.sv
    hw/ip/coprocessors/chain_lengths.sv
    hw/ip/coprocessors/sphincs_ops.sv
    hw/ip/coprocessors/commit_stage.sv
    hw/ip/coprocessors/id_stage.sv
    hw/ip/coprocessors/horcrux.sv
    hw/ip/coprocessors/horcrux_top.sv
    reports/m0_followup/horcrux_char_wrapper.sv
}
set srcs [lreplace $srcs [lsearch $srcs __MULRTL__] [lsearch $srcs __MULRTL__] $mulrtl]

puts "TASK5 tag=$tag part=$part period=$period mul=$mulrtl"
foreach f $srcs { read_verilog -sv $f }

synth_design -top horcrux_char_wrapper -part $part
create_clock -period $period -name clk [get_ports clk]

# Post-synthesis, before any physical optimisation: this is the number directly
# comparable to the SoC util_hier.rpt figure of 21,688 LUT.
report_utilization -hierarchical -file $outdir/task5_${tag}_synth_util_hier.rpt
report_utilization              -file $outdir/task5_${tag}_synth_util.rpt

opt_design
place_design
phys_opt_design
route_design

report_utilization -hierarchical -file $outdir/task5_${tag}_routed_util_hier.rpt
report_utilization              -file $outdir/task5_${tag}_routed_util.rpt
report_timing_summary           -file $outdir/task5_${tag}_routed_summary.rpt
report_timing -delay_type max -max_paths 10 -nworst 10 \
    -file $outdir/task5_${tag}_routed_paths.rpt

set wns [get_property -quiet SLACK [get_timing_paths -max_paths 1 -delay_type max]]
puts "RESULT tag=$tag period=$period WNS=$wns"
if {$wns ne ""} { puts "RESULT tag=$tag fmax_MHz=[expr {1000.0/($period - $wns)}]" }
puts "RESULT tag=$tag DSPs=[llength [get_cells -quiet -hier -filter {PRIMITIVE_TYPE =~ *DSP*}]]"

write_checkpoint -force $outdir/task5_${tag}_routed.dcp

# Unplaced cells would mean the run did not really place -- check, don't assume.
# GND/VCC tie-offs never get a site and must be excluded, or the check cries
# wolf on every healthy run.
set unpl [get_cells -quiet -hier -filter     {IS_PRIMITIVE && STATUS == UNPLACED && REF_NAME != GND && REF_NAME != VCC}]
puts "RESULT tag=$tag unplaced=[llength $unpl]"
foreach c $unpl { puts "  UNPLACED [get_property REF_NAME $c] $c" }
puts "RESULT tag=$tag tieoffs=[llength [get_cells -quiet -hier -filter     {IS_PRIMITIVE && STATUS == UNPLACED && (REF_NAME == GND || REF_NAME == VCC)}]]"
puts "TASK5 \[$tag\] DONE"
