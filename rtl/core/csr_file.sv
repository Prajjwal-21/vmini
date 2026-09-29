// =============================================================================
// csr_file
// -----------------------------------------------------------------------------
// Purpose    : Machine-mode CSRs (docs/architecture.md P2.2, P2.5, P2.6):
//              mstatus, misa, mie, mtvec, mstatush, mscratch, mepc, mcause,
//              mtval, mip, the Sdtrig "no triggers" stubs, the 64-bit mcycle
//              and minstret counters with their read-only aliases, and the ID
//              registers. Also computes the pending-interrupt request.
// Interfaces : * read port: raddr_i -> rdata_o (combinational), used by the
//                CSR instruction committing in MEM;
//              * commit-point commands from mem_stage, applied at the end of
//                the cycle: a CSR write (csr_we_i), trap entry (trap_i), MRET
//                (mret_i), and retire_i for minstret. At most one of csr_we_i,
//                trap_i and mret_i is set in a cycle (a CSR instruction or MRET
//                never takes an interrupt, and never raises an exception);
//              * interrupt lines in, irq_pend_o / irq_code_o out.
// Timing     : * every output is a function of registers, raddr_i and the
//                interrupt lines, so the commit logic that consumes them forms
//                no loop with the commands it produces;
//              * mip is the live state of the interrupt lines (level
//                sensitive, no synchronizer: the sources are synchronous);
//              * a counter read returns the value before this cycle's (or this
//                instruction's) increment; a write to either half of a counter
//                replaces that half and suppresses the increment (P2.6).
// =============================================================================
module csr_file
  import riscv_pkg::*;
