# Design decisions

Each entry records the context, the decision, and the rationale. Status is one of:
**Accepted** (in effect), **Proposed** (in effect provisionally, awaiting owner approval), or **Open** (needs owner input).

---

## D-001: Build riscv-tests out of tree, `-p` variants only

- **Date / phase:** 2026-09-29, Phase 0
- **Status:** Accepted
- **Context:** CLAUDE.md forbids modifying `third_party/`. The upstream `isa/Makefile` writes its build products into the source tree by default. The test targets are `rv32ui-p-*` and `rv32mi-p-*` only. The `-v` variants need S-mode and virtual memory, which this design omits. They also need `md5sum` at build time.
- **Decision:** `make riscv-tests-build` runs the upstream `isa/Makefile` from `build/riscv-tests/`, setting `src_dir` to point back at the submodule. It asks explicitly for the `-p` ELFs and their `.dump` disassembly. The test lists are read from the upstream `rv32ui/Makefrag` and `rv32mi/Makefrag`, so they follow the submodule when it is updated. The current lists are 42 rv32ui tests and 16 rv32mi tests.
- **Rationale:** This keeps the submodule clean, uses the upstream build rules unchanged, and puts every output under `build/`.

## D-002: Use Homebrew `riscv64-elf-gcc`

- **Date / phase:** 2026-09-29, Phase 0
- **Status:** Accepted (owner approved 2026-09-29)
- **Context:** CLAUDE.md section 2 names `riscv32-unknown-elf-gcc` or `riscv64-unknown-elf-gcc`. On this machine (macOS 27, arm64), those come from the `riscv-software-src/riscv` Homebrew tap. That tap has no prebuilt bottle for this macOS version, so it builds the full GNU toolchain from source. Homebrew core ships a prebuilt `riscv64-elf-gcc` (GCC 16.2.0, binutils 2.47), whose prefix is `riscv64-elf-`. It is a bare-metal build that includes libgcc, and the project's software is freestanding.
- **Decision:** `riscv64-elf-` is the project standard. The Makefile still falls back to `riscv32-unknown-elf-` or `riscv64-unknown-elf-` if that prefix is missing. `make RISCV_PREFIX=...` overrides the choice. `scripts/check_tools.py` checks that the chosen compiler accepts `-march=rv32i_zicsr_zifencei -mabi=ilp32`.
- **Rationale:** The compiler installs as a prebuilt bottle in minutes, compared with an hour or more for a source build of the tap toolchain. Every flag in section 2 still applies. The prefix is the only difference.
- **Multilib check (2026-09-29):** `riscv64-elf-gcc -print-multi-lib` lists `rv32i/ilp32`, `rv32im/ilp32`, `rv32iac/ilp32`, `rv32imac/ilp32`, `rv32imafc/ilp32f`, `rv64imac/lp64` and `rv64imafdc/lp64d`.
  - `-march=rv32i_zicsr_zifencei -mabi=ilp32` selects `rv32i/ilp32`.
  - That `libgcc.a` is ELF32 and defines `__mulsi3`, `__divsi3`, `__modsi3`, `__udivsi3` and `__umodsi3`.
  - So `sw/common` does **not** need its own software multiply and divide routines.

## D-003: Keep the upstream riscv-tests compile flags

- **Date / phase:** 2026-09-29, Phase 0
- **Status:** Accepted. The `rv32mi-p-csr` question is resolved (2026-09-29, Phase 2 audit, below).
- **Context:** Upstream compiles rv32ui and rv32mi with `-march=rv32g -mabi=ilp32`, which is hard-coded in `isa/Makefile`. The project's own flags use `-march=rv32i_zicsr_zifencei`.
- **Decision:** Build the stock-environment tests with the upstream flags unchanged.
- **Verification (2026-09-29):** all 58 ELFs were disassembled with `-M no-aliases`.
  - **rv32ui:** only RV32I, Zicsr and Zifencei. The one instruction outside the test body is the `unimp` padding (`0xc0001073`, `csrrw x0, cycle, x0`) emitted by `RVTEST_CODE_END`, which never executes.
  - **rv32mi:** several deliberate exceptions, all expected:
    - `illegal` contains `sret`, `sfence.vma` and `.word 0` on purpose, and expects them to trap.
    - `shamt` contains `.word 0x02051513` (an RV64-only shift amount) on purpose, and expects it to trap.
    - `ma_fetch` contains compressed instructions under `.option rvc`. They are gated at run time: without C support, the test's trap handler skips them.
