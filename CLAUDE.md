# Mini RISC-V SoC — Project Guide for Claude Code

This file is the persistent specification for this repository. Read it at the start of every session.
If anything here conflicts with a request in chat, ask me before proceeding.

## 1. Project goal

A small, synthesizable RISC-V SoC written in SystemVerilog:

1. 5-stage pipelined RV32I core (IF/ID/EX/MEM/WB) with full hazard handling, plus Zicsr, Zifencei and M-mode traps/interrupts
2. Instruction cache and data cache
3. AXI4-Lite system bus with an AXI4-Lite-to-APB bridge for peripherals
4. Peripherals: UART, SPI master, CLINT-style timer, PLIC-style interrupt controller
5. Verification: directed tests, official riscv-tests / riscv-arch-test, trace co-simulation against Spike, and a UVM environment
6. Physical implementation with OpenLane 2 / LibreLane on sky130 to report area, timing and power

Quality bar: this is a portfolio project. Clean, readable, well-commented RTL and reproducible scripts matter as much as features.

## 2. Toolchain

| Purpose | Tool |
|---|---|
| Lint + fast simulation | Verilator 5.x (`verilator --lint-only -Wall`) |
| UVM simulation | Verilator 5.x (`--binary --timing`) with Accellera `uvm-core` 2020.3.1 (git submodule `third_party/uvm-core`), built with `UVM_NO_DPI` |
| Constraint solver | Z3 — Verilator calls it at run time for constrained randomization |
| Waveforms | Surfer (FST output) |
| Compiler | `riscv64-elf-gcc` (Homebrew core) with `-march=rv32i_zicsr_zifencei -mabi=ilp32`. Its `rv32i/ilp32` libgcc multilib provides `__mulsi3`, `__divsi3`, `__modsi3`, `__udivsi3` and `__umodsi3` |
| Reference model | Spike (`riscv-isa-sim`), run with `--isa=rv32i_zicsr_zifencei --priv=m` |
| Tests | riscv-tests (git submodule), riscv-arch-test via RISCOF (later), riscv-dv (later) |
| Scripting | Python 3, GNU Make 3.81 (the macOS system make) |
| Physical design | OpenLane 2 / LibreLane, sky130A PDK, sky130 SRAM macros (OpenRAM) or DFFRAM |

Before starting any phase, check that the tools it needs are installed (`make check-tools PHASE=N`). If something is missing, tell me the exact install command instead of working around it.

**Repository path:** the repository lives at `~/Desktop/mini risc v`, and that path contains spaces. GNU Make and many EDA tools cannot handle spaces in file names, so:
- Every Makefile and script path is relative to the repository root, and `make` is run from the root.
- Verilator's generated makefiles refuse to build under a path containing spaces. Verilator object directories therefore go in `~/.cache/mini-riscv/verilator/`, and logs stay in `build/`.

## 3. Repository layout

```
rtl/
  pkg/        riscv_pkg.sv, soc_pkg.sv (opcodes, types, memory map, parameters)
  core/       pipeline stages, regfile, alu, hazard_unit, forwarding_unit, csr, core_top
  cache/      icache.sv, dcache.sv, write_buffer.sv
  bus/        axil_if.sv, apb_if.sv, axil_interconnect.sv, axil2apb.sv, mem_arbiter.sv
  periph/     uart.sv, spi_master.sv, clint.sv, plic.sv
  soc_top.sv
tb/
  common/     memory models, ELF/hex loader, tohost monitor, RVFI trace writer
  core_tb/    Verilator testbench for the bare core
  soc_tb/     Verilator testbench for the full SoC
  uvm/        UVM environment (agents, env, sequences, tests, scoreboards, coverage);
              smoke/ holds the Phase 0 UVM tool-flow smoke test
sw/
  common/     crt0.S, linker script, minimal HAL for peripherals,
              test_env_nocsr/ (CSR-free riscv-tests environment for Phase 1)
  tests/      directed C/asm programs (hazards, traps, interrupts, UART, SPI)
third_party/  riscv-tests, uvm-core (submodules), others as needed — never edit these
scripts/      run_riscv_tests.py, cosim_compare.py, regression.py
pnr/          OpenLane/LibreLane configs, constraints, macro placement
docs/         architecture.md, memory_map.md, decisions.md, results.md
PROGRESS.md   phase checklist and current status
Makefile      top-level targets (lint, sim, test, cosim, uvm, pnr)
```

