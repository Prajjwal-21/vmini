# =============================================================================
# tr_misaligned.S - misaligned load/store traps (docs/architecture.md P2.5)
# -----------------------------------------------------------------------------
# Every misaligned lw/lh/lhu/sw/sh offset traps with mcause 4 (load) or 6
# (store), mepc = its pc and mtval = the effective address, and is followed by
# a younger load and a younger store. The trap handler resumes past both, so:
#   * rd of the trapping load and of the younger load are unchanged;
#   * the trapping store and the younger store never reach memory (their
#     targets are re-read). The issue rule (4.6) keeps the younger store in EX
#     while the trapping instruction is in MEM; a_no_unsafe_issue checks it.
# A last case resumes at mepc + 4 and checks the next instruction executes.
#
# Stock environment + sw/common/irq_handler.h, interrupts enabled. Registers
# t5/t6 and s5-s11 belong to the trap handler.
# =============================================================================
#include "riscv_test.h"
#include "test_macros.h"
#include "irq_handler.h"

# Common part: the trapping instruction at 1:, a younger load and store, and
# the resume point 2: after them.
#define MA_CASE(n, trapping, cause, off)                                \
  li   TESTNUM, n;                                                      \
  la   a1, tdat;                                                        \
  li   a0, 0x5a5a;                                                      \
  li   a2, 0x6666;                                                      \
  li   a3, 0x77777777;                                                  \
  la   s11, 2f;                                                         \
1:trapping;                                                             \
  lw   a2, 0(a1);                     /* younger load  */               \
  sw   a3, 16(a1);                    /* younger store */               \
2:bnez s11, fail;                                                       \
  li   t0, cause; bne s8, t0, fail;                                     \
  la   t0, 1b; bne s9, t0, fail;                                        \
  addi t0, a1, off; bne s10, t0, fail;                                  \
  li   t0, 0x6666; bne a2, t0, fail;                                    \
  lw   t0, 16(a1); bnez t0, fail;

#define MA_LOAD(n, inst, off)                                           \
  MA_CASE(n, inst a0 COMMA off(a1), CAUSE_MISALIGNED_LOAD, off)         \
  li   t0, 0x5a5a; bne a0, t0, fail;

#define MA_STORE(n, inst, off)                                          \
  MA_CASE(n, inst a3 COMMA off(a1), CAUSE_MISALIGNED_STORE, off)        \
  lw   t0, 0(a1); li t1, 0x11223344; bne t0, t1, fail;                  \
  lw   t0, 4(a1); li t1, 0x55667788; bne t0, t1, fail;

#define COMMA ,

RVTEST_RV32M
RVTEST_CODE_BEGIN

  DIRECTED_TRAP_INSTALL(trap_handler)
  IRQ_ENABLE_ALL

  MA_LOAD ( 2, lw,  1)
  MA_LOAD ( 3, lw,  2)
  MA_LOAD ( 4, lw,  3)
  MA_LOAD ( 5, lh,  1)
  MA_LOAD ( 6, lh,  3)
  MA_LOAD ( 7, lhu, 1)
  MA_LOAD ( 8, lhu, 3)
  MA_STORE( 9, sw,  1)
  MA_STORE(10, sw,  2)
  MA_STORE(11, sw,  3)
  MA_STORE(12, sh,  1)
  MA_STORE(13, sh,  3)

  # Aligned halfword/byte accesses at the same offsets do not trap
  TEST_CASE(14, a0, 0x1122,     la a1, tdat; lhu a0, 2(a1) )
  TEST_CASE(15, a0, 0x11,       la a1, tdat; lbu a0, 3(a1) )

  # Resume at mepc + 4: the instruction after the trapping load executes, and
  # a dependent consumer of the trapping load sees the old value.
  li   TESTNUM, 16
  la   a1, tdat
  li   a0, 7
  li   a4, 0
  li   s11, 1
  lw   a0, 1(a1)
  addi a4, a0, 1                     # executes after the handler: a0 is still 7
  bnez s11, fail
  li   t0, 8
  bne  a4, t0, fail

  # One exception per case above
  li   TESTNUM, 17
  li   t0, 13
  bne  s7, t0, fail

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
tdat: .word 0x11223344, 0x55667788, 0, 0, 0

RVTEST_DATA_END
