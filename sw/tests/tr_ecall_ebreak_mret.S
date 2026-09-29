# =============================================================================
# tr_ecall_ebreak_mret.S - trap entry/exit (docs/architecture.md P2.5, P2.6)
# -----------------------------------------------------------------------------
#  2-3  ECALL round trip with MIE = 1: mcause 11, mepc, mtval 0; on entry
#       MIE = 0 / MPIE = 1, after mret MIE = 1 / MPIE = 1
#  4    ECALL with MIE = 0: on entry MPIE = 0, after mret MIE = 0 / MPIE = 1
#  5    EBREAK: mcause 3, mtval = pc
#  6-8  MRET to an explicit mepc: MIE <- MPIE, MPIE <- 1; mepc[1:0] ignored
#  9    csrw mtvec takes effect for the very next trap
# 10-11 minstret does not count ECALL or EBREAK (the handler's first
#       instruction reads minstret)
# 12-13 instruction access fault: a jump outside the executable region traps
#       with mcause 1, mepc = mtval = the target; the jump itself retires
# 14    misaligned jump target: mcause 0, mepc = the jump, mtval = the target,
#       rd not written
#
# Stock environment + sw/common/irq_handler.h, interrupts enabled except where
# a check needs MIE = 0. Registers t5/t6 and s5-s11 belong to the trap handler.
# The stock trap vector would treat ECALL as the pass/fail call, so ECALLs here
# are expected exceptions of our own handler (s11 != 0).
# =============================================================================
#include "riscv_test.h"
#include "test_macros.h"
#include "irq_handler.h"

#define MIE_MPIE (MSTATUS_MIE | MSTATUS_MPIE)

RVTEST_RV32M
RVTEST_CODE_BEGIN

  DIRECTED_TRAP_INSTALL(trap_handler)
  IRQ_ENABLE_ALL

  # --- 2-3: ECALL with interrupts enabled -------------------------------------
  li   TESTNUM, 2
  li   s11, 1
1:ecall
  bnez s11, fail
  li   t0, CAUSE_MACHINE_ECALL; bne s8, t0, fail
  la   t0, 1b; bne s9, t0, fail
  bnez s10, fail
  li   t0, MIE_MPIE; and t1, s6, t0
  li   t2, MSTATUS_MPIE; bne t1, t2, fail        # entry: MIE = 0, MPIE = 1
  li   TESTNUM, 3
  csrr t1, mstatus; and t1, t1, t0
  bne  t1, t0, fail                              # after mret: MIE = MPIE = 1

  # --- 4: ECALL with MIE = 0 ---------------------------------------------------
  li   TESTNUM, 4
  csrci mstatus, MSTATUS_MIE
  li   t0, MSTATUS_MPIE
  csrc mstatus, t0                               # MPIE = 0 as well
  li   s11, 1
  ecall
  bnez s11, fail
  li   t0, MIE_MPIE; and t1, s6, t0
  bnez t1, fail                                  # entry: MIE = 0, MPIE = 0
  csrr t1, mstatus; and t1, t1, t0
  li   t2, MSTATUS_MPIE; bne t1, t2, fail        # after mret: MIE = 0, MPIE = 1
  csrsi mstatus, MSTATUS_MIE

  # --- 5: EBREAK ---------------------------------------------------------------
  li   TESTNUM, 5
  li   s11, 1
1:ebreak
  bnez s11, fail
  li   t0, CAUSE_BREAKPOINT; bne s8, t0, fail
  la   t0, 1b; bne s9, t0, fail
  bne  s10, t0, fail                             # mtval = pc

  # --- 6-8: MRET to an explicit mepc (MIE = 0 while mepc is live) --------------
  li   TESTNUM, 6
  csrci mstatus, MSTATUS_MIE
  la   t0, 1f
  csrw mepc, t0
  li   t0, MSTATUS_MPIE
  csrs mstatus, t0
  mret
  j    fail
