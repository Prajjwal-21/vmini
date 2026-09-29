# =============================================================================
# hz_load_use.S - directed load-use tests (docs/architecture.md 4.2)
# -----------------------------------------------------------------------------
# A load followed immediately by a consumer must stall exactly one cycle and
# then forward from MEM/WB. Consumers: rs1, rs2, both, store data, load and
# store address, branch operands, the JALR base, subword loads. Also: distance
# 2 (no stall), a load into x0 (no stall), back-to-back loads.
#
# Built with the CSR-free environment. x3 (TESTNUM) and x7 are reserved.
# HAZARD-EXPECT: load_use>=15
# =============================================================================
#include "riscv_test.h"
#include "test_macros.h"

RVTEST_RV32U
RVTEST_CODE_BEGIN

  la x6, tdat
  la x8, ptr

  # --- Consumer immediately after the load (1-cycle stall each) -------------
  TEST_CASE( 2, x2, 0x12, lw x1, 0(x6); addi x2, x1, 1 )                    # rs1
  TEST_CASE( 3, x2, 0xde, li x5, 0x100; lw x1, 4(x6); sub x2, x5, x1 )       # rs2
  TEST_CASE( 4, x2, 0x22, lw x1, 0(x6); add x2, x1, x1 )                    # both
  TEST_CASE( 5, x2, 0x11, lw x1, 0(x6); sw x1, 12(x6); lw x2, 12(x6) )      # store data
  TEST_CASE( 6, x2, 0x11, lw x1, 0(x8); lw x2, 0(x1) )                      # load address
  TEST_CASE( 7, x2, 0x22, li x9, 0x22; lw x1, 0(x8); sw x9, 12(x1); lw x2, 12(x6) )  # store address

  # --- Branch operands --------------------------------------------------------
  li TESTNUM, 8
  li x5, 0x11
  lw x1, 0(x6)
  bne x1, x5, fail                   # not taken
  li TESTNUM, 9
  lw x1, 0(x6)
  beq x1, x5, 1f                     # taken
  j fail
1:
  li TESTNUM, 10
  lw x1, 4(x6)
  blt x1, x5, fail                   # 0x22 < 0x11: not taken

  # --- JALR base from a load --------------------------------------------------
  li TESTNUM, 11
  la x9, jptr
  lw x1, 0(x9)
  jalr x10, 0(x1)
  j fail
jtarget:

  # --- No stall ---------------------------------------------------------------
  TEST_CASE(12, x2, 0x12, lw x1, 0(x6); nop; addi x2, x1, 1 )               # distance 2
  TEST_CASE(13, x2, 1,    lw x0, 0(x6); addi x2, x0, 1 )                    # load into x0

  # --- Subword loads with sign/zero extension --------------------------------
  TEST_CASE(14, x2, 0xffffffff, lb  x1, 8(x6); addi x2, x1, 0 )
  TEST_CASE(15, x2, 0xff,       lbu x1, 8(x6); addi x2, x1, 0 )
  TEST_CASE(16, x2, 0xffffffff, lh  x1, 8(x6); addi x2, x1, 0 )
  TEST_CASE(17, x2, 0xffff,     lhu x1, 8(x6); addi x2, x1, 0 )

  # --- Back-to-back loads: second one consumed immediately --------------------
  TEST_CASE(18, x4, 0x33, lw x1, 0(x6); lw x2, 4(x6); add x4, x1, x2 )

  TEST_PASSFAIL

RVTEST_CODE_END

  .data
RVTEST_DATA_BEGIN

  TEST_DATA

tdat: .word 0x11, 0x22, 0xffffffff, 0
ptr:  .word tdat
jptr: .word jtarget

RVTEST_DATA_END
