# Lab Bring-Up Notes (x25519-ext)

This documents everything needed to get `make questasim-sim` running on a
fresh clone of this branch on a shared EDA lab server (Synopsys/Cadence/
Siemens tools available, no Docker). None of this touches shared/system
paths — everything lives under your own home directory.

None of the issues below are specific to your machine; they're gaps in
this branch's vendored dependencies. If you hit something not covered
here, it's worth checking `git log` for a fix before repeating the
workaround.

## 1. Clone your fork and check out the branch

```csh
git clone git@github.com:<you>/horcrux-x25519.git
cd horcrux-x25519
git checkout x25519-ext   # or: git fetch && git checkout x25519-ext
```

## 2. Python virtual environment

The top-level `makefile` expects `./.venv/bin/python` / `./.venv/bin/fusesoc`
to already exist — nothing creates it automatically. `.venv/` is
gitignored, so this is a one-time per-checkout setup:

```csh
python3 -m venv .venv
source .venv/bin/activate.csh        # csh/tcsh; use `activate` for bash
```

Install the packages `mcu_gen.py`/`crheepto_gen.py` need (their
`hw/vendor/x-heep/python-requirements.txt` was never vendored in, so
there's nothing to `pip install -r`):

```csh
pip install fusesoc hjson jsonref mako
```

`setuptools` ≥ 82 removed `pkg_resources`, which the vendored (lowRISC
OpenTitan) `regtool.py` still imports. Pin it or `mcu-gen` fails with
`ModuleNotFoundError: No module named 'pkg_resources'`:

```csh
pip install "setuptools<81"
```

Every `make mcu-gen` / `make crheepto-gen` / `make app` invocation needs
this venv active. Re-activate after any shell that resets your
environment (e.g. after `source ~/.cshrc`):

```csh
source .venv/bin/activate.csh
```

## 3. verible (RTL formatter, required by `mcu-gen`)

`make mcu-gen`'s last step shells out to `verible-verilog-format`, which
isn't installed on the lab servers. It's a static binary, no build
needed:

```csh
mkdir -p ~/tools && cd ~/tools
curl -LO https://github.com/chipsalliance/verible/releases/download/v0.0-4163-g6cce8f19/verible-v0.0-4163-g6cce8f19-linux-static-x86_64.tar.gz
tar xzf verible-v0.0-4163-g6cce8f19-linux-static-x86_64.tar.gz
```
(Check https://github.com/chipsalliance/verible/releases for a newer
build if this one 404s.)

## 4. Register this checkout with fusesoc

The `makefile`'s fusesoc calls don't pass `--cores-root`, so fusesoc
needs this directory registered as a core library (this is a per-user
setting stored in `~/.config/fusesoc/fusesoc.conf`, not part of the
repo):

```csh
fusesoc library add crheepto . --sync-type local
```

## 5. RISC-V toolchain (CORE-V GCC)

The default `COMPILER_PREFIX ?= riscv32-corev-` and `ARCH ?=
rv32imfdc_zicsr_xcvbitmanip` require the OpenHW/CORE-V GCC fork — a
generic or PULP RISC-V toolchain will *not* work (older PULP builds
predate the `zicsr`/`zifencei` ISA string split and don't know
`xcvbitmanip` at all; you'll see `Fatal error: ... Invalid or unknown z
ISA extension: 'zicsr'`).

Install X-HEEP's documented toolchain (Embecosm's CORE-V build, ~1.8GB
download, ~3-4GB installed — check `df -h ~` first):

```csh
mkdir -p ~/tools && cd ~/tools
curl -C - --retry 20 --retry-delay 10 -L -O https://buildbot.embecosm.com/job/corev-gcc-ubuntu2004/50/artifact/corev-openhw-gcc-ubuntu2004-20240530.tar.gz
tar xzf corev-openhw-gcc-ubuntu2004-20240530.tar.gz
```
(The Ubuntu 20.04 build's older glibc is the most portable across
distros; 18.04/22.04 builds also exist on the same release page if this
one doesn't run.)

## 6. lowRISC's fusesoc/edalize fork

The vendored `hw/ip/prim/util/primgen.py` (from lowRISC OpenTitan) was
written against lowRISC's own fork of `fusesoc`/`edalize`, which passes
generators a richer "GAPI" structure (including a `cores` key) than
upstream PyPI `fusesoc` does. **No version of the official PyPI
`fusesoc` package supports this** — install the fork instead:

```csh
pip install "fusesoc @ git+https://github.com/lowRISC/fusesoc.git@ot"
pip install "edalize @ git+https://github.com/lowRISC/edalize.git@ot"
```

This also sidesteps the strict CAPI2 JSON-schema validation that
official fusesoc ≥ 2.2 added (which otherwise silently drops ~30
vendored `lowrisc:prim:*` core files that use `files:`/`depend:` with no
value instead of `[]` — already fixed on this branch, see `git log` for
`Fix null files/depend keys in vendored lowrisc_opentitan .core files`,
but keep in mind if you're vendoring in a newer x-heep/OpenTitan drop).

## 7. Environment variables

Add to `~/.cshrc` (adjust paths/versions to what you actually installed):

```csh
# HORCRUX / x-heep toolchain
setenv RISCV ~/tools/corev-openhw-gcc-ubuntu2004-20240530
setenv MODEL_TECH /usr/cad/mentor/Questa_Sim/2025.2_2/questasim/bin
setenv PATH ${RISCV}/bin:~/tools/verible-v0.0-4163-g6cce8f19/bin:${PATH}
```

`MODEL_TECH` is QuestaSim's own required variable (must point at its
`bin/` directory) — without it, `make questasim-sim` fails at the final
`make` step with `Environment variable MODEL_TECH was not found`.

`.venv` activation is deliberately **not** in `.cshrc` — it's
per-project, activate it manually per shell (step 2).

## 8. Build/generate/simulate flow, cmake/EDA env conflicts

The lab's Cadence/Xcelium install prepends its own (older) `liblzma` to
`LD_LIBRARY_PATH`, which breaks the system `cmake3`/`libarchive` used by
`make app`. Clear it for build/generate steps only (leave it alone for
the actual `questasim-sim` step, which needs the tool env):

```csh
env LD_LIBRARY_PATH="" make mcu-gen
env LD_LIBRARY_PATH="" make crheepto-gen
env LD_LIBRARY_PATH="" make app PROJECT=<project>
make questasim-sim
```

## Known-good sequence from a clean checkout

```csh
git clone git@github.com:<you>/horcrux-x25519.git
cd horcrux-x25519
git checkout x25519-ext

python3 -m venv .venv
source .venv/bin/activate.csh
pip install fusesoc hjson jsonref mako "setuptools<81"
pip install "fusesoc @ git+https://github.com/lowRISC/fusesoc.git@ot"
pip install "edalize @ git+https://github.com/lowRISC/edalize.git@ot"
fusesoc library add crheepto . --sync-type local

# one-time tool installs — see sections 3 and 5 above for URLs
# then add the setenv block from section 7 to ~/.cshrc and `source` it

env LD_LIBRARY_PATH="" make mcu-gen
env LD_LIBRARY_PATH="" make crheepto-gen
env LD_LIBRARY_PATH="" make app PROJECT=tests/keccak-abs
make questasim-sim
```

If `make app`'s last step (`find ... -exec cp ... build/sw/app/`) fails
with `find: 'sw/build/': No such file or directory`, the build itself
still succeeded (check for `hw/vendor/x-heep/sw/build/main.elf`) — just
the copy step's `$(XHEEP_DIR)` doesn't expand in that recipe line for
reasons not yet root-caused. Work around it manually:

```csh
mkdir -p build/sw/app
find hw/vendor/x-heep/sw/build/ -maxdepth 1 -type f -name "main.*" -exec cp '{}' build/sw/app/ \;
```