- **Correction to the original rationale:** `-march` *does* change the generated code for one test. `rv64si/csr.S`, which `rv32mi-p-csr` includes, wraps F-extension code (`fmv.w.x`, `fsw`, test case 13) in `#ifdef __riscv_flen`. That macro is defined for `rv32g`, so the stock ELF runs FP instructions that an RV32I core must trap as illegal.
- **Phase 2 options:**
  - (a) Build `rv32mi-p-csr` with a project rule using `-march=rv32i_zicsr_zifencei`, same sources, `third_party/` untouched.
  - (b) Record test 13 as an exclusion.
  - Proposal: (a).
- **Resolution (2026-09-29, Phase 2 audit):** neither option is needed. `rv64si/csr.S` gates the FP section at run time on `misa.F`; our `misa` reads `0x4000_0100` (I only), so the `fmv.w.x`/`fsw` in the stock ELF are never executed. `rv32mi-p-csr` is built and run from the stock ELF, unchanged.

## D-004: Makefile uses repository-relative paths only (the repository path contains spaces)

- **Date / phase:** 2026-09-29, Phase 0
- **Status:** Accepted. The owner decided on 2026-09-29 to keep the repository at `~/Desktop/mini risc v`, recorded in CLAUDE.md section 2.
- **Context:** The repository lives at `~/Desktop/mini risc v`. GNU Make cannot handle spaces in file names, and `$(CURDIR)` or `$(abspath ...)` would break. Some later tools are likely to break too, especially OpenLane/LibreLane's Tcl and OpenROAD flows and possibly Verilator's generated makefiles.
- **Decision:** Every Makefile path is relative to the repository root, and `make` is run from the root. The Makefile targets GNU Make 3.81, the macOS system make, so `gmake` is not required.
- **Consequences:**
  - Verilator cannot build under this path (see D-010).
  - OpenLane/LibreLane will probably need the same treatment in Phase 8.

## D-005: What goes in each package

- **Date / phase:** 2026-09-29, Phase 0
- **Status:** Accepted
- **Decision:**
  - `riscv_pkg` holds only facts fixed by the RISC-V ISA: widths, major opcodes, and funct3/funct7 values. Microarchitectural types (pipeline structs, decoded-op enums) are added in Phase 1, and CSR definitions in Phase 2, each after design approval.
  - `soc_pkg` is the single source of truth for the memory map (section 5.4), `RESET_PC` (set to `MEM_BASE`, 0x8000_0000), and `CACHEABLE_BASE` (0x8000_0000; everything below it bypasses the D-cache).
- **Rationale:** This is enough real RTL for `make lint` to check in Phase 0 without deciding any Phase 1 design question early.

## D-006: Placeholder Makefile targets fail loudly

- **Date / phase:** 2026-09-29, Phase 0
- **Status:** Accepted
- **Decision:** `test-core`, `riscv-tests`, `cosim`, `uvm` and `pnr` exist now, but exit with status 1 and the message "not implemented yet". `make test` runs only what is currently implemented. `riscv-tests-build` builds the ELFs. `riscv-tests`, added in Phase 1, will build and run them on the core.
- **Rationale:** CLAUDE.md section 7 rule 8 requires every capability to be reachable through `make`. A placeholder must never look like a passing run.

## D-007: riscv-tests submodule pin

- **Date / phase:** 2026-09-29, Phase 0
- **Status:** Accepted
- **Decision:** `third_party/riscv-tests` is pinned at `bcffa2b3188b040c611f90dc0b6e422f54775a09` (2026-09-25, "Add Zalasr Support (#668)"). Its `env` submodule is at `6de71edb142be36319e380ce782c3d1830c65d68`. Change the pin only on purpose, and record the change here.

## D-008: Waveform viewer

- **Date / phase:** 2026-09-29, Phase 0
- **Status:** Accepted: Surfer (owner decision, 2026-09-29). GTKWave is removed from `make check-tools`.
- **Context:** CLAUDE.md section 2 specifies GTKWave. On this machine, `/opt/homebrew/bin/gtkwave` points to `/Applications/gtkwave.app`, which no longer exists. The Homebrew cask was disabled upstream on 2025-10-29, so it cannot be reinstalled. Surfer 0.6.0, which reads FST and VCD, is already installed at `/opt/homebrew/bin/surfer`.
- **Options:** (a) use Surfer; (b) build GTKWave from source; (c) install GTKWave through MacPorts.
- **Proposal:** (a). Simulations write FST either way, so the choice only affects viewing.

## D-009: Phase 1 and the riscv-tests `-p` environment's CSR requirements

