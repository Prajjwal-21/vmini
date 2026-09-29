# Progress

Phase definitions and acceptance criteria: CLAUDE.md section 8.
Architectural decisions and test exclusions: [docs/decisions.md](docs/decisions.md).

**Current phase: 2. Implemented; `make accept-phase2` passes. Awaiting owner review, including one proposed design change (D-033) and one testbench register added during implementation (`IRQ_RANDOM`, D-029).**

| Phase | Deliverable | Status |
|---|---|---|
| 0 | Repo skeleton, Makefile, toolchain check, riscv-tests, UVM smoke test | **done** (2026-09-29) |
| 1 | Core with ideal and random-latency memories, no CSRs | **done** (2026-09-29) |
| 2 | Zicsr, traps, interrupts, FENCE.I | implemented, acceptance passes; awaiting owner review |
| 3 | RVFI trace + Spike offline co-simulation | not started |
| 4 | I-cache / D-cache, random-latency memory | not started |
| 5 | AXI4-Lite interconnect, arbiter, AXI-to-APB bridge | not started |
| 6 | CLINT, PLIC, UART, SPI | not started |
| 7 | UVM environment | not started |
| 8 | OpenLane / LibreLane on sky130 | not started |

## Phase 0: repo skeleton, Makefile, toolchain, riscv-tests, UVM smoke test

Acceptance: `make lint` runs, the riscv-tests ELFs build, and `make uvm-smoke` passes.

- [x] Directory layout from CLAUDE.md section 3
- [x] `Makefile` targets: `help`, `check-tools`, `submodules`, `lint`, `riscv-tests-build` (`-stock` and `-nocsr`), `uvm-smoke`, `test`, `clean`, plus failing placeholders for `test-core`, `riscv-tests`, `cosim`, `uvm`, `pnr`
- [x] `scripts/check_tools.py`: per-phase toolchain check with install hints. GTKWave dropped, Z3 added.
- [x] Toolchain installed: Verilator 5.052 and riscv64-elf-gcc 16.2.0 with binutils 2.47
- [x] rv32i/ilp32 libgcc multilib present, with `__mulsi3`, `__divsi3` and `__modsi3` (D-002)
- [x] `third_party/riscv-tests` at `bcffa2b` (`env` at `6de71ed`)
- [x] `third_party/uvm-core` at tag `2020.3.1` (D-011)
- [x] `rtl/pkg/riscv_pkg.sv` and `rtl/pkg/soc_pkg.sv`. **`make lint` is clean.**
- [x] **`make riscv-tests-stock`:** 42 `rv32ui-p-*` and 16 `rv32mi-p-*` ELFs, with dumps
- [x] CSR-free test environment `sw/common/test_env_nocsr` (D-009). **`make riscv-tests-nocsr`:** 42 `rv32ui-p-*` ELFs, with no CSR, `ecall` or `mret` instructions.
- [x] ELF instruction-set audit (D-003). rv32ui is clean. `rv32mi-p-csr` contains FP code, which is a Phase 2 decision.
- [x] UVM smoke test `tb/uvm/smoke`: DUT, agent (sequencer, driver, monitor), scoreboard, env and test. It verilates and builds with zero warnings under `-Wall`.
- [x] Z3 5.1.0 installed (D-013)
- [x] **`make check-tools` passes**
- [x] **`make uvm-smoke` passes:** 50 of 50 results checked, 0 UVM_ERROR, 0 UVM_FATAL. The 2 UVM_WARNINGs are the expected no-DPI notices (D-011).
- [x] Mutation check: a DUT deliberately broken with `+1` makes the scoreboard report a UVM_ERROR on every transaction
- [x] Initial commit

## Phase 1: core with ideal single-cycle memories, no CSRs

Acceptance: directed hazard tests pass, and all `rv32ui-p-*` built with the CSR-free environment pass (exclusions `ma_data` and `fence_i`, D-015/D-016). Everything must pass with ideal memory and with random latency for seeds 101, 202 and 303 (`make accept-phase1`, D-017).

