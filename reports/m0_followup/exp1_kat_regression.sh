#!/bin/sh
# KAT / directed-test regression for the unified_mul_32x32 DSP-split change
# (Experiment 1 in M0_FINDINGS.md).
#
# Run from the repo root on the lab server, with the Python venv active:
#     source .venv/bin/activate.csh     # csh/tcsh
#     sh reports/m0_followup/exp1_kat_regression.sh
#
# Build steps need LD_LIBRARY_PATH cleared (Cadence's liblzma breaks cmake3);
# the simulation step must NOT have it cleared, since it needs the tool env.
# See SETUP_NOTES.md sections 7-8.
#
# The RTL change is purely combinational -- no pipeline stage was added or
# removed -- so cycle counts must come out IDENTICAL to the M0 reference
# numbers below. A changed cycle count is a red flag even if the KAT passes.
#
#   ML-KEM-768  KeyGen/Encaps/Decaps :   260,388 /   288,498 /   426,258
#   HQC-1       KeyGen/Encaps/Decaps : 2,411,827 / 4,537,744 / 7,406,292
#
# STATUS: this script has never been executed end to end. Every step in it was
# run by hand during the Experiment 1 regression and the results are in
# M0_FINDINGS.md, but the script as assembled here is unvalidated. `sh -n`
# passes. Treat the first run as a shakedown.
#
# Note also scripts/sim_all_app.sh, which does a similar sweep but marks a test
# PASSED on the string "TEST SUCCEEDED" alone. That is the testbench reporting
# the program returned 0, not the application's own correctness check -- it
# would mark tests/falcon-montg as passing while all 19 of its hardware vectors
# fail. This script greps for FAIL instead, which is what caught that.

# WARNING: never run this alongside another build/simulation in the same working
# tree. They share hw/vendor/x-heep/sw/build/main.elf, build/sw/app/main.hex and
# the ModelSim `work` library; running a background sweep next to a foreground
# loop produced three spurious failures ("Failed to find design unit 'tb_top'",
# a phantom BUILD FAILED) that all vanished on a serial re-run.
#
# WARNING: do NOT run `make clean` to force a rebuild. BUILD_DIR is `build`,
# and clean does `rm -rf build` -- which would also delete build/pynq-z2-vivado
# (the M0 Vivado project and its original reports). This script instead removes
# only the ModelSim build directory, below.

OUT=reports/m0_followup/kat
mkdir -p "$OUT"

# Guard against a false pass: confirm the working tree really has the rewritten
# multiplier before spending an hour simulating the old one.
if ! grep -q "int_prod" hw/ip/coprocessors/unified_mul_32x32.sv; then
    echo "ABORT: hw/ip/coprocessors/unified_mul_32x32.sv does not contain the"
    echo "       rewritten integer path (no 'int_prod'). Wrong revision checked out?"
    exit 1
fi

# Force one full recompile of the simulation model, so the result cannot come
# from a stale ModelSim library that missed the RTL edit. Surgical -- this
# touches only the sim build, not the Vivado project.
echo "Removing ModelSim build dir to force a clean recompile..."
rm -rf build/polito_vlsi_crheepto_*/sim-modelsim

# Tier 1: directed tests. Fast, and they pinpoint which mode broke.
#   karats / gf-carryless  -> carry-less GF(2) path (cl_prod)
#   *-montg / mq-montymul  -> integer path (int_prod), all four modes
#   *-ntt / *-intt         -> integer path under real butterfly traffic
#   *-barrett              -> all four OP_BARRETT* opcodes
#   remainder              -> regression, should be untouched by this change
DIRECTED="tests/karats \
tests/gf-carryless \
tests/kyber-montg \
tests/dilithium-montg \
tests/mq-montymul \
tests/kyber-ntt \
tests/kyber-intt \
tests/dilithium-ntt \
tests/dilithium-intt \
tests/falcon-ntt \
tests/falcon-intt \
tests/dilithium-reduce32 \
tests/gf-reduce \
tests/kyber-barrett \
tests/hqc-barrett \
tests/compare-u32"

# Tier 2: full end-to-end KATs with published cycle counts.
KAT="pqc/optimized/KEM/ML-KEM/ml-kem-768 \
pqc/optimized/KEM/HQC/HQC-2025/HQC-1 \
pqc/optimized/DS/ML-DSA/ML-DSA-65"

# Deliberately NOT in the lists above -- both fail for pre-existing reasons
# that have nothing to do with any RTL change, so including them would report
# two failures on a perfectly good design:
#
#   tests/falcon-montg   its .insn encoding (funct7=0x02) decodes to OP_CBD3
#                        and is dispatched to the CBD sampler, never reaching
#                        multiplier_tree. 19/19 hardware vectors fail, before
#                        and after, confirmed by reverting the RTL.
#   .../FALCON/falcon-512  does not link: "region 'ram0' overflowed by 19232
#                        bytes". No binary is produced.
#
# Falcon's datapath is still covered, by falcon-ntt / falcon-intt.
# See M0_FINDINGS.md for both. Re-add them only once they are fixed.

pass=0
fail=0
failed_list=""

run_one() {
    p="$1"
    name=`echo "$p" | tr '/' '_'`
    echo "=================================================================="
    echo "RUN  $p"

    # Delete last test's artefacts first. Without this a failed build leaves the
    # PREVIOUS test's binary in place and it gets silently re-simulated -- one
    # falcon-512 run reported ML-DSA-65's cycle counts verbatim that way.
    rm -f build/sw/app/main.* hw/vendor/x-heep/sw/build/main.*

    env LD_LIBRARY_PATH="" make app PROJECT="$p" > "$OUT/${name}.build.log" 2>&1
    # `make app`'s final find/cp step loses $(XHEEP_DIR) in some contexts and
    # exits non-zero even though the build succeeded (SETUP_NOTES.md) -- so
    # check for the artefact rather than trusting the exit status.
    if [ ! -f hw/vendor/x-heep/sw/build/main.elf ]; then
        echo "BUILD FAILED  ->  $OUT/${name}.build.log"
        fail=`expr $fail + 1`
        failed_list="$failed_list $p(build)"
        return
    fi
    mkdir -p build/sw/app
    find hw/vendor/x-heep/sw/build/ -maxdepth 1 -type f -name "main.*" \
        -exec cp '{}' build/sw/app/ \; 2>/dev/null

    make questasim-sim > "$OUT/${name}.sim.log" 2>&1

    # Match FAIL, not FAILED: the applications print "Test 3 FAIL:" and
    # "FINAL STATUS: TEST FAILURE DETECTED", neither of which contains "FAILED".
    # An earlier version of this pattern matched the pass case but not either
    # failure case, which silently hid a fully failing test.
    grep -E "PASSED|FAIL|FINAL STATUS|ERROR|[Mm]ismatch|[Cc]ycles:|TEST SUCCEEDED" \
        "$OUT/${name}.sim.log"

    if grep -qE "FAIL|ERROR|[Mm]ismatch" "$OUT/${name}.sim.log"; then
        echo "  ^^ FAIL  ->  $OUT/${name}.sim.log"
        fail=`expr $fail + 1`
        failed_list="$failed_list $p"
    else
        pass=`expr $pass + 1`
    fi
}

for p in $DIRECTED $KAT; do
    run_one "$p"
done

echo "=================================================================="
echo "SUMMARY: $pass passed, $fail failed"
if [ -n "$failed_list" ]; then
    echo "FAILED:$failed_list"
fi
echo "Logs in $OUT/"
echo "Now compare the cycle counts above against the M0 reference numbers"
echo "in the header of this script -- they must match exactly."
