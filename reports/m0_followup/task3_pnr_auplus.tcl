## Task 3 — genuine post-route numbers via the register-wrapped harness,
## on Artix UltraScale+ (16 nm, DSP48E2) rather than the Z020 proxy.
##
##   vivado -mode batch -source task3_pnr_auplus.tcl -tclargs <tag> <rtl> <period>
##
## <tag>    label for the report files, e.g. before / after
## <rtl>    path to the unified_mul_32x32.sv to use
## <period> clock period in ns
##
## Same part family and speed grade as the paper's ZCU104 (16 nm, -2, DSP48E2),
## which the Z020 could match on neither count, and large enough to place and
## route -- the whole reason M0 could never get past synthesis estimates.

set tag    [lindex $argv 0]
set rtl    [lindex $argv 1]
set period [lindex $argv 2]

set part   xcau25p-ffvb676-2-e
set outdir reports/m0_followup

read_verilog -sv hw/ip/coprocessors/include/horcrux_pkg.sv
read_verilog -sv $rtl
read_verilog -sv hw/ip/coprocessors/shared_multiplication_logic.sv
read_verilog -sv hw/ip/coprocessors/barrett.sv
read_verilog -sv hw/ip/coprocessors/multiplier_tree.sv
read_verilog -sv $outdir/mt_char_wrapper.sv

synth_design -top mt_char_wrapper -part $part

create_clock -period $period -name clk [get_ports clk]

opt_design
place_design
phys_opt_design
route_design

report_timing_summary -file $outdir/task3_${tag}_routed_summary.rpt
report_timing -delay_type max -max_paths 10 -nworst 10 \
    -file $outdir/task3_${tag}_routed_paths.rpt
report_utilization -hierarchical -file $outdir/task3_${tag}_routed_util.rpt

set wns [get_property -quiet SLACK [get_timing_paths -max_paths 1 -delay_type max]]
puts "RESULT tag=$tag period=$period WNS=$wns"

set dsps [get_cells -quiet -hier -filter {PRIMITIVE_TYPE =~ *DSP*}]
puts "RESULT tag=$tag DSPs=[llength $dsps]"
puts "TASK3 \[$tag\] DONE"
