// =============================================================================
// irq_handler.h - shared interrupt-handling macros for assembly tests
// -----------------------------------------------------------------------------
// Include after riscv_test.h (it uses encoding.h's MIP_* / MSTATUS_* masks).
// Used by the rv32ui interrupt-hook environment (test_env_irq, D-028) and by
// the directed tests in sw/tests (docs/architecture.md P2.9, P2.10).
//
// IRQ_ACK_AND_COUNT  acknowledge the interrupt in mcause at sim_ctrl and
//                    increment irq_handled. Clobbers t5 and t6 only (the stock
//                    trap vector already clobbers them). Call with MIE = 0,
//                    i.e. from a trap handler, and follow it with mret.
// IRQ_ENABLE_ALL     mie = MEIE|MTIE|MSIE, then mstatus.MIE = 1. Clobbers t0.
// IRQ_DATA           the counter the testbench compares with its own count
//                    (+irq_count, P2.9 check 1).
//
// DIRECTED_TRAP_HANDLER  body of a trap handler for the directed tests (place
//                    it at a 4-byte aligned label and write that label to
//                    mtvec). Register convention, reserved in every directed
//                    test that uses it:
//                      t5, t6  scratch (as in the stock trap vector)
//                      s11     in:  0 = no exception expected; 1 = expected,
//                                   resume at mepc + 4; otherwise = expected,
//                                   resume at the address in s11.
//                              out: 0 once an expected exception is handled.
//                      s5      minstret on entry (its first instruction)
//                      s6      mstatus on entry        } written for expected
//                      s8/s9/s10  mcause/mepc/mtval    } exceptions only
//                      s7      count of expected exceptions handled
//                    Interrupts: acknowledge, count, mret. Exceptions with
//                    s11 = 0, including the ECALL of RVTEST_PASS/RVTEST_FAIL,
//                    go to the stock trap_vector, which reports pass/fail or
//                    fails the test with 1337.
// =============================================================================
#ifndef IRQ_HANDLER_H
#define IRQ_HANDLER_H

#include "simctrl.h"

#define IRQ_ALL_MASK (MIP_MEIP | MIP_MTIP | MIP_MSIP)

#define IRQ_ACK_AND_COUNT                                               \
        csrr t5, mcause;                                                \
        andi t5, t5, 0xF;                                               \
        li   t6, SIMCTRL_IRQ_ACK;                                       \
        sw   t5, 0(t6);                                                 \
        la   t6, irq_handled;                                           \
        lw   t5, 0(t6);                                                 \
        addi t5, t5, 1;                                                 \
        sw   t5, 0(t6);

#define IRQ_ENABLE_ALL                                                  \
        li   t0, IRQ_ALL_MASK;                                          \
        csrs mie, t0;                                                   \
        csrsi mstatus, MSTATUS_MIE;

#define DIRECTED_TRAP_HANDLER                                           \
        csrr s5, minstret;                                              \
        csrr t5, mcause;                                                \
        bltz t5, 88f;                                                   \
        bnez s11, 86f;                                                  \
        j    trap_vector;                                               \
86:     mv   s8, t5;                                                    \
        csrr s9, mepc;                                                  \
        csrr s10, mtval;                                                \
        csrr s6, mstatus;                                               \
        addi s7, s7, 1;                                                 \
        addi t5, s9, 4;                                                 \
        li   t6, 1;                                                     \
        beq  s11, t6, 87f;                                              \
        mv   t5, s11;                                                   \
87:     csrw mepc, t5;                                                  \
        li   s11, 0;                                                    \
        mret;                                                           \
88:     IRQ_ACK_AND_COUNT                                               \
        mret;

// The stock pass/fail code needs the stock trap vector for its ECALL; the
// handler above forwards it, so no restore is needed before TEST_PASSFAIL.
// DIRECTED_TRAP_INSTALL(label) points mtvec at a DIRECTED_TRAP_HANDLER and
// clears its state registers. Clobbers t0.
#define DIRECTED_TRAP_INSTALL(label)                                    \
        li   s11, 0;                                                    \
        li   s7, 0;                                                     \
        la   t0, label;                                                 \
        csrw mtvec, t0;

#define IRQ_DATA                                                        \
        .align 2;                                                       \
        .global irq_handled;                                            \
irq_handled: .word 0;

#endif
