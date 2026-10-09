#!/bin/bash
##########################################################################################
# Pack the reports of every synthesis run into one tarball, for committing to the repo.
#
#   make pack                       # -> ~/<worktree>_synth_reports.tgz
#   bash pack_reports.sh <implementation/synthesis dir> <out.tgz>
#
# Per run it keeps what a write-up needs and drops what can be regenerated or is too
# large for git (netlist, ddc, sdf, the full synth.log):
#   summary.rpt area.rpt qor.rpt resources.rpt power.rpt
#   constraint_summary.rpt -- per constraint, the number of violating nets and the
#                         worst slack. The full report_constraint -all_violators
#                         lists every pin of every violating net, ~1 MB per run.
#   timing_worst.rpt   -- the first (worst) path of timing_max.rpt only. The full
#                         report lists 100 paths, each several hundred cells long on
#                         the original multiplier, i.e. megabytes per run.
# plus compare.txt, the `make compare` table of all runs.
##########################################################################################
set -euo pipefail

SYN="${1:?usage: pack_reports.sh <implementation/synthesis dir> <out.tgz>}"
OUT="${2:?usage: pack_reports.sh <implementation/synthesis dir> <out.tgz>}"
SYN=$(cd "$SYN" && pwd)
case "$OUT" in /*) ;; *) OUT="$PWD/$OUT" ;; esac
HERE=$(cd "$(dirname "$0")" && pwd)

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/synth_reports"

bash "$HERE/compare.sh" "$SYN" > "$TMP/synth_reports/compare.txt"

n=0
for d in "$SYN"/*/; do
  run=$(basename "$d")
  [ "$run" = last_output ] && continue
  [ -f "$d/report/summary.rpt" ] || continue
  dest="$TMP/synth_reports/$run"
  mkdir -p "$dest"
  for f in summary area qor resources power; do
    [ -f "$d/report/$f.rpt" ] && cp "$d/report/$f.rpt" "$dest/"
  done
  if [ -f "$d/report/constraint.rpt" ]; then
    bash "$HERE/constraint_summary.sh" "$d/report/constraint.rpt" > "$dest/constraint_summary.rpt"
  fi
  if [ -f "$d/report/timing_max.rpt" ]; then
    awk '/Startpoint/{n++} n<=1' "$d/report/timing_max.rpt" > "$dest/timing_worst.rpt"
  fi
  n=$((n + 1))
done

tar czf "$OUT" -C "$TMP" synth_reports
echo "Packed $n runs into $OUT ($(du -h "$OUT" | cut -f1))"