## 4. RTL coding rules

- Synthesizable SystemVerilog only inside `rtl/`. No `initial` blocks, no delays, no `$display` in RTL (except behind `ifndef SYNTHESIS`).
- `always_ff` for sequential logic, `always_comb` for combinational logic. Default-assign every signal at the top of `always_comb` so no latches are inferred.
- Types: `logic` everywhere; `typedef enum logic [...]` for FSM states and decoded ops; `typedef struct packed` for pipeline registers.
- Naming: inputs `_i`, outputs `_o`, active-low `_n`, register outputs `_q`, next-state `_d`. Clock `clk_i`, reset `rst_ni` (active-low, synchronous deassertion).
- One module per file; filename matches module name.
- All constants, opcodes, and the memory map live in packages — no magic numbers in modules.
- Every module starts with a header comment: purpose, interfaces, timing assumptions.
- The code must pass `verilator --lint-only -Wall` with zero warnings. If a warning is intentionally waived, use a targeted `/* verilator lint_off */` with a comment explaining why.

## 5. Architecture specification

### 5.1 Core pipeline

- Stages: IF, ID, EX, MEM, WB, with explicit pipeline registers (packed structs) between them.
- Reset PC: `0x8000_0000`.
- **Forwarding:** EX/MEM → EX and MEM/WB → EX for both ALU operands and store data.
- **Register file:** 2 read ports and 1 write port. x0 is hardwired to zero. It either writes in the first half of the cycle or has a WB→ID bypass, so an instruction in ID sees a value being written back in the same cycle.
- **Load-use hazard:** stall IF/ID for exactly 1 cycle and insert a bubble into EX.
- **Branches and jumps:** resolved in EX with static predict-not-taken. A taken branch, JAL, or JALR flushes IF and ID (2-cycle penalty). Keep the design modular so a BTB can be added later.
- **Stall vs flush:** there is one global `stall` that freezes all pipeline registers, and separate per-stage `flush` signals. Their priority is documented in `docs/architecture.md`.
  - `stall` comes only from the **data side**: the instruction in MEM waiting for its D-cache/bus response, or the instruction in EX unable to issue its D-side request.
  - The **instruction side never stalls the pipeline** (D-014). A decoupled fetch unit with a small fetch queue inserts **bubbles** into ID when no instruction is available, so older instructions keep moving during an I-cache miss.
  - Fetch responses already in flight when a redirect happens are discarded by a stale-response counter. Branches, traps, MRET and FENCE.I all redirect through this mechanism.
- **No speculative data access:** a D-side request is issued only when the instruction issuing it is certain to commit. That means no older instruction in MEM can still trap or is still waiting for its response, the instruction has no exception of its own, and no trap or interrupt is being taken. A cancelled store never reaches memory, and a cancelled load never reaches an MMIO device. Instruction fetch only accesses the executable main-memory region.
- **An issued request is never withdrawn (D-033):** once EX has asserted a D-side request that is not yet accepted, the commit point takes no interrupt until it is accepted (taking one would flush EX and withdraw the request, breaking protocol rule 1 below). The interrupt is taken on a later commit, at the latest on that load/store. Interrupt latency therefore depends on every D-side slave accepting requests within a bounded time (section 5.4).
- **Memory interfaces:** the core has separate instruction and data ports. Each has a valid/ready request channel and a response channel with no ready, which the core always accepts. Responses come back in order, with an `err` bit. The protocol rules are:
  - A response arrives **at least one cycle after its request is accepted**.
  - `rsp_valid` and `rsp_err` **never depend combinationally on `req_valid` or the request payload**. The Phase 4 caches and every later slave must obey this; otherwise the path from a response to the next `dmem_req_valid` becomes a combinational loop.
  - `req_valid` never depends combinationally on any `ready`.

  The core never knows whether a cache is present.

### 5.2 CSRs and traps (M-mode only)

- CSRs: `mstatus` (MIE, MPIE, MPP fixed to M), `misa`, `mie`, `mip`, `mtvec` (direct mode, optionally vectored), `mepc`, `mcause`, `mtval`, `mscratch`, `mhartid` (= 0), `mcycle`/`mcycleh`, `minstret`/`minstreth`, plus read-only `cycle`/`instret` aliases.
- Instructions: CSRRW/S/C and their immediate forms, ECALL, EBREAK, MRET, WFI (may act as NOP), FENCE (NOP), FENCE.I (flushes the pipeline and invalidates the I-cache).
- **Exceptions:** illegal instruction, instruction/load/store address misaligned, ECALL, EBREAK.
- **Precise traps:** exceptions are carried down the pipeline and taken at a single commit point (the end of MEM). All younger instructions are flushed. Interrupts are taken at the same point.
- **Interrupts:** machine timer (MTIP from CLINT), machine software (MSIP from CLINT), and machine external (MEIP from PLIC).

