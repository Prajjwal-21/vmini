# Architecture

Specification: CLAUDE.md section 5. Each section below records a design once the owner approves it.

---

# Core pipeline (Phase 1)

> **Status: APPROVED** on 2026-09-29 (D-014 to D-021) and **implemented** in `rtl/core/`. `make accept-phase1` passes. The owner's four follow-up fixes are included: `req_sent` (4.6), the response-timing rule (protocol rule 3), fetch-fault ordering (3.1), and the Phase 1 exception assertion (4.6 and 8).

## 1. Scope

Phase 1 is a 5-stage RV32I pipeline with no CSRs, driven by memories that are either ideal or have random latency.

| Instruction class | Phase 1 behaviour |
|---|---|
| LUI, AUIPC, JAL, JALR, branches, loads, stores, OP, OP-IMM | Fully implemented |
| FENCE | Executes as a NOP. With in-order, single-issue memory access, no reordering is possible. |
| FENCE.I | Executes as a NOP in Phase 1. `rv32ui-p-fence_i` is excluded until Phase 2 (D-016), which implements FENCE.I with the redirect mechanism in 3.2. |
| ECALL, EBREAK, CSR*, MRET, WFI, anything undecoded | Decoded as `illegal` and executed as a NOP. A simulation-only check fails the test when the instruction reaches MEM. Phase 2 turns the flag into a trap. |
| Misaligned load/store, or a misaligned branch/jump target | Flagged in the pipeline (`exc` field). A misaligned load or store never issues a memory request (4.6). The simulation check fails the test. Phase 2 turns the flag into a trap. |

The exception flags travel down the pipeline from Phase 1, and the rules in 3.2 and 4.6 are already written for traps and interrupts. Phase 2 therefore only adds the commit logic; the pipeline structure does not change.

## 2. Top-level interface (`core_top`)

```
core_top #(parameter logic [31:0] RESET_PC = soc_pkg::RESET_PC)
  clk_i, rst_ni                 async assert, sync de-assert (synchronised outside the core)

  // Instruction port
  imem_req_valid_o, imem_req_ready_i, imem_req_o   (mem_req_t: addr, we=0, be=4'hF, wdata=0)
  imem_rsp_valid_i, imem_rsp_i                     (mem_rsp_t: rdata, err)

  // Data port
  dmem_req_valid_o, dmem_req_ready_i, dmem_req_o   (mem_req_t: addr, we, be, wdata)
  dmem_rsp_valid_i, dmem_rsp_i                     (mem_rsp_t: rdata, err)
```

`mem_req_t` and `mem_rsp_t` are packed structs in `riscv_pkg`. Both ports use the same types, so a cache, the arbiter or a bus bridge can sit behind either port without the core knowing (spec section 5.1). `rsp.err` is carried now so that Phase 5 access faults need no port change. In Phase 1 the testbench treats an error as a test failure.

### Port protocol

The request channel is a valid/ready channel. The response channel has no ready: the core always accepts a response, because it never has more requests in flight than it can absorb.

1. A request transfers on a cycle where `req_valid && req_ready`. The signals `req_valid` and `req_o` stay stable until then.
2. `req_valid` never depends combinationally on any `ready`, on either port. This rules out combinational loops once the Phase 5 arbiter makes each port's `ready` depend on the other port's `valid`.
3. Every accepted request, including stores, gets exactly one response, in request order, **at least one cycle after the request is accepted**. `rsp_valid` and `rsp.err` (and `rsp.rdata`) **never depend combinationally on `req_valid` or on the request payload**. Responses carry no tag. The Phase 4 caches and every later slave must obey this. Otherwise the path `rsp` → `dmem_req_valid_o` (4.6) closes into a combinational loop.
4. `rsp_valid` is a single-cycle pulse per response.

```
Ideal memory: always ready, response exactly 1 cycle after acceptance
cycle            0      1      2      3
req_valid        1      1      1      0
req_ready        1      1      1      1
req.addr         A      B      C      -
rsp_valid        0      1      1      1
rsp.rdata        -     M[A]   M[B]   M[C]
```

## 3. Stages

| Stage | Work |
|---|---|
| **IF** | The fetch unit issues requests, holds returned instructions in a 2-entry fetch queue, drops stale responses (3.2), and presents the oldest instruction to ID. |
| **ID** | Decode, immediate generation, register-file read (with a WB→ID bypass), and load-use detection. |
| **EX** | Forwarding muxes, ALU, branch comparison, jump and branch target calculation, and redirect. For loads and stores it also builds the address, byte enables and aligned store data, and **issues the D-port request, subject to the issue rule in 4.6**. |
| **MEM** | Waits for the D-port response, then extracts and sign/zero-extends the loaded byte, halfword or word. **This is the commit point**, where Phase 2 will take traps and interrupts. |
| **WB** | Writes the register file. |

The D-port request is issued in EX so that its response, including `err`, arrives in MEM. That puts load and store access faults (Phase 5) at the commit point (end of MEM) required by spec section 5.2, and lets loaded data leave MEM already registered, so it can be forwarded from MEM/WB to EX. With a synchronous cache, EX presents the index and MEM does the tag compare, the usual split.

### 3.1 Fetch unit and fetch queue

The fetch unit keeps its own state, so the global stall never has to reach the I-port handshake (protocol rule 2):

- `fetch_pc_q`: the address of the next request to issue.
- `inflight_q`: the number of accepted requests still waiting for a response (0–2).
- `drop_q`: how many of those in-flight responses are stale (3.2).
- `fq`: a 2-entry queue of `{pc, instr, err}`.

The unit issues a request only when `fq_count + inflight < 2`. This credit check guarantees space for every response without looking at whether ID will consume anything this cycle. When the queue is empty, a live response that arrives passes straight through to ID in the same cycle. So with the ideal memory, fetch delivers one instruction per cycle with a single request in flight, and the queue only fills while ID is held.

**Fetch never reaches a device:** fetch runs ahead speculatively, so it only issues requests to the executable region `[MEM_BASE, MEM_BASE + MEM_SIZE)` from `soc_pkg`. A wrong-path fetch therefore can never read an MMIO register. For an address outside that region, the fetch unit issues no request and creates a **local fetch-fault entry** instead: `{pc, instr = 0, err = 1}`, carried down the pipeline as an instruction-fetch fault. The entry:

- is created only when `inflight_q == 0` and there is credit (`fq_count_q < 2`). Every older fetch, live or stale, has then returned, so the entry is queued behind all of them and program order is kept.
- is written into `fq` like any response, so it takes a queue slot and counts against credit.
- is discarded on a redirect like any other queue entry. If the redirect happens in the same cycle the entry would be created, the entry is not created.
- pauses fetch: after creating one, the fetch unit issues nothing more until the next redirect. Everything after a faulting fetch is on a path that will be abandoned, since Phase 2 traps on the entry.

### 3.2 Discarding stale fetch responses

**Mechanism: a counter of stale in-flight responses (`drop_q`).** Responses come back in request order and carry no tag (protocol rule 3). So when a redirect happens, the stale responses are exactly the next `drop_q` responses to arrive.

An epoch bit would work too. But the memory does not echo tags, so the core would have to keep one epoch bit per in-flight request (a small FIFO) and compare it on return. That is the same information with more state and logic.

**Held requests (protocol rule 1).** Once `imem_req_valid_o` is asserted, it and the address must stay stable until the request is accepted. So a request that is not accepted in its first cycle is held in `pend_q`/`pend_addr_q`, and no new request is formed while one is held. Neither a redirect nor a change in credit can withdraw or change it. If a redirect happens while a request is held, the held request becomes stale (`pend_stale_q`). When it is finally accepted, it is added to `drop_q`, and the redirect target waits in `fetch_pc_q`.

Per cycle:

```
req_fire   = imem_req_valid_o && imem_req_ready_i
rsp_fire   = imem_rsp_valid_i
rsp_stale  = rsp_fire && (drop_q != 0 || redirect)       // old-path response: never delivered

credit     = redirect ? (inflight_q - rsp_fire) < 2       // fq is being cleared
                      : (fq_count_q + inflight_q) < 2
issue_new  = !pend_q && (!paused_q || redirect) && credit && in_exec(new_addr)
new_addr   = redirect ? redirect_pc : fetch_pc_q

imem_req_valid_o = pend_q || issue_new
imem_req_o.addr  = pend_q ? pend_addr_q : new_addr
fire_stale       = req_fire && pend_q && (pend_stale_q || redirect)   // a held old-path request

inflight_d = inflight_q + req_fire - rsp_fire
drop_d     = (redirect ? inflight_q - rsp_fire                         // every old-path request in flight
                       : drop_q - (rsp_fire && drop_q != 0))
           + fire_stale
fetch_pc_d = issue_new ? new_addr + 4
           : redirect  ? redirect_pc                                   // no credit, or a request is held
           :             fetch_pc_q
fq         : cleared on redirect; stale responses are never written into it or passed to ID
```

The rsp → `imem_req_valid_o` dependency (through `credit`) is a valid-to-valid path and is legal. `imem_req_valid_o` never depends on any ready, or on the pipeline stall.

These rules guarantee four things:

- **At most 2 requests in flight,** and there is always room for every live response. The credit reserved when a request is first asserted still covers it if it is held.
- **A stale response has no effect,** even when it carries `err`. For example, a wrong-path fetch past the end of memory raises no fault.
- **A redirect is never lost.** If there is no credit to issue the target in the redirect cycle, the target waits in `fetch_pc_q` and is issued as soon as a response frees credit.
- **Back-to-back redirects work.** A second redirect sets `drop_d` from the current `inflight_q`, which marks the first redirect's target request stale too.

**Where redirects come from:**
- Phase 1: a taken branch, JAL or JALR in EX.
- Phase 2: trap entry and MRET from MEM. A MEM redirect wins over an EX redirect in the same cycle, because MEM holds the older instruction.
- Phase 2: FENCE.I, which redirects to `pc + 4` from MEM. At that point every older store has already received its response, so the refetch sees the new data. FENCE.I reuses the mechanism above unchanged. **Phase 4:** FENCE.I also invalidates the I-cache, and it must **wait for the D-cache write buffer to drain** before redirecting. A store's response can come back from the write buffer before the store reaches memory, so without the drain the refetch could read stale instructions.

```
Taken branch while a fetch is outstanding.
The I-port response arrives 3 cycles after acceptance. BEQ is at address B and is taken to T.

cycle              4        5            6        7            8           9
EX                 ...      BEQ taken    bubble   bubble       bubble      bubble
ID                 B+4      B+4 killed   -        -            -           T
redirect           0        1            0        0            0           0
I-req accepted     B+8      T            -        -            T+4         T+8
I-rsp arrives      -        -            -        B+8          T           -
response fate                                     stale: drop  live -> ID
inflight_q         0        1            2        2            1           1
drop_q             0        0            1        1            0           0

cycle 5: redirect with inflight_q=1 and no response this cycle, so drop_d = 1.
         Credit allows T to issue in the same cycle; flush_id kills B+4.
cycle 6: no credit (fq 0 + inflight 2), so no request.
cycle 7: B+8 arrives while drop_q=1, so it is discarded; drop_q -> 0.
cycle 8: T arrives while drop_q=0, so it is live and bypasses to ID; T+4 is issued.
```

