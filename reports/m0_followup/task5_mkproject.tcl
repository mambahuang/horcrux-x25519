## Builds a Vivado PROJECT for the horcrux_top characterisation harness, so the
## same run can be driven from the GUI (Run Synthesis / Run Implementation
## buttons, schematic, device view, timing browser) instead of batch Tcl.
##
##   vivado -mode batch -source reports/m0_followup/task5_mkproject.tcl \
##          -tclargs <tag> <period_ns> [<unified_mul_rtl>]
##
## Then open the project in the GUI:
##   vivado build/task5_gui_<tag>/task5_gui_<tag>.xpr
##
## Run from the repo root. The source list is deliberately a copy of the one in
## task5_pnr_horcrux_z020.tcl -- keep the two in sync if files are added.

set tag    [expr {[llength $argv] > 0 ? [lindex $argv 0] : "horcrux"}]
set period [expr {[llength $argv] > 1 ? [lindex $argv 1] : 45.0}]
set mulrtl [expr {[llength $argv] > 2 ? [lindex $argv 2] : "hw/ip/coprocessors/unified_mul_32x32.sv"}]

set root [pwd]
set proj build/task5_gui_$tag

create_project -force task5_gui_$tag $proj -part xc7z020clg400-1

set srcs [list \
    hw/vendor/x-heep/hw/vendor/openhwgroup_cv32e40x/rtl/include/cv32e40x_pkg.sv \
    hw/ip/coprocessors/include/cv32e40px_pkg.sv \
    hw/ip/coprocessors/include/cv32e40px_core_v_xif_pkg.sv \
    hw/vendor/x-heep/hw/vendor/openhwgroup_cv32e40x/rtl/if_xif.sv \
    hw/ip/coprocessors/include/horcrux_pkg.sv \
    hw/ip/coprocessors/sampler.sv \
    hw/ip/coprocessors/keccak/pkg_keccak.sv \
    hw/ip/coprocessors/keccak/keccak_cu.sv \
    hw/ip/coprocessors/keccak/keccak_dp.sv \
    hw/ip/coprocessors/keccak/keccak_round_constants_gen.sv \
    hw/ip/coprocessors/keccak/keccak_round.sv \
    hw/ip/coprocessors/keccak/keccak_f.sv \
    hw/ip/coprocessors/horcrux_register.sv \
    $mulrtl \
    hw/ip/coprocessors/shared_multiplication_logic.sv \
    hw/ip/coprocessors/fpr.sv \
    hw/ip/coprocessors/multiplier_tree.sv \
    hw/ip/coprocessors/barrett.sv \
    hw/ip/coprocessors/chain_lengths.sv \
    hw/ip/coprocessors/sphincs_ops.sv \
    hw/ip/coprocessors/commit_stage.sv \
    hw/ip/coprocessors/id_stage.sv \
    hw/ip/coprocessors/horcrux.sv \
    hw/ip/coprocessors/horcrux_top.sv \
    reports/m0_followup/horcrux_char_wrapper.sv \
]

foreach f $srcs { add_files -norecurse -fileset sources_1 [file join $root $f] }
set_property file_type SystemVerilog [get_files -of_objects [get_filesets sources_1]]
set_property top horcrux_char_wrapper [get_filesets sources_1]

# In project mode the XDC is read before synthesis too, so unlike the batch
# script the constraint is active for synth_design as well as implementation.
set xdcfile $proj/task5_$tag.xdc
set fh [open $xdcfile w]
puts $fh "create_clock -period $period -name clk \[get_ports clk\]"
close $fh
add_files -fileset constrs_1 -norecurse $xdcfile

puts "PROJECT  = [file normalize $proj/task5_gui_$tag.xpr]"
puts "TOP      = [get_property top [get_filesets sources_1]]"
puts "PART     = [get_property part [current_project]]"
puts "MUL RTL  = $mulrtl"
puts "PERIOD   = $period ns"
puts "TASK5-MKPROJECT DONE -- open it with: vivado [file normalize $proj/task5_gui_$tag.xpr]"