- **Date / phase:** 2026-09-29, raised in Phase 0 for Phase 1
- **Status:** Accepted: option (a) (owner decision, 2026-09-29). Implemented in Phase 0.
- **Context:** The Phase 1 core has no CSRs, and its acceptance criterion is "all non-CSR `rv32ui-p-*` pass". The stock `env/p/riscv_test.h` uses the following, so no rv32ui test can pass unmodified on a core without CSRs:
  - `RVTEST_CODE_BEGIN` runs `csrw` and `csrr` on `mtvec`, `mstatus`, `mepc`, `mhartid`, `satp`, `pmpaddr0`, `medeleg` and other CSRs, then `mret`s into the test.
  - `RVTEST_PASS` and `RVTEST_FAIL` signal the result by executing `ecall`. The trap handler reads `mcause` and then writes `tohost`.
- **Options:**
  - (a) A project-owned replacement `riscv_test.h` in `tb/` or `sw/`, added through `-I` ahead of `env/p`. It would have no CSR code and would write `tohost` directly. `third_party/` stays untouched.
  - (b) Move minimal CSR, `ecall` and `mret` support into Phase 1.
  - (c) Have the Phase 1 testbench treat SYSTEM instructions specially.
- **Implementation:**
  - `sw/common/test_env_nocsr/riscv_test.h` replaces `RVTEST_CODE_BEGIN`, `RVTEST_CODE_END`, `RVTEST_PASS`, `RVTEST_FAIL`, `RVTEST_DATA_BEGIN` and `RVTEST_DATA_END`.
  - PASS and FAIL store to `tohost`: 1 means pass, `(n << 1) | 1` means test `n` failed. The upper word is written 0.
  - `RVTEST_CODE_END` is a self-loop instead of `unimp`.
  - The stock `env/p/link.ld` is reused as is.
  - `make riscv-tests-nocsr` builds all 42 `rv32ui-p-*` into `build/riscv-tests-nocsr/` with `-march=rv32i_zifencei` (no Zicsr), so any CSR instruction fails to assemble.
- **Verification (2026-09-29):** all 42 ELFs contain only RV32I instructions plus `fence` and `fence.i`. `_start` is at 0x80000000 and `tohost` at 0x80001000.
- **Phase 2:** switch to the stock `env/p` build, `make riscv-tests-stock`.
- **Phase 1 exclusions:** decided in D-015 (`ma_data`, permanent) and D-016 (`fence_i`, Phase 1 only).

## D-010: Verilator object directories live outside the repository

- **Date / phase:** 2026-09-29, Phase 0
- **Status:** Accepted
- **Context:** Verilator's `verilated.mk` stops with: `Unsupported: GNU Make cannot build in directories containing spaces, build elsewhere: '.../mini risc v/build/uvm-smoke/obj_dir'`.
- **Decision:**
  - When `$(CURDIR)` contains spaces, `VL_OBJ_ROOT` defaults to `~/.cache/mini-riscv/verilator`. Otherwise it defaults to `build/verilator`.
  - Logs and every other build product stay in `build/`.
  - `make clean` removes both locations.
- **Notes:**
  - Verilator creates only the last directory level of `-Mdir`, so the Makefile runs `mkdir -p` first.
  - C++ sources passed to Verilator, such as UVM's DPI code, must also have space-free paths, because the C++ build runs inside the object directory.

## D-011: UVM on Verilator: uvm-core 2020.3.1, built without DPI

- **Date / phase:** 2026-09-29, Phase 0
- **Status:** Accepted for Phase 0. Revisit DPI in Phase 7.
- **Context:** The owner chose Verilator as the UVM simulator. Verilator's own regression suite runs unmodified Accellera UVM 2017-1.0, 2020.3.1 and 2020.3.2, and Verilator ships lint waivers for the UVM base files.
- **Decision:**
  - `third_party/uvm-core` is a submodule pinned to tag `2020.3.1` (`78c06547a2a0a29b3dc9dcafae62b75b2ff61544`).
  - It is compiled from source with `+define+UVM_NO_DPI` and `--binary --timing -Wall`.
- **Why no DPI:** the DPI build (`--vpi` plus `src/dpi/uvm_dpi.cc`) fails on macOS with `uvm_dpi.h:45:10: fatal error: 'malloc.h' file not found`. It also needs a space-free path to the `.cc` file (D-010). Fixing the first problem would need a stand-in `malloc.h` on the include path.
- **Cost of no DPI:**
  - UVM prints `NO_DPI_USED` ("thinking of removing support for UVM_NO_DPI") and `NO_VISIT_CHECK` warnings.
  - There is no regex-based component name checking, and no HDL backdoor access for the register model.
  - Phase 7 should decide whether backdoor access is needed. If it is, add the `malloc.h` stand-in under `tb/uvm/`.
- **Other findings:**
  - The simulator exits 0 even after `UVM_FATAL`, so `make uvm-smoke` decides pass/fail from the log.
  - The `uvm_field_*` automation macros expand to dozens of `-Wall` width warnings inside user code, so project UVM code writes `convert2string` and `do_copy` explicitly instead.