A stale response can also arrive in the redirect cycle itself (always the case with the ideal memory). It is dropped by the `|| redirect` term, and `drop_d = inflight_q - 1` excludes it from the count.

## 4. Hazard handling

### 4.1 Forwarding (EX/MEM → EX, MEM/WB → EX)

For each of rs1 and rs2, which covers both the ALU operands and the store data:

```
if   (ex_mem.valid && ex_mem.rd_we && ex_mem.rd != 0 && ex_mem.rd == rsN)  use ex_mem.result   // newest wins
elif (mem_wb.valid && mem_wb.rd_we && mem_wb.rd != 0 && mem_wb.rd == rsN)  use mem_wb.wdata
else                                                                       use id_ex.rsN_data
```

A load never needs forwarding out of EX/MEM, because the load-use stall stops a dependent instruction from reaching EX while the load is in MEM. The register file handles a dependency three instructions back through its **WB→ID bypass**: when a read address matches a write in the same cycle, the read returns the data being written, and x0 always reads 0.

### 4.2 Load-use stall

Condition: the instruction in EX is a load with `rd != 0`, and the instruction in ID reads that register as rs1 or rs2.

Action, for exactly one cycle:
- if_id holds its value
- the fetch queue is not popped
- id_ex takes a bubble
- EX, MEM and WB advance as normal

The loaded value then reaches the dependent instruction through the MEM/WB → EX path.

### 4.3 Control hazards

Branches and jumps resolve in EX with static predict-not-taken. When a branch is taken, or on any JAL or JALR, EX raises `redirect`:
- the fetch unit redirects, as described in 3.2
- IF delivers nothing this cycle
- `flush_id` kills if_id

The penalty is 2 cycles with the ideal memory. The redirect target is a single `next_pc` signal, so a BTB can later feed the same point.

To avoid a loop through the ready signals, `redirect` does **not** wait for the global stall. If the pipeline is stalled while a taken branch sits in EX, the redirect fires once. A flag `ex_redirected_q` records this and stops it from firing again; the flag clears when id_ex advances.

### 4.4 Global stall

`stall` is defined in 4.6. It comes only from the D-port side. When it is high, **all four pipeline registers hold** their values. The fetch unit keeps running: it can still receive responses and issue requests while it has credit.

A D-port response can arrive while the pipeline is stalled because EX's request was refused. `rsp_held_q`/`rsp_data_q` capture it so it is not lost.

The I-port never raises `stall` (D-014). When no instruction is available, IF sends a bubble into ID and the older instructions keep moving.

### 4.5 Priority (per pipeline register, highest first)

| Register | 1st | 2nd | 3rd | 4th | Otherwise |
|---|---|---|---|---|---|
| if_id | `kill_ex` (Phase 2 trap/irq) → valid=0 | `flush_id` (redirect) → valid=0 | `stall` or `load_use` → hold | IF empty → bubble | load from IF |
| id_ex | `kill_ex` → bubble | `stall` → hold | `flush_id` or `load_use` → bubble | | load from ID |
| ex_mem | `kill_ex` → bubble (Phase 2) | `stall` → hold | | | load from EX |
| mem_wb | `stall` → hold | | | | load from MEM |

Flushes beat stall: an instruction on the wrong path, or one being cancelled, is killed even while the pipeline is frozen. In Phase 1, `kill_ex = trap_take = irq_take = 0`.

### 4.6 Data-request issue rule (no speculative data access)

**Invariant: a D-port request leaves the core only if the instruction issuing it is certain to commit.** So a store that is later cancelled never reaches memory, and a load that is later cancelled never reaches a device. This matters because a read can have side effects: reading UART `RXDATA` pops its FIFO.

An instruction in EX can only fail to commit for the reasons below. Each one is ruled out before its request is issued:

