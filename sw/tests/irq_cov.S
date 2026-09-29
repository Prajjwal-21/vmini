# =============================================================================
# irq_cov.S - deterministic interrupt-coverage scenarios (architecture.md P2.13)
# -----------------------------------------------------------------------------
# Every scenario uses the same construct:
#
#   csrci mstatus, MIE        MIE = 0: nothing can be taken from here on
#   sw    MSIP, IRQ_FORCE     the line is high from the cycle after acceptance
#   csrsi mstatus, MIE        serializing: no interrupt on it (its pre-state has
#                             MIE = 0); it flushes and refetches from S1
#   S1                        the FIRST instruction to commit with MIE = 1 and
#   S2                        a line pending, whatever the memory latencies
#
# Why the counts below are guaranteed (the events are defined in P2.13):
#
# irq_ldst >= 4 (any memory): in C1, S1 is a load or store with no exception,
#   so it commits carrying the interrupt. The interrupt cannot be deferred by
#   D-033: EX can only assert a request while S1 is safe in MEM, i.e. from the
#   cycle S1's response is present, which is the cycle S1 commits; so no
#   request is held unaccepted in that cycle. 4 scenarios.
# irq_ex_memop >= 4 (ideal memory): in C1, S2 is a load or store. After the
#   MEM redirect of csrsi in cycle c, S1 is requested in c, delivered in c+1,
#   in ID in c+2, EX in c+3, MEM in c+4; S2 is requested in c+1 and is in EX in
#   c+4, when S1 commits: its request is blocked by kill_ex. With random
#   latency S2 may not have arrived yet, so no floor there.
# irq_redirect >= 4 (ideal memory): in C2, S1 is an addi and S2 a taken branch
#   or jump; by the same timing S2 is in EX, redirecting, when S1 commits.
# irq_defer_csr >= 2, irq_defer_fencei >= 2, irq_defer_mret >= 2 (any
#   memory): in C3/C4/C5, S1 is a CSR instruction / FENCE.I / MRET. It commits
#   with MIE = 1 and a line pending, and is serializing, so the interrupt is
#   deferred (to the next instruction). 2 scenarios each.
# exc_irq >= 5 (any memory): in C6, S1 raises an exception (ECALL, EBREAK,
#   illegal, misaligned load, load access fault) while the line is pending;
#   the exception wins. 5 scenarios.
#
# A random interrupt that happens to be pending as well only changes which
# cause is taken, not the event. After each scenario the test checks that an
# interrupt was handled (irq_handled increased); after C3's csrci it checks
# that none was (MIE cleared by a serializing instruction).
#
# IRQ-EXPECT(any): irq_ldst>=4 irq_defer_csr>=2 irq_defer_fencei>=2 irq_defer_mret>=2 exc_irq>=5
# IRQ-EXPECT(ideal): irq_ex_memop>=4 irq_redirect>=4
#
# Stock environment + sw/common/irq_handler.h. Registers t5/t6 and s5-s11
# belong to the trap handler.
# =============================================================================
#include "riscv_test.h"
#include "test_macros.h"
#include "irq_handler.h"

#define ARM_MSIP                                                        \
  csrci mstatus, MSTATUS_MIE;                                           \
  li   t0, SIMCTRL_IRQ_FORCE;                                           \
  li   t1, MIP_MSIP;                                                    \
  sw   t1, 0(t0);

#define IRQ_COUNT(reg)  la t0, irq_handled; lw reg, 0(t0);
#define EXPECT_TAKEN    IRQ_COUNT(a6); beq a6, a5, fail;
#define EXPECT_NONE     IRQ_COUNT(a6); bne a6, a5, fail;

# C1: S1 = load/store (E2), S2 = load/store in EX (E1, ideal memory)
#define C1(n, s1, s2)                                                   \
  li   TESTNUM, n;                                                      \
  IRQ_COUNT(a5)                                                         \
  ARM_MSIP                                                              \
  csrsi mstatus, MSTATUS_MIE;                                           \
  s1;                                                                   \
  s2;                                                                   \
  EXPECT_TAKEN

# C2: S1 = addi, S2 = taken branch/jump to 1: (E3, ideal memory)
#define C2(n, s2)                                                       \
  li   TESTNUM, n;                                                      \
  IRQ_COUNT(a5)                                                         \
  ARM_MSIP                                                              \
  csrsi mstatus, MSTATUS_MIE;                                           \
  addi a0, a0, 1;                                                       \
  s2;                                                                   \
  j    fail;                                                            \
1:EXPECT_TAKEN

