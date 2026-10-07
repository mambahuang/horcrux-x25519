##########################################################################################
# HORCRUX ASIC synthesis - driver
#
#   make synth SYNOPSYS_SETUP=/path/to/synopsys.setup
#   make synth CLK_PERIOD=8.0        # override any setup.tcl variable on the command line
#   make synth DESIGN_TOP=horcrux    # datapath only, no CORE-V XIF
#   make synth-topo                  # topographical mode (needs MW_REF_LIB + TLUPLUS_*)
#   make sweep PERIODS="20 15 12 10 8"    # find fmax
#   make report                      # print the summary of the last run
#   make gui                         # open Design Vision on the last run
#   make clean                       # remove all synthesis runs
#
# SYNOPSYS_SETUP is sourced verbatim inside dc_shell, so search_path,
# target_library, link_library, symbol_library and the hdlin_* switches all come
# from your lab's file. Set it once here rather than typing it every time:
SYNOPSYS_SETUP ?=

# Every variable in setup.tcl can be overridden on the command line; they are
# passed through the environment, e.g.
#   make synth SYNOPSYS_SETUP=~/synopsys.setup CLK_PERIOD=8 CLOCK_GATING=1
##########################################################################################

SHELL       := /bin/bash
DC_DIR      := $(patsubst %/,%,$(dir $(abspath $(lastword $(MAKEFILE_LIST)))))
REPO_ROOT   := $(abspath $(DC_DIR)/../..)
OUT_ROOT    := $(REPO_ROOT)/implementation/synthesis

DC_SHELL    ?= dc_shell
DESIGN_TOP  ?= horcrux_top_synth
# 10 ns / 100 MHz. The paper's 6.25 ns (160 MHz) is a 65 nm number and is not a
# realistic starting constraint on the CBDK 0.13 um kit -- use `make sweep`.
CLK_PERIOD  ?= 10.0
RUN_NAME    ?= $(DESIGN_TOP)_$(subst .,p,$(CLK_PERIOD))ns_$(shell date +%Y%m%d_%H%M%S)
# Force one-time expansion. Without this RUN_NAME stays recursive, so the $(shell date)
# inside it re-runs on every reference and the directory make creates can differ by a
# second from the one dc_shell writes into.
RUN_NAME    := $(RUN_NAME)
RUN_DIR      = $(OUT_ROOT)/$(RUN_NAME)

# dc_shell runs with its cwd set to the run directory, so a relative SYNOPSYS_SETUP
# would resolve against that instead of where you typed it. Anchor it here, against
# make's working directory. Paths starting with ~ or / are left alone.
ifneq ($(SYNOPSYS_SETUP),)
ifeq ($(filter ~% /%,$(SYNOPSYS_SETUP)),)
override SYNOPSYS_SETUP := $(abspath $(SYNOPSYS_SETUP))
endif
endif

# Technology presets, so every design point is synthesized with the same library
# settings. Anything given on the command line still wins over the preset:
#   make sweep TECH=tsmc40 PERIODS="4.8 4.6 4.5" MAX_CORES=1
TECH ?=
ifeq ($(TECH),tsmc40)
STD_CELL_DB     ?= /cad/designkit/CBDK_TSMC40_Arm_f2.0/CIC/SynopsysDC/db/sc9_base_rvt/sc9_cln40g_base_rvt_ss_typical_max_0p81v_125c.db
WIRE_LOAD_LIB   ?= sc9_cln40g_base_rvt_ss_typical_max_0p81v_125c
WIRE_LOAD_MODEL ?= Medium
IO_DELAY_FRAC   ?= 0.15
else ifneq ($(TECH),)
$(error Unknown TECH=$(TECH). Known: tsmc40)
endif

# Variables forwarded to the Tcl scripts. Only non-empty ones are exported, so
# setup.tcl keeps its own defaults for anything you do not set.
EXPORT_VARS := SYNOPSYS_SETUP STD_CELL_DB EXTRA_DBS SYMBOL_LIB \
               MW_REF_LIB MW_TECH_FILE TLUPLUS_MAX TLUPLUS_MAP \
               OPCOND OPCOND_LIBRARY WIRE_LOAD_MODEL WIRE_LOAD_LIB WIRE_LOAD_MODE \
               NAND2_CELL \
               DESIGN_TOP CLK_PERIOD CLK_UNCERT CLK_UNCERT_HOLD CLK_LATENCY CLK_TRAN IO_DELAY_FRAC \
               DRIVING_CELL DRIVING_PIN OUTPUT_LOAD MAX_FANOUT MAX_TRAN \
               RST_FALSE_PATH MAX_CORES USE_ULTRA KEEP_HIER CLOCK_GATING \
               INCREMENTAL RETIME FIX_HOLD FIX_MPN HIGH_FANOUT \
               CHANGE_NAMES_RULES RUN_NAME
$(foreach v,$(EXPORT_VARS),$(if $($(v)),$(eval export $(v))))

