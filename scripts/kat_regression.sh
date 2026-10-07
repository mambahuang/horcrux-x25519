#!/bin/sh
# KAT / directed-test regression: every directed test under
# sw/applications/tests plus the end-to-end ML-KEM, HQC and ML-DSA KATs.
# Rerun it after every RTL change, so the pseudo-Mersenne extension can be shown
# not to break the existing PQC paths.
#
# Run from the repo root on the lab server, with the Python venv active:
#     source .venv/bin/activate.csh     # csh/tcsh
#     sh scripts/kat_regression.sh
#
# Build steps need LD_LIBRARY_PATH cleared (Cadence's liblzma breaks cmake3);
# the simulation step must NOT have it cleared, since it needs the tool env.
# See SETUP_NOTES.md sections 7-8.
#
# The extension only adds new instructions; it must not add or remove a pipeline
# stage on the existing ones. Cycle counts must therefore come out IDENTICAL to
# the reference numbers below, measured on unmodified locket. A changed cycle
# count is a red flag even if the KAT passes.
#
#   ML-KEM-768  KeyGen/Encaps/Decaps :   260,388 /   288,498 /   426,258
#   HQC-1       KeyGen/Encaps/Decaps : 2,411,827 / 4,537,744 / 7,406,292
#
# STATUS: this script has never been executed end to end. Every step in it was
# run by hand during the M0 FPGA regression (tag m0-fpga, M0_FINDINGS.md), but
# the script as assembled here is unvalidated. `sh -n` passes. Treat the first
# run as a shakedown.
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

OUT=build/kat-regression
mkdir -p "$OUT"

# Force one full recompile of the simulation model, so the result cannot come
# from a stale ModelSim library that missed the RTL edit. This removes only the
# sim build, unlike `make clean`, which deletes all of build/.
echo "Removing ModelSim build dir to force a clean recompile..."
rm -rf build/polito_vlsi_crheepto_*/sim-modelsim

# Known failures. These are RUN, not skipped -- excluding a broken test hides
# it, and if someone fixes one it would silently stay unrun. They are reported
# as "expected failure" so they do not drown the signal, and a test here that
# starts PASSING is called out, because that means the cause was fixed and this
# list needs updating.
#
#   falcon-montg   its .insn encoding (funct7=0x02) decodes to OP_CBD3 and is
#                  dispatched to the CBD sampler, never reaching
#                  multiplier_tree. 19/19 hardware vectors fail, before and
#                  after, confirmed by reverting the RTL. Falcon's datapath is
#                  covered by falcon-ntt / falcon-intt regardless.
#                  See M0_FINDINGS.md at tag m0-fpga.
XFAIL="tests/falcon-montg"

# Tier 1: every directed test, discovered rather than listed.
#
# An earlier version hand-picked the 16 tests judged to touch the changed code.
# That judgement was wrong: it missed fqmul and the four *-poly-ntt /
# *-poly-intt variants, all of which drive the multiplier. Whether a test is
# relevant is exactly the kind of call that should not be made by hand, so the
# list is now derived from the directory.
DIRECTED=""
for d in sw/applications/tests/*/ ; do
    DIRECTED="$DIRECTED tests/`basename "$d"`"
done

# Tier 2: full end-to-end KATs with published cycle counts.
KAT="pqc/optimized/KEM/ML-KEM/ml-kem-768 \
pqc/optimized/KEM/HQC/HQC-2025/HQC-1 \
pqc/optimized/DS/ML-DSA/ML-DSA-65"

# FALCON/falcon-512 is likewise absent from the Tier 2 list: it does not link
# ("region 'ram0' overflowed by 19232 bytes"), so no binary is produced.

pass=0
fail=0
xfail=0
xpass=0
failed_list=""
xpass_list=""

is_xfail() {
    case " $XFAIL " in *" $1 "*) return 0 ;; esac
    return 1
}

# Record the outcome, accounting for whether this test is a known failure.
record() {
    p="$1"; ok="$2"
    if is_xfail "$p"; then
        if [ "$ok" = yes ]; then
            echo "  ^^ XPASS -- known failure now passes, update XFAIL"
            xpass=`expr $xpass + 1`
            xpass_list="$xpass_list $p"
        else
            echo "  ^^ xfail (known, see XFAIL note)"
            xfail=`expr $xfail + 1`
        fi
    elif [ "$ok" = yes ]; then
        pass=`expr $pass + 1`
    else
        fail=`expr $fail + 1`
        failed_list="$failed_list $p"
    fi
}

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
        record "$p" no
        return
    fi
    mkdir -p build/sw/app
    find hw/vendor/x-heep/sw/build/ -maxdepth 1 -type f -name "main.*" \
        -exec cp '{}' build/sw/app/ \; 2>/dev/null

    make questasim-sim > "$OUT/${name}.sim.log" 2>&1

    # Display. The tests use several different conventions for the success
    # line -- "FINAL STATUS: ALL TESTS PASSED" (32 of them), "All suites
    # passed.", "Result: ALL TESTS PASSED", "REJ_ETA: All tests passed.",
    # "Tests: 8/8 passed" -- so lowercase `passed` is matched too. Without it
    # a passing test shows only its cycle counts and you are left inferring
    # success from the absence of a failure line.
    grep -E "PASSED|passed|FAIL|FINAL STATUS|Result:|ERROR|[Mm]ismatch|[Cc]ycles:|TEST SUCCEEDED" \
        "$OUT/${name}.sim.log"

    # Decision. Deliberately case-SENSITIVE on FAIL, and it must stay that way:
    # every failure message in these tests is uppercase (FAIL, FAILED, FAILURE,
    # ERROR, Mismatch), while cbd_eta2 prints the counter line
    #   "ETA2: %d passed, %d failed"
    # on every run, pass or fail. Adding -i here to catch lowercase success
    # messages looks like an improvement and would mark that test failed every
    # time. The display grep above handles lowercase; this one must not.
    if grep -qE "FAIL|ERROR|[Mm]ismatch" "$OUT/${name}.sim.log"; then
        echo "  ^^ FAIL  ->  $OUT/${name}.sim.log"
        record "$p" no
    else
        record "$p" yes
    fi
}

for p in $DIRECTED $KAT; do
    run_one "$p"
done

echo "=================================================================="
echo "SUMMARY: $pass passed, $fail failed, $xfail expected-fail, $xpass xpass"
if [ -n "$failed_list" ]; then
    echo ""
    echo "FAILED (unexpected -- these are the ones that matter):$failed_list"
fi
if [ -n "$xpass_list" ]; then
    echo ""
    echo "XPASS (known failures that now pass -- update XFAIL):$xpass_list"
fi
echo ""
echo "Logs in $OUT/"
echo "Now compare the cycle counts above against the locket reference numbers"
echo "in the header of this script -- they must match exactly."
