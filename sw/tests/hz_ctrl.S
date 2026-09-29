# =============================================================================
# hz_ctrl.S - directed control-hazard tests (docs/architecture.md 3.2, 4.3)
# -----------------------------------------------------------------------------
# Every branch type taken and not taken with forwarded operands; the shadow of
# a taken branch (register write, store, branch) has no effect; back-to-back
# taken branches, including a target inside the flushed shadow; JAL/JALR link
# values; JALR clears bit 0; JALR with rd == rs1 and with an offset; branch
# after load; a counted loop; a jump whose shadow holds a store.
#
# Built with the CSR-free environment. x3 (TESTNUM) and x7 are reserved.
#
# Why the minimum counts below are guaranteed by the design (ideal memory,
# which is the only mode where run_riscv_tests.py checks them):
#
# redirect >= 24: the program has 24 deliberate taken branches/jumps: six
#   taken compares in 2..12, one each in 14, 16, 17, 18, 19, 20 and 22, two in
#   15, and nine taken `bnez` in the loop of 21. TEST_PASSFAIL adds a 25th.
#
# fetch_drop >= 24: in ideal mode, ready is always 1 and every response
#   arrives exactly one cycle after its request, so the D-side never stalls.
#   While ID is not held, the fetch unit has fq empty and one request in
#   flight, so it issues a request every cycle (fq + inflight = 1 < 2).
#   A redirect in cycle t therefore meets the response to the request issued
#   in t-1, and drops it (rsp_stale includes `|| redirect`). That is one drop
#   per redirect.
#
#   The only exception is a load-use hold. If a load is in EX in cycle c, then
#   in c the next response is pushed into fq instead of consumed. In c+1,
#   fq + inflight = 2, so no request is issued. So in c+2 there is no response
#   to drop, and if the load's consumer redirects in c+2 (it is in EX then),
#   the redirect only clears fq. From c+2 onward requests resume, so any
#   later instruction's redirect drops one response again.
#
#   Only one redirecting instruction here consumes a load: the `beq` in case
#   20. That gives 25 - 1 = 24. (Verified by tracing: the single redirect with
#   no drop is that `beq`, with inflight_q = 0 and fq = 1; D-022.)
#
# load_use >= 1: case 20 (lw, then beq on the loaded value).
# HAZARD-EXPECT: redirect>=24 fetch_drop>=24 load_use>=1
# =============================================================================
#include "riscv_test.h"
#include "test_macros.h"

RVTEST_RV32U
RVTEST_CODE_BEGIN

  la x6, tdat

  # --- Each branch type, taken (T) and not taken (N), operands forwarded -----
  li TESTNUM, 2;  li x1, 5;  li x2, 5;  beq  x1, x2, 1f; j fail; 1:   # T
  li TESTNUM, 3;  li x1, 5;  li x2, 6;  beq  x1, x2, fail              # N
  li TESTNUM, 4;  li x1, 5;  li x2, 6;  bne  x1, x2, 1f; j fail; 1:   # T
  li TESTNUM, 5;  li x1, 5;  li x2, 5;  bne  x1, x2, fail              # N
  li TESTNUM, 6;  li x1, -1; li x2, 1;  blt  x1, x2, 1f; j fail; 1:   # T
  li TESTNUM, 7;  li x1, 1;  li x2, -1; blt  x1, x2, fail              # N
  li TESTNUM, 8;  li x1, 1;  li x2, -1; bge  x1, x2, 1f; j fail; 1:   # T
  li TESTNUM, 9;  li x1, -1; li x2, 1;  bge  x1, x2, fail              # N
  li TESTNUM, 10; li x1, 1;  li x2, -1; bltu x1, x2, 1f; j fail; 1:   # T
  li TESTNUM, 11; li x1, -1; li x2, 1;  bltu x1, x2, fail              # N
  li TESTNUM, 12; li x1, -1; li x2, 1;  bgeu x1, x2, 1f; j fail; 1:   # T
  li TESTNUM, 13; li x1, 1;  li x2, -1; bgeu x1, x2, fail              # N

  # --- The shadow of a taken branch has no effect -----------------------------
  li TESTNUM, 14
  li x4, 0
  sw x0, 0(x6)
  beq x0, x0, 1f
  addi x4, x4, 1                     # in ID when the branch redirects
  sw x6, 0(x6)                       # in IF when the branch redirects
  j fail
1:
  bnez x4, fail
  lw x5, 0(x6)
  bnez x5, fail

  # --- Back-to-back taken branches; the second is inside the first's shadow ---
  li TESTNUM, 15
  li x4, 0
  beq x0, x0, 1f
  addi x4, x4, 1
1:
  beq x0, x0, 2f
  addi x4, x4, 1
2:
  bne x0, x0, fail
  bnez x4, fail

  # --- JAL link value ---------------------------------------------------------
  li TESTNUM, 16
  jal x1, 2f
1:
  j fail
2:
  la x5, 1b
  bne x1, x5, fail

  # --- JALR clears bit 0; link value -----------------------------------------
  li TESTNUM, 17
  la x1, 2f
  addi x1, x1, 1                     # odd base, forwarded from EX/MEM
  jalr x5, 0(x1)
1:
  j fail
2:
  la x8, 1b
  bne x5, x8, fail

  # --- JALR with rd == rs1: the target uses the old value ---------------------
  li TESTNUM, 18
  la x1, 2f
  jalr x1, 0(x1)
1:
  j fail
2:
  la x8, 1b
  bne x1, x8, fail

  # --- JALR with a non-zero offset --------------------------------------------
  li TESTNUM, 19
  la x1, 1f
  jalr x0, 8(x1)
1:
  j fail
  j fail
  # 1b + 8 lands here

  # --- Branch after load --------------------------------------------------------
  li TESTNUM, 20
  li x5, 7
  sw x5, 4(x6)
  lw x1, 4(x6)
  beq x1, x5, 1f
  j fail
1:

  # --- Counted loop: 9 taken backward branches, 1 fall-through ----------------
  li TESTNUM, 21
  li x1, 10
  li x4, 0
1:
  addi x4, x4, 3
  addi x1, x1, -1
  bnez x1, 1b
  li x5, 30
  bne x4, x5, fail

  # --- A jump whose shadow holds a store: the store must not happen -----------
  li TESTNUM, 22
  li x5, 0x5a
  sw x0, 8(x6)
  j 1f
  sw x5, 8(x6)
  sw x5, 8(x6)
1:
  lw x4, 8(x6)
  bnez x4, fail

  # --- A not-taken branch does not disturb the next instruction ---------------
  li TESTNUM, 23
  li x1, 1
  bne x1, x1, fail
  addi x1, x1, 1
  li x5, 2
  bne x1, x5, fail

  TEST_PASSFAIL

RVTEST_CODE_END

  .data
RVTEST_DATA_BEGIN

  TEST_DATA

tdat: .word 0, 0, 0, 0

RVTEST_DATA_END
