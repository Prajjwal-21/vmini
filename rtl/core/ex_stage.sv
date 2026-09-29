// =============================================================================
// ex_stage
// -----------------------------------------------------------------------------
// Purpose    : Execute stage datapath: forwarding muxes, ALU, branch unit,
//              link address, misalignment checks, the trap cause and mtval of
//              the highest-priority exception flag (architecture.md P2.5), and
//              formation of the D-port request payload and the next EX/MEM
//              contents. For CSR instructions the ALU passes the operand (rs1
//              or uimm) through to ex_mem.result.
// Interfaces : id_ex_i plus forwarding selects/sources -> ex_mem_o (valid and
//              req_sent are filled in by core_top), the redirect request, the
//              D-port payload, and the flags the issue rule needs (4.6).
// Timing     : fully combinational. Longest paths: forwarding mux -> branch
//              compare -> redirect_o -> fetch address, and forwarding mux ->
//              address adder -> dmem_req_o.addr (architecture.md s.9).
// =============================================================================
module ex_stage
  import riscv_pkg::*;
(
  // .rs1/.rs2 (register addresses) are consumed by forwarding_unit instead.
  /* verilator lint_off UNUSEDSIGNAL */
  input  id_ex_t   id_ex_i,
  /* verilator lint_on UNUSEDSIGNAL */
  input  fwd_sel_e fwd_rs1_i,
  input  fwd_sel_e fwd_rs2_i,
  input  word_t    exmem_result_i,   // EX/MEM forwarding source
  input  word_t    memwb_wdata_i,    // MEM/WB forwarding source

  output ex_mem_t  ex_mem_o,         // .valid/.req_sent: don't care here
  output logic     redirect_o,       // taken branch/JAL/JALR with a legal target
  output word_t    redirect_pc_o,
  output logic     mem_op_o,         // a valid load/store is in EX
  output logic     self_exc_o,       // this instruction will trap (no request)
  output mem_req_t dmem_req_o
);

  function automatic word_t forward(fwd_sel_e sel, word_t reg_value);
    unique case (sel)
      FWD_EXMEM: return exmem_result_i;
      FWD_MEMWB: return memwb_wdata_i;
      default:   return reg_value;
    endcase
  endfunction

  word_t rs1, rs2, op_a, op_b, alu_result, link;
  logic  taken, target_misaligned;
  word_t target;

  assign rs1 = forward(fwd_rs1_i, id_ex_i.rs1_data);
  assign rs2 = forward(fwd_rs2_i, id_ex_i.rs2_data);

  always_comb begin
    unique case (id_ex_i.ctrl.op_a_sel)
      OPA_PC:   op_a = id_ex_i.pc;
      OPA_ZERO: op_a = '0;
      default:  op_a = rs1;
    endcase
  end
  assign op_b = (id_ex_i.ctrl.op_b_sel == OPB_RS2) ? rs2 : id_ex_i.imm;

  alu u_alu (
    .op_i     (id_ex_i.ctrl.alu_op),
    .a_i      (op_a),
    .b_i      (op_b),
    .result_o (alu_result)
  );

  branch_unit u_branch (
    .branch_i            (id_ex_i.ctrl.branch),
    .pc_i                (id_ex_i.pc),
    .imm_i               (id_ex_i.imm),
    .rs1_i               (rs1),
    .rs2_i               (rs2),
    .taken_o             (taken),
    .target_o            (target),
    .target_misaligned_o (target_misaligned)
  );

  assign link = id_ex_i.pc + 32'd4;

  // ---------------------------------------------------------------------------
  // Loads/stores: the ALU computes rs1 + imm.
  // ---------------------------------------------------------------------------
  logic       is_load, is_store, misaligned;
  logic [1:0] off;

  assign is_load    = (id_ex_i.ctrl.mem_op == MEM_LOAD);
  assign is_store   = (id_ex_i.ctrl.mem_op == MEM_STORE);
  assign off        = alu_result[1:0];
  assign misaligned = (is_load || is_store) && is_misaligned(id_ex_i.ctrl.mem_size, off);

  exc_t exc;
  always_comb begin
    exc               = id_ex_i.exc;
    exc.ld_misaligned = exc.ld_misaligned || (is_load  && misaligned);
    exc.st_misaligned = exc.st_misaligned || (is_store && misaligned);
    exc.if_misaligned = exc.if_misaligned || target_misaligned;
  end

  assign mem_op_o   = id_ex_i.valid && (is_load || is_store);
  assign self_exc_o = (exc != '0);

  assign dmem_req_o = '{
    addr:  alu_result,
    we:    is_store,
    be:    byte_enable(id_ex_i.ctrl.mem_size, off),
    wdata: store_data(id_ex_i.ctrl.mem_size, rs2)
  };

  // ---------------------------------------------------------------------------
  // Redirect: only for a valid instruction with no exception. A misaligned
  // target raises if_misaligned on the branch itself (Phase 2 trap) instead.
  // ---------------------------------------------------------------------------
  assign redirect_o    = id_ex_i.valid && taken && !target_misaligned && (id_ex_i.exc == '0);
  assign redirect_pc_o = target;

  // ---------------------------------------------------------------------------
  // Trap cause and mtval, in privileged-spec priority order (P2.5). With no
  // flag set, tval carries the load/store address, which MEM uses if the
  // response returns an access fault.
  // ---------------------------------------------------------------------------
  exc_code_t cause;
  word_t     tval;

  always_comb begin
    cause = EXC_ILLEGAL;
    tval  = alu_result;
    if (exc.if_fault) begin
      cause = EXC_INSTR_ACCESS;
      tval  = id_ex_i.pc;
    end else if (exc.illegal) begin
      // The faulting instruction's bits: a 16-bit length encoding
      // (inst[1:0] != 11) is 16 bits long, zero-extended (as Spike reports).
      cause = EXC_ILLEGAL;
      tval  = (id_ex_i.instr[1:0] == 2'b11) ? id_ex_i.instr : {16'b0, id_ex_i.instr[15:0]};
    end else if (exc.if_misaligned) begin
      cause = EXC_INSTR_MISALIGNED;
      tval  = target;
    end else if (exc.ecall) begin
      cause = EXC_ECALL_M;
      tval  = '0;
    end else if (exc.ebreak) begin
      cause = EXC_BREAKPOINT;
      tval  = id_ex_i.pc;
    end else if (exc.ld_misaligned) begin
      cause = EXC_LOAD_MISALIGNED;
    end else if (exc.st_misaligned) begin
      cause = EXC_STORE_MISALIGNED;
    end
  end

  // ---------------------------------------------------------------------------
  // Next EX/MEM contents
  // ---------------------------------------------------------------------------
  always_comb begin
    ex_mem_o              = '0;
    ex_mem_o.pc           = id_ex_i.pc;
    ex_mem_o.next_pc      = (taken && !target_misaligned) ? target : link;
    ex_mem_o.instr        = id_ex_i.instr;
    ex_mem_o.rd           = id_ex_i.rd;
    ex_mem_o.rd_we        = id_ex_i.ctrl.rd_we;
    ex_mem_o.result       = (id_ex_i.ctrl.wb_sel == WB_PC4) ? link : alu_result;
    ex_mem_o.mem_op       = id_ex_i.ctrl.mem_op;
    ex_mem_o.mem_size     = id_ex_i.ctrl.mem_size;
    ex_mem_o.mem_unsigned = id_ex_i.ctrl.mem_unsigned;
    ex_mem_o.addr_off     = off;
    ex_mem_o.wb_sel       = id_ex_i.ctrl.wb_sel;
    ex_mem_o.sys_op       = id_ex_i.ctrl.sys_op;
    ex_mem_o.csr_we       = id_ex_i.ctrl.csr_we;
    ex_mem_o.exc          = exc;
    ex_mem_o.exc_cause    = cause;
    ex_mem_o.tval         = tval;
  end

endmodule : ex_stage
