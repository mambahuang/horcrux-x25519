##########################################################################################
# HORCRUX ASIC synthesis - quiet launcher
#
# `dc_shell -f foo.tcl` echoes every command in foo.tcl *and* every command's return
# value, which buries the actual synthesis output under a copy of the script. Tcl's
# `source`, by contrast, echoes nothing unless you ask for -echo / -verbose.
#
# So the Makefile points dc_shell -f at this one-line file instead, and the real
# script gets sourced from here. `info script` inside the sourced file still reports
# that file's own path, so SCRIPT_DIR / REPO_ROOT resolution is unaffected.
#
# The script to run comes from the DC_MAIN_SCRIPT environment variable.
##########################################################################################

if {![info exists ::env(DC_MAIN_SCRIPT)]} {
  puts "ERROR: DC_MAIN_SCRIPT is not set; run this through the Makefile."
  exit 1
}
if {![file exists $::env(DC_MAIN_SCRIPT)]} {
  puts "ERROR: DC_MAIN_SCRIPT does not exist: $::env(DC_MAIN_SCRIPT)"
  exit 1
}

source $::env(DC_MAIN_SCRIPT)