## D-012: Lint waivers so far

- **Date / phase:** 2026-09-29, Phase 0
- **Status:** Accepted
- **Waivers:** each is a targeted `lint_off`/`lint_on` pair with a comment in the source.
  - `UNUSEDPARAM` around the bodies of `riscv_pkg` and `soc_pkg`. A package is a catalogue of constants, and not every constant is used by every module or configuration. The warning stays active for parameters declared inside modules.
  - `DECLFILENAME` around `tb/uvm/smoke/smoke_pkg.sv`. UVM convention puts many classes in one package file.
  - `UNDRIVEN` and `UNUSEDSIGNAL` around `tb/uvm/smoke/smoke_if.sv`. The signals are only accessed through a virtual interface from class code, which Verilator's usage analysis does not follow.

## D-013: Z3 is a required tool from Phase 0

- **Date / phase:** 2026-09-29, Phase 0
- **Status:** Accepted. Z3 5.1.0 was installed with owner approval on 2026-09-29.
- **Context:** Verilator implements constrained randomization by calling an SMT solver at run time (`z3 --in` by default, or whatever `VERILATOR_SOLVER` names). Without one, the smoke test prints `%Warning: Unable to communicate with SAT solver`, then `randomize()` returns 0 and the sequence raises `UVM_FATAL`.
- **Decision:** Z3 is required from Phase 0, and `make check-tools` and `make uvm-smoke` both check for it. The smoke test keeps its constraint on purpose, so this dependency is caught now rather than in Phase 7. Removing the constraint would weaken the test.

## D-014: The I-side inserts bubbles; only the D-side raises the global stall

- **Date / phase:** 2026-09-29, Phase 1 design
- **Status:** Accepted (owner approved 2026-09-29). CLAUDE.md section 5.1 is updated.
- **Context:** Spec section 5.1 originally said the single global stall comes from the I-cache, the D-cache and the bus.
- **Decision:** A decoupled fetch unit with a 2-entry fetch queue and a credit limit feeds ID. When no instruction is available, ID receives a bubble. `stall` is raised only by the D-side: MEM waiting for its response, or EX unable to issue its request.
- **Rationale:**
  - Older instructions keep moving during an I-cache miss.
  - If the I-side stalled, the fetch request would have to depend on the D-port's `ready`. The Phase 5 arbiter makes each port's `ready` depend on the other port's `valid`, so that would create a combinational loop.
- **Detail:** `docs/architecture.md` sections 3.1 and 4.4.

## D-015: `rv32ui-p-ma_data` is excluded permanently

- **Date / phase:** 2026-09-29, Phase 1 design
- **Status:** Accepted (owner approved 2026-09-29)
- **Reason:** The test performs misaligned loads and stores and expects them to complete in hardware. Upstream runs Spike with `--misaligned` for this. Spec section 5.2 makes misaligned data accesses an exception, and the `-p` environment has no handler to emulate them, so the test cannot pass in Phase 1 (no traps) or Phase 2 (trap into an environment with no handler).
- **Consequence:** Phase 3 Spike co-simulation runs without `--misaligned`, matching the hardware. Misaligned-access traps are still tested by `rv32mi-p-ma_addr` in Phase 2.

## D-016: `rv32ui-p-fence_i` is excluded in Phase 1 only

- **Date / phase:** 2026-09-29, Phase 1 design
- **Status:** Accepted (owner approved 2026-09-29)
- **Reason:** FENCE.I is Phase 2 scope (CLAUDE.md section 8). In Phase 1 it executes as a NOP, so the self-modifying-code test may execute stale instructions.
- **Consequence:** the test is re-enabled in Phase 2, where FENCE.I redirects to `pc + 4` from MEM through the stale-fetch mechanism (D-020). `scripts/exclusions.txt` limits the exclusion to phase 1, so `--phase 2` runs it.

## D-017: Random memory latency is part of Phase 1 acceptance

- **Date / phase:** 2026-09-29, Phase 1 design
- **Status:** Accepted (owner decision 2026-09-29, changed from the proposal)
- **Decision:** `tb/common/mem_model.sv` has two modes:
  - `ideal`: always ready, 1-cycle response.
  - `random`: on each port, independently, `ready` is dropped with probability 1/4 per cycle, and each response takes 1–6 cycles, still in order. Runs are seeded with `+seed=N`.
