# Progress

Phase definitions and acceptance criteria: CLAUDE.md section 8.
Architectural decisions and test exclusions: [docs/decisions.md](docs/decisions.md).

**Current phase: 1, starting with a design proposal for owner approval. Phase 0 is complete.**

| Phase | Deliverable | Status |
|---|---|---|
| 0 | Repo skeleton, Makefile, toolchain check, riscv-tests, UVM smoke test | **done** (2026-09-29) |
| 1 | Core with ideal memories, no CSRs | in progress: design proposal awaiting approval |
| 2 | Zicsr, traps, FENCE.I | not started |
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

Acceptance: directed hazard tests pass, and all `rv32ui-p-*` built with the CSR-free environment pass (exclusions documented).

- [ ] Design proposal: **awaiting owner approval**
- [ ] RTL
- [ ] Core testbench (`tb/core_tb`, `tb/common`)
- [ ] Directed hazard tests
- [ ] `make test-core`, `make riscv-tests`

## Open items for the project owner

1. Approve the Phase 1 design proposal, including the exclusion candidates `rv32ui-p-ma_data` and `rv32ui-p-fence_i` (D-009).
2. How to build `rv32mi-p-csr` (D-003). To decide in Phase 2.
3. Whether to enable UVM DPI for register-model backdoor access (D-011). To decide in Phase 7.
