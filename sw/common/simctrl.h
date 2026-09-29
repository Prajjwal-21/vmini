// =============================================================================
// simctrl.h - simulation-control device (core testbench only)
// -----------------------------------------------------------------------------
// Mirrors soc_pkg::SIMCTRL_BASE and docs/memory_map.md ("Reserved, simulation
// only", D-029). The SoC never decodes this window; only tb/common/sim_ctrl.sv
// implements it. Usable from C and from assembly (.S).
//   IRQ_ACK   (W) write a cause code 3/7/11: lower that line, count an ack
//   IRQ_FORCE (W) bits 3/7/11: raise the MSIP/MTIP/MEIP line
//   IRQ_LINES (R) current line state, bits 3/7/11
//   IRQ_RANDOM(W) 0: pause the random interrupt generator, 1: resume. Lines
//                 already high stay high until acknowledged. Used by directed
//                 tests around checks that need a fixed interrupt order.
// All accesses must be full-word.
// =============================================================================
#ifndef SIMCTRL_H
#define SIMCTRL_H

#define SIMCTRL_BASE       0x40000000
#define SIMCTRL_IRQ_ACK    (SIMCTRL_BASE + 0x0)
#define SIMCTRL_IRQ_FORCE  (SIMCTRL_BASE + 0x4)
#define SIMCTRL_IRQ_LINES  (SIMCTRL_BASE + 0x8)
#define SIMCTRL_IRQ_RANDOM (SIMCTRL_BASE + 0xC)

#endif
