##########################################################################################
# HORCRUX ASIC synthesis - Synopsys Design Compiler flow
#
# Usage (normally via the Makefile in this directory):
#   dc_shell -f implementation/design_compiler/dc_script.tcl
#   dc_shell -topographical_mode -f implementation/design_compiler/dc_script.tcl
#
# Configuration lives in setup.tcl. Source list lives in filelist.tcl.
# Constraints live in constraints.tcl.
#
# The library setup is expected to come from your lab's synopsys.setup, sourced via
# the SYNOPSYS_SETUP variable. See setup.tcl.
##########################################################################################

set SCRIPT_DIR [file dirname [file normalize [info script]]]
source [file join $SCRIPT_DIR setup.tcl]

set_app_var sh_continue_on_error false
set_app_var sh_enable_page_mode  false

puts "########################################################################"
puts "### HORCRUX synthesis"
puts "###   top          : $DESIGN_TOP"
puts "###   clock period : $CLK_PERIOD ns"
puts "###   run dir      : $OUT_DIR"
puts "###   topographical: [expr {[shell_is_in_topographical_mode] ? {yes} : {no}}]"
puts "########################################################################"

# ---------------------------------------------------------------------------------------
# Libraries
# ---------------------------------------------------------------------------------------
# Cache the alib next to the scripts so repeat runs skip the library analysis step.
# Must be set before the libraries are read.
set_app_var alib_library_analysis_path [file join $SCRIPT_DIR .alib]

if {[string length $SYNOPSYS_SETUP] > 0} {
  if {![file exists $SYNOPSYS_SETUP]} {
    puts "ERROR: SYNOPSYS_SETUP does not exist: $SYNOPSYS_SETUP"
    puts "       (dc_shell cwd is [pwd], which is the run directory --"
    puts "        a relative path is resolved against $DC_DIR instead)"
    exit 1
  }
  puts "### Sourcing lab setup: $SYNOPSYS_SETUP"
  # Lab setup files often carry interactive conveniences (sh_enable_line_editing,
  # history, alias) that can complain in batch mode. Do not let those abort the run;
  # a genuinely broken setup is caught by the target_library check below instead.
  set_app_var sh_continue_on_error true
  if {[catch {source $SYNOPSYS_SETUP} _err]} {
    puts "### WARNING while sourcing $SYNOPSYS_SETUP: $_err"
  }
  set_app_var sh_continue_on_error false

  # The CIC kit ships a file that is a setup *and* a complete synthesis script in
  # one (read_file / current_design / compile / write / report_*). If someone points
  # SYNOPSYS_SETUP at it unedited, it will have read some unrelated design by now.
  # Drop anything it loaded so the run below starts from a clean slate, and say so.
  catch {
    if {[sizeof_collection [get_designs -quiet *]] > 0} {
      puts "### WARNING: $SYNOPSYS_SETUP left designs loaded -- it looks like a"
      puts "###          combined setup+synthesis script, not a pure setup file."
      puts "###          Discarding them. Trim everything from the first read_file"
      puts "###          onwards out of that file."
      remove_design -all
    }
  }
} else {
  puts "### No SYNOPSYS_SETUP given and no synopsys.setup in $DC_DIR;"
  puts "###   relying on DC to find a .synopsys_dc.setup, or on STD_CELL_DB below."
}

if {[string length $STD_CELL_DB] > 0} {
  # Explicit library route: build the variables here.
  if {![file exists $STD_CELL_DB]} {
    puts "ERROR: STD_CELL_DB does not exist: $STD_CELL_DB"
    exit 1
  }
  set_app_var target_library    [concat [list $STD_CELL_DB] $EXTRA_DBS]
  set_app_var synthetic_library [list dw_foundation.sldb]
  set_app_var link_library      [concat "*" $target_library $synthetic_library]
  if {[string length $SYMBOL_LIB] > 0} { set_app_var symbol_library [list $SYMBOL_LIB] }
}

