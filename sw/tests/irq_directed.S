# =============================================================================
# irq_directed.S - interrupt behaviour (docs/architecture.md P2.5, P2.9)
# -----------------------------------------------------------------------------
#  2  Priority: MEI, MSI and MTI forced while MIE = 0, then MIE set: handled in
#     the order 11, 3, 7.
#  3  mepc of a forced interrupt: the IRQ_FORCE store itself carries the
#     interrupt (the line rises the cycle after acceptance, the store commits
#     no earlier), so mepc = the next instruction.
#  4  An interrupt pending when an exception is taken waits for the handler's
#     mret and is then taken on the first instruction to commit.
#  5  Masked: a line with its mie bit clear is visible in mip but not taken.
#  6  MIE toggle loop under forced and random interrupts: an interrupt is never
#     taken on a csrci that clears MIE (the handler checks the instruction
#     before mepc), never while MIE = 0, and every forced line is taken at the
#     next nop after csrsi.
#  7  WFI is a NOP.
# Cases 2-4 pause the random generator (IRQ_RANDOM) so the order is fixed.
#
# The interrupt handler logs {mcause, mepc} and checks that the cause's line is
# high and enabled. It saves the registers it needs; exceptions go to the
# shared DIRECTED_TRAP_HANDLER. Registers t5/t6 and s5-s11 are reserved.
# =============================================================================
#include "riscv_test.h"
#include "test_macros.h"
#include "irq_handler.h"

#define CSRCI_MSTATUS_MIE 0x30047073    /* csrci mstatus, MSTATUS_MIE */
#define LOG_MAX           64            /* log entries of 8 bytes */
#define MIE_MPIE_MASK     (MSTATUS_MIE | MSTATUS_MPIE)

#define STORE_SC(reg_addr, value)  li t0, reg_addr; li t1, value; sw t1, 0(t0);
#define PAUSE_RANDOM   STORE_SC(SIMCTRL_IRQ_RANDOM, 0)
#define RESUME_RANDOM  STORE_SC(SIMCTRL_IRQ_RANDOM, 1)
#define FORCE(mask)    STORE_SC(SIMCTRL_IRQ_FORCE, mask)
#define LOG_RESET      la t0, irq_log_idx; sw zero, 0(t0);

# Take every pending line with MIE = 1 until none is high (random paused).
#define DRAIN                                                           \
  csrsi mstatus, MSTATUS_MIE;                                           \
  li   t0, SIMCTRL_IRQ_LINES;                                           \
91: lw t1, 0(t0);                                                       \
  bnez t1, 91b;

RVTEST_RV32M
RVTEST_CODE_BEGIN

  DIRECTED_TRAP_INSTALL(trap_handler)
  IRQ_ENABLE_ALL

  # --- 2: priority MEI > MSI > MTI ---------------------------------------------
  li   TESTNUM, 2
  PAUSE_RANDOM
  DRAIN
  csrci mstatus, MSTATUS_MIE
  LOG_RESET
  FORCE(IRQ_ALL_MASK)
  csrsi mstatus, MSTATUS_MIE
  nop
  nop
  nop
  nop
  csrci mstatus, MSTATUS_MIE
  la   a0, irq_log
  lw   t0, irq_log_idx
  li   t1, 3*8; bne t0, t1, fail                 # exactly three interrupts
  lw   t0, 0(a0);  li t1, 0x8000000b; bne t0, t1, fail
  lw   t0, 8(a0);  li t1, 0x80000003; bne t0, t1, fail
  lw   t0, 16(a0); li t1, 0x80000007; bne t0, t1, fail

  # --- 3: mepc of a forced interrupt ---------------------------------------------
  li   TESTNUM, 3
  csrsi mstatus, MSTATUS_MIE
  LOG_RESET
  li   t0, SIMCTRL_IRQ_FORCE
  li   t1, MIP_MTIP
  sw   t1, 0(t0)                                 # carries the interrupt
1:nop
  nop
  csrci mstatus, MSTATUS_MIE
  la   a0, irq_log
  lw   t0, irq_log_idx
  li   t1, 8; bne t0, t1, fail
  lw   t0, 0(a0); li t1, 0x80000007; bne t0, t1, fail
  lw   t0, 4(a0); la t1, 1b; bne t0, t1, fail

  # --- 4: an interrupt pending at an exception waits for mret --------------------
  li   TESTNUM, 4
  LOG_RESET
  FORCE(MIP_MSIP)                                # MIE = 0: stays pending
  li   s11, 1
  csrsi mstatus, MSTATUS_MIE
1:ecall                                          # first to commit: exception wins
  nop                                            # handler resumes here: interrupt