- **Phase 1 acceptance:** every directed hazard test and every non-excluded `rv32ui-p-*` (CSR-free environment) must pass in `ideal` mode, and in `random` mode for each seed in the recorded default **`SEEDS = 101 202 303`**. `make accept-phase1` runs the whole set. Any single run can be reproduced with `MEM=random SEED=N`.
- **Rationale:** It exercises the stall, redirect and stale-fetch logic under realistic timing while the core is fresh, rather than waiting for the caches in Phase 4.
- **Evidence (2026-09-29):** in a mutation check with stale-fetch dropping disabled, every ideal-mode run still passed and every random-latency run failed. With ideal memory, a stale response only ever arrives in the redirect cycle itself.

## D-018: The core testbench is SystemVerilog, built with Verilator `--binary`

- **Date / phase:** 2026-09-29, Phase 1 design
- **Status:** Accepted (owner approved 2026-09-29)
- **Decision:** The testbench is SystemVerilog, built with `verilator --binary --timing`. ELFs are converted with `objcopy -O verilog` and loaded with `$readmemh`. The `tohost` address comes from `nm` and is passed as `+tohost=`.
- **Rationale:** It uses the same flow as the UVM work, there is no C++ ELF loader to maintain, and the memory model is reused unchanged in later phases.

## D-019: Data-request issue rule (no speculative data access)

- **Date / phase:** 2026-09-29, Phase 1 design
- **Status:** Accepted (owner approved 2026-09-29, with fixes).
- **Owner fixes:**
  - MEM-side waiting is keyed on a `req_sent` bit in EX/MEM, not on the instruction type. Otherwise a misaligned load or store, which never sends a request, would wait forever for a response.
  - Responses must never depend combinationally on the request (CLAUDE.md section 5.1).
  - In Phase 1, a simulation-only assertion stops the run as soon as an instruction with an exception flag reaches MEM.
- **Requirement (owner):** a cancelled store must never reach memory, and a cancelled load must never reach an MMIO device. The design must already be correct for Phase 2 traps and interrupts.
- **Decision:** EX issues its D-port request only when:
  - its own instruction has no exception, and
  - the instruction in MEM cannot still trap: it has no exception flag, is not waiting for its response, and its response did not return `err`, and
  - no trap or interrupt is being taken this cycle.

  Interrupts are taken on the instruction committing in MEM, after it commits, with `mepc` set to its `next_pc`, so memory streams cannot starve them. EX holds (global stall) until its request is accepted.
- **Cost:** a combinational path from `dmem_rsp.valid`/`err` to `dmem_req_valid`. Back-to-back memory operations still run at one per cycle.

## D-020: Stale fetch responses are discarded with a counter, not an epoch bit

- **Date / phase:** 2026-09-29, Phase 1 design
- **Status:** Accepted (owner approved 2026-09-29).
- **Phase 4 note:** FENCE.I must also wait for the D-cache write buffer to drain before redirecting.
- **Decision:** `drop_q` counts in-flight I-port responses that belong to an abandoned path. On a redirect, `drop_q` is set to the number of requests still in flight, excluding any response arriving in that cycle, which is dropped directly. Each later response decrements it and is discarded, even if it carries `err`.
- **Rationale:** Responses are in order and untagged. An epoch scheme would need a per-request epoch FIFO in the core, which is the same information with more state.
- **Reused by:** Phase 2 trap entry, MRET and FENCE.I.
- **Implementation detail (2026-09-29, architecture.md 3.2):** protocol rule 1 requires a request to stay stable until it is accepted. So an unaccepted fetch request is held in `pend_q`. A redirect while it is held marks it stale, and it is added to `drop_q` when it is accepted.

## D-021: Instruction fetch only from the executable region

- **Date / phase:** 2026-09-29, Phase 1 design
- **Status:** Accepted (owner approved 2026-09-29, including the new instruction access fault).
- **Owner fix:** the local fetch-fault entry is created only when `inflight_q == 0`, so it stays in order behind every older fetch. It is discarded on a redirect like any queue entry, and fetch pauses after it until the next redirect.
- **Context:** Fetch runs ahead speculatively, and the owner requires that nothing cancelled or speculative reaches an MMIO device.
- **Decision:** The fetch unit issues I-port requests only inside `[MEM_BASE, MEM_BASE + MEM_SIZE)`. For any other address it creates a local entry marked with a fetch fault and issues no request. This entry becomes an instruction access fault in Phase 2: `mcause` 1, an addition to the exception list in spec section 5.2.

## D-022: Directed-test hazard thresholds are derived, not measured

