#!/bin/bash
##########################################################################################
# Condense a `report_constraint -all_violators` report into one line per constraint:
# how many nets / endpoints violate it and the worst slack.
#
#   bash constraint_summary.sh <constraint.rpt>
#
# The full report lists every pin of every violating net -- around 1 MB per run when a
# high-fanout net misses max_transition -- which is too much to commit and too much to
# read. A section is a line holding only the constraint name, e.g. "   max_transition"
# or "   max_delay/setup ('clk' group)"; PIN lines repeat their net's violation and are
# not counted.
##########################################################################################
set -euo pipefail
RPT="${1:?usage: constraint_summary.sh <constraint.rpt>}"

awk '
  function flush() {
    if (sec != "") printf "  %-40s %8d %12s\n", sec, cnt, (cnt ? worst : "-")
  }
  /^   [a-z][a-z_\/]*( \([^)]*\))?[[:space:]]*$/ {
    flush(); sec = $0; sub(/^ +/, "", sec); sub(/ +$/, "", sec); cnt = 0; worst = ""; next
  }
  sec != "" && /VIOLATED/ && !/PIN :/ {
    cnt++
    # The slack is the last number before "(VIOLATED".
    line = $0; sub(/[[:space:]]*\(VIOLATED.*/, "", line)
    n = split(line, f, /[[:space:]]+/); s = f[n]
    if (s ~ /^-?[0-9.]+$/ && (worst == "" || s + 0 < worst + 0)) worst = s
  }
  END { flush() }
  BEGIN { printf "  %-40s %8s %12s\n", "constraint", "violators", "worst slack"
          printf "  %-40s %8s %12s\n", "----------", "---------", "-----------" }
' "$RPT"
