# =============================================================================
# tr_illegal.S - illegal-instruction detection (docs/architecture.md P2.4)
# -----------------------------------------------------------------------------
# Every class of P2.4 traps with mcause = 2, mepc = its pc, mtval = the
# instruction bits (16 bits, zero-extended, for a 16-bit length encoding), and
# does not write rd or memory. Then the legal corner cases must NOT trap:
# reads of the read-only counters and ID CSRs, including the CSRRS/CSRRC with
# rs1 = x0 and CSRRSI/CSRRCI with uimm = 0 forms, WFI, FENCE, FENCE.I, and the
# WARL CSRs. A trap there reaches the stock trap vector and fails the test.
#
# Stock environment + sw/common/irq_handler.h, interrupts enabled. Registers
# t5/t6 and s5-s11 belong to the trap handler.
# =============================================================================
#include "riscv_test.h"
#include "test_macros.h"
#include "irq_handler.h"

# ILLEGAL(n, encoding, expected mtval): the word must trap as illegal; a0 (the
# rd of every encoding that has one) and memory must be unchanged.
#define ILLEGAL(n, enc, tval)                                           \
  li   TESTNUM, n;                                                      \
  li   a0, 0x5a5a;                                                      \
  la   a4, 1f;                                                          \
  li   s11, 1;                                                          \
1:.word enc;                                                            \
  bnez s11, fail;                                                       \
  li   t0, CAUSE_ILLEGAL_INSTRUCTION; bne s8, t0, fail;                 \
  bne  s9, a4, fail;                                                    \
  li   t0, tval; bne s10, t0, fail;                                     \
  li   t0, 0x5a5a; bne a0, t0, fail;

RVTEST_RV32M
RVTEST_CODE_BEGIN

  .option norvc
  DIRECTED_TRAP_INSTALL(trap_handler)
  IRQ_ENABLE_ALL
  la   a1, tdat                     # a valid address for the load/store forms

  # --- Reserved opcodes and 16-bit encodings -----------------------------------
  ILLEGAL( 2, 0x00000000, 0x00000000)   # all zero (also a 16-bit encoding)
  ILLEGAL( 3, 0x00014501, 0x00004501)   # c.li a0,0 + c.nop: 16 bits, no C
  ILLEGAL( 4, 0x0000050b, 0x0000050b)   # custom-0 opcode, rd = a0
  ILLEGAL( 5, 0x0000057f, 0x0000057f)   # >= 80-bit length prefix

  # --- SYSTEM, funct3 = 000: exact encodings only -----------------------------
  ILLEGAL( 6, 0x10200073, 0x10200073)   # sret
  ILLEGAL( 7, 0x00200073, 0x00200073)   # uret
  ILLEGAL( 8, 0x12000073, 0x12000073)   # sfence.vma x0, x0
  ILLEGAL( 9, 0x7b200073, 0x7b200073)   # dret
  ILLEGAL(10, 0x10500573, 0x10500573)   # wfi with rd = a0
  ILLEGAL(11, 0x00050073, 0x00050073)   # ecall with rs1 = a0
  ILLEGAL(12, 0x30200573, 0x30200573)   # mret with rd = a0
  # SYSTEM, funct3 = 100 (reserved)
  ILLEGAL(13, 0x00004573, 0x00004573)

  # --- Reserved funct3 / funct7 --------------------------------------------------
  ILLEGAL(14, 0x02c58533, 0x02c58533)   # mul a0, a1, a2 (no M extension)
  ILLEGAL(15, 0x40c5f533, 0x40c5f533)   # and with funct7 = 0100000
  ILLEGAL(16, 0x00051567, 0x00051567)   # jalr with funct3 = 001
  ILLEGAL(17, 0x0005b503, 0x0005b503)   # ld a0, 0(a1) (RV64 only)
  ILLEGAL(18, 0x00a5b023, 0x00a5b023)   # sd a0, 0(a1) (RV64 only; no store)
  ILLEGAL(19, 0x0000250f, 0x0000250f)   # MISC-MEM funct3 = 010
  ILLEGAL(20, 0x00002063, 0x00002063)   # BRANCH funct3 = 010
  ILLEGAL(21, 0x02051513, 0x02051513)   # slli a0, a0, 32 (shamt[5] = 1)
  ILLEGAL(22, 0x4205d513, 0x4205d513)   # srai with funct7 = 0100001

  # --- Nonexistent CSRs ---------------------------------------------------------
  ILLEGAL(23, 0x18002573, 0x18002573)   # csrr a0, satp
  ILLEGAL(24, 0x7a302573, 0x7a302573)   # csrr a0, tdata3
  ILLEGAL(25, 0x32002573, 0x32002573)   # csrr a0, mcountinhibit
  ILLEGAL(26, 0x7b002573, 0x7b002573)   # csrr a0, dcsr
  ILLEGAL(27, 0xc0102573, 0xc0102573)   # csrr a0, time
  ILLEGAL(28, 0x30202573, 0x30202573)   # csrr a0, medeleg

  # --- Writes to read-only CSRs -------------------------------------------------
  ILLEGAL(29, 0xf1459573, 0xf1459573)   # csrrw  a0, mhartid, a1
  ILLEGAL(30, 0xc0005573, 0xc0005573)   # csrrwi a0, cycle, 0 (CSRRWI always writes)
  ILLEGAL(31, 0xc005a573, 0xc005a573)   # csrrs  a0, cycle, a1 (rs1 != x0)
  ILLEGAL(32, 0xc020f573, 0xc020f573)   # csrrci a0, instret, 1 (uimm != 0)
  ILLEGAL(33, 0xc8016573, 0xc8016573)   # csrrsi a0, cycleh, 2
  ILLEGAL(34, 0xc0001073, 0xc0001073)   # unimp = csrrw x0, cycle, x0

  # Each of the 33 cases above trapped exactly once
  li   TESTNUM, 35
  li   t0, 33
  bne  s7, t0, fail
  # The store forms above left memory alone
  lw   t0, 0(a1)
  li   t1, 0x13579bdf
  bne  t0, t1, fail
  lw   t0, 4(a1)
  bnez t0, fail

  # --- Legal forms: none of these may trap -------------------------------------
  li   TESTNUM, 36
  csrr   a0, cycle
  csrr   a0, cycleh
  csrr   a0, instret
  csrr   a0, instreth
  csrrs  x0, cycle, x0
  csrrc  x0, cycleh, x0
  csrrsi x0, instret, 0
  csrrci x0, instreth, 0
  csrrc  a0, mhartid, x0
  csrr   a0, mvendorid
  csrr   a0, marchid
  csrr   a0, mimpid
  csrr   a0, mhartid
  csrw   mstatush, a0
  csrw   misa, a0
  csrw   mip, a0
  csrr   a0, tselect
  wfi
  fence
  fence rw, rw
  fence.i
  # No exception was taken on the way (an unexpected one fails via the stock
  # trap vector; this also checks none was absorbed as "expected")
  li   t0, 33
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

tdat: .word 0x13579bdf, 0, 0, 0

RVTEST_DATA_END