| Cause | How it is handled |
|---|---|
| It is on a mispredicted path | **Cannot happen.** Branches resolve in EX, so an instruction only reaches EX after every older branch has left EX. Wrong-path instructions only ever exist in IF and ID. |
| It raises its own exception (illegal instruction, fetch fault, misaligned address computed in EX) | `ex_self_exc`: it issues **no** request, moves on to MEM with `req_sent = 0`, and traps there. This is not a stall, and MEM never waits for a response that was never requested. |
| The older instruction in MEM traps | `mem_unsafe`: EX does not issue while the instruction in MEM **could still trap**. That is the case when it carries an exception flag, sent a request and is still waiting for the response (which might carry `err`), or sent a request and received a response with `err`. |
| An interrupt is taken at the commit point | Interrupts are taken on the instruction committing in MEM, **after** it commits (`mepc` = the committing instruction's successor PC, carried as `next_pc`). `irq_take` kills EX in that cycle, and the kill also blocks EX's request. Every committing instruction can carry an interrupt, so a stream of memory operations cannot starve interrupts. |

Once EX's request is accepted, the instruction moves to MEM. The older instruction moves to WB and has already committed. Nothing older remains that could trap, so the invariant holds.

The EX/MEM register carries a **`req_sent`** bit. It is set when the instruction's D-port request was accepted in EX (`dmem_req_valid_o && dmem_req_ready_i`) and 0 otherwise, including for memory instructions that were blocked by `ex_self_exc`. Everything in MEM that concerns the D-port response is keyed on `req_sent`, not on the instruction type.

Equations:

```
ex_mem_op     = id_ex.valid && id_ex.is_mem
ex_self_exc   = (id_ex.exc != 0) || ex_addr_misaligned
rsp_present   = dmem_rsp_valid_i || rsp_held_q
rsp_err       = rsp_held_q ? rsp_err_q : dmem_rsp_i.err
mem_wait      = ex_mem.valid && ex_mem.req_sent && !rsp_present
mem_unsafe    = ex_mem.valid && ( ex_mem.exc != 0
                                || mem_wait
                                || (ex_mem.req_sent && rsp_err) )
kill_ex       = trap_take || irq_take                       // Phase 2; 0 in Phase 1

dmem_req_valid_o = ex_mem_op && !ex_self_exc && !mem_unsafe && !kill_ex
ex_issue_wait    = ex_mem_op && !ex_self_exc && !kill_ex
                   && !(dmem_req_valid_o && dmem_req_ready_i)  // hold EX until the request is out
stall            = mem_wait || ex_issue_wait

ex_mem.req_sent  <= dmem_req_valid_o && dmem_req_ready_i  // loaded along with the rest of EX/MEM
```

Properties:
- **No loop through ready.** `dmem_req_valid_o` depends only on pipeline registers, the D-response valid/err, and (in Phase 2) the trap and interrupt decisions. None of those depend on a ready signal. Only `stall` uses `dmem_req_ready_i`, and `stall` feeds no valid signal.
- **Full throughput.** In the cycle the MEM instruction's response arrives with `err = 0`, `mem_unsafe` is 0 and EX issues, so back-to-back loads and stores still run at one per cycle with the ideal memory. The cost is a combinational path from `dmem_rsp.valid`/`err` to `dmem_req_valid_o`, noted in section 9.
- **At most one D-port request in flight,** so D-port responses never have to be matched to instructions.
- **Phase 1:** `trap_take = irq_take = 0`, so nothing would ever remove an instruction with `exc` set from MEM, and `mem_unsafe` would block a younger memory operation forever. To fail fast instead of timing out, `core_top` has a **simulation-only assertion** (under `ifndef SYNTHESIS`) that stops the run with `$fatal` in the first cycle an instruction with `exc != 0` is valid in MEM. It prints the PC, the instruction and which flag is set. Phase 2 removes the assertion when `trap_take` handles the case.
- **Phase 2 refinement:** an interrupt must not ride on a committing instruction that disables interrupts itself, for example a CSR write clearing `mstatus.MIE`, or MRET. The Phase 2 design will specify this.

## 5. Timing diagrams

```
Normal flow (ideal memory)
cycle        1    2    3    4    5    6
I1          IF   ID   EX   MEM  WB
I2               IF   ID   EX   MEM  WB
I3                    IF   ID   EX   MEM

Load-use: 1-cycle stall, then MEM/WB -> EX forwarding
cycle          1    2    3    4    5    6    7
lw  x1,0(x2)  IF   ID   EX   MEM  WB
add x3,x1,x4       IF   ID   ID   EX   MEM  WB      detected in cycle 3: ID held, bubble into EX in cycle 4
I3                      IF   IF   ID   EX   MEM     cycle 5: x1 forwarded from MEM/WB

Taken branch: redirect in EX, 2-cycle penalty (ideal memory)
cycle          1    2    3    4    5    6
beq (taken)   IF   ID   EX   MEM  WB
I+1                IF   ID   --                     flush_id in cycle 3
I+2                     IF   --                     arrives in cycle 3; dropped (3.2)
target                       IF   ID   EX           target requested in cycle 3

D-port latency: load response arrives 3 cycles after the request
cycle          1    2    3    4    5
lw            EX   MEM  MEM  MEM  WB                request accepted at the end of 1; response in 4
stall          0    1    1    0                     all pipeline registers hold in 2 and 3

Taken branch while a fetch is outstanding under latency: see section 3.2
```

## 6. Microarchitectural types (added to `riscv_pkg`, D-005)

- **Decoded-op enums:**
  - `alu_op_e`: ADD, SUB, SLL, SLT, SLTU, XOR, SRL, SRA, OR, AND, PASS_B
  - `branch_e`: NONE, EQ, NE, LT, GE, LTU, GEU, JAL, JALR
  - `mem_op_e`: NONE, LOAD, STORE, with `mem_size_e` (B, H, W) and an `unsigned` bit
  - `op_a_sel_e`: RS1, PC, ZERO
  - `op_b_sel_e`: RS2, IMM
  - `wb_sel_e`: ALU, MEM, PC4
- **Exception flags:** `exc_t` has `illegal`, `if_fault`, `if_misaligned`, `ld_misaligned` and `st_misaligned`. Access faults are added in Phase 5.
- **Pipeline registers**, all packed structs with a `valid` bit:
  - `if_id_t`: pc, instr, exc
  - `id_ex_t`: pc, instr, rs1/rs2 addresses and data, imm, rd, rd_we, decoded ops, exc
  - `ex_mem_t`: pc, next_pc, instr, rd, rd_we, result, mem op/size/unsigned/address offset, `req_sent`, wb_sel, exc
  - `mem_wb_t`: pc, instr, rd, rd_we, wdata

  `pc`, `instr` and `next_pc` are carried for Phase 2 (`mepc`/`mtval`) and Phase 3 (the RVFI trace).
- **Memory port types:** `mem_req_t` and `mem_rsp_t`.

## 7. Files

| File | Contents |
|---|---|
| `rtl/pkg/riscv_pkg.sv` | Add the types from section 6 and the load/store alignment helper functions. |
| `rtl/core/core_top.sv` | Pipeline registers, stall/flush application and stage wiring. |
| `rtl/core/if_stage.sv` | Fetch unit: `fetch_pc_q`, the credit logic, the fetch queue, `drop_q` and the executable-region check. |
| `rtl/core/decoder.sv` | Instruction to decoded ops, immediate and `illegal` flag. Purely combinational. |
| `rtl/core/regfile.sv` | 31×32 flip-flop array, 2 read ports, 1 write port, x0 hard-wired to zero, WB→ID bypass. |
| `rtl/core/forwarding_unit.sv` | The rs1 and rs2 select signals (4.1). |
| `rtl/core/hazard_unit.sv` | `load_use`, the issue rule, `stall`, `flush_id` and `ex_redirected_q` (4.2–4.6). |
| `rtl/core/alu.sv` | The ALU. |
| `rtl/core/branch_unit.sv` | Branch compare and taken/not-taken decision; jump and branch target calculation; target-misalignment flag. |
| `rtl/core/ex_stage.sv` | Forwarding muxes, the ALU and branch unit, and D-port request formation (byte enables, store data, misalignment check). |
| `rtl/core/mem_stage.sv` | D-port response capture (`rsp_held_q`), keyed on `req_sent`, and load extract/extend. |

WB is a single write port, so it is wired directly in `core_top`.

## 8. Verification plan

### Testbench (`tb/core_tb`, `tb/common`)

The testbench is in SystemVerilog, built with `verilator --binary --timing` (D-018).

- **`tb/common/mem_model.sv`:** a dual-port, 64 KB memory at `MEM_BASE`. An address outside the region returns `err`. Assertions check the core against protocol rules 1–2 and against the 4.6 invariant (no D-port request while `mem_unsafe`). Two modes:
  - `MEM=ideal`: always ready, 1-cycle response.
  - `MEM=random`: on each port, independently, `ready` is dropped with probability 1/4 per cycle, and each response comes back after 1–6 cycles (uniformly distributed, still in order). The generator is seeded from `+seed=N`, so each seed gives a reproducible run.
- **Loading programs:** `objcopy -O verilog` turns the ELF into a hex file for `$readmemh`. The Makefile takes the `tohost` address from `nm` and passes it as `+tohost=`.
- **`tb/common/tohost_monitor.sv`:** watches D-port stores to `tohost`. A value of 1 means PASS; any other value means FAIL, with the test number equal to the value >> 1. A timeout (`+timeout=`, default 200k cycles) also fails the test.
- **Simulation-only checks:** the core's assertion fires immediately if an instruction with `exc` set reaches MEM (4.6). The testbench fails the test on any D-port `err` and prints the PC and instruction.
- **Hazard event counters:** hierarchical probes count EX/MEM forwards, MEM/WB forwards, WB→ID bypasses, load-use stalls, redirects, stale fetch drops and stall cycles. They print at the end of each run.

### Directed hazard tests (`sw/tests/`)

These are assembly files built with the CSR-free environment and `test_macros.h`:

| Test | Covers |
|---|---|
| `hz_fwd.S` | EX/MEM and MEM/WB forwarding on rs1, rs2 and both at once; newest-producer priority (two writers in a row); the WB→ID bypass at distance 3; writes to x0 never forwarded; forwarding into store data. |
| `hz_load_use.S` | Load then immediate use as rs1, as rs2, as store data, as a branch operand and as the JALR base; load-use at distance 2 (no stall); a load into x0. |
| `hz_ctrl.S` | Taken and not-taken branches of every type; the instructions in a taken branch's shadow must have no effect (register writes and stores); back-to-back taken branches; JAL/JALR link values; JALR clearing the target's bit 0; branch after load. |

Each test lists the **minimum hazard event counts** it must produce, for example `load_use >= 6`. The runner fails the test if they are not reached, in ideal mode, which is deterministic. This proves the tests really exercise the hazards they claim to.

### Phase 1 acceptance run (D-017)

- `make test-core` runs the directed tests, and `make riscv-tests` runs all `rv32ui-p-*` from `build/riscv-tests-nocsr` minus the documented exclusions. Both take `MEM=ideal|random` and `SEED=N`.
- **`make accept-phase1`** runs everything once with `MEM=ideal`, then once with `MEM=random` for each seed in **`SEEDS ?= 101 202 303`** (the recorded default). Any single run can be reproduced with `make riscv-tests MEM=random SEED=202`, for example.
- `scripts/run_riscv_tests.py` prints a pass/fail table per mode and seed, and exits non-zero on any failure. The machine-readable exclusion list is `scripts/exclusions.txt`, and each line points to its `docs/decisions.md` entry.

## 9. Known timing-critical paths

These are noted now and measured in Phase 8:

1. Forwarding mux → branch compare → `redirect` → `imem_req.addr`. This is what keeps the branch penalty at 2 cycles.
2. Forwarding mux → address adder → `dmem_req.addr`.
3. `dmem_rsp.valid`/`err` → `mem_unsafe` → `dmem_req_valid_o` (4.6).

If one of these limits Fmax, the fix is a documented trade-off: register the redirect (+1 cycle branch penalty), or register the issue permission (+1 cycle between back-to-back memory operations).

## 10. Decisions

| Decision | Record |
|---|---|
| The I-port inserts bubbles; only the D-port raises the global stall | D-014 |
| `rv32ui-p-ma_data` is excluded permanently | D-015 |
| `rv32ui-p-fence_i` is excluded in Phase 1 only | D-016 |
| Random memory latency on both ports is part of Phase 1 acceptance (3 seeds) | D-017 |
| The testbench is SystemVerilog, built with Verilator `--binary` | D-018 |
| Data-request issue rule (4.6) | D-019 |
| Stale fetch discard by counter (3.2) | D-020 |
| Fetch only from the executable region (3.1) | D-021 |

---

# Phase 2: CSRs, traps, interrupts, FENCE.I

> **Status: APPROVED** on 2026-09-29 (owner decisions D1–D11, recorded as D-023 to D-032 in `docs/decisions.md`). Changes from the proposal are marked **(owner)**. The interrupt-coverage events and minimums in P2.13 are new in this revision.

## P2.1 Summary

- CSR instructions, MRET and FENCE.I are **serializing**. Each executes at the commit point (end of MEM), then redirects to its successor through the existing redirect mechanism (3.2). Every younger instruction is flushed and refetched, so it sees the new CSR state. No CSR forwarding or CSR hazard logic is needed.
- Exceptions travel down the pipeline as flags (as in Phase 1) and are taken at the commit point. The Phase 1 assertion is replaced by trap entry.
- Interrupts are taken **after** a committing instruction, never on a serializing one. They use the CSR state from before that instruction.
- The data-request issue rule (4.6) gains one term: EX may not issue while MEM holds a serializing instruction, because that instruction is about to flush EX.

## P2.2 CSR set

All accesses are in M-mode. Any address not listed here is **nonexistent**, and accessing it is illegal (P2.4).

| CSR | Addr | Access | Contents / behaviour | Reset |
|---|---|---|---|---|
| `mstatus` | 0x300 | RW | MIE[3], MPIE[7] writable. MPP[12:11] read-only `11` (M). All other bits read-only 0. | MIE=0, MPIE=0 |
| `misa` | 0x301 | RW, writes ignored | `0x4000_0100`: MXL=1 (RV32), extension I only | constant |
| `mie` | 0x304 | RW | MEIE[11], MTIE[7], MSIE[3] writable. Other bits read-only 0. | 0 |
| `mtvec` | 0x305 | RW | BASE[31:2] writable. MODE[1:0] read-only 0 (direct only, D-024). | `RESET_PC` |
| `mstatush` | 0x310 | RW, writes ignored | **(owner, D11)** read-only 0 (MBE=0, little-endian M-mode) | constant |
| `mscratch` | 0x340 | RW | 32 bits | 0 |
| `mepc` | 0x341 | RW | bits [31:2]; [1:0] read as 0 (IALIGN=32) | 0 |
| `mcause` | 0x342 | RW | Interrupt[31], code[3:0]. Other bits read-only 0. | 0 |
| `mtval` | 0x343 | RW | 32 bits | 0 |
| `mip` | 0x344 | RW, writes ignored | MEIP[11], MTIP[7], MSIP[3]: live copies of the interrupt inputs (read-only) | - |
| `tselect` | 0x7A0 | RW, writes ignored | **(owner, D4)** Sdtrig "no triggers" stub: reads 0 | constant |
| `tdata1` | 0x7A1 | RW, writes ignored | **(owner, D4)** reads 0 (type 0: no trigger at this index) | constant |
| `tdata2` | 0x7A2 | RW, writes ignored | **(owner, D4)** reads 0 | constant |
| `mcycle` / `mcycleh` | 0xB00 / 0xB80 | RW | 64-bit cycle counter (P2.6) | 0 |
| `minstret` / `minstreth` | 0xB02 / 0xB82 | RW | 64-bit retired-instruction counter (P2.6) | 0 |
| `cycle` / `cycleh` | 0xC00 / 0xC80 | RO | aliases of `mcycle`/`mcycleh` | - |
| `instret` / `instreth` | 0xC02 / 0xC82 | RO | aliases of `minstret`/`minstreth` | - |
| `mvendorid`, `marchid`, `mimpid` | 0xF11–0xF13 | RO | 0 | - |
| `mhartid` | 0xF14 | RO | 0 | - |

Deliberately **absent**, so an access is an illegal-instruction trap:
- S/U-mode CSRs: `medeleg`, `mideleg`, `mcounteren`, `satp`, ...
- PMP: `pmpcfg*`, `pmpaddr*` (so `rv32mi-p-pmpaddr` is excluded, D-026)
- The other debug/trigger CSRs: `tdata3`, `tinfo`, `tcontrol`, `dcsr`, `dpc`, ...
- `mcountinhibit`, `mconfigptr`, `mnstatus`, `time`/`timeh`

The stock environment probes several of these (`satp`, `pmpaddr0`, `pmpcfg0`, `mnstatus`, `medeleg`, `mideleg`) under a temporary `mtvec` and expects exactly this trap. `rv32mi-p-breakpoint` probes `tcontrol` the same way.

## P2.3 (a) CSR execution at the commit point

### Mechanism

```
ID   decode: sys_op (CSRRW/S/C, MRET, FENCE.I), csr_we (write intent), and the illegal checks of P2.4
EX   operand = forwarded rs1, or zero-extended uimm[4:0]; carried in ex_mem.result
MEM  in the cycle the instruction commits (valid, no exception):
       rdata   = csr_read(csr_addr)                         // old value
       wdata   = W: operand | S: rdata | operand | C: rdata & ~operand
       write   = csr_we -> csr_file updates at the end of the cycle
       mem_wb.wdata = rdata (to rd; rd = x0 means no write)
       redirect from MEM, target = ex_mem.pc + 4            // flush younger, refetch
```

The redirect from MEM uses the same fetch-unit input as the EX redirect (3.2): queue cleared, in-flight responses marked stale. **MEM beats EX** when both redirect in the same cycle, because MEM holds the older instruction.

```
Timing: csrw mtvec, x5 followed by an unrelated add (ideal memory)
cycle            1    2    3    4    5    6    7
csrw mtvec,x5   IF   ID   EX   MEM  WB                 cycle 4: mtvec written; redirect to pc+4
add                  IF   ID   EX   --                   flushed in cycle 4
next                      IF   ID   --                   flushed in cycle 4
add (refetched)                     IF   ID   EX   MEM   requested in cycle 4
```

The penalty is 3 cycles per CSR instruction. CSR instructions are rare in normal code, and the cost buys three things:
- **No CSR read-after-write hazards.** A CSR read in MEM always sees every older CSR write, because the older writes committed in earlier cycles.
- **No GPR forwarding hazard on the CSR result.** The CSR's rd value only exists from MEM/WB onward. Every younger instruction is refetched, so it reads the value through the register file (the refetched instruction reaches ID two cycles after the commit, when the value is already written).
- **Side effects are immediately architectural.** A new `mtvec`, `mie` or `mstatus.MIE` applies to every later instruction, because those instructions are fetched after the write.

### Interaction with the issue rule (4.6)

The instruction in EX will be flushed when the serializing instruction in MEM commits. So it must not issue:

```
mem_unsafe = ex_mem.valid && ( ex_mem.exc != 0 || mem_wait || (ex_mem.req_sent && rsp_err)
                             || serializing(ex_mem.sys_op) )                  // new
```

A serializing instruction never waits in MEM (it makes no memory access, and `kill_ex` clears `ex_issue_wait`, so nothing can stall it), so it spends exactly one cycle in MEM. The new term is redundant with `kill_ex` in that cycle; it is kept so the rule reads the same as the architecture.

### Alternatives considered

1. **Execute CSRs in EX** (read, modify and write there, forwarding the result like an ALU value). The write would happen before the older instruction in MEM is known to commit (imprecise traps); moving the write to commit then needs CSR forwarding or stalls; instructions already fetched behind `csrs mstatus, MIE` or `csrw mtvec` would run under the old state; and a read of `minstret` would miss the older instructions still in MEM and WB.
2. **Commit in MEM, stall younger instructions in ID instead of flushing.** Needs a "serializing instruction in flight" scoreboard, and is still wrong for instructions already fetched past a FENCE.I. Flushing reuses the Phase 1 mechanism and handles every case.

## P2.4 (b) Illegal-instruction detection (in ID)

All checks are static (instruction bits plus CSR address), so they happen in the decoder and set `exc.illegal`. The trap happens at MEM with `mtval` = instruction bits. An illegal instruction gets a NOP control word, as in Phase 1.

| Class | Illegal when |
|---|---|
| Compressed / reserved opcode | `inst[1:0] != 11`, or an opcode that is not RV32I/Zicsr/Zifencei (Phase 1 rules kept) |
| Reserved `funct3`/`funct7` | As in Phase 1: LOAD/STORE/BRANCH/JALR/OP/OP-IMM, RV32 shamt[5], MISC-MEM `funct3` not in {000, 001} |
| SYSTEM, `funct3 = 000` | Anything other than an exact match of ECALL `0x00000073`, EBREAK `0x00100073`, MRET `0x30200073` or WFI `0x10500073`. For example SRET, URET, SFENCE.VMA, DRET, or non-zero rd/rs1 fields. |
| SYSTEM, `funct3 = 100` | Always (reserved) |
| CSR op, nonexistent CSR | `csr_addr` not in the P2.2 table |
| CSR op, write to a read-only CSR | `csr_addr[11:10] == 2'b11` (`cycle*`, `instret*`, `mvendorid`..`mhartid`) **and** the instruction writes (below) |

Write intent follows the privileged spec:

| Instruction | Writes the CSR when |
|---|---|
| CSRRW, CSRRWI | always, even with `rd = x0` |
| CSRRS, CSRRC | `rs1 != x0` |
| CSRRSI, CSRRCI | `uimm != 0` |

So `csrr a0, cycle` (CSRRS with rs1 = x0) and `csrrci x0, instret, 0` are legal reads, and `unimp` (`csrrw x0, cycle, x0`, emitted by the stock `RVTEST_CODE_END`) is illegal.

Writes to read-only *fields* of RW CSRs (`misa`, `mip`, `mstatush`, the trigger stubs, `mstatus.MPP`, `mtvec.MODE`) are **not** illegal. The written value is dropped (WARL).

## P2.5 (c) Trap and interrupt rules

### Taking a trap (at the commit point, end of MEM)

```
rsp_err    = ex_mem.req_sent && rsp_present && rsp.err
exc_valid  = ex_mem.valid && (ex_mem.exc != 0 || rsp_err)
can_commit = ex_mem.valid && !mem_wait && !exc_valid       // independent of stall
serial     = ex_mem.sys_op != SYS_NONE                     // CSR*, MRET, FENCE.I
irq_pend   = mstatus.MIE && |(mip & mie)
irq_block  = dreq_hold_q            // EX asserted a D request last cycle, not accepted (D-033)
irq_take   = irq_pend && can_commit && !serial && !irq_block
trap_take  = exc_valid                                     // exceptions beat interrupts
ser_commit = can_commit && serial
kill_ex    = trap_take || irq_take || ser_commit
commit     = can_commit && !stall                          // retires (minstret, rd write)
```

`can_commit` does not depend on `stall`, because `stall` depends on `kill_ex` through the issue rule. Whenever `kill_ex` is 1, `stall` is 0 (MEM is not waiting and `kill_ex` clears `ex_issue_wait`), so an instruction that takes an interrupt or serializes always commits in that cycle.

- **On `trap_take`:** the instruction does not commit (no rd write, no `minstret` increment; MEM/WB marks it `trap`). Then:
  - `mepc` = `ex_mem.pc`; `mcause` and `mtval` per the table below
  - `mstatus`: MPIE←MIE, MIE←0 (MPP stays M)
  - redirect to `{mtvec[31:2], 2'b00}`
- **On `irq_take`:** the instruction **commits normally** (rd write, `minstret`). Then:
  - `mepc` = `ex_mem.next_pc`
  - `mcause` = `{1'b1, code}`, `mtval` = 0
  - `mstatus` is updated as for a trap, and fetch redirects to the `mtvec` base
- **On `kill_ex`:** IF, ID and EX are flushed (4.5 priority table), EX's D-port request is blocked (4.6), and an EX redirect in the same cycle is dropped (MEM's redirect wins).

