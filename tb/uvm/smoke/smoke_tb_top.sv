// =============================================================================
// smoke_tb_top
// -----------------------------------------------------------------------------
// Purpose : Top level of the UVM smoke test: clock, reset, DUT, interface,
//           config_db hand-off and run_test().
// Timing  : 100 MHz clock (10 ns period); reset held low for 4 cycles.
// =============================================================================
module smoke_tb_top;

  import uvm_pkg::*;
  import smoke_pkg::*;

  logic clk;
  logic rst_n;

  initial begin
    clk = 1'b0;
    forever #5ns clk = ~clk;
  end

  initial begin
    rst_n = 1'b0;
    repeat (4) @(posedge clk);
    rst_n <= 1'b1;
  end

  smoke_if vif (.clk(clk), .rst_n(rst_n));

  smoke_dut u_dut (
    .clk_i   (clk),
    .rst_ni  (rst_n),
    .valid_i (vif.valid_i),
    .a_i     (vif.a_i),
    .b_i     (vif.b_i),
    .valid_o (vif.valid_o),
    .sum_o   (vif.sum_o)
  );

  initial begin
    uvm_config_db#(virtual smoke_if)::set(null, "uvm_test_top.*", "vif", vif);
    run_test("smoke_test");
  end

endmodule : smoke_tb_top