.PHONY: help
help:
	@echo "HORCRUX ASIC synthesis"
	@echo ""
	@echo "  make synth [VAR=value ...]   run Design Compiler"
	@echo "  make synth-topo              run DC in topographical mode"
	@echo "  make sweep PERIODS=\"20 15 12\"  synthesize at several clock periods"
	@echo "  make report                  show the last summary"
	@echo "  make gui                     open Design Vision on the last run"
	@echo "  make compare                 table of every run so far"
	@echo "  make libinfo                 dump wire load models / cell areas"
	@echo "  make clean                   delete implementation/synthesis/*"
	@echo ""
	@echo "  tech       = $(if $(TECH),$(TECH),<< none, set STD_CELL_DB or SYNOPSYS_SETUP >>)"
	@echo "  top        = $(DESIGN_TOP)"
	@echo "  period     = $(CLK_PERIOD) ns"
	@echo "  setup      = $(if $(SYNOPSYS_SETUP),$(SYNOPSYS_SETUP),<< set SYNOPSYS_SETUP or STD_CELL_DB >>)"
	@echo "  output     = $(RUN_DIR)"

.PHONY: check-tool
check-tool:
	@command -v $(DC_SHELL) >/dev/null 2>&1 || { \
	  echo "ERROR: $(DC_SHELL) not found in PATH. Load the Synopsys module first."; exit 1; }

.PHONY: synth
synth: check-tool
	@mkdir -p $(RUN_DIR)/report
	@ln -sfn $(RUN_DIR) $(OUT_ROOT)/last_output
	@echo "### Run directory: $(RUN_DIR)"
	@set -o pipefail; cd $(RUN_DIR) && \
	  DC_MAIN_SCRIPT=$(DC_DIR)/dc_script.tcl $(DC_SHELL) -f $(DC_DIR)/run.tcl 2>&1 | tee $(RUN_DIR)/report/synth.log
	@# invoked through bash so it works whether or not the exec bit survived
	@# the checkout / file transfer
	@cd $(REPO_ROOT) && bash ./scripts/check_log_synth.sh || true
	@cat $(RUN_DIR)/report/summary.rpt 2>/dev/null || true

.PHONY: synth-topo
synth-topo: check-tool
	@mkdir -p $(RUN_DIR)/report
	@ln -sfn $(RUN_DIR) $(OUT_ROOT)/last_output
	@set -o pipefail; cd $(RUN_DIR) && \
	  DC_MAIN_SCRIPT=$(DC_DIR)/dc_script.tcl $(DC_SHELL) -topographical_mode -f $(DC_DIR)/run.tcl 2>&1 | tee $(RUN_DIR)/report/synth.log
	@# invoked through bash so it works whether or not the exec bit survived
	@# the checkout / file transfer
	@cd $(REPO_ROOT) && bash ./scripts/check_log_synth.sh || true
	@cat $(RUN_DIR)/report/summary.rpt 2>/dev/null || true

# Binary-search fmax by hand: synthesize at each period, then compare the summaries.
PERIODS ?= 20 16 13 11 10 9 8
.PHONY: sweep
sweep: check-tool
	@for p in $(PERIODS); do \
	  echo "=================== period $$p ns ==================="; \
	  $(MAKE) --no-print-directory -f $(DC_DIR)/Makefile synth \
	    CLK_PERIOD=$$p \
	    RUN_NAME=$(DESIGN_TOP)_$${p/./p}ns_$$(date +%Y%m%d_%H%M%S) || exit 1; \
	done
	@echo ""
	@echo "=================== sweep summary ==================="
	@bash $(DC_DIR)/compare.sh $(OUT_ROOT)

# Inspect the technology library: wire load models, operating conditions, cell areas.
# Runs through bash regardless of your login shell, so no csh redirect syntax needed.
.PHONY: libinfo
libinfo: check-tool
	@DC_MAIN_SCRIPT=$(DC_DIR)/libinfo.tcl $(DC_SHELL) -f $(DC_DIR)/run.tcl 2>&1 | grep -v "^ *$$" | tail -40
	@echo ""
	@echo "=================== wire load models ==================="
	@grep -i -A40 "wire load" $(DC_DIR)/libinfo.rpt | head -60 || \
	  echo "(no 'wire load' section found -- open $(DC_DIR)/libinfo.rpt)"
	@echo ""
	@echo "=================== operating conditions ==================="
	@grep -i -A20 "operating condition" $(DC_DIR)/libinfo.rpt | head -30 || true

.PHONY: compare
compare:
	@bash $(DC_DIR)/compare.sh $(OUT_ROOT)

.PHONY: report
report:
	@cat $(OUT_ROOT)/last_output/report/summary.rpt 2>/dev/null || \
	  echo "No run found. Try: make synth"

.PHONY: gui
gui: check-tool
	@cd $(OUT_ROOT)/last_output && DC_MAIN_SCRIPT=$(DC_DIR)/dc_script.tcl design_vision -f $(DC_DIR)/run.tcl

.PHONY: clean
clean:
	rm -rf $(OUT_ROOT)
	rm -rf $(DC_DIR)/.alib
	rm -f  $(DC_DIR)/libinfo.rpt
