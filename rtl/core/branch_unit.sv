// =============================================================================
// branch_unit
// -----------------------------------------------------------------------------
// Purpose    : Branch/jump resolution in EX (static predict-not-taken).
//              Evaluates the branch condition, computes the target, and flags a
//              target that is not 4-byte aligned (no C extension).
// Interfaces : branch_i, pc_i, imm_i, rs1_i, rs2_i (forwarded operands)
//              -> taken_o, target_o, target_misaligned_o.
// Timing     : combinational; feeds `redirect`, which reaches the fetch request
//              address in the same cycle (critical path 1, architecture.md s.9).
// =============================================================================
module branch_unit
  import riscv_pkg::*;
(
  input  branch_e branch_i,
  input  word_t   pc_i,
  input  word_t   imm_i,
  input  word_t   rs1_i,
  input  word_t   rs2_i,
  output logic    taken_o,
  output word_t   target_o,
  output logic    target_misaligned_o
);

  logic  eq, lt, ltu;
  word_t pc_target, jalr_target;

  assign eq          = (rs1_i == rs2_i);
  assign lt          = ($signed(rs1_i) < $signed(rs2_i));
  assign ltu         = (rs1_i < rs2_i);
  assign pc_target   = pc_i + imm_i;
  assign jalr_target = (rs1_i + imm_i) & ~word_t'(1);   // JALR clears bit 0

  always_comb begin
    unique case (branch_i)
      BR_EQ:   taken_o = eq;
      BR_NE:   taken_o = !eq;
      BR_LT:   taken_o = lt;
      BR_GE:   taken_o = !lt;
      BR_LTU:  taken_o = ltu;
      BR_GEU:  taken_o = !ltu;
      BR_JAL,
      BR_JALR: taken_o = 1'b1;
      default: taken_o = 1'b0;
    endcase
  end

  assign target_o            = (branch_i == BR_JALR) ? jalr_target : pc_target;
  assign target_misaligned_o = taken_o && (target_o[1:0] != 2'b00);

endmodule : branch_unit
