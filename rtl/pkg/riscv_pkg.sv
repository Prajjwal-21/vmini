// =============================================================================
// riscv_pkg
// -----------------------------------------------------------------------------
// Purpose    : (1) ISA-level constants for RV32I: widths, major opcodes and
//              funct3/funct7 encodings from the RISC-V Unprivileged ISA spec.
//              (2) Core microarchitecture types: decoded-operation enums,
//              exception flags, pipeline-register structs, memory-port
//              structs and load/store alignment helpers
//              (docs/architecture.md sections 2 and 6).
//              (3) Machine-mode CSR addresses, fields, exception and interrupt
//              codes, and the CSR existence/read-only rules shared by the
//              decoder and csr_file (architecture.md P2.2, P2.4, P2.5).
// Interfaces : none (package).
// Timing     : n/a.
// =============================================================================
package riscv_pkg;

  // Waiver: a package is a catalogue of constants; not every constant is
  // referenced by every module or build configuration, so UNUSEDPARAM is
  // noise here. It stays enabled for parameters declared inside modules.
  /* verilator lint_off UNUSEDPARAM */

  // ---------------------------------------------------------------------------
  // Widths
  // ---------------------------------------------------------------------------
  localparam int unsigned XLEN       = 32;  // integer register width
  localparam int unsigned ILEN       = 32;  // instruction width (no C extension)
  localparam int unsigned NUM_REGS   = 32;  // x0..x31
  localparam int unsigned REG_ADDR_W = $clog2(NUM_REGS);

  typedef logic [XLEN-1:0]       word_t;
  typedef logic [ILEN-1:0]       inst_t;
  typedef logic [REG_ADDR_W-1:0] reg_addr_t;

  // ---------------------------------------------------------------------------
  // Major opcodes: inst[6:0]
  // ---------------------------------------------------------------------------
  typedef enum logic [6:0] {
    OPC_LOAD     = 7'b000_0011,
    OPC_MISC_MEM = 7'b000_1111,  // FENCE, FENCE.I
    OPC_OP_IMM   = 7'b001_0011,
    OPC_AUIPC    = 7'b001_0111,
    OPC_STORE    = 7'b010_0011,
    OPC_OP       = 7'b011_0011,
    OPC_LUI      = 7'b011_0111,
    OPC_BRANCH   = 7'b110_0011,
    OPC_JALR     = 7'b110_0111,
    OPC_JAL      = 7'b110_1111,
    OPC_SYSTEM   = 7'b111_0011   // ECALL, EBREAK, CSR*, MRET, WFI
  } opcode_e;

  // ---------------------------------------------------------------------------
  // funct3: inst[14:12]
  // ---------------------------------------------------------------------------
  // BRANCH
  localparam logic [2:0] F3_BEQ  = 3'b000;
  localparam logic [2:0] F3_BNE  = 3'b001;
  localparam logic [2:0] F3_BLT  = 3'b100;
  localparam logic [2:0] F3_BGE  = 3'b101;
  localparam logic [2:0] F3_BLTU = 3'b110;
  localparam logic [2:0] F3_BGEU = 3'b111;

  // LOAD / STORE (bit 2 = unsigned for loads; bits [1:0] = log2(size))
  localparam logic [2:0] F3_LB  = 3'b000;
  localparam logic [2:0] F3_LH  = 3'b001;
  localparam logic [2:0] F3_LW  = 3'b010;
  localparam logic [2:0] F3_LBU = 3'b100;
  localparam logic [2:0] F3_LHU = 3'b101;
  localparam logic [2:0] F3_SB  = 3'b000;
  localparam logic [2:0] F3_SH  = 3'b001;
  localparam logic [2:0] F3_SW  = 3'b010;

  // OP / OP-IMM
  localparam logic [2:0] F3_ADD_SUB = 3'b000;  // ADDI has no SUB form
  localparam logic [2:0] F3_SLL     = 3'b001;
  localparam logic [2:0] F3_SLT     = 3'b010;
  localparam logic [2:0] F3_SLTU    = 3'b011;
  localparam logic [2:0] F3_XOR     = 3'b100;
  localparam logic [2:0] F3_SRL_SRA = 3'b101;
  localparam logic [2:0] F3_OR      = 3'b110;
  localparam logic [2:0] F3_AND     = 3'b111;

  // MISC-MEM
  localparam logic [2:0] F3_FENCE   = 3'b000;
  localparam logic [2:0] F3_FENCE_I = 3'b001;

  // SYSTEM (funct3 = 000 selects ECALL/EBREAK/MRET/WFI via funct12; 100 is
  // reserved; funct3[2] selects the immediate CSR forms, funct3[1:0] the op)
  localparam logic [2:0] F3_PRIV     = 3'b000;
  localparam logic [2:0] F3_SYS_RSVD = 3'b100;
  localparam logic [1:0] F3_CSR_RW   = 2'b01;   // funct3[1:0]
  localparam logic [1:0] F3_CSR_RS   = 2'b10;
  localparam logic [1:0] F3_CSR_RC   = 2'b11;

  // Complete encodings of the SYSTEM instructions with funct3 = 000 (every
  // other field must be zero; anything else is illegal, P2.4)
  localparam logic [31:0] INSTR_ECALL  = 32'h0000_0073;
  localparam logic [31:0] INSTR_EBREAK = 32'h0010_0073;
  localparam logic [31:0] INSTR_MRET   = 32'h3020_0073;
  localparam logic [31:0] INSTR_WFI    = 32'h1050_0073;

  // ---------------------------------------------------------------------------
  // funct7: inst[31:25]
  // ---------------------------------------------------------------------------
  localparam logic [6:0] F7_BASE = 7'b000_0000;
  localparam logic [6:0] F7_ALT  = 7'b010_0000;  // SUB, SRA, SRAI

  // ===========================================================================
  // Core microarchitecture types (docs/architecture.md section 6)
  // ===========================================================================

  // ---------------------------------------------------------------------------
  // Decoded operations
  // ---------------------------------------------------------------------------
  typedef enum logic [3:0] {
    ALU_ADD, ALU_SUB, ALU_SLL, ALU_SLT, ALU_SLTU,
    ALU_XOR, ALU_SRL, ALU_SRA, ALU_OR,  ALU_AND, ALU_PASS_B
  } alu_op_e;

  typedef enum logic [3:0] {
    BR_NONE, BR_EQ, BR_NE, BR_LT, BR_GE, BR_LTU, BR_GEU, BR_JAL, BR_JALR
  } branch_e;

  typedef enum logic [1:0] { MEM_NONE, MEM_LOAD, MEM_STORE } mem_op_e;
  typedef enum logic [1:0] { SIZE_B, SIZE_H, SIZE_W }        mem_size_e;
  typedef enum logic [1:0] { OPA_RS1, OPA_PC, OPA_ZERO }     op_a_sel_e;
  typedef enum logic       { OPB_RS2, OPB_IMM }              op_b_sel_e;
  typedef enum logic [1:0] { WB_ALU, WB_MEM, WB_PC4, WB_CSR } wb_sel_e;
  typedef enum logic [1:0] { FWD_NONE, FWD_EXMEM, FWD_MEMWB } fwd_sel_e;

  // Serializing SYSTEM/MISC-MEM operations, executed at the commit point
  // (P2.3). SYS_NONE for every other instruction, including ECALL, EBREAK,
  // WFI and FENCE (the first two are exceptions, the last two NOPs).
  typedef enum logic [2:0] {
    SYS_NONE, SYS_CSRRW, SYS_CSRRS, SYS_CSRRC, SYS_MRET, SYS_FENCE_I
  } sys_op_e;

  function automatic logic is_serializing(sys_op_e op);
    return op != SYS_NONE;
  endfunction

  function automatic logic is_csr_op(sys_op_e op);
    return (op == SYS_CSRRW) || (op == SYS_CSRRS) || (op == SYS_CSRRC);
  endfunction

  // Control word produced by the decoder and carried in ID/EX.
  typedef struct packed {
    alu_op_e   alu_op;
    op_a_sel_e op_a_sel;
    op_b_sel_e op_b_sel;
    branch_e   branch;
    mem_op_e   mem_op;
    mem_size_e mem_size;
    logic      mem_unsigned;  // zero-extend loads
    wb_sel_e   wb_sel;
    logic      rd_we;
    logic      uses_rs1;      // for load-use detection: only real operands stall
    logic      uses_rs2;
    sys_op_e   sys_op;        // serializing operation (P2.3)
    logic      csr_we;        // the CSR instruction writes its CSR (P2.4)
  } ctrl_t;

  // Synchronous exception flags, carried down the pipeline to the commit point
  // (end of MEM), where they become a trap (P2.5). Load/store access faults
  // are not flags: they arrive with the D-port response in MEM.
  typedef struct packed {
    logic illegal;        // undecodable or reserved encoding, bad CSR access
    logic if_fault;       // fetch outside the executable region, or I-port err
    logic if_misaligned;  // taken branch/jump to a target not 4-byte aligned
    logic ld_misaligned;
    logic st_misaligned;
    logic ecall;
    logic ebreak;
  } exc_t;

  // ===========================================================================
  // Machine-mode CSRs, exception and interrupt codes (architecture.md P2.2)
  // ===========================================================================
  typedef logic [11:0] csr_addr_t;

  localparam csr_addr_t CSR_MSTATUS   = 12'h300;
  localparam csr_addr_t CSR_MISA      = 12'h301;
  localparam csr_addr_t CSR_MIE       = 12'h304;
  localparam csr_addr_t CSR_MTVEC     = 12'h305;
  localparam csr_addr_t CSR_MSTATUSH  = 12'h310;
  localparam csr_addr_t CSR_MSCRATCH  = 12'h340;
  localparam csr_addr_t CSR_MEPC      = 12'h341;
  localparam csr_addr_t CSR_MCAUSE    = 12'h342;
  localparam csr_addr_t CSR_MTVAL     = 12'h343;
  localparam csr_addr_t CSR_MIP       = 12'h344;
  localparam csr_addr_t CSR_TSELECT   = 12'h7A0;  // Sdtrig "no triggers" stubs (D-025)
  localparam csr_addr_t CSR_TDATA1    = 12'h7A1;
  localparam csr_addr_t CSR_TDATA2    = 12'h7A2;
  localparam csr_addr_t CSR_MCYCLE    = 12'hB00;
  localparam csr_addr_t CSR_MINSTRET  = 12'hB02;
  localparam csr_addr_t CSR_MCYCLEH   = 12'hB80;
  localparam csr_addr_t CSR_MINSTRETH = 12'hB82;
  localparam csr_addr_t CSR_CYCLE     = 12'hC00;
  localparam csr_addr_t CSR_INSTRET   = 12'hC02;
  localparam csr_addr_t CSR_CYCLEH    = 12'hC80;
  localparam csr_addr_t CSR_INSTRETH  = 12'hC82;
  localparam csr_addr_t CSR_MVENDORID = 12'hF11;
  localparam csr_addr_t CSR_MARCHID   = 12'hF12;
  localparam csr_addr_t CSR_MIMPID    = 12'hF13;
  localparam csr_addr_t CSR_MHARTID   = 12'hF14;

  // Every CSR listed above exists; any other address is illegal (P2.4).
  function automatic logic csr_exists(csr_addr_t a);
    unique case (a)
      CSR_MSTATUS, CSR_MISA, CSR_MIE, CSR_MTVEC, CSR_MSTATUSH,
      CSR_MSCRATCH, CSR_MEPC, CSR_MCAUSE, CSR_MTVAL, CSR_MIP,
      CSR_TSELECT, CSR_TDATA1, CSR_TDATA2,
      CSR_MCYCLE, CSR_MINSTRET, CSR_MCYCLEH, CSR_MINSTRETH,
      CSR_CYCLE, CSR_INSTRET, CSR_CYCLEH, CSR_INSTRETH,
      CSR_MVENDORID, CSR_MARCHID, CSR_MIMPID, CSR_MHARTID: return 1'b1;
      default:                                              return 1'b0;
    endcase
  endfunction

  // Privileged spec: addresses with [11:10] = 11 are read-only; writing one is
  // illegal (a write to a read-only *field* of an RW CSR is not). Only those
  // two address bits matter, hence the waiver.
  /* verilator lint_off UNUSEDSIGNAL */
  function automatic logic csr_read_only(csr_addr_t a);
    return a[11:10] == 2'b11;
  endfunction
  /* verilator lint_on UNUSEDSIGNAL */

  // Field positions. The interrupt bit positions in mie/mip equal the
  // interrupt cause codes (IRQ_* below).
  localparam int unsigned MSTATUS_MIE  = 3;
  localparam int unsigned MSTATUS_MPIE = 7;
  localparam int unsigned MIP_MSIP     = 3;   // also MIE.MSIE
  localparam int unsigned MIP_MTIP     = 7;   // also MIE.MTIE
  localparam int unsigned MIP_MEIP     = 11;  // also MIE.MEIE
  localparam word_t       MSTATUS_MPP  = 32'h0000_1800;  // read-only 11 (M)
  localparam word_t       MISA_VALUE   = 32'h4000_0100;  // MXL=1 (RV32), I

  typedef logic [3:0] exc_code_t;

  localparam exc_code_t IRQ_MSI = 4'd3;
  localparam exc_code_t IRQ_MTI = 4'd7;
  localparam exc_code_t IRQ_MEI = 4'd11;

  localparam exc_code_t EXC_INSTR_MISALIGNED = 4'd0;
  localparam exc_code_t EXC_INSTR_ACCESS     = 4'd1;
  localparam exc_code_t EXC_ILLEGAL          = 4'd2;
  localparam exc_code_t EXC_BREAKPOINT       = 4'd3;
  localparam exc_code_t EXC_LOAD_MISALIGNED  = 4'd4;
  localparam exc_code_t EXC_LOAD_ACCESS      = 4'd5;
  localparam exc_code_t EXC_STORE_MISALIGNED = 4'd6;
  localparam exc_code_t EXC_STORE_ACCESS     = 4'd7;
  localparam exc_code_t EXC_ECALL_M          = 4'd11;

  // ---------------------------------------------------------------------------
  // Pipeline registers
  // ---------------------------------------------------------------------------
  typedef struct packed {
    logic  valid;
    word_t pc;
    inst_t instr;
    exc_t  exc;
  } if_id_t;

  typedef struct packed {
    logic      valid;
    word_t     pc;
    inst_t     instr;
    reg_addr_t rs1;
    reg_addr_t rs2;
    reg_addr_t rd;
    word_t     rs1_data;
    word_t     rs2_data;
    word_t     imm;
    ctrl_t     ctrl;
    exc_t      exc;
  } id_ex_t;

  typedef struct packed {
    logic      valid;
    word_t     pc;
    word_t     next_pc;       // architectural successor (Phase 2: mepc on interrupt)
    inst_t     instr;
    reg_addr_t rd;
    logic      rd_we;
    word_t     result;        // ALU result, link address, or load/store address
    mem_op_e   mem_op;
    mem_size_e mem_size;
    logic      mem_unsigned;
    logic [1:0] addr_off;     // byte offset within the word, for load extract
    logic      req_sent;      // the D-port request was accepted in EX (4.6)
    wb_sel_e   wb_sel;
    sys_op_e   sys_op;
    logic      csr_we;
    exc_t      exc;
    exc_code_t exc_cause;     // mcause code of the highest-priority flag in exc
    word_t     tval;          // mtval for exc, or the load/store address
  } ex_mem_t;

  typedef struct packed {
    logic      valid;
    word_t     pc;
    inst_t     instr;
    reg_addr_t rd;
    logic      rd_we;
    word_t     wdata;
    logic      trap;          // the instruction trapped instead of retiring
  } mem_wb_t;

  // ---------------------------------------------------------------------------
  // Memory ports (docs/architecture.md section 2)
  // ---------------------------------------------------------------------------
  typedef struct packed {
    word_t      addr;   // byte address; `be` selects the lanes
    logic       we;
    logic [3:0] be;
    word_t      wdata;  // store data replicated across the word
  } mem_req_t;

  typedef struct packed {
    word_t rdata;
    logic  err;
  } mem_rsp_t;

  // ---------------------------------------------------------------------------
  // Load/store alignment helpers
  // ---------------------------------------------------------------------------
  function automatic logic is_misaligned(mem_size_e size, logic [1:0] off);
    unique case (size)
      SIZE_H:  return off[0];
      SIZE_W:  return off != 2'b00;
      default: return 1'b0;
    endcase
  endfunction

  function automatic logic [3:0] byte_enable(mem_size_e size, logic [1:0] off);
    unique case (size)
      SIZE_B:  return 4'b0001 << off;
      SIZE_H:  return off[1] ? 4'b1100 : 4'b0011;
      default: return 4'b1111;
    endcase
  endfunction

  // Store data replicated to every lane; the byte enables pick the lane(s).
  function automatic word_t store_data(mem_size_e size, word_t data);
    unique case (size)
      SIZE_B:  return {4{data[7:0]}};
      SIZE_H:  return {2{data[15:0]}};
      default: return data;
    endcase
  endfunction

  // Extract and sign/zero-extend a loaded byte/halfword/word.
  function automatic word_t load_extract(mem_size_e size, logic uns, word_t rdata,
                                         logic [1:0] off);
    logic [15:0] half  = off[1] ? rdata[31:16] : rdata[15:0];
    logic [7:0]  byte8 = off[0] ? half[15:8]   : half[7:0];
    unique case (size)
      SIZE_B:  return uns ? {24'b0, byte8} : {{24{byte8[7]}}, byte8};
      SIZE_H:  return uns ? {16'b0, half}  : {{16{half[15]}}, half};
      default: return rdata;
    endcase
  endfunction

  /* verilator lint_on UNUSEDPARAM */

endpackage : riscv_pkg