### Rules

- **Interrupt priority** (privileged spec): **MEI (code 11) > MSI (3) > MTI (7)**. The code is chosen from `mip & mie` in that order.
- **Exceptions beat interrupts on the same instruction.** An instruction with an exception never commits, so no interrupt can ride on it. The pending interrupt is taken after the handler's `mret`, on the next committing instruction.
- **No interrupt on a serializing instruction** (CSR*, MRET, FENCE.I). `irq_pend` uses the CSR state from before the committing instruction. So without this rule, an interrupt could be taken after a `csrci mstatus, MIE` using the old MIE=1, or after MRET using the handler's MIE=0 instead of the restored value. With the rule, the next committing instruction sees the new state. This is a strict superset of the required rule (no interrupt on an instruction that clears MIE, or on MRET), and costs nothing because those instructions flush anyway.
- **Every other committing instruction can carry an interrupt,** including loads and stores whose response has arrived. So interrupts cannot be starved (4.6).
- **No interrupt while EX holds an unaccepted D-port request (D-033).** Protocol rule 1 forbids withdrawing an asserted request, and `kill_ex` would withdraw it. The completed instruction stalled in MEM therefore commits without the interrupt; the interrupt is taken on a later commit (at the latest on the load/store itself). Exceptions and serializing commits cannot arise in that window, because MEM was safe when the request was issued and is frozen by the stall.
- **Exception priority within one instruction** (privileged spec order, only the combinations possible here):
  1. Instruction access fault (`if_fault`; the fault entry carries instruction bits 0, which also decode as illegal)
  2. Illegal instruction
  3. Instruction address misaligned
  4. ECALL / EBREAK
  5. Load/store address misaligned
  6. Load/store access fault (response `err`)

  Misaligned accesses never issue, so 5 and 6 cannot occur together.

### `mcause` / `mtval` / `mepc`

| Event | mcause | mtval | mepc |
|---|---|---|---|
| Instruction address misaligned (taken branch/JAL/JALR target[1] set; the jump does not write rd) | 0 | target address | pc of the branch/jump |
| Instruction access fault (fetch outside the executable region, or I-port `err`) | 1 | pc | pc |
| Illegal instruction | 2 | instruction bits (a 16-bit length encoding, `inst[1:0] != 11`, gives its 16 bits zero-extended, as Spike does) | pc |
| Breakpoint (EBREAK) | 3 | pc (matches Spike) | pc |
| Load address misaligned | 4 | effective address | pc |
| Load access fault (D-port `err`) | 5 | effective address | pc |
| Store address misaligned | 6 | effective address | pc |
| Store access fault (D-port `err`) | 7 | effective address | pc |
| ECALL from M-mode | 11 | 0 | pc |
| Machine software / timer / external interrupt | 0x8000_0003 / 0x8000_0007 / 0x8000_000B | 0 | `next_pc` of the committing instruction |

`ex_mem` gains a `tval` field, computed in EX (pc, instruction bits, target or effective address). The `exc_t` flags gain `ecall` and `ebreak`.

**MRET** (serializing, at commit): MIE←MPIE, MPIE←1, MPP stays M, then redirect to `mepc`.
**WFI** executes as a NOP (allowed by the spec).

## P2.6 Counters: `mcycle` and `minstret`

- **`mcycle`** (64-bit) increments every clock cycle.
- **`minstret`** (64-bit) increments once for each instruction that **commits** (`commit` above). Trapping instructions (including ECALL and EBREAK) do not retire. An instruction that carries an interrupt does retire.
- **Carry:** both are true 64-bit counters. The low half wrapping increments the high half.
- **Software writes** happen at commit. A write to either half replaces that half, and **suppresses the increment for that cycle (`mcycle`) or that instruction (`minstret`)**. So the next read sees exactly the written value (for `mcycle`, plus the cycles elapsed since). This is what `instret_overflow` checks:
  - `csrwi minstret, 0; csrr a0, minstret` must read 0.
  - Writing all-ones to both halves, then a `nop`, must wrap both halves to 0.
- **A CSR read of a counter** returns the value before the reading instruction's own increment.

## P2.7 (g) Pipeline changes, FENCE.I, removal of the Phase 1 assertion

- **Remove the Phase 1 assertion** `a_no_exc_in_mem` from `core_top`. An instruction with an exception in MEM now traps.
- **New simulation-only assertions:**
  - no `irq_take` on a serializing instruction
  - never `trap_take` and `irq_take` in the same cycle
  - the redirect target after a trap or interrupt is the `mtvec` base
  - no D-port request in a cycle with `kill_ex` (extends `a_no_unsafe_issue`)
  - a D-port request asserted without `ready` is asserted again, unchanged, in the next cycle (`a_dreq_stable`, D-033)
  - `stall` is 0 whenever `kill_ex` is 1
- **Redirect source mux:** MEM (`trap_take`, `irq_take`, a serializing commit) has priority over EX (a taken branch). The fetch unit is unchanged: one redirect input, with stale drop and queue clear.
- **FENCE.I** is serializing. At commit it redirects to `pc + 4`: the fetch queue is cleared and in-flight responses are marked stale (3.2). By then every older store has received its response, so the refetch sees the stored instructions.
  - Phase 4 adds: invalidate the I-cache, and wait for the D-cache write buffer to drain before redirecting.
  - `rv32ui-p-fence_i` is re-enabled (D-016).