2:nop
  csrci mstatus, MSTATUS_MIE
  li   t0, CAUSE_MACHINE_ECALL; bne s8, t0, fail
  la   t0, 1b; bne s9, t0, fail
  li   t0, MIE_MPIE_MASK; and t1, s6, t0
  li   t0, MSTATUS_MPIE; bne t1, t0, fail        # exception entry: MIE = 0, MPIE = 1
  la   a0, irq_log
  lw   t0, irq_log_idx
  li   t1, 8; bne t0, t1, fail
  lw   t0, 0(a0); li t1, 0x80000003; bne t0, t1, fail
  lw   t0, 4(a0); la t1, 2b; bne t0, t1, fail    # taken on the nop after mret
  RESUME_RANDOM

  # --- 5: masked source: pending in mip, not taken --------------------------------
  li   TESTNUM, 5
  la   t0, irq_handled; lw a5, 0(t0)
  csrci mstatus, MSTATUS_MIE
  PAUSE_RANDOM
  li   t0, IRQ_ALL_MASK
  csrc mie, t0                                   # all masked
  FORCE(MIP_MEIP)
  csrsi mstatus, MSTATUS_MIE
  nop
  nop
  csrr a0, mip
  li   t0, MIP_MEIP; and a0, a0, t0
  beqz a0, fail                                  # visible in mip
  la   t0, irq_handled; lw a6, 0(t0)
  bne  a5, a6, fail                              # but not taken
  li   t0, IRQ_ALL_MASK
  csrs mie, t0                                   # unmask: now taken
  nop
  la   t0, irq_handled; lw a6, 0(t0)
  beq  a5, a6, fail
  RESUME_RANDOM

  # --- 6: MIE toggle loop ------------------------------------------------------------
  li   TESTNUM, 6
  la   t0, irq_handled; lw a5, 0(t0)
  csrci mstatus, MSTATUS_MIE
  li   a4, 64
  nop
loop:
  andi t0, a4, 3
  bnez t0, 1f
  FORCE(MIP_MSIP)                                # every 4th iteration, MIE = 0
  nop
1:csrsi mstatus, MSTATUS_MIE
  nop                                            # the only instruction that can take one
  csrci mstatus, MSTATUS_MIE
  nop                                            # MIE = 0: never taken here
  csrsi mstatus, MSTATUS_MIE
  csrci mstatus, MSTATUS_MIE                     # back to back: deferred, never taken
  nop
  addi a4, a4, -1
  bnez a4, loop
  lw   t0, irq_bad
  bnez t0, fail                                  # handler saw a bad mepc or cause
  la   t0, irq_handled; lw a6, 0(t0)
  sub  a6, a6, a5
  sltiu a6, a6, 16
  bnez a6, fail                                  # at least the 16 forced ones
  csrsi mstatus, MSTATUS_MIE

  # --- 7: WFI is a NOP -------------------------------------------------------------------
  TEST_CASE(7, a0, 2, li a0, 1; wfi; addi a0, a0, 1)

  li   TESTNUM, 8
  lw   t0, irq_bad
  bnez t0, fail

  TEST_PASSFAIL

  # --- Trap handler ---------------------------------------------------------------------
  .align 2
trap_handler:
  csrr t5, mcause
  bltz t5, irq_entry
  j    exc_entry

irq_entry:
  csrw mscratch, a0
  la   t6, save_area
  sw   a1, 0(t6)
  sw   a2, 4(t6)
  sw   a3, 8(t6)
  # log {mcause, mepc}
  la   a0, irq_log_idx
  lw   a1, 0(a0)
  li   a2, LOG_MAX*8
  bgeu a1, a2, 1f
  la   a2, irq_log
  add  a2, a2, a1
  csrr a3, mcause
  sw   a3, 0(a2)
  csrr a3, mepc
  sw   a3, 4(a2)
  addi a1, a1, 8
  sw   a1, 0(a0)
1:# the cause's line must be high and enabled (it stays high until the ack)
  li   a0, SIMCTRL_IRQ_LINES
  lw   a0, 0(a0)
  csrr a1, mie
  and  a0, a0, a1
  csrr a1, mcause
  andi a1, a1, 0xf
  srl  a0, a0, a1
  andi a0, a0, 1
  beqz a0, 2f
  # never right after an instruction that clears MIE
  csrr a1, mepc
  lw   a1, -4(a1)
  li   a2, CSRCI_MSTATUS_MIE
  bne  a1, a2, 3f
2:la   a0, irq_bad
  li   a1, 1
  sw   a1, 0(a0)
3:la   t6, save_area
  lw   a1, 0(t6)
  lw   a2, 4(t6)
  lw   a3, 8(t6)
  csrr a0, mscratch
  IRQ_ACK_AND_COUNT
  mret

  .align 2
exc_entry:
  DIRECTED_TRAP_HANDLER

RVTEST_CODE_END

  .data
RVTEST_DATA_BEGIN

  TEST_DATA
  IRQ_DATA

  .align 2
irq_bad:     .word 0
irq_log_idx: .word 0
save_area:   .word 0, 0, 0
irq_log:     .fill LOG_MAX*2, 4, 0

RVTEST_DATA_END
