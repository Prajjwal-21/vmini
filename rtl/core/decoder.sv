// =============================================================================
// decoder
// -----------------------------------------------------------------------------
// Purpose    : RV32I + Zicsr + Zifencei + M-mode SYSTEM decoder (ID stage).
//              Produces the control word, the immediate and the exception
//              flags `illegal`, `ecall` and `ebreak`.
// Interfaces : instr_i -> ctrl_o, imm_o, illegal_o, ecall_o, ebreak_o.
//              Purely combinational.
// Timing     : single combinational level inside ID.
//
// Scope (docs/architecture.md P2.3, P2.4):
//   * FENCE and WFI decode as NOPs.
//   * CSR*, MRET and FENCE.I decode to a serializing sys_op, executed at the
//     commit point. A CSR access is illegal when the CSR does not exist, or
//     when it is read-only and the instruction writes it (write intent:
//     CSRRW/CSRRWI always; CSRRS/CSRRC when rs1 != x0; CSRRSI/CSRRCI when
//     uimm != 0).
//   * ECALL and EBREAK raise their exception flags.
//   * Every reserved encoding is illegal. An instruction with any exception
//     flag gets a NOP control word (no register write, no memory access, no
//     branch, no sys_op), so it has no side effects before it traps.
// =============================================================================
module decoder
  import riscv_pkg::*;
