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
RTL_CORE := rtl/core/decoder.sv rtl/core/regfile.sv rtl/core/alu.sv \
            rtl/core/branch_unit.sv rtl/core/forwarding_unit.sv \
            rtl/core/hazard_unit.sv rtl/core/if_stage.sv rtl/core/ex_stage.sv \
            rtl/core/mem_stage.sv rtl/core/csr_file.sv rtl/core/core_top.sv
RTL_SRCS := $(RTL_PKGS) $(RTL_CORE)
RTL_TOP  := core_top

LINT_FLAGS := --lint-only -Wall --top-module $(RTL_TOP)

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
# rejects any CSR instruction. Used by Phase 1 (accept-phase1).
#
# Interrupt-hook build (D-028): the same rv32ui sources with the upstream
# compiler flags, and sw/common/test_env_irq ahead of env/p. That wrapper
# #include_next's the unmodified stock riscv_test.h and redefines only the
# EXTRA_INIT / INTERRUPT_HANDLER / EXTRA_DATA hooks. Used only in the
# random-interrupt configurations; the interrupt-free configuration runs the
# unmodified stock ELFs.
#
# Every build target ends with $(check_third_party): nothing may be written
# into third_party/ (D-028).
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
IRQ_ENV   := sw/common/test_env_irq
IRQ_BUILD := $(BUILD_DIR)/riscv-tests-irq
IRQ_TESTS := $(addprefix $(IRQ_BUILD)/,$(rv32ui_p_tests))
# Upstream rv32ui flags (isa/Makefile compile_template), plus the wrapper.
IRQ_FLAGS := -march=rv32g -mabi=ilp32 -static -mcmodel=medany -fvisibility=hidden \
             -nostdlib -nostartfiles -I$(IRQ_ENV) -Isw/common -I$(RT_ROOT)/env/p \
             -I$(RT_ISA)/macros/scalar -T$(RT_ROOT)/env/p/link.ld

STOCK_UI := $(addprefix $(RT_BUILD)/,$(rv32ui_p_tests))
STOCK_MI := $(addprefix $(RT_BUILD)/,$(rv32mi_p_tests))

# Fails if any submodule (recursively) has a modified, untracked or ignored
# file, i.e. if a build wrote into third_party/.
define check_third_party
	@dirty=$$(git submodule foreach --recursive --quiet \
	    'git status --porcelain --ignored --untracked-files=all | sed "s|^|$$displaypath: |"'); \
	  if [ -n "$$dirty" ]; then echo "$$dirty"; \
	    echo "error: third_party/ was modified by the build (D-028)" >&2; exit 1; fi
endef

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

# -----------------------------------------------------------------------------
# Core simulation (Phase 1): SystemVerilog testbench on Verilator (D-018)
# -----------------------------------------------------------------------------
CORE_TB_SRCS := tb/common/mem_model.sv tb/common/sim_ctrl.sv tb/common/tohost_monitor.sv \
                tb/core_tb/core_tb_top.sv
CORE_SIM_OBJ := $(VL_OBJ_ROOT)/core_tb
CORE_SIM     := $(CORE_SIM_OBJ)/Vcore_tb
CORE_SIM_LOG := $(BUILD_DIR)/core_tb

# Directed tests (sw/tests). The Phase 1 hazard tests use the CSR-free
# environment; the Phase 2 tests use the unmodified stock environment plus
# sw/common (simctrl.h, irq_handler.h) with the project -march.
DIRECTED_NOCSR  := hz_fwd hz_load_use hz_ctrl
DIRECTED_M      := csr_ops tr_illegal tr_misaligned tr_access_fault \
                   tr_ecall_ebreak_mret irq_directed irq_cov
DIRECTED_BUILD  := $(BUILD_DIR)/directed
DIRECTED_NOCSR_ELFS := $(addprefix $(DIRECTED_BUILD)/,$(DIRECTED_NOCSR))
DIRECTED_M_ELFS     := $(addprefix $(DIRECTED_BUILD)/,$(DIRECTED_M))
DIRECTED_ELFS       := $(DIRECTED_NOCSR_ELFS) $(DIRECTED_M_ELFS)
M_FLAGS := -march=rv32i_zicsr_zifencei -mabi=ilp32 -static -mcmodel=medany \
           -fvisibility=hidden -nostdlib -nostartfiles -Isw/common \
           -I$(RT_ROOT)/env/p -I$(RT_ISA)/macros/scalar -T$(RT_ROOT)/env/p/link.ld
