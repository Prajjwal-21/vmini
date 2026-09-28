// =============================================================================
// smoke_dut
// -----------------------------------------------------------------------------
// Purpose    : Minimal DUT for the UVM tool-flow smoke test (`make uvm-smoke`).
//              A registered 8-bit adder: when valid_i is high on a rising
//              clock edge, sum_o = a_i + b_i and valid_o are presented on the
//              next cycle. Not part of the SoC.
// Interfaces : valid_i/a_i/b_i in, valid_o/sum_o out. No back-pressure.
// Timing     : 1-cycle latency; one result per cycle.
// =============================================================================
module smoke_dut (
  input  logic       clk_i,
  input  logic       rst_ni,
  input  logic       valid_i,
  input  logic [7:0] a_i,
  input  logic [7:0] b_i,
  output logic       valid_o,
  output logic [8:0] sum_o
);

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      valid_o <= 1'b0;
      sum_o   <= '0;
    end else begin
      valid_o <= valid_i;
      if (valid_i) begin
        sum_o <= {1'b0, a_i} + {1'b0, b_i};
      end
    end
  end

endmodule : smoke_dut
