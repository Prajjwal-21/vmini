// =============================================================================
// tohost_monitor  (testbench only)
// -----------------------------------------------------------------------------
// Purpose    : riscv-tests pass/fail detection (CLAUDE.md section 6). Watches
//              accepted D-port stores to the `tohost` address (+tohost=<hex>,
//              taken from the ELF symbol table). A value of 1 means PASS; any
//              other value means FAIL with test number = value >> 1.
// Interfaces : snoops the D-port request channel; done_o/pass_o/testnum_o are
//              registered and stay set once a result has been seen.
// Timing     : the store is observed at acceptance. That is safe: the issue
//              rule (architecture.md 4.6) guarantees an accepted store commits.
// =============================================================================
module tohost_monitor
  import riscv_pkg::*;
(
  input  logic     clk_i,
  input  logic     rst_ni,
  input  logic     dmem_req_valid_i,
  input  logic     dmem_req_ready_i,
  input  mem_req_t dmem_req_i,
  output logic     done_o,
  output logic     pass_o,
  output word_t    testnum_o
);

  word_t tohost;

  initial begin
    if (!$value$plusargs("tohost=%h", tohost))
      $fatal(1, "[tohost_monitor] missing +tohost=<hex address>");
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      done_o    <= 1'b0;
      pass_o    <= 1'b0;
      testnum_o <= '0;
    end else if (!done_o && dmem_req_valid_i && dmem_req_ready_i && dmem_req_i.we
                 && (dmem_req_i.addr == tohost) && (dmem_req_i.be == 4'b1111)) begin
      done_o    <= 1'b1;
      pass_o    <= (dmem_req_i.wdata == 32'd1);
      testnum_o <= dmem_req_i.wdata >> 1;
    end
  end

endmodule : tohost_monitor