SW_COMMON_HDRS := sw/common/simctrl.h sw/common/irq_handler.h

# Configuration (D-017, D-030): MEM=ideal|random, IRQ=off|on. SEED=N runs one
# seed, otherwise every seed in SEEDS (the recorded acceptance seeds). The seed
# drives the memory latency and the interrupt generator.
MEM   ?= ideal
IRQ   ?= off
SEEDS ?= 101 202 303
SEED  ?=
RUN_SEEDS  := $(if $(SEED),$(SEED),$(SEEDS))
RUN_CONFIG := $(MEM)$(if $(filter on,$(IRQ)),+irq)

RUNNER_BASE := $(PYTHON) scripts/run_riscv_tests.py --sim $(CORE_SIM) --prefix $(RISCV_PREFIX) \
               --work $(BUILD_DIR)/runs --exclude scripts/exclusions.txt --src-dir sw/tests
RUNNER1 := $(RUNNER_BASE) --phase 1
RUNNER  := $(RUNNER_BASE) --phase 2 --irq-variant-dir $(IRQ_BUILD)
# Phase 2 acceptance matrix: 7 runs per test.
PHASE2_CONFIGS := ideal ideal+irq random+irq

# =============================================================================
# Targets
# =============================================================================
.PHONY: help check-tools submodules lint riscv-tests-build riscv-tests-stock \
        riscv-tests-nocsr riscv-tests-irq uvm-smoke core-sim directed test-core \
        riscv-tests accept-phase1 accept-phase2 test clean

help:
	@echo "Mini RISC-V SoC - make targets"
	@echo ""
	@echo "  check-tools        report toolchain status (PHASE=N fails if a tool needed"
	@echo "                     by phases 0..N is missing; default PHASE=0)"
	@echo "  submodules         fetch/update third_party submodules"
	@echo "  lint               verilator --lint-only -Wall on all RTL"
	@echo "  riscv-tests-build  the three riscv-tests builds below"
	@echo "  riscv-tests-stock  rv32ui-p-* and rv32mi-p-*, stock env    -> $(RT_BUILD)/"
	@echo "  riscv-tests-irq    rv32ui-p-*, stock env + interrupt hooks -> $(IRQ_BUILD)/"
	@echo "  riscv-tests-nocsr  rv32ui-p-*, CSR-free env (Phase 1)      -> $(NOCSR_BUILD)/"
	@echo "  uvm-smoke          build and run the UVM smoke test on Verilator"
	@echo "  core-sim           build the core testbench simulator"
	@echo "  directed           build the directed tests (sw/tests)"
	@echo "  test-core          run the directed tests       [MEM=ideal|random IRQ=off|on SEED=N]"
	@echo "  riscv-tests        run rv32ui-p-* and rv32mi-p-* [MEM=ideal|random IRQ=off|on SEED=N]"
	@echo "  accept-phase1      Phase 1 acceptance: CSR-free env, ideal + random x SEEDS"
	@echo "  accept-phase2      Phase 2 acceptance: all tests x (ideal, ideal+irq, random+irq"
	@echo "                     x SEEDS), plus the interrupt coverage check"
	@echo "  test               lint, riscv-tests-build, uvm-smoke, accept-phase1, accept-phase2"
	@echo "  clean              remove $(BUILD_DIR)/ and $(VL_OBJ_ROOT)/"
	@echo ""
	@echo "  Planned (not implemented yet):"
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
riscv-tests-build: riscv-tests-stock riscv-tests-irq riscv-tests-nocsr

riscv-tests-stock:
	$(need_riscv_gcc)
	@test -f $(RT_ISA)/Makefile || { echo "error: riscv-tests submodule missing - run 'make submodules'" >&2; exit 1; }
	@mkdir -p $(RT_BUILD)
	$(MAKE) -C $(RT_BUILD) -f $(RT_UP)/$(RT_ISA)/Makefile src_dir=$(RT_UP)/$(RT_ISA) \
	    XLEN=32 RISCV_PREFIX=$(RISCV_PREFIX) \
	    $(RT_TESTS) $(addsuffix .dump,$(RT_TESTS))
	$(check_third_party)
	@echo "riscv-tests-stock: $(words $(RT_TESTS)) ELFs in $(RT_BUILD)/"

riscv-tests-nocsr: $(NOCSR_TESTS) $(addsuffix .dump,$(NOCSR_TESTS))
	$(check_third_party)
	@echo "riscv-tests-nocsr: $(words $(NOCSR_TESTS)) ELFs in $(NOCSR_BUILD)/"

