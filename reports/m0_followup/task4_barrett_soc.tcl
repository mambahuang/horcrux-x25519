## Task 4 — is the Barrett unit really absent from the netlist?
##
## M0 reported `get_cells -hier -filter {NAME =~ "*barrett*"}` returning zero
## and concluded a genuine absence. But barrett_result also feeds OP_BFINTTK
## (multiplier_tree.sv:269), and tests/kyber-intt passes in RTL simulation --
## so the logic cannot actually be missing. This checks how it is named
## instead.

set outdir build/polito_vlsi_crheepto_0/pynq-z2-vivado-exp1/reports
set dcp build/polito_vlsi_crheepto_0/pynq-z2-vivado-exp1/polito_vlsi_crheepto_0.runs/synth_1/xilinx_crheepto_wrapper.dcp

open_checkpoint $dcp

set fh [open $outdir/task4_barrett_soc.rpt w]

proc emit {fh msg} { puts $fh $msg ; puts $msg }

emit $fh "=== M0's original query ==="
emit $fh "cells matching *barrett* : [llength [get_cells -quiet -hier -filter {NAME =~ *barrett*}]]"
emit $fh "nets  matching *barrett* : [llength [get_nets  -quiet -hier -filter {NAME =~ *barrett*}]]"
emit $fh "cells matching *kyber*   : [llength [get_cells -quiet -hier -filter {NAME =~ *kyber*}]]"

# The instance is `barrett kyber_barrett_inst`, so if the hierarchy survived at
# all these would hit. If they are all zero the boundary dissolved -- look for
# the logic by what it drives instead.
emit $fh ""
emit $fh "=== does the barrett_result net survive under any name? ==="
foreach pat {*barrett_result* *hqc_r* *hqc_q* *z_kyber* *m_kyber* *hqc_mu_sum* *hqc_n_sum*} {
    emit $fh "  nets $pat : [llength [get_nets -quiet -hier -filter "NAME =~ $pat"]]"
}

# OP_BFINTTK routes barrett_result into result_o[15:0]. Whatever computes it
# has to be in that cone, so walk back from the multiplier tree's output.
emit $fh ""
emit $fh "=== fan-in cone of multiplier_tree result_o ==="
set ro [get_nets -quiet -hier -filter {NAME =~ *multiplier_tree_inst*result_o*}]
emit $fh "  result_o nets found: [llength $ro]"

# barrett.sv is pure shift/add/compare on `a`, so its logic should appear as
# LUT/CARRY4 driving the low half of the Kyber INTT result.
set bf [get_cells -quiet -hier -filter {NAME =~ *BFINTTK* || NAME =~ *bfinttk*}]
emit $fh "  cells named *BFINTTK*: [llength $bf]"

emit $fh ""
emit $fh "=== sanity: is the multiplier tree itself present? ==="
emit $fh "  cells under multiplier_tree_inst: [llength [get_cells -quiet -hier -filter {NAME =~ *multiplier_tree_inst*}]]"
emit $fh "  cells under u_shared_mul        : [llength [get_cells -quiet -hier -filter {NAME =~ *u_shared_mul*}]]"

close $fh
puts "TASK4 SOC QUERY DONE -> $outdir/task4_barrett_soc.rpt"
