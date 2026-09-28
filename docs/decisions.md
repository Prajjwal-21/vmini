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
- **Status:** Accepted for rv32ui. **Open for `rv32mi-p-csr`**, to be decided in Phase 2.
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
- **Phase 1 exclusion candidates** (not approved yet; to raise in the Phase 1 design proposal):
  - `rv32ui-p-ma_data` expects misaligned loads and stores to work in hardware. Section 5.2 says they raise an exception, and Phase 1 has no traps.
  - `rv32ui-p-fence_i` needs FENCE.I, which section 8 places in Phase 2.

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

---

## Test exclusions

Tests from `rv32ui-p-*` and `rv32mi-p-*` that this design intentionally does not run, with reasons. Empty so far.

| Test | Phase | Reason | Approved |
|---|---|---|---|
