# =============================================================================
# Mini RISC-V SoC - top-level Makefile
#
# Every project capability is reachable from here (CLAUDE.md section 7, rule 8).
# Run `make help` for the list of targets.
#
# Run make from the repository root. The repository path contains spaces,
# which GNU Make cannot handle in file names, so every path below is relative
# to the root (decision D-004). Written for GNU Make 3.81 (the macOS system make).
# =============================================================================

SHELL := /bin/bash
.DEFAULT_GOAL := help

BUILD_DIR := build

# Verilator's generated makefiles refuse to build in a directory whose path
# contains spaces, so when the repository path has spaces, Verilator object
# directories live outside the repository (decision D-010). Logs stay in build/.
ifeq ($(words $(CURDIR)),1)
  VL_OBJ_ROOT ?= $(BUILD_DIR)/verilator
else
  VL_OBJ_ROOT ?= $(HOME)/.cache/mini-riscv/verilator
endif

# -----------------------------------------------------------------------------
# Tools
# -----------------------------------------------------------------------------
PYTHON    ?= python3
VERILATOR ?= verilator

# RISC-V cross-compiler prefix: the first candidate found on PATH, unless given
# on the command line (make RISCV_PREFIX=...). The project standard is
# riscv64-elf- (D-002). Keep the list in sync with scripts/check_tools.py.
RISCV_PREFIX_CANDIDATES := riscv64-elf- riscv32-unknown-elf- riscv64-unknown-elf-
ifeq ($(origin RISCV_PREFIX),undefined)
  RISCV_PREFIX := $(firstword $(foreach p,$(RISCV_PREFIX_CANDIDATES),\
                    $(if $(shell command -v $(p)gcc 2>/dev/null),$(p))))
endif
RISCV_GCC     := $(RISCV_PREFIX)gcc
RISCV_OBJDUMP := $(RISCV_PREFIX)objdump

# Recipe-time guards: they only fire when a target that needs the tool runs.
need_tool = $(if $(shell command -v $(1) 2>/dev/null),,\
  $(error '$(1)' not found on PATH - run 'make check-tools' for install instructions))
need_riscv_gcc = $(if $(RISCV_PREFIX),,\
  $(error no RISC-V GCC found on PATH (tried: $(RISCV_PREFIX_CANDIDATES)) - run 'make check-tools'))

# -----------------------------------------------------------------------------
# RTL sources (packages first; later phases append modules)
# -----------------------------------------------------------------------------
RTL_PKGS := rtl/pkg/riscv_pkg.sv rtl/pkg/soc_pkg.sv
RTL_SRCS := $(RTL_PKGS)

LINT_FLAGS := --lint-only -Wall

# -----------------------------------------------------------------------------
# riscv-tests (third_party/riscv-tests is never modified)
#
# Stock environment (D-001): the upstream isa/Makefile is run out of tree from
# $(RT_BUILD) with src_dir pointing back at the submodule. Only the -p variants
# of rv32ui and rv32mi are built; the test lists come from the upstream
# Makefrags so they track the submodule.
#
# CSR-free environment (D-009): the same rv32ui sources, built against
# sw/common/test_env_nocsr/riscv_test.h. -march has no Zicsr, so the assembler
# rejects any CSR instruction. Used by Phase 1; Phase 2 switches to stock.
# -----------------------------------------------------------------------------
RT_ROOT  := third_party/riscv-tests
RT_ISA   := $(RT_ROOT)/isa
RT_BUILD := $(BUILD_DIR)/riscv-tests
# Path from $(RT_BUILD) back to the repository root.
RT_UP    := ../..

-include $(RT_ISA)/rv32ui/Makefrag
-include $(RT_ISA)/rv32mi/Makefrag
RT_TESTS := $(rv32ui_p_tests) $(rv32mi_p_tests)

NOCSR_ENV   := sw/common/test_env_nocsr
NOCSR_BUILD := $(BUILD_DIR)/riscv-tests-nocsr
NOCSR_TESTS := $(addprefix $(NOCSR_BUILD)/,$(rv32ui_p_tests))
NOCSR_FLAGS := -march=rv32i_zifencei -mabi=ilp32 -static -mcmodel=medany \
               -fvisibility=hidden -nostdlib -nostartfiles \
               -I$(NOCSR_ENV) -I$(RT_ISA)/macros/scalar -T$(RT_ROOT)/env/p/link.ld
# Same disassembly options as the upstream dumps.
DUMP_FLAGS  := --disassemble-all --disassemble-zeroes --section=.text \
               --section=.text.startup --section=.text.init --section=.data

# -----------------------------------------------------------------------------
# UVM on Verilator (D-011): Accellera uvm-core 2020.3.1, built without DPI.
# -----------------------------------------------------------------------------
UVM_SRC      := third_party/uvm-core/src
UVM_FLAGS    := +define+UVM_NO_DPI +incdir+$(UVM_SRC) $(UVM_SRC)/uvm_pkg.sv
VL_SIM_FLAGS := --binary --timing -j 0 -Wall --timescale 1ns/1ps

SMOKE_DIR  := tb/uvm/smoke
SMOKE_SRCS := $(SMOKE_DIR)/smoke_if.sv $(SMOKE_DIR)/smoke_dut.sv \
              $(SMOKE_DIR)/smoke_pkg.sv $(SMOKE_DIR)/smoke_tb_top.sv
SMOKE_OBJ  := $(VL_OBJ_ROOT)/uvm-smoke
SMOKE_LOG  := $(BUILD_DIR)/uvm-smoke

# =============================================================================
# Targets
# =============================================================================
.PHONY: help check-tools submodules lint riscv-tests-build riscv-tests-stock \
        riscv-tests-nocsr uvm-smoke test clean