- **`ex_redirected_q`** (4.3) is also cleared on `kill_ex` (it follows from `stall` = 0 in that cycle).
- **The TB's "any D-port `err` fails the test" check is removed.** `err` is now an architected access fault.

## P2.8 (d) Audit of every `rv32mi-p` test

What each test exercises, and whether our spec (P2.2 to P2.6) provides it:

| Test | Needs | Our spec | Expected |
|---|---|---|---|
| `breakpoint` | `tselect`, `tdata1`, `tdata2` must exist (Sdtrig). It probes `tcontrol` under a temporary `mtvec`. With the "no triggers" stubs (`tselect` reads back 0, `tdata1` reads 0 so the written trigger type does not stick), every section skips and the test passes. It sets `mstatus.MIE` but leaves `mie` = 0, so no interrupt is taken. | stubs (D-025) | pass |
| `csr` | `mscratch` with every CSRRx/CSRRxI form. `misa.F=0` skips the FP section (so the `fmv`/`fsw` in the ELF never execute; D-003 is resolved). `misa.U=0` skips the user-mode section. | yes | pass |
| `mcsr` | `misa.MXL=1`, `mhartid=0`, reads of `mimpid`/`marchid`/`mvendorid` must not trap, `csrs mtvec, x0` / `csrs mepc, x0` | yes | pass |
| `illegal` | `.word 0` traps with `mcause=2`, `mtval` = 0 or the instruction bits, `mepc` = its pc. It then writes `mstatus.MPP=S`; because MPP reads back M ("S-mode absent"), the test passes early, before its `mip`/`mie`/vectored-mode section. | yes | pass |
| `ma_fetch` | JALR/JAL/taken-branch to a target with bit 1 set: `mcause=0`, `mepc` = the jump, `mtval` = target (or 0), rd **not** written. A not-taken branch to a misaligned target does not trap. JALR target bit 0 is cleared. `misa.C` cannot be set, so the test passes early. | yes | pass |
| `ma_addr` | Misaligned load/store: `mcause` 4/6, `mtval` = address. A trapping store has no effect. | yes | pass |
| `scall` | MPP reads M, so ECALL gives `mcause=11`. MRET with MPP=M. The stock trap vector reports PASS. | yes | pass |
| `sbreak` | EBREAK: `mcause=3`, `mepc` = the EBREAK | yes | pass |
| `shamt` | `slli` with shamt[5]=1 is illegal on RV32 | yes | pass |
| `lw`/`lh`/`sh`/`sw-misaligned` | Misaligned access traps with `mcause` 4/6; the handler emulates the load or skips the store | yes | pass |
| `zicntr` | `cycle`, `instret`, `cycleh`, `instreth` readable, and the x0/uimm=0 forms do not trap | yes | pass |
| `instret_overflow` | `mcountinhibit` is optional (the trap is caught). A write suppresses the writing instruction's increment; 64-bit wrap. | yes (P2.6) | pass |
| `pmpaddr` | A real PMP entry (writable `pmpcfg0` / NAPOT `pmpaddr0` with granularity G). | PMP not in spec | **excluded (D-026)** |

The stock `-p` environment itself needs: `mhartid`, `mtvec`, `mstatus`, `mie`, `mepc`, `mcause`, ECALL and MRET. It also expects **traps** on `satp`, `pmpaddr0`, `pmpcfg0`, `mnstatus`, `medeleg` and `mideleg`. P2.2 provides all of this.

**`rv32ui-p` with the stock environment:** `fence_i` is re-enabled (P2.7). `ma_data` stays excluded (D-015).

## P2.9 (f) Interrupt testing

### Simulation-control device `tb/common/sim_ctrl.sv` (TB only)

It owns the three interrupt lines driven into `core_top` (`irq_external_i`, `irq_software_i`, `irq_timer_i`; in Phase 6 the PLIC and CLINT drive them instead). The lines are flip-flops, so they never depend combinationally on the core.

- **Random generator** (`+irq=on`; default off): each line independently. While the line is low, it waits a random delay, uniform in [`+irq_min`, `+irq_max`] cycles (default 100–1000), then raises the line. The line stays high until software acknowledges it. The generator is seeded from `+seed`, on a stream separate from `mem_model`'s, so memory timing and interrupt timing are independent and every run is reproducible.
- **Registers**, at the reserved simulation-only base **`0x4000_0000`** (`soc_pkg::SIMCTRL_BASE`, **(owner, D8)** recorded in `docs/memory_map.md`). `mem_model` routes D-port accesses in this 4 KB window to `sim_ctrl`; they respond like memory (in order, same latency model) and never return `err`:

| Offset | Register | Access | Effect |
|---|---|---|---|
| 0x0 | `IRQ_ACK` | W | Write an interrupt cause code (3/7/11). Lowers that line from the cycle after the store is accepted and counts one acknowledgement. Acknowledging a line that is low fails the test. |
| 0x4 | `IRQ_FORCE` | W | Bit 3/7/11 set raises that line from the cycle after acceptance. Used by directed tests for deterministic scenarios; works with the generator on or off. |
| 0x8 | `IRQ_LINES` | R | Current line state, bits 3/7/11 |
| 0xC | `IRQ_RANDOM` | R/W | 0 pauses the random generator, 1 resumes it; lines already high stay high until acknowledged. `irq_directed.S` pauses it around the checks that need a fixed order (priority 11, 3, 7; `mepc` of a forced interrupt). A run that ends with the generator paused fails (D-029). |

The address is outside every SoC region and below the cacheability boundary, so the Phase 4 D-cache bypasses it. The SoC decodes it as unmapped, so the device never escapes the core testbench.

### Software handler

- **`rv32ui-p`, `ideal` configuration (interrupts off): the completely unmodified stock environment (owner, D7).** These are the ELFs built by the upstream `isa/Makefile` (`make riscv-tests-stock`).
- **`rv32ui-p`, random-interrupt configurations: stock environment plus interrupt hooks**, built separately into `build/riscv-tests-irq/`. `sw/common/test_env_irq/riscv_test.h` does `#include_next` of the **unmodified** stock `env/p/riscv_test.h`, then redefines three of its documented hook macros. The stock startup, trap vector and pass/fail code are unchanged:
  - `EXTRA_INIT`: sets `mie = MEIE|MSIE|MTIE` and `mstatus.MPIE = 1`, so the stock `mret` into the test enables MIE.
  - `INTERRUPT_HANDLER`, which the stock trap vector reaches for `mcause < 0` when the test defines no `mtvec_handler` (no rv32ui test does):
    ```
    csrr t5, mcause; andi t5, t5, 0xF          # cause code
    li   t6, SIMCTRL_IRQ_ACK; sw t5, 0(t6)     # ack: line drops after acceptance
    la   t6, irq_handled; lw t5, 0(t6); addi t5, t5, 1; sw t5, 0(t6)
    mret                                       # commits after the ack store
    ```
    It uses only `t5`/`t6`, which the stock trap vector already clobbers. No `rv32ui` test body uses `x30`/`x31` (checked on the disassembly).
  - `EXTRA_DATA`: defines `irq_handled: .word 0`.
- **`rv32mi-p` tests: stock environment, unmodified, with interrupts pending but masked (owner, D6).** These tests own the trap machinery (11 of 16 define `mtvec_handler`, several write `mepc`/`mstatus` and execute `mret` in straight-line code), so an asynchronous interrupt would corrupt them. The stock environment leaves `mie` = 0 throughout, so the generator still raises the lines and the check is that **no interrupt is ever taken while masked**.
- **Phase 1 hazard tests** (CSR-free environment): `mstatus.MIE` stays 0 from reset, so the lines are also pending but masked.
- **New directed tests:** a shared handler macro in `sw/common/irq_handler.h` (same ack and count), called from their own trap handlers.

### Checks at the end of every run (at the `tohost` store)

1. Interrupt entries seen by the TB == `IRQ_ACK` writes == `irq_handled` (read from memory; the runner passes its address from `nm` as `+irq_count=` when the symbol exists). For masked runs all three must be 0.
2. Lines raised − lines acknowledged == lines still high (at most 3). No interrupt is lost or handled twice.
3. Checked on every interrupt entry: `mstatus.MIE` was 1, the source is enabled in `mie`, its line is high, and no higher-priority enabled line is high.

### Why the ack cannot race with `mret`

The ack store is older than `mret`, and commit is in order. The store is accepted before it commits, and the line is low from the cycle after acceptance. `mret` commits at least one cycle after the store commits, and the first instruction that can take an interrupt after `mret` is refetched, so it commits several cycles later still. The line is therefore low before MIE is restored.

## P2.10 (e) New directed tests (`sw/tests/`)

All use the stock environment (unmodified `env/p/riscv_test.h`, plus `sw/common/irq_handler.h`). Tests that raise their own exceptions install their own trap handler in `mtvec` and restore the stock `trap_vector` before `TEST_PASSFAIL` (the stock vector treats every M-mode ECALL as the pass/fail call). They run with interrupts **enabled** in the random-interrupt configurations; their handlers dispatch on `mcause[31]`, and every check of `mepc`/`mcause`/`mtval` is made inside the handler (MIE=0) or on values the handler saved.

| Test | What it checks |
|---|---|
| `tr_misaligned.S` | Misaligned `lw`, `lh`, `lhu`, `sw` and `sh`, each **followed by a load and a store**: `mcause`/`mtval`/`mepc` are correct, rd is not written, the younger store never reaches memory (its target is re-read), and execution resumes at `mepc + 4` |
| `tr_access_fault.S` | `lw` from unmapped `0x7000_0000` (`mem_model` returns `err`): `mcause=5`, `mtval` = address, and a **younger `sw` never issues** (checked in memory, and by `a_no_unsafe_issue`). Same with an `sw` (`mcause=7`). In random-latency runs the faulting response arrives late while the younger store waits in EX. |
| `tr_illegal.S` | Every P2.4 class: all-zero word, SYSTEM `funct3=100`, SRET/URET/SFENCE.VMA, OP with a bad `funct7`, JALR `funct3≠0`, a nonexistent CSR, `csrw mhartid`, `csrrwi x0, cycle, 0`. It also checks that `csrr` of every read-only counter and `csrrci x0, instret, 0` **do not** trap. For traps: `mtval` = instruction bits, rd unchanged. |
| `tr_ecall_ebreak_mret.S` | ECALL round trip (`mcause=11`, `mepc`, `mtval=0`, MPIE/MIE on entry and after `mret`); EBREAK (`mcause=3`, `mtval=pc`); MRET to an explicit `mepc`; `csrw mtvec` taking effect for the very next trap; `minstret` not counting the ECALL; instruction access fault by jumping outside the executable region (`mcause=1`) |
| `csr_ops.S` | CSRRW/S/C and the immediate forms on `mscratch`/`mtvec`/`mie`; WARL fields (`misa`, `mstatus.MPP`, `mtvec.MODE`, `mip`, `mstatush`, trigger stubs); back-to-back CSR read-after-write; a CSR result used by the next instruction; `mcycle`/`minstret` write semantics (P2.6) |
| `irq_directed.S` | All three sources forced with MIE=0, then MIE set: handled in the order **11, 3, 7**. `mepc` of a forced interrupt. A pending interrupt during an exception handler is taken only after `mret`. A `csrsi`/`csrci mstatus, MIE` toggle loop under forced and random interrupts, with the handler checking that `mepc` never points just after a MIE-clearing instruction. WFI is a NOP. |
| `irq_cov.S` | The deterministic interrupt-coverage scenarios of P2.13, with their derived per-run minimums |