# C3/C4: S1 = serializing instruction (E4), S2 = nop takes the interrupt
#define C_SERIAL(n, s1)                                                 \
  li   TESTNUM, n;                                                      \
  IRQ_COUNT(a5)                                                         \
  ARM_MSIP                                                              \
  csrsi mstatus, MSTATUS_MIE;                                           \
  s1;                                                                   \
  nop;                                                                  \
  EXPECT_TAKEN

# C6: S1 raises an exception with the line pending (E5); the handler resumes
# at S1 + 4, mret restores MIE = 1 and the nop there takes the interrupt.
#define C6(n, s1, cause)                                                \
  li   TESTNUM, n;                                                      \
  IRQ_COUNT(a5)                                                         \
  ARM_MSIP                                                              \
  li   s11, 1;                                                          \
  csrsi mstatus, MSTATUS_MIE;                                           \
  s1;                                                                   \
  nop;                                                                  \
  EXPECT_TAKEN                                                          \
  bnez s11, fail;                                                       \
  li   t0, cause; bne s8, t0, fail;

#define COMMA ,

RVTEST_RV32M
RVTEST_CODE_BEGIN

  .option norvc
  DIRECTED_TRAP_INSTALL(trap_handler)
  IRQ_ENABLE_ALL
  la   s0, tdat
  li   a0, 1
  la   a4, 3f                        # jalr target for C2
  li   a7, 0x70000000                # unmapped, for the access fault

  # --- C1: interrupt on a load/store, next load/store in EX ----------------
  C1( 2, lw  a0 COMMA 0(s0), sw  a1 COMMA 4(s0))
  C1( 3, lbu a0 COMMA 1(s0), lw  a1 COMMA 0(s0))
  C1( 4, sh  a1 COMMA 8(s0), lw  a2 COMMA 0(s0))
  C1( 5, sw  a1 COMMA 12(s0), sb a2 COMMA 13(s0))

  # --- C2: interrupt in the cycle EX redirects -------------------------------
  C2( 6, beq  a0 COMMA a0 COMMA 1f)
  C2( 7, bne  a0 COMMA zero COMMA 1f)
  C2( 8, jal  zero COMMA 1f)
  li   TESTNUM, 9                    # jalr: its target label 3 is fixed above
  IRQ_COUNT(a5)
  ARM_MSIP
  csrsi mstatus, MSTATUS_MIE
  addi a0, a0, 1
  jalr zero, 0(a4)
  j    fail
3:EXPECT_TAKEN

  # --- C3: deferred by a CSR instruction ------------------------------------------
  C_SERIAL(10, csrr a1 COMMA mscratch)
  # csrci clearing MIE is deferred too, and then nothing is taken at all
  li   TESTNUM, 11
  IRQ_COUNT(a5)
  ARM_MSIP
  csrsi mstatus, MSTATUS_MIE
  csrci mstatus, MSTATUS_MIE
  nop
  EXPECT_NONE
  csrsi mstatus, MSTATUS_MIE
  nop
  EXPECT_TAKEN

  # --- C4: deferred by FENCE.I ---------------------------------------------------------
  C_SERIAL(12, fence.i)
  C_SERIAL(13, fence.i)

  # --- C5: deferred by MRET (mepc and MPIE set while MIE = 0) ---------------------
  li   TESTNUM, 14
  IRQ_COUNT(a5)
  ARM_MSIP
  la   t0, 1f
  csrw mepc, t0
  li   t0, MSTATUS_MPIE
  csrs mstatus, t0
  csrsi mstatus, MSTATUS_MIE
  mret
1:nop
  EXPECT_TAKEN

  li   TESTNUM, 15
  IRQ_COUNT(a5)
  ARM_MSIP
  la   t0, 1f
  csrw mepc, t0
  li   t0, MSTATUS_MPIE
  csrs mstatus, t0
  csrsi mstatus, MSTATUS_MIE
  mret
1:nop
  EXPECT_TAKEN

  # --- C6: exception with an interrupt pending -------------------------------------
  C6(16, ecall,                CAUSE_MACHINE_ECALL)
  C6(17, ebreak,               CAUSE_BREAKPOINT)
  C6(18, .word 0,              CAUSE_ILLEGAL_INSTRUCTION)
  C6(19, lw a0 COMMA 1(s0),    CAUSE_MISALIGNED_LOAD)
  C6(20, lw a0 COMMA 0(a7),    CAUSE_LOAD_ACCESS)

  csrsi mstatus, MSTATUS_MIE
  TEST_PASSFAIL

  .align 2
trap_handler:
  DIRECTED_TRAP_HANDLER

RVTEST_CODE_END

  .data
RVTEST_DATA_BEGIN

  TEST_DATA
  IRQ_DATA

  .align 4
tdat: .word 0x11223344, 0x55667788, 0, 0

RVTEST_DATA_END
