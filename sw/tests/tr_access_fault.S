# =============================================================================
# tr_access_fault.S - load/store access faults (docs/architecture.md P2.5, 4.6)
# -----------------------------------------------------------------------------
# Loads and stores to unmapped addresses get a D-port response with err
# (mem_model), which traps with mcause 5 (load) or 7 (store), mepc = its pc and
# mtval = the effective address. Each is followed by younger stores (and a
# consumer of the faulting load) that must never execute: the trap handler
# resumes past them, and their target memory is re-read. While the faulting
# instruction waits in MEM for its response (1..6 cycles in random-latency
# runs), the issue rule holds the younger store in EX; a_no_unsafe_issue
# checks that it never reaches the D-port.
#
# Addresses: inside the gap below main memory, address 0, the last word before
# main memory, the first word after it, and sub-word accesses.
#
# Stock environment + sw/common/irq_handler.h, interrupts enabled. Registers
# t5/t6 and s5-s11 belong to the trap handler.
# =============================================================================
#include "riscv_test.h"
#include "test_macros.h"
#include "irq_handler.h"

#define COMMA ,

#define AF_CASE(n, trapping, cause, addr)                               \
  li   TESTNUM, n;                                                      \
  li   a1, addr;                                                        \
  la   a2, tdat;                                                        \
  li   a0, 0x5a5a;                                                      \
  li   a3, 0x77777777;                                                  \
  li   a5, 0x6666;                                                      \
  la   s11, 2f;                                                         \
1:trapping;                                                             \
  addi a5, a0, 1;                     /* consumer of a faulting load */ \
  sw   a3, 0(a2);                     /* younger stores */              \
  sw   a3, 4(a2);                                                       \
2:bnez s11, fail;                                                       \
  li   t0, cause; bne s8, t0, fail;                                     \
  la   t0, 1b; bne s9, t0, fail;                                        \
  bne  s10, a1, fail;                                                   \
  li   t0, 0x5a5a; bne a0, t0, fail;                                    \
  li   t0, 0x6666; bne a5, t0, fail;                                    \
  lw   t0, 0(a2); bnez t0, fail;                                        \
  lw   t0, 4(a2); bnez t0, fail;

#define AF_LOAD(n, inst, addr)  AF_CASE(n, inst a0 COMMA 0(a1), CAUSE_LOAD_ACCESS, addr)
#define AF_STORE(n, inst, addr) AF_CASE(n, inst a3 COMMA 0(a1), CAUSE_STORE_ACCESS, addr)

RVTEST_RV32M
RVTEST_CODE_BEGIN

  DIRECTED_TRAP_INSTALL(trap_handler)
  IRQ_ENABLE_ALL

  AF_LOAD ( 2, lw,  0x70000000)
  AF_LOAD ( 3, lw,  0x00000000)
  AF_LOAD ( 4, lw,  0x7ffffffc)      # last word before main memory
  AF_LOAD ( 5, lw,  0x80010000)      # first word after main memory (64 KB)
  AF_LOAD ( 6, lbu, 0x70000003)
  AF_LOAD ( 7, lh,  0x70000002)
  AF_STORE( 8, sw,  0x70000000)
  AF_STORE( 9, sw,  0x80010000)
  AF_STORE(10, sb,  0x70000001)
  AF_STORE(11, sh,  0x0000fffe)

  # Two faulting loads back to back: the second never issues (the handler
  # resumes past it), and the first reports its own address.
  li   TESTNUM, 12
  li   a1, 0x70000000
  li   a4, 0x70000100
  la   s11, 2f
1:lw   a0, 0(a1)
  lw   a0, 0(a4)
2:bnez s11, fail
  la   t0, 1b
  bne  s9, t0, fail
  bne  s10, a1, fail

  # One exception per case above
  li   TESTNUM, 13
  li   t0, 11
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
tdat: .word 0, 0, 0, 0

RVTEST_DATA_END