- **Date / phase:** 2026-09-29, after Phase 1
- **Status:** Accepted
- **Context:** In Phase 1, `hz_ctrl`'s `fetch_drop` minimum was first set to the measured value (24) and then lowered to 20. Neither value had a derivation.
- **Decision:** Every `HAZARD-EXPECT` minimum must follow from the program and the design, with the derivation written in the test's header comment. The minimums are checked only in ideal mode, the one deterministic timing.
- **`hz_ctrl` derivation:** `fetch_drop >= 24`, restored from 20.
  - In ideal mode the D-side never stalls. While ID is not held, the fetch unit issues a request every cycle, so every redirect meets exactly one in-flight response and drops it.
  - The exception is the consumer of a load. The load-use hold pushes one response into the fetch queue, which blocks one request by credit. When the consumer reaches EX two cycles later, there is no response in flight to drop.
  - `hz_ctrl` has 25 redirects: 24 deliberate, plus `TEST_PASSFAIL`. Exactly one of them, the `beq` in case 20, consumes a load. So the guarantee is 24.
  - A redirect trace confirmed it: the one redirect that drops nothing is that `beq`, with `inflight_q = 0` and `fq = 1`.
- **Other thresholds:** `hz_load_use` `load_use >= 15` is one stall per deliberate consumer (the measured value is exactly 15). The `hz_fwd` minimums count only the deliberate cases; `TEST_CASE`'s own checks add more.

## D-023: CSR instructions, MRET and FENCE.I execute at the commit point and serialize

- **Date / phase:** 2026-09-29, Phase 2 design
- **Status:** Accepted (owner decision D1, 2026-09-29)
- **Decision:** CSR*, MRET and FENCE.I read and write CSR state in MEM, in the cycle they commit, and then redirect (to `pc + 4`, or to `mepc` for MRET) through the fetch unit's redirect input, flushing IF, ID and EX. The issue rule (D-019) gains the term "MEM holds a serializing instruction". Interrupts are never taken on a serializing instruction.
- **Rationale:** no CSR forwarding, no CSR hazard detection, precise traps, and every side effect (`mtvec`, `mie`, `mstatus.MIE`, new code after FENCE.I) applies to every later instruction because they are fetched after it. The cost is 3 cycles per CSR instruction. Detail: `docs/architecture.md` P2.3.

## D-024: CSR set

- **Date / phase:** 2026-09-29, Phase 2 design
- **Status:** Accepted (owner decisions D2 and D3, 2026-09-29)
- **Decision:** the CSRs of spec section 5.2, plus `cycleh`, `instreth` (needed by `rv32mi-p-zicntr`) and `mvendorid`, `marchid`, `mimpid` (required by the privileged spec, read by `rv32mi-p-mcsr`), all read-only 0 except the counter aliases. `mtvec` is **direct mode only**: MODE is read-only 0 (spec section 5.2 says "optionally vectored"; no test needs it). Every other address is nonexistent and traps as illegal. Table: `docs/architecture.md` P2.2.

## D-025: Sdtrig "no triggers" stubs for `rv32mi-p-breakpoint`

- **Date / phase:** 2026-09-29, Phase 2 design
- **Status:** Accepted (owner decision D4, 2026-09-29)
- **Context:** `rv32mi-p-breakpoint` writes `tselect`, `tdata1` and `tdata2`. If they trap, the test's handler sees `mcause = 2` and fails.
- **Decision:** `tselect`, `tdata1` and `tdata2` exist, read as 0 and ignore writes. `tdata1` = 0 is trigger type 0, "no trigger at this index", which Sdtrig allows. The test then skips every trigger section and passes. `tdata3`, `tinfo` and `tcontrol` stay nonexistent (the test probes `tcontrol` under a temporary `mtvec` and tolerates the trap).
- **Phase 3 consequence:** Spike implements Sdtrig triggers, so its trace for `rv32mi-p-breakpoint` differs from ours (its `tdata1` read-back matches and the breakpoint sections execute). Phase 3 needs either a Spike configuration with no triggers that matches this design, or a co-simulation-only exclusion of `rv32mi-p-breakpoint`, recorded here when decided.
- **Phase 3 finding (Spike source, commit `0bff121`; to confirm on the installed binary):** with `--triggers=0`, Spike's `tselect` ignores writes and reads 0, `tdata1`/`tdata2` are constant 0 and `tcontrol` is absent, which matches these stubs exactly. So `rv32mi-p-breakpoint` needs no co-simulation exclusion (architecture.md P3.3).

## D-026: `rv32mi-p-pmpaddr` is excluded permanently

- **Date / phase:** 2026-09-29, Phase 2 design
- **Status:** Accepted (owner decision D5, 2026-09-29)
- **Reason:** the test needs a working PMP entry (writable `pmpcfg0`, NAPOT `pmpaddr0` with a granularity check). PMP is not in the spec (M-mode only, no memory protection). With no PMP, its first `csrw pmpcfg0` traps to a handler that is `j fail`.

## D-027: rv32mi runs with interrupts pending but masked