help:
	@echo "Mini RISC-V SoC - make targets"
	@echo ""
	@echo "  check-tools        report toolchain status (PHASE=N fails if a tool needed"
	@echo "                     by phases 0..N is missing; default PHASE=0)"
	@echo "  submodules         fetch/update third_party submodules"
	@echo "  lint               verilator --lint-only -Wall on all RTL"
	@echo "  riscv-tests-build  both riscv-tests builds below"
	@echo "  riscv-tests-stock  rv32ui-p-* and rv32mi-p-*, stock env  -> $(RT_BUILD)/"
	@echo "  riscv-tests-nocsr  rv32ui-p-*, CSR-free env (Phase 1)    -> $(NOCSR_BUILD)/"
	@echo "  uvm-smoke          build and run the UVM smoke test on Verilator"
	@echo "  test               everything implemented so far (lint, riscv-tests-build, uvm-smoke)"
	@echo "  clean              remove $(BUILD_DIR)/ and $(VL_OBJ_ROOT)/"
	@echo ""
	@echo "  Planned (not implemented yet):"
	@echo "    test-core    directed core tests            (Phase 1)"
	@echo "    riscv-tests  run riscv-tests on the core    (Phase 1)"
	@echo "    cosim        Spike trace co-simulation      (Phase 3)"
	@echo "    uvm          UVM regression, TEST=...       (Phase 7)"
	@echo "    pnr          OpenLane/LibreLane on sky130   (Phase 8)"

PHASE ?= 0
check-tools:
	@$(PYTHON) scripts/check_tools.py --phase $(PHASE)

submodules:
	git submodule update --init --recursive

lint:
	$(call need_tool,$(VERILATOR))
	$(VERILATOR) $(LINT_FLAGS) $(RTL_SRCS)
	@echo "lint: clean ($(words $(RTL_SRCS)) files)"

# --- riscv-tests --------------------------------------------------------------
riscv-tests-build: riscv-tests-stock riscv-tests-nocsr

riscv-tests-stock:
	$(need_riscv_gcc)
	@test -f $(RT_ISA)/Makefile || { echo "error: riscv-tests submodule missing - run 'make submodules'" >&2; exit 1; }
	@mkdir -p $(RT_BUILD)
	$(MAKE) -C $(RT_BUILD) -f $(RT_UP)/$(RT_ISA)/Makefile src_dir=$(RT_UP)/$(RT_ISA) \
	    XLEN=32 RISCV_PREFIX=$(RISCV_PREFIX) \
	    $(RT_TESTS) $(addsuffix .dump,$(RT_TESTS))
	@echo "riscv-tests-stock: $(words $(RT_TESTS)) ELFs in $(RT_BUILD)/"

riscv-tests-nocsr: $(NOCSR_TESTS) $(addsuffix .dump,$(NOCSR_TESTS))
	@echo "riscv-tests-nocsr: $(words $(NOCSR_TESTS)) ELFs in $(NOCSR_BUILD)/"

$(NOCSR_BUILD)/rv32ui-p-%: $(RT_ISA)/rv32ui/%.S $(NOCSR_ENV)/riscv_test.h
	$(need_riscv_gcc)
	@mkdir -p $(NOCSR_BUILD)
	$(RISCV_GCC) $(NOCSR_FLAGS) $< -o $@

$(NOCSR_BUILD)/%.dump: $(NOCSR_BUILD)/%
	$(RISCV_OBJDUMP) $(DUMP_FLAGS) $< > $@

# --- UVM ----------------------------------------------------------------------
uvm-smoke:
	$(call need_tool,$(VERILATOR))
	$(call need_tool,z3)
	@test -f $(UVM_SRC)/uvm_pkg.sv || { echo "error: uvm-core submodule missing - run 'make submodules'" >&2; exit 1; }
	@mkdir -p $(SMOKE_OBJ) $(SMOKE_LOG)
	@echo "uvm-smoke: building (log: $(SMOKE_LOG)/build.log)"
	@$(VERILATOR) $(VL_SIM_FLAGS) --top-module smoke_tb_top $(UVM_FLAGS) $(SMOKE_SRCS) \
	    -Mdir $(SMOKE_OBJ) -o Vsmoke > $(SMOKE_LOG)/build.log 2>&1 \
	    || { tail -40 $(SMOKE_LOG)/build.log; echo "uvm-smoke: BUILD FAILED" >&2; exit 1; }
	@echo "uvm-smoke: running (log: $(SMOKE_LOG)/run.log)"
	@$(SMOKE_OBJ)/Vsmoke +UVM_TESTNAME=smoke_test +UVM_NO_RELNOTES > $(SMOKE_LOG)/run.log 2>&1; \
	    grep -E '^UVM_(INFO|WARNING|ERROR|FATAL) :|SMOKE TEST' $(SMOKE_LOG)/run.log
	@# The simulator exits 0 even after UVM_FATAL, so pass/fail comes from the log.
	@grep -q '\*\* UVM SMOKE TEST PASSED \*\*' $(SMOKE_LOG)/run.log \
	    || { echo "uvm-smoke: FAILED (see $(SMOKE_LOG)/run.log)" >&2; exit 1; }
	@echo "uvm-smoke: PASSED"

# --- aggregate / housekeeping -------------------------------------------------
test: lint riscv-tests-build uvm-smoke

clean:
	rm -rf $(BUILD_DIR) $(VL_OBJ_ROOT)

# Targets named in CLAUDE.md that later phases implement. They fail loudly so
# nothing can mistake a placeholder for a passing run.
PLANNED_TARGETS := test-core riscv-tests cosim uvm pnr
.PHONY: $(PLANNED_TARGETS)
$(PLANNED_TARGETS):
	@echo "error: 'make $@' is not implemented yet - see 'make help' and PROGRESS.md" >&2
	@exit 1