#(
  parameter word_t MTVEC_RESET = soc_pkg::RESET_PC
) (
  input  logic      clk_i,
  // rst_ni is also sampled by the simulation-only assertion (disable iff),
  // which Verilator reports as a synchronous use of an async reset.
  /* verilator lint_off SYNCASYNCNET */
  input  logic      rst_ni,
  /* verilator lint_on SYNCASYNCNET */

  // Interrupt lines (level)
  input  logic      irq_software_i,   // MSIP
  input  logic      irq_timer_i,      // MTIP
  input  logic      irq_external_i,   // MEIP

  // Read port
  input  csr_addr_t raddr_i,
  output word_t     rdata_o,

  // CSR instruction write, at commit (wdata already combined for RW/RS/RC)
  input  logic      csr_we_i,
  input  word_t     csr_wdata_i,

  // Trap entry (exception or interrupt), at commit
  input  logic      trap_i,
  input  logic      trap_irq_i,       // 1: interrupt (mcause[31])
  input  exc_code_t trap_code_i,
  // The pc is always 4-byte aligned (IALIGN = 32), so bits [1:0] are unused.
  /* verilator lint_off UNUSEDSIGNAL */
  input  word_t     trap_epc_i,
  /* verilator lint_on UNUSEDSIGNAL */
  input  word_t     trap_tval_i,

  input  logic      mret_i,
  input  logic      retire_i,         // an instruction commits (minstret)

  output word_t     mtvec_o,          // trap target (direct mode)
  output word_t     mepc_o,           // MRET target
  output logic      irq_pend_o,       // mstatus.MIE && |(mip & mie)
  output exc_code_t irq_code_o        // highest-priority pending: MEI > MSI > MTI
);

  // ---------------------------------------------------------------------------
  // State
  // ---------------------------------------------------------------------------
  logic        mie_q, mpie_q;                   // mstatus.MIE, mstatus.MPIE
  logic        meie_q, mtie_q, msie_q;          // mie
  logic [29:0] mtvec_base_q;                    // mtvec[31:2]; MODE = 0 (direct)
  word_t       mscratch_q;
  logic [29:0] mepc_q;                          // mepc[31:2]; [1:0] read 0
  logic        mcause_irq_q;                    // mcause[31]
  exc_code_t   mcause_code_q;                   // mcause[3:0]
  word_t       mtval_q;
  logic [63:0] mcycle_q, minstret_q;

  word_t mip, mie, mstatus;

  assign mip     = 32'(irq_external_i) << MIP_MEIP | 32'(irq_timer_i) << MIP_MTIP
                 | 32'(irq_software_i) << MIP_MSIP;
  assign mie     = 32'(meie_q) << MIP_MEIP | 32'(mtie_q) << MIP_MTIP | 32'(msie_q) << MIP_MSIP;
  assign mstatus = MSTATUS_MPP | 32'(mpie_q) << MSTATUS_MPIE | 32'(mie_q) << MSTATUS_MIE;

  // ---------------------------------------------------------------------------
  // Read port
  // ---------------------------------------------------------------------------
  always_comb begin
    unique case (raddr_i)
      CSR_MSTATUS:                 rdata_o = mstatus;
      CSR_MISA:                    rdata_o = MISA_VALUE;
      CSR_MIE:                     rdata_o = mie;
      CSR_MTVEC:                   rdata_o = {mtvec_base_q, 2'b00};
      CSR_MSCRATCH:                rdata_o = mscratch_q;
      CSR_MEPC:                    rdata_o = {mepc_q, 2'b00};
      CSR_MCAUSE:                  rdata_o = {mcause_irq_q, 27'b0, mcause_code_q};
      CSR_MTVAL:                   rdata_o = mtval_q;
      CSR_MIP:                     rdata_o = mip;
      CSR_MCYCLE,   CSR_CYCLE:     rdata_o = mcycle_q[31:0];
      CSR_MCYCLEH,  CSR_CYCLEH:    rdata_o = mcycle_q[63:32];
      CSR_MINSTRET, CSR_INSTRET:   rdata_o = minstret_q[31:0];
      CSR_MINSTRETH, CSR_INSTRETH: rdata_o = minstret_q[63:32];
      // mstatush, tselect/tdata1/tdata2, mvendorid/marchid/mimpid/mhartid read
      // 0. Nonexistent addresses never get here: the decoder traps them.
      default:                     rdata_o = '0;
    endcase
  end

  // ---------------------------------------------------------------------------
  // Interrupt request
  // ---------------------------------------------------------------------------
  word_t enabled;
  assign enabled    = mip & mie;
  assign irq_pend_o = mie_q && (enabled != '0);

  always_comb begin
    if      (enabled[MIP_MEIP]) irq_code_o = IRQ_MEI;
    else if (enabled[MIP_MSIP]) irq_code_o = IRQ_MSI;
    else                       irq_code_o = IRQ_MTI;
  end

  assign mtvec_o = {mtvec_base_q, 2'b00};
  assign mepc_o  = {mepc_q, 2'b00};

  // ---------------------------------------------------------------------------
  // Counters (P2.6)
  // ---------------------------------------------------------------------------
  logic [63:0] mcycle_d, minstret_d;

  always_comb begin
    mcycle_d   = mcycle_q + 64'd1;
    minstret_d = minstret_q + 64'(retire_i);
    if (csr_we_i) begin
      unique case (raddr_i)
        CSR_MCYCLE:    mcycle_d   = {mcycle_q[63:32], csr_wdata_i};
        CSR_MCYCLEH:   mcycle_d   = {csr_wdata_i, mcycle_q[31:0]};
        CSR_MINSTRET:  minstret_d = {minstret_q[63:32], csr_wdata_i};
        CSR_MINSTRETH: minstret_d = {csr_wdata_i, minstret_q[31:0]};
        default: ;
      endcase
    end
  end

  // ---------------------------------------------------------------------------
  // Registers
  // ---------------------------------------------------------------------------
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      mie_q         <= 1'b0;
      mpie_q        <= 1'b0;
      meie_q        <= 1'b0;
      mtie_q        <= 1'b0;
      msie_q        <= 1'b0;
      mtvec_base_q  <= MTVEC_RESET[31:2];
      mscratch_q    <= '0;
      mepc_q        <= '0;
      mcause_irq_q  <= 1'b0;
      mcause_code_q <= '0;
      mtval_q       <= '0;
      mcycle_q      <= '0;
      minstret_q    <= '0;
    end else begin
      mcycle_q   <= mcycle_d;
      minstret_q <= minstret_d;

      if (trap_i) begin
        mepc_q        <= trap_epc_i[31:2];
        mcause_irq_q  <= trap_irq_i;
        mcause_code_q <= trap_code_i;
        mtval_q       <= trap_tval_i;
        mpie_q        <= mie_q;
        mie_q         <= 1'b0;
      end else if (mret_i) begin
        mie_q  <= mpie_q;
        mpie_q <= 1'b1;
      end else if (csr_we_i) begin
        // Writable fields only; read-only fields and WARL CSRs (misa, mip,
        // mstatush, the trigger stubs) drop the written value.
        unique case (raddr_i)
          CSR_MSTATUS: begin
            mie_q  <= csr_wdata_i[MSTATUS_MIE];
            mpie_q <= csr_wdata_i[MSTATUS_MPIE];
          end
          CSR_MIE: begin
            meie_q <= csr_wdata_i[MIP_MEIP];
            mtie_q <= csr_wdata_i[MIP_MTIP];
            msie_q <= csr_wdata_i[MIP_MSIP];
          end
          CSR_MTVEC:    mtvec_base_q <= csr_wdata_i[31:2];
          CSR_MSCRATCH: mscratch_q   <= csr_wdata_i;
          CSR_MEPC:     mepc_q       <= csr_wdata_i[31:2];
          CSR_MCAUSE: begin
            mcause_irq_q  <= csr_wdata_i[31];
            mcause_code_q <= csr_wdata_i[3:0];
          end
          CSR_MTVAL:    mtval_q      <= csr_wdata_i;
          default: ;
        endcase
      end
    end
  end

`ifndef SYNTHESIS
  // The commit logic issues at most one state-changing command per cycle.
  a_one_cmd: assert property (@(posedge clk_i) disable iff (!rst_ni)
                              $onehot0({csr_we_i, trap_i, mret_i}))
    else $fatal(1, "[csr_file] more than one of csr_we/trap/mret in one cycle");
`endif

endmodule : csr_file