## P2.11 Acceptance run and Makefile

Test sets:
- **rv32ui (42 tests):** `ma_data` excluded (D-015). Stock-unmodified ELFs in the `ideal` configuration; hooked ELFs in the random-interrupt configurations (D7).
- **rv32mi (16 tests):** stock environment with interrupts masked; `pmpaddr` excluded (D-026).
- **Directed:** the 3 Phase 1 hazard tests (CSR-free environment, unchanged) plus the 7 new ones.

Each test runs in these configurations:

| Config | Memory | Interrupts | rv32ui ELFs | Purpose |
|---|---|---|---|---|
| `ideal` | ideal | off | stock, unmodified | deterministic; the only config where `HAZARD-EXPECT` minimums are checked |
| `ideal+irq:S` | ideal | random, seed S | stock + hooks | |
| `random+irq:S` | random latency | random, seed S | stock + hooks | |

S is each of **101, 202 and 303**, so there are 7 runs per test. `make accept-phase2` runs everything and then checks the interrupt coverage (P2.13). `make riscv-tests MEM=random IRQ=on SEED=202` reproduces a single configuration; the runner prints the exact simulator command line for every failure.

**`third_party/` stays clean (owner, D7).** Every build target (`riscv-tests-stock`, `riscv-tests-irq`, `riscv-tests-nocsr`, `directed`, `core-sim`, `uvm-smoke`) ends with `git submodule foreach --recursive git status --porcelain --ignored --untracked-files=all` and fails if anything is printed.

`accept-phase1` is kept, unchanged, as a regression target (CSR-free ELFs, no interrupts).

## P2.12 Owner decisions (2026-09-29)

| # | Question | Decision |
|---|---|---|
| D1 | CSR/MRET/FENCE.I execute at commit and flush with a redirect to pc+4 (P2.3) | Approved (D-023) |
| D2 | Add `cycleh`, `instreth`, `mvendorid`, `marchid`, `mimpid` | Approved (D-024) |
| D3 | `mtvec` direct-only (MODE read-only 0) | Approved (D-024) |
| D4 | `breakpoint`: Sdtrig "no triggers" stubs | Approved: stubs. Phase 3 note on Spike's triggers (D-025) |
| D5 | Exclude `pmpaddr` (PMP out of scope) | Approved (D-026) |
| D6 | rv32mi with interrupts masked; rv32ui and directed tests with interrupts enabled | Approved (D-027) |
| D7 | Stock environment plus hooks via `#include_next` | Approved, **but** the `ideal` (interrupts off) config uses the completely unmodified stock environment, hooks only in random-interrupt configs, and `third_party/` must be clean after every build (D-028) |
| D8 | TB-only simulation-control device at `0x4000_0000` | Approved; recorded in `docs/memory_map.md` as simulation-only, reserved (D-029) |
| D9 | 7 configs per test | Approved, **plus** interrupt coverage with derived minimums (P2.13, D-030) |
| D10 | `mtval` = instruction bits for illegal, pc for EBREAK | Approved (D-031) |
| D11 | `mstatush` | Add as read-only zero (D-032) |

**Phase 3 notes:** Spike co-simulation runs with interrupts **off** (or with injection, in the lockstep variant), because offline Spike cannot reproduce the TB's interrupt timing. Spike implements Sdtrig triggers, so `rv32mi-p-breakpoint` needs either a Spike configuration with no triggers or a co-simulation-only exclusion (D-025).

## P2.13 Interrupt coverage (owner, D9)

### Events

The testbench counts five events (one of them split three ways), using the commit-point signals of P2.5. Each is counted at most once per cycle.

| Counter | Event (owner's wording) | Definition |
|---|---|---|
| `irq_ex_memop` | Interrupt taken while EX holds a memory op waiting to issue | `irq_take` and EX holds a valid load/store with no exception of its own. Its request is blocked this cycle by `kill_ex`; without the interrupt it would issue now or wait in EX. |
| `irq_ex_memop_held` | (stronger form, reported only) | As above, and EX had already been held for at least one cycle by the issue rule (4.6). Only random latency can hold EX, so this cannot be derived (see below). |
| `irq_ldst` | Interrupt taken on a committing load or store | `irq_take` and the MEM instruction is a load or store (its response has arrived without `err`) |
| `irq_redirect` | Interrupt taken in the same cycle as a branch redirect from EX | `irq_take` and EX requests a redirect this cycle (taken branch/JAL/JALR not already fired, 4.3). MEM's redirect wins and the branch is refetched after `mret`. |
| `irq_defer_csr`, `irq_defer_mret`, `irq_defer_fencei` | Interrupt pending but deferred because MEM held a CSR op, MRET or FENCE.I | `irq_pend` and `can_commit`, and MEM holds a CSR instruction / MRET / FENCE.I. `irq_pend` uses the state before the instruction, so a deferred interrupt was really enabled and pending. |
| `exc_irq` | Trap (exception) and interrupt pending in the same cycle | `trap_take` and `irq_pend` |

### Where the events come from, and why random stimulus alone cannot guarantee them

`irq_pend` lasts only until the next committing instruction takes the interrupt, so a randomly timed line mostly hits "ordinary" instructions. E4 and E5 need the pending window to begin exactly when the next commit is a serializing or excepting instruction; with random delays of 100–1000 cycles that is rare, and no minimum can be derived for it. The same is true of E1 and E3 under random latency. So the minimums come from **`sw/tests/irq_cov.S`**, which builds each event deterministically, the same way `hz_ctrl` guarantees its redirect counts. Every other test contributes its random-stimulus events on top; the report shows the two parts separately.

### The construct

Every scenario in `irq_cov.S` uses the same three steps:

```
csrci mstatus, MIE           # MIE = 0: nothing can be taken from here on
sw    t1, IRQ_FORCE(t0)      # raise MSIP; the line is high from the cycle after acceptance
csrsi mstatus, MIE           # serializing: no interrupt on it (pre-state MIE=0); flushes
<S1>                         # the FIRST instruction to commit after the flush
<S2>
```

Why this is deterministic under **any** memory timing: MIE is 0 from the `csrci` until the `csrsi` commits, so no interrupt is taken in between. The force store commits before `csrsi`, so the line is already high when `csrsi` commits. `csrsi` flushes everything younger and refetches from `S1`, so `S1` is the first instruction to commit with MIE=1 and a pending line, whatever the latencies. A random line that happens to be pending too changes only which cause is taken, not the event.

D-033 (no interrupt while EX holds an unaccepted D request) cannot defer the interrupt past `S1`: EX may assert a request only while `S1` is safe in MEM, which for a load/store `S1` starts in the cycle its response is present, the same cycle it commits; so no request can have been held unaccepted in the previous cycle. In C2–C6, `S2` is not a load/store.

For E1 and E3 the event also needs `S2` in EX in the cycle `S1` commits. In ideal memory that is guaranteed: after the MEM redirect in cycle c, `S1` is requested in c, delivered in c+1, in ID in c+2, EX in c+3 and MEM in c+4; `S2` is requested in c+1 and is in EX in c+4. With random latency, `S2` can arrive later than `S1`'s commit (the I-port's `ready` can drop for any number of cycles), so E1/E3 are not guaranteed there.

| Scenario (count) | S1 | S2 | Events guaranteed per run |
|---|---|---|---|
| C1 (4) | `lw`, `lbu`, `sh`, `sw` | `sw`, `lw`, `lw`, `sb` | E2 = 4 (any memory); E1 = 4 (ideal memory) |
| C2 (4) | `addi` | taken `beq`, taken `bne`, `jal`, `jalr` | E3 = 4 (ideal memory) |
| C3 (2) | `csrr a0, mscratch`; `csrci mstatus, MIE` | `nop` | E4 CSR = 2 (any). After the `csrci`, the test also checks that no interrupt was taken (the handler count is unchanged) until MIE is set again. |
| C4 (2) | `fence.i` | `nop` | E4 FENCE.I = 2 (any) |
| C5 (2) | `mret` (with `mepc` = S2 and MPIE=1, set while MIE=0) | `nop` | E4 MRET = 2 (any) |
| C6 (5) | `ecall`, `ebreak`, `.word 0`, misaligned `lw`, `lw` from unmapped `0x7000_0000` | `nop` | E5 = 5 (any). The handler skips the instruction (`mepc += 4`); `mret` restores MIE=1 and the pending interrupt is taken on the next commit. |

Deferred scenarios (C3–C5) and exception scenarios (C6) are then followed by an ordinary instruction, which takes the interrupt; `irq_cov.S` checks the handler count after every scenario.

### Measured against the derivation (seed 101, `irq_cov` alone)

| Config | E1 | E2 | E3 | E4 CSR / MRET / FENCE.I | E5 |
|---|---|---|---|---|---|
| `ideal` (interrupts off) | 4 | 4 | 4 | 2 / 2 / 2 | 5 |
| `ideal+irq` | 4 | 5 | 4 | 2 / 2 / 2 | 5 |
| `random` (interrupts off) | 1 | 4 | 3 | 2 / 2 / 2 | 5 |
| `random+irq` | 1 | 5 | 2 | 2 / 2 / 2 | 5 |

With ideal memory and no random interrupts every count sits exactly on its floor, and with random latency E1/E3 fall below it, as the derivation predicts; that is why their floors apply to ideal memory only.

### Minimums

Per run, checked by `run_riscv_tests.py` from two lines in the `irq_cov.S` header, in every configuration where the derivation holds:

```
IRQ-EXPECT(any):   irq_ldst>=4 irq_defer_csr>=2 irq_defer_fencei>=2 irq_defer_mret>=2 exc_irq>=5
IRQ-EXPECT(ideal): irq_ex_memop>=4 irq_redirect>=4
```

`(ideal)` means ideal memory (with or without random interrupts). Aggregated over the six random-interrupt runs (3 × `ideal+irq`, 3 × `random+irq`), `make accept-phase2` fails unless every total reaches the sum of the per-run floors:

| Event | Counter | Per run, ideal memory | Per run, random latency | **Minimum over the 6 random-interrupt runs** |
|---|---|---|---|---|
| E1 | `irq_ex_memop` | 4 | – | **12** |
| E2 | `irq_ldst` | 4 | 4 | **24** |
| E3 | `irq_redirect` | 4 | – | **12** |
| E4 | `irq_defer_csr` | 2 | 2 | **12** |
| E4 | `irq_defer_mret` | 2 | 2 | **12** |
| E4 | `irq_defer_fencei` | 2 | 2 | **12** |
| E5 | `exc_irq` | 5 | 5 | **30** |

The runner computes the aggregate floors from the `IRQ-EXPECT` lines and the configurations actually run, so the two can never disagree. The report prints, for each event, the total, the `irq_cov` part and the random-stimulus part (all other tests), plus `irq_ex_memop_held`. The random-stimulus part is reported, not gated: it depends on the seeds, and a floor for it could only be measured, not derived (D-022).

---

