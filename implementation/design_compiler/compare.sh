#!/bin/bash
##########################################################################################
# Compare every synthesis run in implementation/synthesis/ as one table.
#
#   make compare
#
# Reads each run's report/summary.rpt. Runs made before the summary grew its
# provenance lines simply show "-" in those columns.
##########################################################################################

OUT_ROOT="${1:?usage: compare.sh <implementation/synthesis dir>}"

printf "%-26s %-14s %8s %8s %10s %7s %8s  %s\n" \
  "RUN" "LIB" "TARGET" "SLACK" "ACHIEVED" "MHz" "kGE" "FLAGS"
printf "%s\n" "-------------------------------------------------------------------------------------------------------------------"

# -type d skips the last_output symlink; -not -name pins it down on filesystems
# where that symlink is materialised as a real directory.
find "$OUT_ROOT" -maxdepth 1 -mindepth 1 -type d -not -name last_output | sort | while read -r d; do
  f="$d/report/summary.rpt"
  [ -f "$f" ] || continue

  # The design name is the same for every run; drop it so the timestamp fits.
  run=$(basename "$d")
  run="${run#horcrux_top_synth_}"

  get() { sed -n "s/^###   $1[ ]*: *//p" "$f" | head -1; }

  lib=$(basename "$(get 'library')" .db)
  # Shorten the library to something that fits: node + vt + corner.
  case "$lib" in
    sc9_cln40g_base_*) lib="40nm ${lib#sc9_cln40g_base_}"; lib="${lib%%_typical*}" ;;
    "")                lib="-" ;;
    *)                 lib="${lib}" ;;
  esac

  target=$(get 'target period'   | awk '{print $1}')
  slack=$( get 'worst slack'     | awk '{print $1}')
  ach=$(   get 'achieved period' | awk '{print $1}')
  mhz=$(   get 'achieved period' | sed -n 's/.*(\([0-9.]*\) MHz).*/\1/p')
  ge=$(    get 'gate equivalent' | awk '{print $1}')
  flags=$( get 'compile')

  # Mark converged runs -- a negative slack means the numbers are not quotable.
  mark=""
  case "$slack" in -*) mark="" ;; *) [ -n "$slack" ] && mark=" <== MET" ;; esac

  # The design-wide flags are constant across most runs; show only what varies.
  flags=$(echo "$flags" | tr ' ' '\n' | grep -vE "^(ultra=1|retime=0|clk_gate=0|fix_hold=1)$" | tr '\n' ' ')

  printf "%-26s %-14s %8s %8s %10s %7s %8s  %s%s\n" \
    "$run" "$lib" "${target:--}" "${slack:--}" "${ach:--}" "${mhz:--}" "${ge:--}" \
    "${flags:--}" "$mark"
done
