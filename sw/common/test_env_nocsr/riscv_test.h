// =============================================================================
// riscv_test.h - CSR-free riscv-tests environment (Phase 1)
// -----------------------------------------------------------------------------
// Drop-in replacement for third_party/riscv-tests/env/p/riscv_test.h, for
// running rv32ui-p-* on a core with no CSRs, no traps and no ECALL/MRET
// (decision D-009). Put this directory on the include path ahead of the
// stock environment; test sources are used unmodified.
//
// Differences from the stock -p environment:
//   * No trap vector and no CSR set-up: execution starts at _start in machine
//     mode and falls straight into the test body.
//   * PASS/FAIL store the result directly to `tohost` instead of executing
//     ECALL and letting the trap handler do it. The encoding is unchanged:
//     1 = pass, (test_number << 1) | 1 = fail. The upper word is written 0,
//     matching the stock environment's RV32 tohost protocol.
//   * RVTEST_CODE_END is a self-loop instead of `unimp` (which is a CSR write).
//
// Build with -march=rv32i_zifencei (no Zicsr) so the assembler rejects any
// CSR instruction. The stock env/p/link.ld is reused unchanged.
// Phase 2 switches back to the stock environment.
// =============================================================================

#ifndef _ENV_NOCSR_RISCV_TEST_H
#define _ENV_NOCSR_RISCV_TEST_H

//-----------------------------------------------------------------------------
// Test-kind selectors: the stock env uses these to define an `init` macro;
// user-level integer tests need no initialisation.
//-----------------------------------------------------------------------------
#define RVTEST_RV32U \
  .macro init;       \
  .endm

#define RVTEST_RV64U RVTEST_RV32U

//-----------------------------------------------------------------------------
// Register usage: gp holds the current test number, as in the stock env.
//-----------------------------------------------------------------------------
#define TESTNUM gp

// Zero every register so results never depend on reset values.
#define INIT_XREG \
  li x1,  0; li x2,  0; li x3,  0; li x4,  0; li x5,  0; li x6,  0; li x7,  0; \
  li x8,  0; li x9,  0; li x10, 0; li x11, 0; li x12, 0; li x13, 0; li x14, 0; \
  li x15, 0; li x16, 0; li x17, 0; li x18, 0; li x19, 0; li x20, 0; li x21, 0; \
  li x22, 0; li x23, 0; li x24, 0; li x25, 0; li x26, 0; li x27, 0; li x28, 0; \
  li x29, 0; li x30, 0; li x31, 0;

//-----------------------------------------------------------------------------
// Begin / end code
//-----------------------------------------------------------------------------
#define RVTEST_CODE_BEGIN \
  .section .text.init;    \
  .align  6;              \
  .globl _start;          \
_start:                   \
  INIT_XREG;              \
  li TESTNUM, 0;          \
  init;

#define RVTEST_CODE_END \
1:                      \
  j 1b

//-----------------------------------------------------------------------------
// Pass / fail: write the result to tohost (t5 is scratch), then spin.
// The testbench stops the simulation when it sees the store to tohost.
//-----------------------------------------------------------------------------
#define RVTEST_WRITE_TOHOST \
  sw TESTNUM, tohost, t5;   \
  sw zero, tohost + 4, t5;  \
1:                          \
  j 1b

#define RVTEST_PASS  \
  fence;             \
  li TESTNUM, 1;     \
  RVTEST_WRITE_TOHOST

#define RVTEST_FAIL          \
  fence;                     \
1:                           \
  beqz TESTNUM, 1b;          \
  sll TESTNUM, TESTNUM, 1;   \
  or TESTNUM, TESTNUM, 1;    \
  RVTEST_WRITE_TOHOST

//-----------------------------------------------------------------------------
// Data section: tohost/fromhost live in their own section, placed by the
// stock env/p/link.ld exactly as in the stock environment.
//-----------------------------------------------------------------------------
#define EXTRA_DATA

#define RVTEST_DATA_BEGIN                                                    \
  EXTRA_DATA                                                                 \
  .pushsection .tohost,"aw",@progbits;                                       \
  .align 6; .global tohost; tohost: .dword 0; .size tohost, 8;               \
  .align 6; .global fromhost; fromhost: .dword 0; .size fromhost, 8;         \
  .popsection;                                                               \
  .align 4; .global begin_signature; begin_signature:

#define RVTEST_DATA_END .align 4; .global end_signature; end_signature:

#endif
