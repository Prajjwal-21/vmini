// =============================================================================
// regfile
// -----------------------------------------------------------------------------
// Purpose    : Integer register file x0..x31: 2 read ports, 1 write port.
//              x0 is hard-wired to zero.
// Interfaces : combinational reads (raddr*_i -> rdata*_o); synchronous write
//              on the rising edge when we_i.
// Timing     : WB->ID bypass: a read of the register being written in the same
//              cycle returns the new data, so an instruction in ID sees a value
//              written back by WB in that cycle (CLAUDE.md section 5.1).
//
// The storage has no reset: software (and the riscv-tests environment)
// initialises registers before use. This saves 992 reset flops.
// =============================================================================
module regfile
  import riscv_pkg::*;
(
  input  logic      clk_i,

  input  reg_addr_t raddr1_i,
  output word_t     rdata1_o,
  input  reg_addr_t raddr2_i,
  output word_t     rdata2_o,

  input  logic      we_i,
  input  reg_addr_t waddr_i,
  input  word_t     wdata_i
);

  word_t regs_q [1:NUM_REGS-1];

  always_ff @(posedge clk_i) begin
    if (we_i && (waddr_i != '0)) begin
      regs_q[waddr_i] <= wdata_i;
    end
  end

  function automatic word_t read_port(reg_addr_t raddr);
    if (raddr == '0)                      return '0;
    else if (we_i && (waddr_i == raddr))  return wdata_i;   // WB->ID bypass
    else                                  return regs_q[raddr];
  endfunction

  assign rdata1_o = read_port(raddr1_i);
  assign rdata2_o = read_port(raddr2_i);

endmodule : regfile
