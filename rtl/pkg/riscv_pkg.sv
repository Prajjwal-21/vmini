// =============================================================================
// riscv_pkg
// -----------------------------------------------------------------------------
// Purpose    : ISA-level constants for the RV32I base integer ISA: data widths,
//              major opcodes and funct3/funct7 encodings, exactly as defined by
//              the RISC-V Unprivileged ISA specification.
// Interfaces : none (package).
// Timing     : n/a.
//
// Only facts fixed by the ISA live here. Microarchitectural types (pipeline
// register structs, decoded-operation enums) are added in Phase 1, and CSR
// addresses/fields in Phase 2, once those designs are approved.
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

  // SYSTEM (funct3 = 000 selects ECALL/EBREAK/MRET/WFI via funct12)
  localparam logic [2:0] F3_PRIV = 3'b000;

  // ---------------------------------------------------------------------------
  // funct7: inst[31:25]
  // ---------------------------------------------------------------------------
  localparam logic [6:0] F7_BASE = 7'b000_0000;
  localparam logic [6:0] F7_ALT  = 7'b010_0000;  // SUB, SRA, SRAI

  /* verilator lint_on UNUSEDPARAM */

endpackage : riscv_pkg
