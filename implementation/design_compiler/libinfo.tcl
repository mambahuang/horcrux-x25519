##########################################################################################
# HORCRUX ASIC synthesis - technology library inspector
#
#   make libinfo
#
# Loads the same libraries the synthesis flow would use and dumps report_lib for each,
# so you can look up wire load model names, operating condition names and cell areas
# without hand-assembling a dc_shell command line (and without fighting csh quoting).
##########################################################################################

set SCRIPT_DIR [file dirname [file normalize [info script]]]
source [file join $SCRIPT_DIR setup.tcl]

set_app_var sh_enable_page_mode false

if {[string length $SYNOPSYS_SETUP] > 0 && [file exists $SYNOPSYS_SETUP]} {
  puts "### Sourcing lab setup: $SYNOPSYS_SETUP"
  set_app_var sh_continue_on_error true
  catch {source $SYNOPSYS_SETUP}
  set_app_var sh_continue_on_error false
}

if {[string length $STD_CELL_DB] > 0} {
  # Rebuild link_library too, exactly as dc_script.tcl does. Otherwise a stale
  # synopsys.setup keeps pulling its own .db into link_library and you end up
  # inspecting cells from the wrong process.
  set_app_var target_library    [concat [list $STD_CELL_DB] $EXTRA_DBS]
  set_app_var synthetic_library [list dw_foundation.sldb]
  set_app_var link_library      [concat "*" $target_library $synthetic_library]
}

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

if {[llength $target_library] == 0} {
  puts "ERROR: target_library is empty -- see 'make synth' for how to point at your setup."
  exit 1
}

set OUT [file join $SCRIPT_DIR libinfo.rpt]
file delete -force $OUT

# Load each target library, and remember its library name so the report below covers
# only the technology libraries -- not gtech / standard.sldb / dw_foundation.sldb,
# which DC pulls in on its own and whose sections (nom_pvt at 5 V, "No wire loading
# specified", ...) are pure noise when you are looking up PDK values.
set ::_tech_libs {}
foreach _lib $target_library {
  set _p [resolve_on_search_path $_lib]
  if {$_p eq ""} {
    puts "### WARNING: cannot find $_lib on search_path, skipping"
    continue
  }
  set _before [get_object_name [get_libs -quiet *]]
  # link_library may have loaded it already; re-reading only produces a DDB-24 warning.
  set _stem [file rootname [file tail $_p]]
  if {[sizeof_collection [get_libs -quiet $_stem]] == 0} {
    puts "### Reading $_p"
    read_db $_p
  } else {
    puts "### Already loaded: $_stem ($_p)"
  }
  foreach _n [get_object_name [get_libs -quiet *]] {
    if {[lsearch -exact $_before $_n] < 0 || $_n eq $_stem} {
      if {[lsearch -exact $::_tech_libs $_n] < 0} { lappend ::_tech_libs $_n }
    }
  }
}

if {[llength $::_tech_libs] == 0} {
  puts "### WARNING: could not identify the technology library; reporting all loaded libs."
  set ::_tech_libs [get_object_name [get_libs -quiet *]]
}

foreach _n $::_tech_libs {
  puts "### report_lib $_n"
  redirect -append $OUT { puts "==================== library: $_n ====================" }
  redirect -append $OUT { report_lib $_n }
}

# Cell areas are easy to pull directly, so print them here rather than making you
# hunt through the (very long) report.
#
# Cell naming is not portable: TSMC/CBDK 0.13um uses NAND2X1/INVX1/DFFRX1, Arm
# Artisan libraries use their own scheme. So for each family try several spellings,
# take the first pattern that matches, and show the smallest few by area.
proc show_family {label patterns {howmany 4}} {
  # Search ONLY the technology libraries this run is about. A "*/" prefix would also
  # match any other library still loaded in the session (a stale setup file, gtech),
  # and silently report cells from the wrong process.
  set _c ""
  set _used ""
  foreach _p $patterns {
    set _q {}
    foreach _l $::_tech_libs { lappend _q "$_l/$_p" }
    set _c [get_lib_cells -quiet $_q]
    if {[sizeof_collection $_c] > 0} { set _used $_p; break }
  }
  if {[sizeof_collection $_c] == 0} {
    puts [format "###   %-8s : no match for %s" $label $patterns]
    return
  }
  set _rows {}
  foreach_in_collection _lc $_c {
    set _a [get_attribute -quiet $_lc area]
    if {$_a ne "" && $_a > 0} { lappend _rows [list $_a [get_object_name $_lc]] }
  }
  set _rows [lsort -real -index 0 $_rows]
  puts [format "###   %-8s : %d cells match %s, smallest:" \
          $label [llength $_rows] $_used]
  set _i 0
  foreach _r $_rows {
    if {[incr _i] > $howmany} break
    puts [format "###                %-28s %s" [lindex $_r 1] [lindex $_r 0]]
  }
}

puts ""
puts "### Reference cell areas (the smallest NAND2 is what the GE conversion uses)"
show_family "NAND2" {NAND2* nand2* ND2* nd2* NA2*}
show_family "INV"   {INV_X* INVX* inv_x* invx* IV* INV*}
show_family "BUF"   {BUF_X* BUFX* buf_x* bufx* BUF*}
show_family "DFF"   {DFFR* DFFQ* dff* DFF* SDFF*}

puts ""
puts "### Full report written to: $OUT"
exit 0