# Verify the libraries actually resolve. Checking only for a non-empty
# target_library is not enough: Synopsys ships a factory .synopsys_dc.setup whose
# target_library is the placeholder "your_library.db", so a run with no real setup
# sails past an emptiness test and then fails much later with nothing but a stream
# of "Can't read link_library file" warnings.
proc resolve_on_search_path {f} {
  if {[file pathtype $f] eq "absolute"} {
    return [expr {[file exists $f] ? $f : ""}]
  }
  foreach d $::search_path {
    set p [file join $d $f]
    if {[file exists $p]} { return $p }
  }
  return ""
}

set _bad_libs {}
foreach _lib $target_library {
  if {[resolve_on_search_path $_lib] eq ""} { lappend _bad_libs $_lib }
}

if {[llength $target_library] == 0 || [llength $_bad_libs] > 0} {
  puts "########################################################################"
  if {[llength $target_library] == 0} {
    puts "ERROR: target_library is empty."
  } else {
    puts "ERROR: target_library names libraries that cannot be found on search_path:"
    foreach _lib $_bad_libs { puts "         $_lib" }
    if {[lsearch -exact $_bad_libs "your_library.db"] >= 0} {
      puts ""
      puts "       \"your_library.db\" is the Synopsys factory placeholder, which means"
      puts "       your lab setup was never sourced -- DC fell back to its own default."
    }
  }
  puts ""
  puts "       search_path is:"
  foreach _d $::search_path { puts "         $_d" }
  puts ""
  puts "       Fix by putting synopsys.setup in"
  puts "         $DC_DIR"
  puts "       (it is picked up automatically), or by naming it:"
  puts "         make synth SYNOPSYS_SETUP=/path/to/synopsys.setup"
  puts "       or by naming a .db directly:"
  puts "         make synth STD_CELL_DB=/usr/cad/designkit/.../db/slow.db"
  puts "########################################################################"
  exit 1
}

puts "### target_library : $target_library"
foreach _lib $target_library { puts "###   -> [resolve_on_search_path $_lib]" }
puts "### link_library   : $link_library"

if {[shell_is_in_topographical_mode]} {
  if {[string length $MW_REF_LIB] > 0} {
    if {[string length $MW_TECH_FILE] == 0} {
      puts "ERROR: topographical mode with MW_REF_LIB also needs MW_TECH_FILE (.tf)"
      exit 1
    }
    create_mw_lib -technology $MW_TECH_FILE -mw_reference_library $MW_REF_LIB \
                  [file join $OUT_DIR mw_lib]
    open_mw_lib [file join $OUT_DIR mw_lib]
  } else {
    puts "### WARNING: topographical mode without MW_REF_LIB; DC will fall back to"
    puts "###          wire-load estimates. Set MW_REF_LIB/MW_TECH_FILE/TLUPLUS_* for"
    puts "###          real physical-aware synthesis."
  }
  if {[string length $TLUPLUS_MAX] > 0} {
    set_tlu_plus_files -max_tluplus $TLUPLUS_MAX -tech2itf_map $TLUPLUS_MAP
  }
}

if {[string length $MAX_CORES] > 0 && $MAX_CORES > 1} {
  set_host_options -max_cores $MAX_CORES
}

# ---------------------------------------------------------------------------------------
# Directories
# ---------------------------------------------------------------------------------------
file mkdir $REPORT_DIR
file mkdir $NETLIST_DIR
set WORK_DIR [file join $OUT_DIR work]
file mkdir $WORK_DIR
define_design_lib WORK -path $WORK_DIR

# ---------------------------------------------------------------------------------------
# Elaboration behaviour
# ---------------------------------------------------------------------------------------
# Infer async set/reset from "always @(posedge clk_i or negedge rst_ni)", the style
# used throughout hw/ip/coprocessors/.
set_app_var hdlin_ff_always_async_set_reset true
# Report anything that infers a latch. This RTL should infer none; if the check fires,
# fix the offending always_comb before trusting any timing number below.
set_app_var hdlin_check_no_latch true
set_app_var verilogout_no_tri true