### 5.3 Caches

- **I-cache:** 2 KB, direct-mapped, 16-byte lines, read-only. Invalidated entirely by FENCE.I.
- **D-cache:** 2 KB, direct-mapped, 16-byte lines, write-through, no-write-allocate, with a 2-entry write buffer. Byte/halfword stores use byte enables.
- Line refill uses four single-beat AXI4-Lite reads, since AXI4-Lite has no bursts.
- **Uncached region:** every address below `0x8000_0000` bypasses the D-cache. This is where all MMIO lives.
- Keep the storage arrays behind a wrapper module (`sram_wrapper`) so a behavioral model is used in simulation and a sky130 SRAM macro is used for physical design.
- A parameter `CACHE_EN` lets the SoC be built with the caches bypassed, for debugging.

### 5.4 Bus and memory map

Topology: I-side and D-side requests go through `mem_arbiter`, then an AXI4-Lite master, then `axil_interconnect`. The interconnect's slaves are (a) the external memory port and (b) `axil2apb`, which feeds the APB peripherals.

| Region | Base | Size | Bus |
|---|---|---|---|
| CLINT | `0x0200_0000` | 64 KB | APB |
| PLIC | `0x0C00_0000` | 4 MB | APB |
| UART | `0x1000_0000` | 4 KB | APB |
| SPI | `0x1000_1000` | 4 KB | APB |
| Main memory (external port) | `0x8000_0000` | 64 KB | AXI4-Lite |

Accesses to unmapped addresses return SLVERR/PSLVERR, which the core reports as a load or store access fault. The memory map is defined once, in `soc_pkg.sv`, and mirrored in `docs/memory_map.md` and `sw/common`.

**Bounded acceptance (Phases 5 and 6, D-034):** every bus slave, bridge and peripheral must accept a request (assert ready, or PREADY on APB) within a bounded number of cycles that does not depend on software. No slave may hold ready low waiting for software action. For example, a write to a full UART TX FIFO is accepted and sets an overflow flag instead of blocking, and a read of an empty RX FIFO returns data with a status bit instead of waiting. Each slave documents its worst-case acceptance latency. D-033 makes interrupt latency depend on this: an interrupt waits for the pending D-side request to be accepted.

### 5.5 Peripherals

- **CLINT:** follows the standard layout — `msip` at offset `0x0000`, `mtimecmp` at `0x4000`, `mtime` at `0xBFF8`. `mtime` increments using a prescaler parameter.
- **PLIC (simplified):** 2 sources (1 = UART, 2 = SPI) and 1 context. Uses the standard offsets: priority at `0x0000 + 4*id`, pending at `0x1000`, enable at `0x2000`, threshold at `0x20_0000`, claim/complete at `0x20_0004`.
- **UART registers:**
  - `0x00` TXDATA
  - `0x04` RXDATA
  - `0x08` STATUS (TX full, TX empty, RX valid, RX overrun)
  - `0x0C` CTRL (TX enable, RX enable)
  - `0x10` BAUDDIV
  - `0x14` IE (RX interrupt, TX-empty interrupt)

  UART behavior: 8N1 format, 8-entry TX and RX FIFOs.
- **SPI master registers:**
  - `0x00` TXDATA
  - `0x04` RXDATA
  - `0x08` STATUS (busy, TX full, RX valid)
  - `0x0C` CTRL (enable, CPOL, CPHA, MSB/LSB first)
  - `0x10` CLKDIV
  - `0x14` CS (manual chip select)
  - `0x18` IE

  SPI behavior: supports modes 0–3, 8-bit frames, 4-entry FIFOs.

Every register map is documented in `docs/memory_map.md` alongside a C header in `sw/common`.

## 6. Verification strategy