riscv-tests-irq: $(IRQ_TESTS) $(addsuffix .dump,$(IRQ_TESTS))
	$(check_third_party)
	@echo "riscv-tests-irq: $(words $(IRQ_TESTS)) ELFs in $(IRQ_BUILD)/"

$(IRQ_BUILD)/rv32ui-p-%: $(RT_ISA)/rv32ui/%.S $(IRQ_ENV)/riscv_test.h $(SW_COMMON_HDRS)
	$(need_riscv_gcc)
	@mkdir -p $(IRQ_BUILD)
	$(RISCV_GCC) $(IRQ_FLAGS) $< -o $@

$(IRQ_BUILD)/%.dump: $(IRQ_BUILD)/%
	$(RISCV_OBJDUMP) $(DUMP_FLAGS) $< > $@

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
	$(check_third_party)
	@echo "uvm-smoke: PASSED"

# --- core simulation ------------------------------------------------------------
core-sim: $(CORE_SIM)

$(CORE_SIM): $(RTL_SRCS) $(CORE_TB_SRCS) Makefile
	$(call need_tool,$(VERILATOR))
	@mkdir -p $(CORE_SIM_OBJ) $(CORE_SIM_LOG)
	@echo "core-sim: building (log: $(CORE_SIM_LOG)/build.log)"
	@$(VERILATOR) $(VL_SIM_FLAGS) --assert --top-module core_tb_top \
	    $(RTL_SRCS) $(CORE_TB_SRCS) -Mdir $(CORE_SIM_OBJ) -o Vcore_tb \
	    > $(CORE_SIM_LOG)/build.log 2>&1 \
	    || { tail -40 $(CORE_SIM_LOG)/build.log; echo "core-sim: BUILD FAILED" >&2; exit 1; }
	$(check_third_party)
	@echo "core-sim: $(CORE_SIM)"

directed: $(DIRECTED_ELFS)
	$(check_third_party)

$(DIRECTED_NOCSR_ELFS): $(DIRECTED_BUILD)/%: sw/tests/%.S $(NOCSR_ENV)/riscv_test.h
	$(need_riscv_gcc)
	@mkdir -p $(DIRECTED_BUILD)
	$(RISCV_GCC) $(NOCSR_FLAGS) $< -o $@
	$(RISCV_OBJDUMP) $(DUMP_FLAGS) $@ > $@.dump

$(DIRECTED_M_ELFS): $(DIRECTED_BUILD)/%: sw/tests/%.S $(SW_COMMON_HDRS)
	$(need_riscv_gcc)
	@mkdir -p $(DIRECTED_BUILD)
	$(RISCV_GCC) $(M_FLAGS) $< -o $@
	$(RISCV_OBJDUMP) $(DUMP_FLAGS) $@ > $@.dump

test-core: $(CORE_SIM) directed
	$(RUNNER) --configs $(RUN_CONFIG) --seeds $(RUN_SEEDS) -- $(DIRECTED_ELFS)

riscv-tests: $(CORE_SIM) riscv-tests-stock riscv-tests-irq
	$(RUNNER) --configs $(RUN_CONFIG) --seeds $(RUN_SEEDS) -- $(STOCK_UI) $(STOCK_MI)

accept-phase1: $(CORE_SIM) directed riscv-tests-nocsr
	$(RUNNER1) --configs ideal random --seeds $(SEEDS) \
	    -- $(DIRECTED_NOCSR_ELFS) $(NOCSR_TESTS)

accept-phase2: $(CORE_SIM) directed riscv-tests-stock riscv-tests-irq
	$(RUNNER) --configs $(PHASE2_CONFIGS) --seeds $(SEEDS) --irq-coverage \
	    -- $(DIRECTED_ELFS) $(STOCK_UI) $(STOCK_MI)

# --- aggregate / housekeeping -------------------------------------------------
test: lint riscv-tests-build uvm-smoke accept-phase1 accept-phase2

clean:
	rm -rf $(BUILD_DIR) $(VL_OBJ_ROOT)

# Targets named in CLAUDE.md that later phases implement. They fail loudly so
# nothing can mistake a placeholder for a passing run.
PLANNED_TARGETS := cosim uvm pnr
.PHONY: $(PLANNED_TARGETS)
$(PLANNED_TARGETS):
	@echo "error: 'make $@' is not implemented yet - see 'make help' and PROGRESS.md" >&2
	@exit 1
