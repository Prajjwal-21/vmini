// =============================================================================
// smoke_if
// -----------------------------------------------------------------------------
// Purpose : Pin-level interface between the UVM smoke agent and smoke_dut.
// Timing  : The driver updates inputs with non-blocking assignments right after
//           a rising edge; the monitor samples everything on the rising edge.
// =============================================================================
// Every signal here, ports included, is driven and sampled only through a
// virtual interface from UVM class code. Verilator's driver/usage analysis does
// not follow virtual-interface accesses, so UNDRIVEN/UNUSEDSIGNAL are false
// positives for this interface.
/* verilator lint_off UNDRIVEN */
/* verilator lint_off UNUSEDSIGNAL */
interface smoke_if (
  input logic clk,
  input logic rst_n
);
  logic       valid_i;
  logic [7:0] a_i;
  logic [7:0] b_i;
  logic       valid_o;
  logic [8:0] sum_o;
endinterface : smoke_if
/* verilator lint_on UNUSEDSIGNAL */
/* verilator lint_on UNDRIVEN */
