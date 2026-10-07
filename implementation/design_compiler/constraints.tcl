##########################################################################################
# HORCRUX ASIC synthesis - timing / environment constraints
#
# Sourced by dc_script.tcl after elaborate+link. All numbers come from setup.tcl.
# A real .sdc is written out at the end of the run (report/${DESIGN_TOP}.sdc) so it
# can be handed to PnR or re-read for a static timing run.
##########################################################################################

puts "### Applying constraints: ${CLK_PERIOD} ns ([format %.1f [expr {1000.0/$CLK_PERIOD}]] MHz)"

# ---- Operating conditions --------------------------------------------------------------
# CBDK idiom: set_operating_conditions -max_library slow -max slow
if {[string length $OPCOND] > 0} {
  if {[catch {set_operating_conditions -max_library $OPCOND_LIBRARY -max $OPCOND} _err]} {
    puts "### WARNING: set_operating_conditions failed ($_err)."
    puts "###          Check OPCOND / OPCOND_LIBRARY against your .db, or set OPCOND=\"\"."
  }
}

# ---- Clock -----------------------------------------------------------------------------
create_clock -name $CLK_NAME -period $CLK_PERIOD [get_ports $CLK_PORT]

# The clock tree does not exist yet, so keep the source network ideal and model the
# skew+jitter you expect to pay for it with uncertainty.
#
# Setup and hold need different numbers. Setup margin covers skew + jitter + design
# margin; hold only has to cover skew, because jitter affects both clock edges the
# same way on a hold path. Charging hold the full setup uncertainty is the usual
# cause of a pile of tiny pre-CTS hold violations that mean nothing -- hold is fixed
# after clock tree synthesis, when the real skew is known.
set_clock_uncertainty -setup $CLK_UNCERT      [get_clocks $CLK_NAME]
set_clock_uncertainty -hold  $CLK_UNCERT_HOLD [get_clocks $CLK_NAME]
set_clock_latency     $CLK_LATENCY     [get_clocks $CLK_NAME]
set_clock_transition  $CLK_TRAN        [get_clocks $CLK_NAME]
set_dont_touch_network                 [get_clocks $CLK_NAME]

# ---- Reset -----------------------------------------------------------------------------
# rst_ni is asynchronous and driven from a global net; treat it as ideal.
if {[sizeof_collection [get_ports $RST_PORT -quiet]] > 0} {
  set_ideal_network      [get_ports $RST_PORT]
  set_drive 0            [get_ports $RST_PORT]
  if {$RST_FALSE_PATH} {
    # Waives recovery/removal. Standard pre-CTS; revisit before tapeout.
    set_false_path -from [get_ports $RST_PORT]
  }
}

# ---- I/O timing ------------------------------------------------------------------------
set io_delay [expr {$IO_DELAY_FRAC * $CLK_PERIOD}]

set data_inputs [remove_from_collection [all_inputs] [get_ports $CLK_PORT]]
if {[sizeof_collection [get_ports $RST_PORT -quiet]] > 0} {
  set data_inputs [remove_from_collection $data_inputs [get_ports $RST_PORT]]
}

set_input_delay  -clock $CLK_NAME $io_delay $data_inputs
set_output_delay -clock $CLK_NAME $io_delay [all_outputs]

# ---- Boundary electrical environment ---------------------------------------------------
if {[string length $DRIVING_CELL] > 0} {
  if {[string length $DRIVING_PIN] > 0} {
    set_driving_cell -lib_cell $DRIVING_CELL -pin $DRIVING_PIN $data_inputs
  } else {
    set_driving_cell -lib_cell $DRIVING_CELL $data_inputs
  }
} else {
  # No PDK cell name given: assume an ideal driver. Optimistic - the input logic
  # cones will look faster than they will be on silicon.
  puts "### WARNING: DRIVING_CELL not set, driving all inputs with an ideal source."
  set_drive 0 $data_inputs
}

set_load $OUTPUT_LOAD [all_outputs]

# ---- Design rule constraints -----------------------------------------------------------
set_max_fanout     $MAX_FANOUT [current_design]
set_max_transition $MAX_TRAN   [current_design]

# ---- Optimisation targets --------------------------------------------------------------
# Ask for zero area so DC keeps shrinking after timing is met.
set_max_area 0

# ---- Wire load (non-topographical only) ------------------------------------------------
# In topographical mode DC uses the physical libraries instead, so the wire load
# model is both unnecessary and ignored.
if {![shell_is_in_topographical_mode]} {
  if {[string length $WIRE_LOAD_MODE] > 0} {
    set_wire_load_mode $WIRE_LOAD_MODE
  }
  # CBDK idiom: set_wire_load_model -name tsmc13_wl10 -library slow
  if {[string length $WIRE_LOAD_MODEL] > 0} {
    if {[catch {set_wire_load_model -name $WIRE_LOAD_MODEL -library $WIRE_LOAD_LIB} _err]} {
      puts "### WARNING: set_wire_load_model failed ($_err)."
      puts "###          Check WIRE_LOAD_MODEL / WIRE_LOAD_LIB, or set WIRE_LOAD_MODEL=\"\""
      puts "###          to let DC pick the library default."
    }
  }
}

puts "### Constraints applied."