# Netlist naming, matching the CIC kit conventions, so the gate-level netlist drops
# straight into ncverilog alongside the library's _udp.v / _neg.v models. Harmless
# if your synopsys.setup already sets the same values. Wrapped because a variable
# name that a given DC release does not know would otherwise abort the run.
foreach {_v _val} {
  bus_inference_style        {%s[%d]}
  bus_naming_style           {%s[%d]}
  hdlout_internal_busses     true
} {
  if {[catch {set_app_var $_v $_val} _e]} {
    puts "### NOTE: could not set $_v ($_e)"
  }
}

# ---------------------------------------------------------------------------------------
# Read RTL
# ---------------------------------------------------------------------------------------
source [file join $SCRIPT_DIR filelist.tcl]

puts "### Analyzing [llength $ANALYZE_FILES] SystemVerilog files..."
foreach f $ANALYZE_FILES {
  puts "###   $f"
  if {![analyze -format sverilog -define {SYNTHESIS} -lib WORK $f]} {
    puts "ERROR: analyze failed on $f"
    exit 1
  }
}

puts "### Elaborating $DESIGN_TOP ..."
if {![elaborate $DESIGN_TOP -lib WORK]} {
  puts "ERROR: elaborate failed on $DESIGN_TOP"
  exit 1
}
current_design $DESIGN_TOP
if {![link]} {
  puts "ERROR: link failed - see unresolved references above."
  exit 1
}

redirect [file join $REPORT_DIR check_design.rpt] { check_design }

set_app_var high_fanout_net_threshold $HIGH_FANOUT
uniquify
if {$FIX_MPN} {
  set_fix_multiple_port_nets -all -buffer_constants [get_designs *]
}

# Combinational loop report. scripts/check_log_synth.sh looks for the exact string
# "No loops." in this file, so emit it explicitly when the design is clean.
redirect -variable _loop_rpt { report_timing -loops -max_paths 100 }
set _fh [open [file join $REPORT_DIR timing_loop.rpt] w]
if {[string match "*Startpoint*" $_loop_rpt]} {
  puts $_fh $_loop_rpt
} else {
  puts $_fh "No loops."
}
close $_fh

# ---------------------------------------------------------------------------------------
# Constraints
# ---------------------------------------------------------------------------------------
current_design $DESIGN_TOP
source [file join $SCRIPT_DIR constraints.tcl]

if {$FIX_HOLD} {
  set_fix_hold [all_clocks]
}

if {$KEEP_HIER} {
  # Preserve the RTL hierarchy so report_area -hierarchy stays readable. Boundary
  # optimisation is still allowed; only auto-ungrouping is disabled.
  set_app_var compile_ultra_ungroup_dw false
}

redirect [file join $REPORT_DIR check_timing.rpt] { check_timing }

# ---------------------------------------------------------------------------------------
# Compile
# ---------------------------------------------------------------------------------------
set compile_opts {}
if {$CLOCK_GATING} { lappend compile_opts -gate_clock }
if {$KEEP_HIER}    { lappend compile_opts -no_autoungroup }
if {$RETIME}       { lappend compile_opts -retime }

puts "### compile_ultra $compile_opts"
if {$USE_ULTRA} {
  eval compile_ultra $compile_opts
  if {$INCREMENTAL} {
    puts "### compile_ultra -incremental"
    eval compile_ultra -incremental $compile_opts
  }
} else {
  compile -map_effort high -area_effort high
  if {$INCREMENTAL} { compile -incremental_mapping -map_effort high }
}

# ---------------------------------------------------------------------------------------
# Reports
# ---------------------------------------------------------------------------------------
puts "### Writing reports to $REPORT_DIR"

