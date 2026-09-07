## Task 4, part 2 — what are the Barrett cells actually called?
##
## The nets keep their RTL names (barrett_result, hqc_r, z_kyber) but
## `get_cells *barrett*` finds nothing, so the leaf cells must have been named
## after something else. This samples the drivers to show what.

set outdir build/polito_vlsi_crheepto_0/pynq-z2-vivado-exp1/reports
set dcp build/polito_vlsi_crheepto_0/pynq-z2-vivado-exp1/polito_vlsi_crheepto_0.runs/synth_1/xilinx_crheepto_wrapper.dcp

open_checkpoint $dcp

set fh [open $outdir/task4_barrett_names.rpt w]
proc emit {fh msg} { puts $fh $msg ; puts $msg }

emit $fh "=== sample barrett_result nets and the cells driving them ==="
set nets [lrange [get_nets -quiet -hier -filter {NAME =~ *barrett_result*}] 0 5]
foreach n $nets {
    set drv [get_cells -quiet -of_objects [get_pins -quiet -leaf -of_objects $n -filter {DIRECTION == OUT}]]
    emit $fh "NET  $n"
    foreach d $drv { emit $fh "  DRIVEN BY  $d   ([get_property -quiet REF_NAME $d])" }
}

emit $fh ""
emit $fh "=== sample z_kyber nets (Kyber Barrett intermediate) ==="
foreach n [lrange [get_nets -quiet -hier -filter {NAME =~ *z_kyber*}] 0 3] {
    set drv [get_cells -quiet -of_objects [get_pins -quiet -leaf -of_objects $n -filter {DIRECTION == OUT}]]
    emit $fh "NET  $n"
    foreach d $drv { emit $fh "  DRIVEN BY  $d   ([get_property -quiet REF_NAME $d])" }
}

emit $fh ""
emit $fh "=== how big is the Barrett cone? ==="
set bcells {}
foreach n [get_nets -quiet -hier -filter {NAME =~ *barrett_result* || NAME =~ *hqc_r* || NAME =~ *z_kyber*}] {
    foreach c [get_cells -quiet -of_objects [get_pins -quiet -leaf -of_objects $n -filter {DIRECTION == OUT}]] {
        lappend bcells $c
    }
}
set bcells [lsort -unique $bcells]
emit $fh "  distinct driver cells: [llength $bcells]"
close $fh
puts "TASK4 NAMES DONE"
