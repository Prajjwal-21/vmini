# =============================================================================
# csr_ops.S - CSR instruction semantics (docs/architecture.md P2.2-P2.6)
# -----------------------------------------------------------------------------
# CSRRW/S/C and the immediate forms; no write for rs1 = x0 / uimm = 0 (except
# CSRRW/CSRRWI); back-to-back CSR read-after-write and a CSR result used by the
# next instruction (the commit-and-refetch path, P2.3); WARL fields (misa,
# mstatus.MPP, mtvec.MODE, mie, mip, mstatush, trigger stubs, ID registers);
# mepc/mcause/mtval field widths; mcycle/minstret write semantics (P2.6).
#
# Stock environment + sw/common/irq_handler.h. Interrupts are enabled; the
# checks whose result an interrupt handler could change (mepc/mcause/mtval,
# exact instruction counts) run with mstatus.MIE = 0. Registers t5/t6 and
# s5-s11 belong to the trap handler (irq_handler.h).
# =============================================================================
#include "riscv_test.h"
#include "test_macros.h"
#include "irq_handler.h"

#define MIE_OFF csrci mstatus, MSTATUS_MIE
#define MIE_ON  csrsi mstatus, MSTATUS_MIE

RVTEST_RV32M
RVTEST_CODE_BEGIN

  DIRECTED_TRAP_INSTALL(trap_handler)
  IRQ_ENABLE_ALL

  # --- mscratch with every instruction form ----------------------------------
  TEST_CASE( 2, a1, 0x12345678, li a0, 0x12345678; csrw mscratch, a0; csrr a1, mscratch )
  TEST_CASE( 3, a1, 0x12345678, li a0, 0xf0; csrrw a1, mscratch, a0 )          # returns old
  TEST_CASE( 4, a2, 0xff,       li a0, 0x0f; csrrs a1, mscratch, a0; csrr a2, mscratch )
  TEST_CASE( 5, a1, 0xff,       li a0, 0x3c; csrrc a1, mscratch, a0 )          # returns old
  TEST_CASE( 6, a1, 0xc3,       csrr a1, mscratch )
  TEST_CASE( 7, a1, 0xc3,       csrrwi a1, mscratch, 0x15 )
  TEST_CASE( 8, a2, 0x1f,       csrrsi a1, mscratch, 0x0a; csrr a2, mscratch )
  TEST_CASE( 9, a2, 0x1c,       csrrci a1, mscratch, 0x03; csrr a2, mscratch )
  # rs1 = x0 / uimm = 0: CSRRS/CSRRC/CSRRSI/CSRRCI read without writing
  TEST_CASE(10, a2, 0x1c,       csrrs a1, mscratch, x0; csrrc a1, mscratch, x0; \
                                csrrsi a1, mscratch, 0; csrrci a1, mscratch, 0; csrr a2, mscratch )
  # CSRRW writes even with rd = x0
  TEST_CASE(11, a1, 0x77,       li a0, 0x77; csrrw x0, mscratch, a0; csrr a1, mscratch )

  # --- Read-after-write and CSR results used immediately ---------------------
  TEST_CASE(12, a1, 6,          csrwi mscratch, 5; csrr a0, mscratch; addi a1, a0, 1 )
  TEST_CASE(13, a4, 0x200,      li a0, 0x100; csrw mscratch, a0; csrrs a1, mscratch, a0; \
                                csrrc a2, mscratch, a0; csrr a3, mscratch; \
                                add a4, a1, a2; add a4, a4, a3 )
  TEST_CASE(14, a1, 0x1ce,      li a0, 0xe7; csrw mscratch, a0; csrr a0, mscratch; add a1, a0, a0 )
  # CSR operand straight from a load (load-use into a CSR instruction)
  TEST_CASE(15, a1, 0xcafef00d, la a4, tdat; lw a0, 0(a4); csrw mscratch, a0; csrr a1, mscratch )

  # --- WARL fields -------------------------------------------------------------
  # mtvec: MODE is read-only 0 (direct only). mtvec keeps pointing at the
  # handler throughout, so an interrupt in between is harmless.
  TEST_CASE(16, a1, 0,          la a0, trap_handler; addi a0, a0, 3; csrw mtvec, a0; \
                                csrr a1, mtvec; la a0, trap_handler; sub a1, a1, a0 )
  TEST_CASE(17, a1, 0x888,      li a0, -1; csrw mie, a0; csrr a1, mie )
  TEST_CASE(18, a1, 0,          csrwi mie, 0; csrr a1, mie; li a0, IRQ_ALL_MASK; csrw mie, a0 )
  TEST_CASE(19, a1, 0x40000100, csrr a1, misa )
  TEST_CASE(20, a1, 0x40000100, li a0, -1; csrw misa, a0; csrr a1, misa )
  # mstatus: only MIE and MPIE are writable; MPP reads 11 (M). An interrupt
  # between the write and the read leaves MIE = MPIE = 1 again after mret.
  TEST_CASE(21, a1, 0x1888,     li a0, -1; csrw mstatus, a0; csrr a1, mstatus )
  TEST_CASE(22, a1, 0x1800,     li a0, MSTATUS_MPP; csrc mstatus, a0; csrr a1, mstatus; and a1, a1, a0 )
  TEST_CASE(23, a1, 0x1800,     csrwi mstatus, 0; csrr a1, mstatus; MIE_ON )
  TEST_CASE(24, a1, 0,          li a0, -1; csrw mstatush, a0; csrr a1, mstatush )
  # mip: writes ignored; only MEIP/MTIP/MSIP can read 1
  TEST_CASE(25, a1, 0,          li a0, -1; csrw mip, a0; csrr a1, mip; li a0, ~IRQ_ALL_MASK; and a1, a1, a0 )
  # Sdtrig "no triggers" stubs (D-025)
  TEST_CASE(26, a1, 0,          li a0, -1; csrw tselect, a0; csrw tdata1, a0; csrw tdata2, a0; \
                                csrr a1, tselect; csrr a2, tdata1; csrr a3, tdata2; or a1, a1, a2; or a1, a1, a3 )
  TEST_CASE(27, a1, 0,          csrr a1, mvendorid; csrr a2, marchid; csrr a3, mimpid; csrr a4, mhartid; \
                                or a1, a1, a2; or a1, a1, a3; or a1, a1, a4 )

  # --- mepc / mcause / mtval (with MIE = 0: trap entry would overwrite them) ---
  TEST_CASE(28, a1, 0x80001234, MIE_OFF; li a0, 0x80001237; csrw mepc, a0; csrr a1, mepc; MIE_ON )
  TEST_CASE(29, a1, 0x8000000f, MIE_OFF; li a0, -1; csrw mcause, a0; csrr a1, mcause; MIE_ON )
  TEST_CASE(30, a1, 0x8000000b, MIE_OFF; li a0, 0x8000000b; csrw mcause, a0; csrr a1, mcause; MIE_ON )
  TEST_CASE(31, a1, 0xdeadbeef, MIE_OFF; li a0, 0xdeadbeef; csrw mtval, a0; csrr a1, mtval; MIE_ON )

  # --- Counters (P2.6), with MIE = 0 so no handler instruction retires --------
  # A write suppresses the writing instruction's own increment.
  TEST_CASE(32, a1, 0,          MIE_OFF; csrwi minstret, 0; csrr a1, minstret; MIE_ON )
  TEST_CASE(33, a1, 3,          MIE_OFF; csrwi minstret, 0; nop; nop; nop; csrr a1, minstret; MIE_ON )
  # instret aliases minstret; the reading csrr retires between the two reads
  TEST_CASE(34, a1, 1,          MIE_OFF; csrr a0, instret; csrr a1, minstret; sub a1, a1, a0; MIE_ON )
  # 64-bit wrap: all-ones in both halves, one retirement -> 0
  TEST_CASE(35, a1, 0,          MIE_OFF; li a0, -1; csrw minstret, a0; csrw minstreth, a0; nop; \
                                csrr a1, minstreth; MIE_ON )
  TEST_CASE(36, a1, 0,          MIE_OFF; li a0, -1; csrw minstret, a0; csrw minstreth, a0; nop; \
                                csrr a1, minstret; MIE_ON )
  TEST_CASE(37, a1, 0,          csrr a0, instreth; csrr a1, minstreth; sub a1, a1, a0 )
  # mcycleh written after mcycle = 0: the low half cannot carry in between
  TEST_CASE(38, a1, 0x55,       MIE_OFF; csrwi mcycle, 0; li a0, 0x55; csrw mcycleh, a0; \
                                csrr a1, mcycleh; MIE_ON )
  TEST_CASE(39, a1, 0,          csrr a0, cycleh; csrr a1, mcycleh; sub a1, a1, a0 )
  # mcycle restarts from the written value: 0 < mcycle < 1000 shortly after
  TEST_CASE(40, a2, 1,          MIE_OFF; csrwi mcycle, 0; csrr a1, mcycle; MIE_ON; \
                                sltiu a2, a1, 1000; snez a3, a1; and a2, a2, a3 )
  # mcycle counts up; cycle aliases it
  TEST_CASE(41, a2, 1,          csrr a0, mcycle; csrr a1, cycle; sltu a2, a0, a1 )

  TEST_PASSFAIL

  .align 2
trap_handler:
  DIRECTED_TRAP_HANDLER

RVTEST_CODE_END

  .data
RVTEST_DATA_BEGIN

  TEST_DATA
  IRQ_DATA

tdat: .word 0xcafef00d

RVTEST_DATA_END