redirect [file join $REPORT_DIR area.rpt]         { report_area -hierarchy -nosplit }
redirect [file join $REPORT_DIR area_summary.rpt] { report_area }
redirect [file join $REPORT_DIR qor.rpt]          { report_qor }
redirect [file join $REPORT_DIR timing_max.rpt]   { report_timing -delay max -max_paths 20 -nworst 5 -significant_digits 4 -nosplit }
redirect [file join $REPORT_DIR timing_min.rpt]   { report_timing -delay min -max_paths 20 -nworst 5 -significant_digits 4 -nosplit }
redirect [file join $REPORT_DIR constraint.rpt]   { report_constraint -all_violators -nosplit }
redirect [file join $REPORT_DIR resources.rpt]    { report_resources -hierarchy }
redirect [file join $REPORT_DIR reference.rpt]    { report_reference -hierarchy }
redirect [file join $REPORT_DIR registers.rpt]    { report_register -level_sensitive }
redirect [file join $REPORT_DIR power.rpt]        { report_power -analysis_effort medium -nosplit }
redirect [file join $REPORT_DIR hierarchy.rpt]    { report_hierarchy }
if {$CLOCK_GATING} {
  redirect [file join $REPORT_DIR clock_gating.rpt] { report_clock_gating }
}

# ---------------------------------------------------------------------------------------
# Outputs
# ---------------------------------------------------------------------------------------
change_names -rules $CHANGE_NAMES_RULES -hierarchy

# netlist.v goes in report/ because that is the path the postsynthesis-netlist fileset
# in crheepto.core points at.
write -format verilog -hierarchy -output [file join $REPORT_DIR netlist.v]
write -format ddc     -hierarchy -output [file join $NETLIST_DIR ${DESIGN_TOP}.ddc]
write_sdf -version 1.0                   [file join $NETLIST_DIR ${DESIGN_TOP}.sdf]
write_sdc -nosplit                       [file join $NETLIST_DIR ${DESIGN_TOP}.sdc]

