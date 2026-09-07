## Experiment 1 — full-SoC synthesis with the rewritten unified_mul_32x32.
##
## The OOC numbers (93.953 -> 44.921 ns) are not comparable to the SoC's
## 97.231 ns critical path. This re-runs M0's SoC synthesis flow so the two
## can be compared directly.
##
## Run from the Vivado checkout root
## (C:/Users/P76144118/Downloads/horcrux-x25519-vivado):
##   vivado -mode batch -source <this file>
##
## Operates on a COPY of M0's project (pynq-z2-vivado-exp1) so the original
## baseline run stays intact.

set proj build/polito_vlsi_crheepto_0/pynq-z2-vivado-exp1/polito_vlsi_crheepto_0.xpr
set outdir build/polito_vlsi_crheepto_0/pynq-z2-vivado-exp1/reports

open_project $proj
file mkdir $outdir

# M0's OOC experiments mutated this project: the top was left as
# multiplier_tree (so a plain launch_runs synthesises the bare module, not the
# SoC) and an OOC wrapper source that no longer exists is still in the fileset.
# Undo both before synthesising.
set stale [get_files -quiet *multiplier_tree_ooc_wrapper.sv]
if {[llength $stale] > 0} {
    remove_files $stale
    puts "removed stale OOC wrapper from fileset"
}
set_property top xilinx_crheepto_wrapper [get_filesets sources_1]

puts "TOP  = [get_property top [get_filesets sources_1]]"
puts "PART = [get_property part [current_project]]"

reset_run synth_1
launch_runs synth_1 -jobs 4
wait_on_run synth_1

if {[regexp -nocase -- {synth_design (error|failed)} \
        [get_property STATUS [get_runs synth_1]] match]} {
    puts "SYNTHESIS FAILED"
    exit 1
}

open_run synth_1 -name synth_1

# Same report command M0 used, so the two are directly comparable.
report_timing -delay_type max -max_paths 20 -nworst 20 \
    -path_type full_clock_expanded \
    -file $outdir/timing_max20.rpt
report_timing_summary -file $outdir/timing_summary.rpt
report_utilization -file $outdir/util.rpt
report_utilization -hierarchical -file $outdir/util_hier.rpt

# Where the DSPs landed, and whether u_primary_mul got any this time.
set dsps [get_cells -hier -filter {PRIMITIVE_TYPE =~ *DSP*}]
set fh [open $outdir/dsp_cells.rpt w]
puts $fh "DSP count: [llength $dsps]"
foreach c $dsps { puts $fh $c }
close $fh

puts "SOC SYNTH DONE -> $outdir/"