- [x] Design proposal approved with changes (D-014 to D-018)
- [x] Sections 3.2 and 4.6 approved, with the four owner fixes (D-019 to D-021)
- [x] RTL in `rtl/core/`: `core_top`, `if_stage`, `decoder`, `regfile`, `forwarding_unit`, `hazard_unit`, `alu`, `branch_unit`, `ex_stage`, `mem_stage`. The core types are in `riscv_pkg`. **`make lint` is clean** (12 files, `-Wall`).
- [x] Core testbench: `tb/core_tb/core_tb_top.sv`, `tb/common/mem_model.sv` (ideal and seeded-random modes, with a protocol rule 1 checker) and `tb/common/tohost_monitor.sv`. It builds with zero Verilator warnings under `-Wall --assert`.
- [x] Simulation-only assertions: no exception reaches MEM (Phase 1); no D-port request while MEM is unsafe (4.6); fetch-unit credit, queue and drop invariants; D-port response ownership.
- [x] Directed hazard tests `sw/tests/hz_fwd.S`, `hz_load_use.S` and `hz_ctrl.S`, each with minimum hazard-event counts (`HAZARD-EXPECT`)
- [x] `scripts/run_riscv_tests.py` and `scripts/exclusions.txt`
- [x] Make targets `core-sim`, `test-core`, `riscv-tests` and `accept-phase1`, with `MEM=ideal|random`, `SEED=N` and `SEEDS` (default 101 202 303)
- [x] **`make accept-phase1`: 172/172 runs pass.** That is 40 `rv32ui-p-*` (CSR-free) plus 3 directed tests, each run in ideal mode and with random latency for seeds 101, 202 and 303. `ma_data` and `fence_i` are excluded (D-015, D-016).
- [x] **`make test` from a clean tree passes** (lint, riscv-tests-build, uvm-smoke, accept-phase1), about 1 minute of wall time.
- [x] Mutation check, three injected bugs, all caught:
  - Forwarding priority reversed: 2/86 runs pass.
  - Load-use detection disabled: 75/86 pass; `hz_load_use` fails in both modes.
  - Stale-fetch dropping disabled: every random-latency run fails and every ideal run passes. This confirms that random latency is needed to cover the drop logic (D-017).
- [x] Owner confirmed and committed

## Phase 2: Zicsr, traps, interrupts, FENCE.I

Acceptance (owner, 2026-09-29):
- every `rv32ui-p` test with the stock environment (`fence_i` included)
- every non-excluded `rv32mi-p` test
- the new directed tests

All under ideal memory and random latency with 3 seeds, with random interrupts enabled.

- [x] `hz_ctrl` hazard threshold derived rather than measured (D-022)
- [x] Design approved (owner decisions D1–D11 → D-023 to D-032); interrupt coverage events and derived minimums added (architecture.md P2.13, D-030)
- [x] RTL: `csr_file` (new), decoder (SYSTEM/CSR/FENCE.I, illegal rules), `ex_stage` (trap cause and mtval), `mem_stage` (commit point: trap/interrupt/serializing commit, CSR commands), `hazard_unit` (MEM redirect, serialize term, D-033 hold), `core_top` (interrupt ports, CSR file, redirect mux). Phase 1 assertion removed; new assertions for P2.5/P2.7 and `a_dreq_stable`. **`make lint` clean** (13 files).
- [x] Testbench: `tb/common/sim_ctrl.sv` (interrupt lines, random generator, IRQ_ACK/FORCE/LINES/RANDOM), `mem_model` routes the 0x4000_0000 window, `core_tb_top` checks (entries = acks = `irq_handled`, raised − acked = lines high, priority at every entry), coverage counters, `+trace`
- [x] Software: `sw/common/simctrl.h`, `irq_handler.h`, `test_env_irq/riscv_test.h` (hooks over the unmodified stock env)
- [x] Directed tests: `csr_ops`, `tr_illegal`, `tr_misaligned`, `tr_access_fault`, `tr_ecall_ebreak_mret`, `irq_directed`, `irq_cov`
- [x] Makefile: `riscv-tests-irq`, stock-env directed builds, `test-core`/`riscv-tests` with `MEM=… IRQ=… SEED=…`, `accept-phase2`; every build target checks `third_party/` is clean (D-028)
- [x] Runner bug fixed: hex files were cached by ELF basename, so a stock ELF could silently run the stale CSR-free hex of the same name. They are now keyed by build directory.
- [x] Bug found and fixed (D-033, **proposed**): an interrupt arriving while EX held an unaccepted D-port request withdrew that request (protocol rule 1). Caught by `mem_model` in `rv32ui-p-lhu`/`ld_st` with random latency and interrupts.
- [x] **`make accept-phase2`: 462/462 runs pass** (66 tests × 7 configs; `ma_data` and `pmpaddr` excluded), and the interrupt coverage totals meet every derived minimum
- [x] Mutation check, 6 injected bugs, all caught (interrupt on a serializing instruction, even with its assertions disabled; interrupt `mepc` = pc; trapping instructions retire; D-033 removed; MRET not setting MPIE; EBREAK `mtval` = 0)
- [ ] Owner review of D-033 and `IRQ_RANDOM`, then confirmation of Phase 2

## Open items for the project owner

1. D-033 (no interrupt while EX holds an unaccepted D request): proposed, implemented.
2. `IRQ_RANDOM` register added to `sim_ctrl` (D-029).
3. Whether to enable UVM DPI for register-model backdoor access (D-011). To decide in Phase 7.