# Phase 3: retirement trace and Spike co-simulation

> **Status: PROPOSED, awaiting owner approval.** No RTL or scripts are written until this is approved. Decisions needed: [P3.9](#p39-decisions-needed).
>
> **Spike is not installed** (`make check-tools PHASE=3` fails). Install: `brew install dtc && brew tap riscv-software-src/riscv && brew install riscv-isa-sim`. Everything below about Spike was checked in the **source** of Spike `main` at commit `0bff121` (2026-09-28), which is what that formula builds (it tracks `main`, unpinned; its bottles are for macOS 15 only, so it builds from source here). **Nothing has been verified against an installed binary yet.** P3.3 lists each option and fact with its source location; the first implementation step is to re-verify every one on the installed binary and record the result.

## P3.1 (a) Scope

Offline co-simulation runs our simulator and Spike on the same ELF, writes both retirement traces, and compares them instruction by instruction. Spike cannot model `sim_ctrl` (interrupt lines, `IRQ_ACK`/`IRQ_FORCE`) or the testbench's interrupt timing, so offline co-simulation covers only runs **without interrupts and without `sim_ctrl` accesses**.

**Configurations:** `ideal` and `random` (random latency), both with `+irq=off`, seeds 101/202/303: **4 runs per test**. Memory latency does not change the architectural trace, so the random-latency runs must produce exactly the same trace as the ideal run. That catches pipeline bugs that corrupt a value silently (for example a wrong forwarded value stored to a location nobody reloads), which the self-checking tests cannot see.

| Test set | ELFs | Offline co-sim | Reason if not |
|---|---|---|---|
| `rv32ui-p-*` | stock, unmodified (41, `ma_data` excluded by D-015) | yes | |
| `rv32ui-p-*` interrupt-hook build | `build/riscv-tests-irq/` | no | only used with random interrupts |
| `rv32mi-p-*` | stock (15, `pmpaddr` excluded by D-026) | yes | |
| `hz_fwd`, `hz_load_use`, `hz_ctrl` | CSR-free env | yes | needs a `fromhost` symbol in the CSR-free env (P3.9 D6) |
| `tr_misaligned`, `tr_ecall_ebreak_mret` | stock env + handler | yes | |
| `tr_access_fault` | | yes, after moving the address-0 case out (P3.4) | Spike maps its debug module at `[0x0, 0x1000)` |
| `csr_ops`, `tr_illegal` | | yes, after moving the implementation-defined checks out (P3.4) | |
| `csr_impl`, `tr_illegal_impl`, `tr_access_fault_null` (new, split out) | | **no** (named exclusion) | they check choices where the spec allows either value and Spike's differs from ours |
| `irq_directed`, `irq_cov` | | **no** (named exclusion) | use `sim_ctrl` and forced interrupts |
| All `+irq` configurations | | **no** | random interrupts |

The co-simulation exclusions go in a new file, `scripts/cosim_exclusions.txt`, with one reason per line, like `scripts/exclusions.txt`. Every excluded test still runs in `accept-phase2`, so nothing loses coverage.

**Lockstep DPI co-simulation (Spike stepped per retirement, interrupts and MMIO read values injected): proposed to be deferred** until after Phase 6, when the real CLINT/PLIC/UART/SPI exist (Phase 7 at the latest).
- **What deferring costs:** every run with interrupts (1935 interrupts taken per `accept-phase2`) and every `sim_ctrl` test is checked only by the self-checking software, the testbench's end-of-run and entry checks (P2.9), the assertions, and the P2.13 coverage. None of it is compared against a reference model, so a wrong but self-consistent value (for example a wrong `mtval` that no handler reads) goes unnoticed in those runs. Phase 5/6 MMIO reads cannot be compared offline either, and are marked "don't compare values" per CLAUDE.md section 6.
- **What doing it now costs:** building Spike as a library (`libriscv`) and linking it into the Verilator simulation, with DPI glue for stepping and injecting interrupts and read values. That needs space-free paths (D-010) and a C++ build that tracks an unpinned upstream API. Most of the value arrives with the peripherals in Phases 5 and 6, so doing it now means doing it twice.

## P3.2 (d) Retirement trace

### Core port (`core_top`, `ifndef SYNTHESIS`)

One `rvfi_t` struct output, `rvfi_o`, valid for one cycle when the instruction in MEM leaves the commit point: `retire` (it commits) or `trap_take` (it raises an exception). The fields follow RVFI naming where they apply:

| Field | Meaning |
|---|---|
| `valid` | an instruction left MEM this cycle (retired, or trapped) |
| `order` | 64-bit count of `valid` beats (the checker requires it to increase by one) |
| `insn`, `pc_rdata`, `pc_wdata` | instruction bits, its pc, and the pc of the next instruction to execute (trap vector, MRET target, branch target, or pc+4) |
| `rd_addr`, `rd_wdata` | 0 when the instruction writes no register (including a trapping one) |
| `mem_addr`, `mem_rmask`, `mem_wmask`, `mem_rdata`, `mem_wdata` | the D-port access, byte address and lane masks as sent |
| `csr_we`, `csr_addr`, `csr_wdata` | a CSR written by this instruction, with the value **read back after the write**. Set for CSR instructions with write intent, and for MRET (`mstatus`). Counter increments are not writes. |
| `trap`, `trap_cause`, `trap_tval` | the instruction raised an exception: it did not retire; `mepc` = `pc_rdata` |
| `intr`, `intr_cause`, `intr_epc` | this instruction retired and an interrupt was taken after it (`mepc` = `intr_epc` = its `next_pc`) |

The testbench (`+rvfi=<file>`) writes one line per beat:

```
I <order> <pc> <insn> [x<rd>=<value>] [ld <addr> <rmask>] [st <addr> <wmask> <data>] [csr <addr>=<value>]
E <order> <pc> <insn> cause=<n> tval=<value>        exception: nothing else retired
Q cause=<n> epc=<value>                              interrupt entry, after the preceding I line
```

Store data is normalized to the bytes actually written (shifted to bit 0), as Spike logs it.

### How the same events appear in Spike's log (checked in source)

Spike runs with both `-l` (the debug log with the disassembly of every executed instruction and the exception lines) and `--log-commits` (one commit line per retired instruction), into one file (`--log=<file>`):
- **Retired instruction:** `core   0: 3 0x80000004 (0x02028593) x11 0x80000030 c768_mstatus 0x00001880 mem 0x80001000 0x00000001`. The fields are: privilege, pc, instruction, register writes, CSR writes as `c<number>_<name>`, then loads (`mem <addr>`) and stores (`mem <addr> <data>`, data in the store's width). `riscv/execute.cc`, `commit_log_print_insn`.
- **Exception:** the trapping instruction gets **no** commit line (the trap is thrown before logging). With `-l`, `take_trap` prints `core   0: exception trap_illegal_instruction, epc 0x80000124` followed, when the trap has a value, by `core   0:           tval 0x74445073` (`riscv/processor.cc`). The comparator maps the trap name to the cause code, takes `insn` from the preceding `-l` disassembly line for the same pc, and uses `tval` = 0 when no tval line follows (ECALL).
- **Trap-entry CSR writes** (`mepc`, `mcause`, `mtval`, `mstatus`) do not appear in either trace. They are compared through the `E`/`Q` fields, and through every later CSR read and `mret`.
- **Interrupts** would appear the same way as exceptions (`take_trap` also handles them). Offline, none can occur: an interrupt in our trace in an offline-scope run is a failure.

The comparator converts Spike's log into the same `I`/`E` line format, then compares line by line: pc, instruction, register write (number and value), memory address/mask/data, CSR write (number and value), and trap cause/tval.

## P3.3 (b) Spike configuration

```
spike --isa=rv32i_zicsr_zifencei_zicntr --priv=m --pmpregions=0 --triggers=0 \
      -m0x80000000:0x10000 --pcs=0:0x80000000 --dtb=build/cosim/core.dtb \
      --wfi-as-nop --instructions=<timeout> -l --log-commits --log=<file> <elf>
```

| Option / fact | Why | Where checked in source |
|---|---|---|
| `--isa=rv32i_zicsr_zifencei_zicntr` | Our instruction set. **`zicntr` is required:** without it Spike has no `cycle`/`instret`/`cycleh`/`instreth` (`rv32mi-p-zicntr`). `misa` then reads `0x4000_0100`, same as ours. | `spike.cc` help; `csr_init.cc` (counters behind `EXT_ZICNTR`) |
| `--priv=m` | M-mode only. `satp`, `medeleg`, `mideleg`, `mcounteren` are then absent (illegal, as in our core); `mstatus.MPP` legalizes to M; `mstatus` writable bits are MIE, MPIE, MPP only, the same as ours. | `csr_init.cc` (`add_supervisor_csr`/`add_user_csr`), `csrs.cc` `mstatus_csr_t::unlogged_write` |
| `--pmpregions=0` | No PMP. Spike then raises an illegal-instruction trap on any `pmpaddr*` access, exactly like our core, so the stock env's `INIT_PMP` probe takes the same trap in both. | `csrs.cc` `pmpaddr_csr_t::verify_permissions` (`n_pmp == 0` → illegal) |
| `--triggers=0` | Spike's Sdtrig with zero triggers: `tselect` ignores writes ≥ the trigger count (reads 0), `tdata1`/`tdata2` are constant 0, `tcontrol` is absent. That is **exactly our D-025 stubs**, so `rv32mi-p-breakpoint` needs **no co-sim exclusion** (resolves the D-025 Phase 3 note). Spike also has `tdata3` and `tinfo` (constant 0), which we lack; see P3.4. | `csr_init.cc` (`trigger_count > 0` branch), `csrs.cc` `tselect_csr_t` |
| `-m0x80000000:0x10000` | Main memory, 64 KB, as `soc_pkg`. Addresses past it fault in both. | `spike.cc` help |
| `--pcs=0:0x80000000` | Starts hart 0 at our reset pc **without executing the boot ROM** (help text: "This will bypass the built-in boot ROM"; `sim.cc` `proc_reset` sets the pc directly). Registers start at 0 in both. | `spike.cc`, `sim.cc` |
| `--dtb=build/cosim/core.dtb` | A device tree with one hart and the memory node only. Spike creates CLINT, PLIC and the 16550 UART **only from device-tree nodes** (`sim.cc`: "clint, plic, ns16550 are always discovered via dtb"). Without this, Spike's CLINT would be at `0x0200_0000` with a free-running `mtime`. The source `core.dts` is generated from `soc_pkg` values and compiled with `dtc` (a dependency of the formula). | `sim.cc` device-factory loop |
| `--wfi-as-nop` | Our WFI is a NOP; Spike would otherwise wait for an interrupt that never comes. | `spike.cc` help |
| `--instructions=<n>` | Timeout, the same budget as the testbench's. | `spike.cc` help |
| no `--misaligned` | Misaligned data accesses trap in both (D-015). | |
| HTIF | Spike ends the run when the program writes `tohost` (needs both `tohost` **and** `fromhost` symbols). The stock env has both; the CSR-free env has only `tohost` (P3.9 D6). | fesvr, to verify on the binary |

**Regions Spike maps that our SoC does not** (they cannot be removed by options): the debug module at `[0x0, 0x1000)` (`sim.cc`: `bus.add_device(DEBUG_START, …)`, always) and the boot ROM at `0x1000` (always added, holding the reset code and the device tree, rounded up to 4 KB pages). A load from address 0 therefore faults in our core but not in Spike, which is why the address-0 case of `tr_access_fault` moves to its own test (P3.4). No other offline-scope test touches `[0x0, 0x2000)`.

**Values that differ:** `marchid` is hard-coded to 5 in Spike (Spike's registered architecture ID; we must not claim it) and 0 in ours. `mvendorid` and `mimpid` are 0 in both. `mcycle` counts retired instructions in Spike and clock cycles in ours. These become rules R3 and R4.

**Pinning:** the formula builds whatever `main` is on install day. Proposal: record the installed commit in `docs/decisions.md`, have `make check-tools` print it, and re-run the P3.3 checks whenever it changes.

## P3.4 Where Spike and our core legitimately differ, and how each is handled

| Item | Spike | Ours | Handling (proposed) |
|---|---|---|---|
| `marchid` | 5 | 0 | Rule **R3** (value divergence) in `rv32mi-p-mcsr`. `csr_ops` case 27 moves to `csr_impl`. |
| `mcycle`/`cycle`(`h`) read values | instructions | clock cycles | Rule **R4**. `csr_ops` case 40 (`mcycle` > 0 right after writing 0) moves to `csr_impl`. |
| `mtvec.MODE` | bit 0 writable (vectored supported) | read-only 0 (D-024) | `csr_ops` case 16 moves to `csr_impl` |
| `mcause` width | all 32 bits writable | bit 31 and [3:0] | `csr_ops` case 29 (write all-ones) moves to `csr_impl` |
| `mcountinhibit` | exists (CY, IR writable) | absent (illegal) | **D1: implement it** (CY and IR, functional; the privileged spec recommends it). Otherwise `rv32mi-p-instret_overflow`'s probe traps only in ours and a resync rule would be needed. |
| `tdata3`, `tinfo` | exist, constant 0 | absent | **D1: add as read-zero stubs**, completing the zero-trigger Sdtrig set of D-025 |
| `mconfigptr` | exists, 0 | absent | **D1: add as read-only 0** (required by privileged spec 1.12) |
| `time`/`timeh` | exist (with `zicntr`), read 0 without a CLINT | absent (illegal) | `tr_illegal` case 27 moves to `tr_illegal_impl`; **D2**: whether the core implements `time` from the CLINT's `mtime` in Phase 6 |
| Address `0x0` | debug module (no fault) | access fault | `tr_access_fault` case 3 moves to `tr_access_fault_null` |

"Moves" means the check is cut from one test and pasted into a new test **unchanged**. The new test still runs in every `accept-phase2` configuration, so no check is weakened or dropped; only offline co-simulation skips it, by name. With D1 approved, `tr_illegal` cases 24 and 25 (`tdata3`, `mcountinhibit` illegal) become wrong. They are replaced by `tcontrol` (0x7A5) and `mhpmcounter3` (0xB03), which neither implementation has.

## P3.5 (c) Comparator rules

`scripts/cosim_compare.py` compares the normalized traces and fails on the **first** difference that no rule covers. On failure it prints that line from both traces, the 10 lines before it, and the disassembly. Each rule has an ID, a reason, and an exact match condition. The report prints how many times each rule fired per test, and a rule that fires where it is not expected (for example R3 on anything but a `marchid` read) is itself a failure. There is no pattern-based or blanket ignore.

| ID | Rule | Reason |
|---|---|---|
| **R1** `BOOT` | Spike's first record must be at `0x8000_0000`. With `--pcs` the boot ROM never executes. If the binary check shows `--pcs` does not do this, the fallback skips exactly the five known ROM instructions (`auipc t0`, `addi a1`, `csrr a0, mhartid`, `lw t0, 24(t0)`, `jr t0`) at `0x1000`–`0x1010` and nothing else. | Spike's reset code; our core starts at `RESET_PC` |
| **R2** `END` | Comparison ends at the first store to `tohost`, in both traces. Spike's later records are dropped, but only if they are the program's own `write_tohost` loop (pc within the loop, stores only to `tohost`/`tohost+4`). Both runs must also report pass: `tohost` = 1 in the testbench, exit 0 in Spike. | Our testbench stops at the store; Spike exits when HTIF next polls `tohost` |
| **R3** `MARCHID` | A CSR read of `marchid` (0xF12): `rd` may be 0 (ours) vs 5 (Spike). | Spike's registered ID; ours is 0 (unregistered). |
| **R4** `CYCLE` | A CSR read of `mcycle`, `mcycleh`, `cycle`, `cycleh`: `rd` values may differ. Writes to `mcycle`/`mcycleh` are compared normally. | Ours counts clock cycles, Spike counts instructions; both are legal. |
| **R5** `LONG-ENC` | For an instruction with `inst[4:0] = 11111` (a 48- or 64-bit length encoding), compare only the low 32 bits of the instruction. `mtval` is XLEN wide, so it compares as is. | Spike fetches 6 or 8 bytes for such encodings (`decode.h` `insn_length`); ours has no long instructions and traps on the first 32 bits. Used by `tr_illegal` case 5 (`0x0000057f`). |

**Value-divergence rules (R3, R4) and taint.** The destination register of an R3/R4 read is marked *tainted*. Taint propagates through data flow: results computed from a tainted source register are tainted, a store of tainted data taints those memory bytes, and a load from tainted bytes taints its result. A value mismatch is allowed only on tainted data. A pc, instruction, trap or memory-address mismatch is **never** allowed, so a divergent value that changes control flow or addressing still fails. Taint is cleared when the register is overwritten with an untainted value.

Rules that may be needed after the binary check, **not proposed yet**: if Spike logs extra CSR records for RV32 counter writes (for example `minstreth` alongside `minstret`), a normalization rule would be proposed with the log evidence. No rule is added without your approval.

## P3.6 Make targets and files (implementation, after approval)

- `rtl/core/core_top.sv`: the `rvfi_o` port. `tb/core_tb/core_tb_top.sv`: the `+rvfi=<file>` trace writer and checker (`order` increases by one, no `Q` line in an `+irq=off` run).
- `scripts/cosim_compare.py` (Spike runner, log normalizer, comparator, rules), `scripts/cosim_exclusions.txt`, and `build/cosim/core.dts` generated from `soc_pkg` values.
- `make cosim` (the whole Phase 3 set, 4 configurations) and `make cosim TEST=<elf> [MEM=random SEED=N]` for one run. `make test` gains `cosim`.
- `check_tools.py` requires `spike` and `dtc` for phase 3 and prints Spike's commit.
- **Phase 3 acceptance (CLAUDE.md section 8, "zero mismatches on the full riscv-tests suite"):** zero unexplained mismatches for every in-scope `rv32ui-p` and `rv32mi-p` test, and for the in-scope directed tests, in all 4 configurations. The per-rule usage counts are recorded in the results.

## P3.7 (e) Mutation plan: bugs only co-simulation catches

**Protocol.** A mutant counts only if it (1) **passes** `make accept-phase2` and `accept-phase1` completely, proving the self-checking tests, testbench checks and assertions miss it, and (2) **fails** `make cosim` at the first affected instruction. A candidate that fails (1) is reported as "already caught by self-checks" and replaced, never counted. All RTL is restored from a copy afterwards, and each result is recorded in `PROGRESS.md`.

| # | Injected bug | Why self-checks miss it | Why co-sim catches it |
|---|---|---|---|
| CM1 | CSRRS/CSRRC with `rs1 = x0` performs a write of the value just read, on the non-counter RW CSRs (`mscratch`, `mtvec`, `mepc`, …) | the value is unchanged, so no software can see it | our trace shows a `csr` write that Spike's log does not |
| CM2 | `sh` to offset 0 also enables byte lane 2 (the replicated low byte is written there) | only visible if byte 2 is read back later | store mask/data differ from Spike's 2-byte store |
| CM3 | For an illegal-instruction trap on an access to a **nonexistent** CSR with `rd = x0` (for example the env's `csrw pmpaddr0`), `mtval` = 0 instead of the instruction bits | the stock env's probe handlers never read `mtval`; `tr_illegal`'s nonexistent-CSR cases all use `rd = a0` (its `rd = x0` case, `unimp`, is a read-only-CSR write and keeps the correct `mtval`) | the `E` line's `tval` differs from Spike's |
| CM4 | A load result is written with the wrong extension (`lbu` behaving as `lb`) **only** when the next instruction overwrites the same `rd` | the wrong value is dead before anything reads it | `rd` value differs on the load's own `I` line |
| CM5 | Under random latency only: a store whose data is forwarded from MEM/WB during a D-side stall takes the value from one cycle too early, on stores to a region that is never reloaded | the stored value is never read back; ideal mode is unaffected | the `random` configuration's store data differs from Spike's (and from our own `ideal` trace) |

CM4 and CM5 are deliberately narrow; if a regression test turns out to observe them, they are replaced by a candidate from the same class (a dead value, or a silent memory corruption).

## P3.8 Documents updated at approval

- `docs/decisions.md`: D-035 onward (scope, lockstep deferral, Spike config and pin, the core alignments, the test splits, the rules and taint semantics, the CSR-free env's `fromhost`). D-025's Phase 3 note is resolved by `--triggers=0`.
- CLAUDE.md section 6: records that offline co-sim runs with interrupts off and without `sim_ctrl`, and the lockstep deferral.

## P3.9 Decisions needed

| # | Question | Recommendation |
|---|---|---|
| D1 | Align the core with Spike where the spec recommends or requires the CSR: `mcountinhibit` (CY, IR; functional), `tdata3`/`tinfo` (read-zero stubs), `mconfigptr` (read-only 0) | **Yes.** About 2 flip-flops plus decode; removes a resync rule; `tr_illegal` cases 24/25 then use `tcontrol` and `mhpmcounter3` |
| D2 | `time`/`timeh`: stay absent (illegal) for now; decide in Phase 6 whether the core reads `mtime` from the CLINT | **Stay absent now, decide in Phase 6** |
| D3 | Keep our other choices (`mtvec` direct-only, `mcause` = interrupt bit + 4-bit code, `marchid` = 0) and move their checks to `csr_impl`/`tr_illegal_impl`, which co-sim skips by name | **Yes** |
| D4 | Move `tr_access_fault`'s address-0 case to `tr_access_fault_null` (Spike's debug module lives there) | **Yes** |
| D5 | Co-sim configurations: `ideal` + `random` × 3 seeds, interrupts off (4 runs per test) | **Yes** |
| D6 | Add a `fromhost` symbol to the CSR-free environment (`sw/common/test_env_nocsr`, ours), so Spike's HTIF can end the `hz_*` runs | **Yes** |
| D7 | Defer lockstep DPI co-simulation to after Phase 6 (Phase 7 at the latest), with the cost stated in P3.1 | **Yes** |
| D8 | Rules R1–R5 with taint for R3/R4, exactly as in P3.5 | **Yes** |
| D9 | Spike install (Homebrew, builds `main` from source), with the installed commit recorded and printed by `check-tools` | **Yes**, install when you approve; the P3.3 checks are then repeated on the binary before any comparator code is written |
