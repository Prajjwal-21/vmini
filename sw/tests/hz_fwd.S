# =============================================================================
# hz_fwd.S - directed forwarding tests (docs/architecture.md 4.1)
# -----------------------------------------------------------------------------
# EX/MEM -> EX and MEM/WB -> EX on rs1, rs2 and both; newest-producer priority;
# the WB -> ID register-file bypass; x0 is never forwarded; forwarding into
# store data and store addresses.
#
# Built with the CSR-free environment (sw/common/test_env_nocsr). Pass/fail is
# reported through tohost. Registers x3 (TESTNUM) and x7 (TEST_CASE scratch)
# are reserved by the macros.
#
# Minimum event counts below are the deliberate cases in this file (the
# TEST_CASE checks add more); run_riscv_tests.py enforces them in ideal mode.
# HAZARD-EXPECT: fwd_exmem>=16 fwd_memwb>=6 wb_bypass>=5
# =============================================================================
#include "riscv_test.h"
#include "test_macros.h"

RVTEST_RV32U
RVTEST_CODE_BEGIN

  # --- EX/MEM -> EX ----------------------------------------------------------
  TEST_CASE( 2, x2, 8,          li x1, 5; addi x2, x1, 3 )               # rs1
  TEST_CASE( 3, x2, 7,          li x4, 10; li x1, 3; sub x2, x4, x1 )     # rs2 (and rs1 from MEM/WB)
  TEST_CASE( 4, x2, 12,         li x1, 6; add x2, x1, x1 )                # both operands
  TEST_CASE( 5, x1, 8,          li x1, 1; add x1, x1, x1; add x1, x1, x1; add x1, x1, x1 )  # chain
  TEST_CASE( 6, x2, 0x12345678, lui x1, 0x12345; addi x2, x1, 0x678 )     # LUI result

  # --- MEM/WB -> EX ----------------------------------------------------------
  TEST_CASE( 7, x2, 10,         li x1, 9; nop; addi x2, x1, 1 )           # rs1
  TEST_CASE( 8, x2, 16,         li x5, 20; li x1, 4; nop; sub x2, x5, x1 )# rs2 (rs1 via WB->ID)

  # --- Newest producer wins --------------------------------------------------
  TEST_CASE( 9, x2, 2,          li x1, 1; li x1, 2; addi x2, x1, 0 )      # EX/MEM over MEM/WB
  TEST_CASE(10, x2, 3,          li x1, 1; li x1, 3; nop; addi x2, x1, 0 ) # MEM/WB over WB->ID
  TEST_CASE(11, x2, 7,          li x1, 1; nop; nop; nop; li x1, 7; nop; nop; addi x2, x1, 0 )  # WB->ID over regfile

  # --- WB -> ID bypass (distance 3) ------------------------------------------
  TEST_CASE(12, x2, 11,         li x1, 11; nop; nop; addi x2, x1, 0 )
  TEST_CASE(13, x2, 13,         li x1, 6; li x4, 7; nop; nop; add x2, x1, x4 )  # x4 bypass, x1 regfile

  # --- x0 is never forwarded or bypassed -------------------------------------
  TEST_CASE(14, x2, 0,          li x1, 1; addi x0, x1, 5; add x2, x0, x0 )
  TEST_CASE(15, x2, 0,          li x1, 1; addi x0, x1, 5; nop; add x2, x0, x0 )
  TEST_CASE(16, x2, 0,          li x1, 1; addi x0, x1, 5; nop; nop; add x2, x0, x0 )

  # --- Store data and store address forwarding -------------------------------
  TEST_CASE(17, x2, 0x55,       la x6, tdat; li x1, 0x55; sw x1, 0(x6); lw x2, 0(x6) )        # data EX/MEM
  TEST_CASE(18, x2, 0x66,       la x6, tdat; li x1, 0x66; nop; sw x1, 4(x6); lw x2, 4(x6) )   # data MEM/WB
  TEST_CASE(19, x2, 0x77,       li x1, 0x77; la x6, tdat; sw x1, 8(x6); lw x2, 8(x6) )        # address EX/MEM
  TEST_CASE(20, x2, 0xffffffab, la x6, tdat; li x1, 0xab; sb x1, 12(x6); lb x2, 12(x6) )      # byte store
  TEST_CASE(21, x2, 0xbeef,     la x6, tdat; li x1, 0xbeef; sh x1, 14(x6); lhu x2, 14(x6) )   # halfword store

  TEST_PASSFAIL

RVTEST_CODE_END

  .data
RVTEST_DATA_BEGIN

  TEST_DATA

tdat: .word 0, 0, 0, 0, 0

RVTEST_DATA_END
