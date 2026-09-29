// =============================================================================
// alu
// -----------------------------------------------------------------------------
// Purpose    : RV32I integer ALU. Also computes load/store addresses (ADD) and
//              LUI/AUIPC results.
// Interfaces : op_i, a_i, b_i -> result_o. Purely combinational.
// Timing     : one combinational stage inside EX (after the forwarding muxes).
// =============================================================================
module alu
  import riscv_pkg::*;
(
  input  alu_op_e op_i,
  input  word_t   a_i,
  input  word_t   b_i,
  output word_t   result_o
);

  logic [4:0] shamt;
  assign shamt = b_i[4:0];

  always_comb begin
    unique case (op_i)
      ALU_ADD:    result_o = a_i + b_i;
      ALU_SUB:    result_o = a_i - b_i;
      ALU_SLL:    result_o = a_i << shamt;
      ALU_SLT:    result_o = {31'b0, $signed(a_i) < $signed(b_i)};
      ALU_SLTU:   result_o = {31'b0, a_i < b_i};
      ALU_XOR:    result_o = a_i ^ b_i;
      ALU_SRL:    result_o = a_i >> shamt;
      ALU_SRA:    result_o = word_t'($signed(a_i) >>> shamt);
      ALU_OR:     result_o = a_i | b_i;
      ALU_AND:    result_o = a_i & b_i;
      ALU_PASS_B: result_o = b_i;
      default:    result_o = '0;
    endcase
  end

endmodule : alu