(
  input  inst_t instr_i,
  output ctrl_t ctrl_o,
  output word_t imm_o,
  output logic  illegal_o,
  output logic  ecall_o,
  output logic  ebreak_o
);

  // Instruction fields
  logic [6:0] opcode;
  logic [2:0] funct3;
  logic [6:0] funct7;
  logic [4:0] rs1_field;   // rs1, or uimm[4:0] for the immediate CSR forms
  csr_addr_t  csr_addr;
  assign rs1_field = instr_i[19:15];
  assign csr_addr  = instr_i[31:20];
  assign opcode = instr_i[6:0];
  assign funct3 = instr_i[14:12];
  assign funct7 = instr_i[31:25];

  // Immediates (RISC-V Unprivileged ISA, section 2.3)
  word_t imm_i, imm_s, imm_b, imm_u, imm_j;
  assign imm_i = {{21{instr_i[31]}}, instr_i[30:20]};
  assign imm_s = {{21{instr_i[31]}}, instr_i[30:25], instr_i[11:7]};
  assign imm_b = {{20{instr_i[31]}}, instr_i[7], instr_i[30:25], instr_i[11:8], 1'b0};
  assign imm_u = {instr_i[31:12], 12'b0};
  assign imm_j = {{12{instr_i[31]}}, instr_i[19:12], instr_i[20], instr_i[30:21], 1'b0};

  // A NOP control word: used as the default and for every illegal encoding.
  localparam ctrl_t CTRL_NOP = '{
    alu_op:       ALU_ADD,
    op_a_sel:     OPA_RS1,
    op_b_sel:     OPB_IMM,
    branch:       BR_NONE,
    mem_op:       MEM_NONE,
    mem_size:     SIZE_W,
    mem_unsigned: 1'b0,
    wb_sel:       WB_ALU,
    rd_we:        1'b0,
    uses_rs1:     1'b0,
    uses_rs2:     1'b0,
    sys_op:       SYS_NONE,
    csr_we:       1'b0
  };

  ctrl_t ctrl;
  logic  illegal, ecall, ebreak;

  always_comb begin
    ctrl    = CTRL_NOP;
    imm_o   = imm_i;
    illegal = 1'b0;
    ecall   = 1'b0;
    ebreak  = 1'b0;

    unique case (opcode)
      OPC_LUI: begin
        ctrl.op_a_sel = OPA_ZERO;
        ctrl.rd_we    = 1'b1;
        imm_o         = imm_u;
      end

      OPC_AUIPC: begin
        ctrl.op_a_sel = OPA_PC;
        ctrl.rd_we    = 1'b1;
        imm_o         = imm_u;
      end

      OPC_JAL: begin
        ctrl.branch = BR_JAL;
        ctrl.wb_sel = WB_PC4;
        ctrl.rd_we  = 1'b1;
        imm_o       = imm_j;
      end

      OPC_JALR: begin
        ctrl.branch   = BR_JALR;
        ctrl.wb_sel   = WB_PC4;
        ctrl.rd_we    = 1'b1;
        ctrl.uses_rs1 = 1'b1;
        imm_o         = imm_i;
        illegal       = (funct3 != 3'b000);
      end

      OPC_BRANCH: begin
        ctrl.uses_rs1 = 1'b1;
        ctrl.uses_rs2 = 1'b1;
        imm_o         = imm_b;
        unique case (funct3)
          F3_BEQ:  ctrl.branch = BR_EQ;
          F3_BNE:  ctrl.branch = BR_NE;
          F3_BLT:  ctrl.branch = BR_LT;
          F3_BGE:  ctrl.branch = BR_GE;
          F3_BLTU: ctrl.branch = BR_LTU;
          F3_BGEU: ctrl.branch = BR_GEU;
          default: illegal     = 1'b1;
        endcase
      end

      OPC_LOAD: begin
        ctrl.mem_op   = MEM_LOAD;
        ctrl.wb_sel   = WB_MEM;
        ctrl.rd_we    = 1'b1;
        ctrl.uses_rs1 = 1'b1;
        imm_o         = imm_i;
        unique case (funct3)
          F3_LB:   ctrl.mem_size = SIZE_B;
          F3_LH:   ctrl.mem_size = SIZE_H;
          F3_LW:   ctrl.mem_size = SIZE_W;
          F3_LBU:  begin ctrl.mem_size = SIZE_B; ctrl.mem_unsigned = 1'b1; end
          F3_LHU:  begin ctrl.mem_size = SIZE_H; ctrl.mem_unsigned = 1'b1; end
          default: illegal = 1'b1;
        endcase
      end

      OPC_STORE: begin
        ctrl.mem_op   = MEM_STORE;
        ctrl.uses_rs1 = 1'b1;
        ctrl.uses_rs2 = 1'b1;
        imm_o         = imm_s;
        unique case (funct3)
          F3_SB:   ctrl.mem_size = SIZE_B;
          F3_SH:   ctrl.mem_size = SIZE_H;
          F3_SW:   ctrl.mem_size = SIZE_W;
          default: illegal = 1'b1;
        endcase
      end

      OPC_OP_IMM: begin
        ctrl.rd_we    = 1'b1;
        ctrl.uses_rs1 = 1'b1;
        unique case (funct3)
          F3_ADD_SUB: ctrl.alu_op = ALU_ADD;
          F3_SLT:     ctrl.alu_op = ALU_SLT;
          F3_SLTU:    ctrl.alu_op = ALU_SLTU;
          F3_XOR:     ctrl.alu_op = ALU_XOR;
          F3_OR:      ctrl.alu_op = ALU_OR;
          F3_AND:     ctrl.alu_op = ALU_AND;
          F3_SLL: begin
            ctrl.alu_op = ALU_SLL;
            illegal     = (funct7 != F7_BASE);  // RV32: shamt[5] must be 0
          end
          F3_SRL_SRA: begin
            ctrl.alu_op = (funct7 == F7_ALT) ? ALU_SRA : ALU_SRL;
            illegal     = (funct7 != F7_BASE) && (funct7 != F7_ALT);
          end
          default: ;
        endcase
      end

      OPC_OP: begin
        ctrl.op_b_sel = OPB_RS2;
        ctrl.rd_we    = 1'b1;
        ctrl.uses_rs1 = 1'b1;
        ctrl.uses_rs2 = 1'b1;
        unique case (funct3)
          F3_ADD_SUB: ctrl.alu_op = (funct7 == F7_ALT) ? ALU_SUB : ALU_ADD;
          F3_SLL:     ctrl.alu_op = ALU_SLL;
          F3_SLT:     ctrl.alu_op = ALU_SLT;
          F3_SLTU:    ctrl.alu_op = ALU_SLTU;
          F3_XOR:     ctrl.alu_op = ALU_XOR;
          F3_SRL_SRA: ctrl.alu_op = (funct7 == F7_ALT) ? ALU_SRA : ALU_SRL;
          F3_OR:      ctrl.alu_op = ALU_OR;
          F3_AND:     ctrl.alu_op = ALU_AND;
          default: ;
        endcase
        // Only ADD/SUB and SRL/SRA have an F7_ALT form.
        if ((funct3 == F3_ADD_SUB) || (funct3 == F3_SRL_SRA)) begin
          illegal = (funct7 != F7_BASE) && (funct7 != F7_ALT);
        end else begin
          illegal = (funct7 != F7_BASE);
        end
      end

      OPC_MISC_MEM: begin
        // FENCE is a NOP (in-order, single-issue memory access); FENCE.I
        // serializes and refetches (P2.7).
        unique case (funct3)
          F3_FENCE:   ;
          F3_FENCE_I: ctrl.sys_op = SYS_FENCE_I;
          default:    illegal     = 1'b1;
        endcase
      end

      OPC_SYSTEM: begin
        if (funct3 == F3_PRIV) begin
          // Exact encodings only (P2.4): SRET, URET, SFENCE.VMA, DRET, or any
          // non-zero rd/rs1 field is illegal. WFI is a NOP.
          unique case (instr_i)
            INSTR_ECALL:  ecall       = 1'b1;
            INSTR_EBREAK: ebreak      = 1'b1;
            INSTR_MRET:   ctrl.sys_op = SYS_MRET;
            INSTR_WFI:    ;
            default:      illegal     = 1'b1;
          endcase
        end else if (funct3 == F3_SYS_RSVD) begin
          illegal = 1'b1;
        end else begin
          // CSRRW/S/C(I). The operand (rs1, or the zero-extended uimm) goes
          // through the ALU as operand + 0 and reaches MEM in ex_mem.result.
          unique case (funct3[1:0])
            F3_CSR_RW: ctrl.sys_op = SYS_CSRRW;
            F3_CSR_RS: ctrl.sys_op = SYS_CSRRS;
            default:   ctrl.sys_op = SYS_CSRRC;   // F3_CSR_RC
          endcase
          ctrl.wb_sel = WB_CSR;
          ctrl.rd_we  = 1'b1;
          ctrl.csr_we = (funct3[1:0] == F3_CSR_RW) || (rs1_field != '0);
          if (funct3[2]) begin                   // immediate form
            ctrl.op_a_sel = OPA_ZERO;
            imm_o         = {27'b0, rs1_field};
          end else begin
            ctrl.uses_rs1 = 1'b1;
            imm_o         = '0;
          end
          illegal = !csr_exists(csr_addr) || (csr_read_only(csr_addr) && ctrl.csr_we);
        end
      end

      default: illegal = 1'b1;
    endcase

    // 16-bit (compressed) encodings are not supported: inst[1:0] must be 11.
    if (instr_i[1:0] != 2'b11) illegal = 1'b1;
  end

  // An instruction that raises an exception must have no side effects.
  // ECALL/EBREAK match exact 32-bit encodings, so they never coincide with
  // `illegal`; masking them with it only keeps the flags one-hot by design.
  assign ctrl_o    = (illegal || ecall || ebreak) ? CTRL_NOP : ctrl;
  assign illegal_o = illegal;
  assign ecall_o   = ecall  && !illegal;
  assign ebreak_o  = ebreak && !illegal;

endmodule : decoder
