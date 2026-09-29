// =============================================================================
// forwarding_unit
// -----------------------------------------------------------------------------
// Purpose    : Operand-forwarding selects for EX (docs/architecture.md 4.1):
//              EX/MEM -> EX and MEM/WB -> EX, for rs1 and rs2 (ALU operands and
//              store data). The newest producer wins; x0 is never forwarded.
// Interfaces : EX source registers and the EX/MEM, MEM/WB destinations
//              -> fwd_rs1_o, fwd_rs2_o.
// Timing     : combinational; drives the operand muxes at the start of EX.
//
// A load in MEM is never a legal forwarding source: the load-use stall keeps
// its consumer out of EX until the load reaches WB.
// =============================================================================
module forwarding_unit
  import riscv_pkg::*;
(
  input  reg_addr_t ex_rs1_i,
  input  reg_addr_t ex_rs2_i,

  input  logic      exmem_valid_i,
  input  logic      exmem_rd_we_i,
  input  reg_addr_t exmem_rd_i,

  input  logic      memwb_valid_i,
  input  logic      memwb_rd_we_i,
  input  reg_addr_t memwb_rd_i,

  output fwd_sel_e  fwd_rs1_o,
  output fwd_sel_e  fwd_rs2_o
);

  function automatic fwd_sel_e select(reg_addr_t rs);
    if (exmem_valid_i && exmem_rd_we_i && (exmem_rd_i != '0) && (exmem_rd_i == rs))
      return FWD_EXMEM;
    else if (memwb_valid_i && memwb_rd_we_i && (memwb_rd_i != '0) && (memwb_rd_i == rs))
      return FWD_MEMWB;
    else
      return FWD_NONE;
  endfunction

  assign fwd_rs1_o = select(ex_rs1_i);
  assign fwd_rs2_o = select(ex_rs2_i);

endmodule : forwarding_unit