- **Date / phase:** 2026-09-29, Phase 2 design
- **Status:** Accepted (owner decision D6, 2026-09-29)
- **Decision:** the `rv32mi-p` tests run from the unmodified stock ELFs in every configuration. The random generator still drives the interrupt lines, but the stock environment leaves `mie` = 0, so the check is that no interrupt is ever taken while masked (entries = acknowledgements = 0). rv32ui and the new directed tests run with interrupts enabled.
- **Rationale:** the rv32mi tests own the trap machinery (`mtvec_handler`, straight-line `mepc`/`mstatus` writes and `mret`), so an asynchronous interrupt would corrupt them, and `third_party/` must not be edited.

## D-028: rv32ui builds: unmodified stock ELFs without interrupts, hooked ELFs with interrupts; `third_party/` checked clean

- **Date / phase:** 2026-09-29, Phase 2 design
- **Status:** Accepted (owner decision D7, with changes, 2026-09-29)
- **Decision:**
  - The `ideal` configuration (interrupts off) runs the rv32ui ELFs built by the upstream `isa/Makefile` with the **completely unmodified** stock environment (`make riscv-tests-stock`, D-001).
  - The random-interrupt configurations run a second build, `build/riscv-tests-irq/`, made from the same sources with the upstream compiler flags and `-Isw/common/test_env_irq` ahead of `env/p`. That wrapper `#include_next`s the stock `riscv_test.h` and redefines only the documented hooks `EXTRA_INIT`, `INTERRUPT_HANDLER` and `EXTRA_DATA`.
  - Every build target ends by running `git status --porcelain --ignored --untracked-files=all` in every submodule, recursively, and fails if anything is printed.
- **Rationale:** the interrupt-free baseline is exactly the upstream test, so a hook can never hide a failure there, and nothing can write into `third_party/` unnoticed.

## D-029: Simulation-control device at `0x4000_0000` (core testbench only)

- **Date / phase:** 2026-09-29, Phase 2 design
- **Status:** Accepted (owner decision D8, 2026-09-29)
- **Decision:** `tb/common/sim_ctrl.sv` drives the three interrupt lines (random generator and software force) and counts acknowledgements. Registers `IRQ_ACK` (0x0), `IRQ_FORCE` (0x4) and `IRQ_LINES` (0x8) sit at `soc_pkg::SIMCTRL_BASE` = `0x4000_0000` (4 KB), reached through `mem_model`'s D-port. The window is recorded in `docs/memory_map.md` as **reserved, simulation only**: the SoC never decodes it, so an access there on real hardware is an access fault.
- **Addition during implementation (owner approved 2026-09-29):** `IRQ_RANDOM` (0xC) pauses (0) or resumes (1) the random generator. `irq_directed.S` pauses it around the checks that need a fixed interrupt order (priority 11, 3, 7; `mepc` of a forced interrupt; an interrupt pending across an exception). Without it those checks would race against randomly raised lines. **Owner requirement:** a run fails if it ends with the generator paused (the testbench reports `irq_paused` in its `STATS:` line and the runner fails the run when it is non-zero), so a test cannot silently switch off random interrupts for the rest of its run.

## D-030: Phase 2 acceptance matrix and interrupt coverage

- **Date / phase:** 2026-09-29, Phase 2 design
- **Status:** Accepted (owner decision D9, with the coverage requirement added, 2026-09-29)
- **Decision:** 7 runs per test: `ideal` (interrupts off), and ideal memory and random latency each with random interrupts for seeds 101, 202 and 303. `make accept-phase2` also counts five interrupt events (EX memory op cancelled by an interrupt, interrupt on a load/store, interrupt in the same cycle as an EX redirect, interrupt deferred by a CSR op/MRET/FENCE.I, exception with an interrupt pending) across the six random-interrupt runs and fails if a total is below its minimum.
- **Minimums:** derived, not measured (D-022). `sw/tests/irq_cov.S` builds each event deterministically (MIE=0, force a line, `csrsi mstatus, MIE`, then the subject instruction is the first to commit). Its header states the per-run floors (`IRQ-EXPECT`), and the aggregate minimum is their sum over the runs where each derivation holds: E1 ≥ 12, E2 ≥ 24, E3 ≥ 12, each E4 kind ≥ 12, E5 ≥ 30. Random-stimulus contributions from the other tests are reported separately and not gated. Derivation: `docs/architecture.md` P2.13.

## D-031: `mtval` values

- **Date / phase:** 2026-09-29, Phase 2 design
- **Status:** Accepted (owner decision D10, 2026-09-29)
- **Decision:** illegal instruction → the instruction bits (for a 16-bit length encoding, `inst[1:0] != 11`, its 16 bits zero-extended, as Spike reports); EBREAK → the pc; ECALL → 0; misaligned or faulting load/store → the effective address; misaligned jump → the target; instruction access fault → the pc. These match Spike, for Phase 3 co-simulation.