- **RVFI-style retirement trace:** the core has a non-synthesized (`ifndef SYNTHESIS`) retirement port reporting order, PC, instruction, rd, rd write data, memory address/data/mask, trap, and interrupt. The testbench writes this to a text trace file.
- **riscv-tests pass/fail:** the testbench finds the `tohost` address from the ELF symbol table and watches for stores to it. A value of 1 means PASS. Any other value means FAIL, with test number = value >> 1. Enforce a timeout.
- **Test targets:** all `rv32ui-p-*` and `rv32mi-p-*` tests. If a test needs a feature this design intentionally omits, do not silently skip it. Report it to me, and record the exclusion and the reason in `docs/decisions.md`.
- **Spike co-simulation (offline):** `scripts/cosim_compare.py` runs Spike with `--log-commits` on the same ELF and compares retirement traces instruction by instruction. On mismatch it prints the first diverging instruction with context. MMIO reads are marked as "don't compare values" in this mode.
- **Lockstep co-simulation (optional, later):** Spike driven over DPI, stepped once per retired instruction, with interrupts and MMIO read values injected into Spike.
- **UVM environment:**
  - Agents: AXI4-Lite, APB, UART (serial line), and SPI (slave-device model).
  - Environment: scoreboards per peripheral, a register model (RAL) for UART/SPI/CLINT/PLIC, and functional coverage on the hazard scenarios.
  - Hazard coverage covers forwarding paths, load-use stalls, branch-after-load, back-to-back CSR access, and interrupts arriving during a stall or flush.
  - Constrained-random instruction streams come from riscv-dv.

## 7. Workflow rules for Claude

1. Work **one phase at a time** (see section 8). Do not start the next phase until the current phase's acceptance criteria pass, and I have confirmed.
2. For any non-trivial block, first propose the design (interfaces, FSM, timing diagram in text) and wait for my approval before writing RTL.
3. After every RTL change: lint, build, and run the relevant tests. Report actual command output, not assumptions.
4. **Never weaken, delete, or skip a test to make it pass.** Never modify anything in `third_party/`. If a test seems wrong, explain why and ask.
5. When debugging, reproduce the issue with the smallest test, inspect the waveform or trace, state the root cause, then fix it. No speculative multi-file changes.
6. Keep `PROGRESS.md` updated (done / in progress / blocked), and record every architectural decision with its rationale in `docs/decisions.md`.
7. Never run git commit, git push, or any command that rewrites history. The user makes all commits. At each milestone, stop and suggest a commit message and the list of files to include. Suggested commit messages carry no `Co-Authored-By` or other AI-attribution trailer.
8. Every capability must be reachable through a Makefile target (e.g. `make lint`, `make test-core`, `make riscv-tests`, `make cosim`, `make uvm TEST=...`, `make pnr`).
9. If a requirement is ambiguous, ask me instead of guessing.

## 8. Phases and acceptance criteria

| Phase | Deliverable | Done when |
|---|---|---|
| 0 | Repo skeleton, Makefile, toolchain check, riscv-tests submodule built for RV32, UVM smoke test | `make lint` runs; riscv-tests ELFs build; `make uvm-smoke` passes |
| 1 | Core with no CSRs yet, tested with ideal and random-latency memories | Directed hazard tests pass, and all `rv32ui-p-*` pass when built with the project's CSR-free environment (`sw/common/test_env_nocsr`, `make riscv-tests-nocsr`), which reports pass/fail by storing directly to `tohost` (exclusions documented). Everything passes with ideal memory **and** with random latency on both ports, for at least 3 fixed seeds. The seeds are recorded, and any run can be reproduced with `make ... MEM=random SEED=N` (`make accept-phase1`) |
| 2 | Zicsr, traps, FENCE.I | All `rv32ui-p-*` and `rv32mi-p-*` pass when built with the stock riscv-tests `env/p` environment (exclusions documented) |
| 3 | RVFI trace + Spike offline co-simulation | Zero mismatches on the full riscv-tests suite |
| 4 | I-cache and D-cache behind valid/ready ports, with random-latency memory model | All tests and co-simulation still pass with random memory latency; hit/miss counters reported |
| 5 | AXI4-Lite interconnect, arbiter, AXI-to-APB bridge, memory map | All tests pass through the full bus; access-fault test passes |
| 6 | CLINT, PLIC, UART, SPI | Directed C tests pass: timer interrupt, UART loopback + RX interrupt, SPI all 4 modes |
| 7 | UVM environment | Agents, scoreboards, RAL, coverage in place; regression passes; coverage report generated |
| 8 | OpenLane/LibreLane on sky130 | Clean DRC/LVS; area, Fmax, and power (with VCD/SAIF activity) recorded in `docs/results.md` |
