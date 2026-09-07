## Post-synthesis queries on the Experiment 1 SoC run.
## Gets the register-to-register worst path in the main clock domain (directly
## comparable to M0's 97.231 ns) and the multiplier's own worst path.

set rundir build/polito_vlsi_crheepto_0/pynq-z2-vivado-exp1/polito_vlsi_crheepto_0.runs/synth_1
set outdir build/polito_vlsi_crheepto_0/pynq-z2-vivado-exp1/reports

open_checkpoint $rundir/xilinx_crheepto_wrapper.dcp

# Register-to-register only: excludes the SPI/JTAG I/O paths that now dominate
# the raw worst-path list but are unrelated to the coprocessor.
report_timing -from [all_registers] -to [all_registers] \
    -delay_type max -max_paths 10 -nworst 10 \
    -file $outdir/reg2reg_max10.rpt

# The multiplier's own worst path, wherever it now ranks.
report_timing -through [get_cells -hier -filter {NAME =~ "*u_primary_mul*"}] \
    -delay_type max -max_paths 5 \
    -file $outdir/primary_mul_path.rpt

report_utilization -hierarchical -file $outdir/util_hier_full.rpt

set dsps [get_cells -hier -filter {PRIMITIVE_TYPE =~ *DSP*}]
set fh [open $outdir/dsp_cells.rpt w]
puts $fh "DSP count: [llength $dsps]"
foreach c $dsps { puts $fh $c }
close $fh

puts "QUERIES DONE -> $outdir/"