# ---------------------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------------------
# The whole summary is cosmetic -- the netlist and every report are already on disk
# by this point, so nothing in here may be allowed to fail the run.
set _sum_failed [catch {

# Read the area back out of report_area rather than from a design attribute:
# "area" is not a queryable attribute of a design in DC 2025.06 (UID-101), and
# get_attribute then hands back an empty string that blows up the arithmetic below.
redirect -variable _area_rpt { report_area }
set _area ""
foreach _ln [split $_area_rpt "\n"] {
  if {[regexp {Total cell area:\s*([0-9.eE+-]+)} $_ln -> _m]} { set _area $_m; break }
}

set _paths [get_timing_paths -delay max -max_paths 1]
set _slack 0.0
if {[sizeof_collection $_paths] > 0} {
  set _slack [get_attribute [index_collection $_paths 0] slack]
}
set _achieved [expr {$CLK_PERIOD - $_slack}]
set _fmax     [expr {$_achieved > 0 ? 1000.0 / $_achieved : 0.0}]

# Convert area to gate equivalents so the number can be compared against a paper
# that used a different process node. 1 GE = the area of a 2-input NAND.
set _nand2_area 0.0
set _nand2_name "none"
if {[string length $NAND2_CELL] > 0} {
  set _c [get_lib_cells -quiet $NAND2_CELL]
} else {
  # Auto-detect the smallest 2-input NAND. Two things to get right:
  #
  #  - Naming is not standardised. TSMC/CBDK uses NAND2X1, Arm Artisan uses
  #    NAND2_X0P5A_A9TR, others use ND2/NA2 or lower case. Try the spellings in
  #    turn and keep the first that matches.
  #  - Search only the libraries THIS run targets. A bare "*/NAND2*" also matches
  #    any other library still loaded in the session -- e.g. a previous kit pulled
  #    in by a stale synopsys.setup -- and a NAND2 from the wrong process silently
  #    scales the reported kGE by the ratio of the two nodes.
  set _tech_libs {}
  foreach _l $target_library { lappend _tech_libs [file rootname [file tail $_l]] }

  set _c ""
  foreach _pat {NAND2* nand2* ND2* nd2* NA2*} {
    set _q {}
    foreach _l $_tech_libs { lappend _q "$_l/$_pat" }
    set _c [get_lib_cells -quiet $_q]
    if {[sizeof_collection $_c] > 0} { break }
  }
}
if {[sizeof_collection $_c] > 0} {
  foreach_in_collection _lc $_c {
    set _a [get_attribute -quiet $_lc area]
    if {$_a ne "" && $_a > 0 && ($_nand2_area == 0.0 || $_a < $_nand2_area)} {
      set _nand2_area $_a
      set _nand2_name [get_object_name $_lc]
    }
  }
}
if {$_area eq ""} {
  set _area_line "###   total cell area : n/a (could not parse report_area)"
  set _ge_line   "###   gate equivalent: n/a"
} else {
  set _area_line [format "###   total cell area : %.1f  (library area units)" $_area]
  if {$_nand2_area > 0.0} {
    set _ge_line [format "###   gate equivalent : %.1f kGE  (1 GE = %s, %.4f)" \
                    [expr {$_area / $_nand2_area / 1000.0}] $_nand2_name $_nand2_area]
  } else {
    set _ge_line "###   gate equivalent : n/a (set NAND2_CELL to enable)"
  }
}

# Record what produced these numbers. With several process nodes, VT flavours and
# PVT corners on hand, a summary that does not name its library is unattributable a
# week later -- and the boundary budget matters as much as the library, since
# IO_DELAY_FRAC alone moved this design by 2.3 ns.
set _lib_lines ""
foreach _lib $target_library {
  set _r [resolve_on_search_path $_lib]
  append _lib_lines [format "###   library         : %s\n" \
                       [expr {$_r ne "" ? $_r : $_lib}]]
}

set _wl [expr {[string length $WIRE_LOAD_MODEL] > 0 ? $WIRE_LOAD_MODEL \
                                                    : "library default / none"}]
set _oc [expr {[string length $OPCOND] > 0 ? $OPCOND : "library default"}]

set _cond [format \
"###   io_delay_frac   : %s  (%.3f ns of the period given to the boundary)
###   clk uncertainty : %s ns setup / %s ns hold
###   wire load       : %s
###   opcond          : %s
###   compile         : ultra=%s keep_hier=%s incr=%s retime=%s clk_gate=%s fix_hold=%s" \
  $IO_DELAY_FRAC [expr {$IO_DELAY_FRAC * $CLK_PERIOD}] $CLK_UNCERT $CLK_UNCERT_HOLD $_wl $_oc \
  $USE_ULTRA $KEEP_HIER $INCREMENTAL $RETIME $CLOCK_GATING $FIX_HOLD]

set _sum [format \
"########################################################################
### SYNTHESIS SUMMARY - %s
%s%s
###   target period   : %.3f ns  (%.1f MHz)
###   worst slack     : %+.3f ns
###   achieved period : %.3f ns  (%.1f MHz)
%s
%s
###   reports         : %s
########################################################################" \
  $DESIGN_TOP $_lib_lines $_cond \
  $CLK_PERIOD [expr {1000.0/$CLK_PERIOD}] $_slack $_achieved $_fmax \
  $_area_line $_ge_line $REPORT_DIR]

puts $_sum
set _fh [open [file join $REPORT_DIR summary.rpt] w]
puts $_fh $_sum
close $_fh

} _sum_err]

if {$_sum_failed} {
  puts "### WARNING: could not build the summary ($_sum_err)."
  puts "###          The netlist and all reports were already written to"
  puts "###          $REPORT_DIR"
}

exit 0