## D-032: `mstatush` reads as zero

- **Date / phase:** 2026-09-29, Phase 2 design
- **Status:** Accepted (owner decision D11, 2026-09-29)
- **Decision:** `mstatush` (0x310) exists on RV32, reads 0 (MBE = 0, little-endian M-mode) and ignores writes, as the privileged spec defines for this configuration.

## D-033: No interrupt while EX holds an unaccepted D-port request

- **Date / phase:** 2026-09-29, Phase 2 implementation
- **Status:** Accepted (owner approved 2026-09-29; found while running the Phase 2 tests). CLAUDE.md section 5.1 updated.
- **Problem:** D-019 checks "no trap or interrupt is being taken" only in the cycle the request is issued. With random latency, EX can assert a request that is not accepted (`ready` = 0), which stalls the pipeline with a completed instruction sitting in MEM. If an interrupt line rises in a later cycle, that instruction takes the interrupt, `kill_ex` flushes EX and the request is withdrawn before acceptance, violating protocol rule 1. `mem_model` caught it in `rv32ui-p-lhu` and `rv32ui-p-ld_st` (`random+irq`, seeds 101/202/303; first seen at cycle 878 of `lhu`, seed 202).
- **Decision:** `hazard_unit` registers `dreq_hold_q = dmem_req_valid && !dmem_req_ready`. While it is set, the commit point does not take an interrupt (`irq_take` gains `&& !irq_block`). No other kill can arise in that window: MEM was safe when the request was issued (no exception, not waiting, not serializing) and is frozen by the stall, so exceptions and serializing commits cannot appear. The interrupt is taken on a later commit, at the latest on the load/store itself once it reaches MEM, so it cannot be starved.
- **Consequences:**
  - `dmem_req_valid` depends on `ready` only through a register, so protocol rule 2 still holds.
  - New assertion `a_dreq_stable` in `core_top`: a request asserted without `ready` is asserted again, unchanged, in the next cycle.
  - The P2.13 event E1 is unaffected: the loads/stores it counts are the ones that have *not* asserted their request (blocked by `kill_ex` in the interrupt cycle, or held by the issue rule while MEM waits for a response).
  - **Interrupt latency now depends on the slaves.** While a request is held unaccepted, interrupts wait. If a slave could hold `ready` low indefinitely (for example until software drains a FIFO), an interrupt, possibly the very one that would let software drain it, could wait forever. D-034 rules that out for every slave.

## D-034: Every bus slave and peripheral accepts requests within a bounded time

- **Date / phase:** 2026-09-29, recorded after Phase 2 for Phases 5 and 6
- **Status:** Accepted (owner decision, 2026-09-29). CLAUDE.md section 5.4.
- **Decision:** every bus slave, bridge and peripheral (interconnect, `axil2apb`, main-memory port, CLINT, PLIC, UART, SPI, and the caches acting as slaves of the core) must accept a request within a bounded number of cycles that does not depend on software. None may hold ready/PREADY low waiting for software action:
  - a write to a full UART or SPI TX FIFO is accepted, drops the data and sets an overflow flag;
  - a read of an empty RX FIFO returns data with a status bit showing it is not valid;
  - no register access waits for a transfer to finish.
  Each slave documents its worst-case acceptance latency in its header comment and `docs/memory_map.md`.
- **Rationale:** D-033 defers interrupts while a D-side request is held unaccepted, so the worst-case interrupt latency is bounded by the slowest slave's acceptance latency plus the pipeline drain. With software-dependent back-pressure, that bound would not exist, and a handler that must run to release the back-pressure could deadlock.
- **Verification (Phase 6/7):** each peripheral's testbench and the UVM agents check a maximum ready latency.

---

## Test exclusions

Tests from `rv32ui-p-*` and `rv32mi-p-*` that this design intentionally does not run, with reasons. `scripts/exclusions.txt` holds the machine-readable copy.

| Test | Phase | Reason | Approved |
|---|---|---|---|
| `rv32ui-p-ma_data` | Phase 1 onward, permanent | Expects misaligned loads and stores to work in hardware, but spec section 5.2 makes them exceptions, and the `-p` environment has no emulation handler (D-015) | 2026-09-29 |
| `rv32ui-p-fence_i` | Phase 1 only | FENCE.I is Phase 2 scope; it is a NOP in Phase 1 (D-016) | 2026-09-29 |
| `rv32mi-p-pmpaddr` | Phase 2 onward, permanent | Needs a working PMP entry; PMP is not in the spec (D-026) | 2026-09-29 |