1:csrr t1, mstatus; li t0, MIE_MPIE; and t1, t1, t0
  bne  t1, t0, fail                              # MIE <- MPIE (1), MPIE <- 1

  li   TESTNUM, 7
  csrci mstatus, MSTATUS_MIE
  la   t0, 1f
  csrw mepc, t0
  li   t0, MSTATUS_MPIE
  csrc mstatus, t0
  mret
  j    fail
1:csrr t1, mstatus; li t0, MIE_MPIE; and t1, t1, t0
  li   t2, MSTATUS_MPIE; bne t1, t2, fail        # MIE <- MPIE (0), MPIE <- 1

  li   TESTNUM, 8
  la   t0, 1f
  addi t0, t0, 3                                 # mepc[1:0] read as 0
  csrw mepc, t0
  mret                                           # MIE = 0 here, MPIE = 1
  j    fail
1:csrsi mstatus, MSTATUS_MIE

  # --- 9: a new mtvec applies to the very next trap -----------------------------
  li   TESTNUM, 9
  csrci mstatus, MSTATUS_MIE
  li   s4, 0
  la   t0, alt_handler
  csrw mtvec, t0
  ecall                                          # goes to alt_handler
  li   t0, 0xabc; bne s4, t0, fail
  la   t0, trap_handler
  csrw mtvec, t0
  csrsi mstatus, MSTATUS_MIE

  # --- 10-11: ECALL and EBREAK do not retire -------------------------------------
  # Retired after the csrwi (whose own increment is suppressed): li and nop.
  li   TESTNUM, 10
  csrci mstatus, MSTATUS_MIE
  csrwi minstret, 0
  li   s11, 1
  nop
  ecall
  li   t0, 2; bne s5, t0, fail
  li   TESTNUM, 11
  csrwi minstret, 0
  li   s11, 1
  nop
  ebreak
  li   t0, 2; bne s5, t0, fail
  csrsi mstatus, MSTATUS_MIE

  # --- 12-13: instruction access fault -------------------------------------------
  li   TESTNUM, 12
  li   a1, 0x70000000
  li   a0, 0
  la   s11, 2f
1:jalr a0, 0(a1)
  j    fail
2:li   t0, CAUSE_FETCH_ACCESS; bne s8, t0, fail
  bne  s9, a1, fail
  bne  s10, a1, fail
  la   t0, 1b; addi t0, t0, 4; bne a0, t0, fail  # the jump retired (link written)

  li   TESTNUM, 13
  li   a1, 0x80010000                            # first word after main memory
  la   s11, 2f
  jr   a1
  j    fail
2:li   t0, CAUSE_FETCH_ACCESS; bne s8, t0, fail
  bne  s9, a1, fail
  bne  s10, a1, fail

  # --- 14: misaligned jump target -------------------------------------------------
  li   TESTNUM, 14
  la   a1, 3f
  addi a1, a1, 2
  li   a0, 0x5a5a
  la   s11, 2f
1:jalr a0, 0(a1)
3:j    fail
  j    fail
2:li   t0, CAUSE_MISALIGNED_FETCH; bne s8, t0, fail
  la   t0, 1b; bne s9, t0, fail
  bne  s10, a1, fail
  li   t0, 0x5a5a; bne a0, t0, fail              # rd not written

  # --- one expected exception per case -------------------------------------------
  li   TESTNUM, 15
  li   t0, 8
  bne  s7, t0, fail

  TEST_PASSFAIL

  .align 2
trap_handler:
  DIRECTED_TRAP_HANDLER

  # Used by case 9 only, with MIE = 0: mark, skip the ECALL, return.
  .align 2
alt_handler:
  li   s4, 0xabc
  csrr t5, mepc
  addi t5, t5, 4
  csrw mepc, t5
  mret

RVTEST_CODE_END

  .data
RVTEST_DATA_BEGIN

  TEST_DATA
  IRQ_DATA

RVTEST_DATA_END
