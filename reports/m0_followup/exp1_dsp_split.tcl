## Experiment 1 — does splitting the integer / carry-less paths in
## unified_mul_32x32 let Vivado infer DSP48E1 for the raw a*b multiply?
##
## Replicates M0's corrected OOC methodology exactly (create_clock and
## set_max_delay BEFORE opt_design) so results are comparable to
## M0_FINDINGS.md's OOC baseline: 5,845 LUT / 11 DSP / 93.795 ns.
##
## Usage:
##   vivado -mode batch -source reports/m0_followup/exp1_dsp_split.tcl -tclargs <tag>
## where <tag> is e.g. "before" or "after".

set tag [lindex $argv 0]
if {$tag eq ""} { set tag "run" }

set part   xc7z020clg400-1
set outdir reports/m0_followup

read_verilog -sv hw/ip/coprocessors/include/horcrux_pkg.sv
read_verilog -sv hw/ip/coprocessors/unified_mul_32x32.sv
read_verilog -sv hw/ip/coprocessors/shared_multiplication_logic.sv
read_verilog -sv hw/ip/coprocessors/barrett.sv
read_verilog -sv hw/ip/coprocessors/multiplier_tree.sv

synth_design -top multiplier_tree -part $part -mode out_of_context

create_clock -period 20.000 -name clk [get_ports clk_i]
set_max_delay 20.000 -from [all_inputs] -to [all_outputs]
opt_design

report_timing -delay_type max -max_paths 10 \
    -file $outdir/exp1_${tag}_timing.rpt
report_utilization \
    -file $outdir/exp1_${tag}_util.rpt
report_utilization -hierarchical \
    -file $outdir/exp1_${tag}_util_hier.rpt

# Where did the DSPs land, and did u_primary_mul get any?
set dsps [get_cells -hier -filter {PRIMITIVE_TYPE =~ *DSP*}]
set fh [open $outdir/exp1_${tag}_dsp_cells.rpt w]
puts $fh "DSP count: [llength $dsps]"
foreach c $dsps { puts $fh $c }
puts $fh "----"
puts $fh "cells under u_primary_mul: [llength [get_cells -hier -filter {NAME =~ *u_primary_mul*}]]"
close $fh

puts "EXP1 \[$tag\] done -> $outdir/exp1_${tag}_*"
