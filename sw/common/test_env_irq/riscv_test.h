// =============================================================================
// test_env_irq/riscv_test.h - stock riscv-tests env/p plus interrupt hooks
// -----------------------------------------------------------------------------
// Used only for the rv32ui-p-* builds that run with random interrupts
// (make riscv-tests-irq, D-028; docs/architecture.md P2.9). The interrupt-free
// configuration runs the unmodified stock ELFs instead.
//
// This header includes the UNMODIFIED stock third_party/riscv-tests/env/p/
// riscv_test.h (#include_next: it must come first on the include path) and
// then redefines only three of its documented hook macros. The startup code,
// trap vector and pass/fail reporting are the stock ones.
//   EXTRA_INIT         mie = MEIE|MTIE|MSIE and mstatus.MPIE = 1, so the stock
//                      mret into the test body sets mstatus.MIE.
//   INTERRUPT_HANDLER  reached from the stock trap vector for mcause < 0 when
//                      the test defines no mtvec_handler (no rv32ui test does):
//                      acknowledge, count, mret. Uses t5/t6 only; no rv32ui
//                      test body uses x30/x31.
//   EXTRA_DATA         the irq_handled counter.
// =============================================================================
#ifndef TEST_ENV_IRQ_RISCV_TEST_H
#define TEST_ENV_IRQ_RISCV_TEST_H

#include_next "riscv_test.h"
#include "irq_handler.h"

#undef  EXTRA_INIT
#define EXTRA_INIT                                                      \
        li   t0, IRQ_ALL_MASK;                                          \
        csrw mie, t0;                                                   \
        li   t0, MSTATUS_MPIE;                                          \
        csrs mstatus, t0;

#undef  INTERRUPT_HANDLER
#define INTERRUPT_HANDLER                                               \
        IRQ_ACK_AND_COUNT                                               \
        mret

#undef  EXTRA_DATA
#define EXTRA_DATA IRQ_DATA

#endif
