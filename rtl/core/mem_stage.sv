// =============================================================================
// mem_stage
// -----------------------------------------------------------------------------
// Purpose    : Memory stage and commit point (docs/architecture.md 4.6, P2.3,
//              P2.5). Receives the D-port response for the instruction in MEM,
//              extracts/extends load data, and decides, for that instruction:
//                * trap_take  : it raises an exception (flag from an earlier
//                               stage, or an access fault in the response);
//                * irq_take   : it commits and an enabled interrupt is taken
//                               after it (never on a serializing instruction,
//                               nor while EX holds an unaccepted D request);
//                * ser_commit : a CSR instruction, MRET or FENCE.I commits.
//              Each of the three flushes IF/ID/EX (kill_ex) and redirects
//              fetch. It drives the CSR file's commit-point commands and forms
//              the MEM/WB contents.
// Interfaces : ex_mem_i, D-port response, CSR file state -> mem_wb_o, the
//              kill/redirect outputs, CSR commands, and mem_wait_o /
//              rsp_err_o for the issue rule and stall (4.6).
// Timing     : * Everything about the response is keyed on ex_mem_i.req_sent:
//                an instruction that never sent a request (e.g. a misaligned
//                load) never waits for a response.
//              * The response channel has no ready, so a response arriving
//                while the pipeline is stalled (MEM cannot advance) is captured
//                in rsp_held_q/rsp_q and used when MEM advances.
//              * trap_take/irq_take/ser_commit do not depend on advance_i
//                (the stall), because the stall depends on them through the
//                issue rule. Whenever one of them is 1 the stall is 0, so the
//                instruction leaves MEM in that cycle.
// =============================================================================
module mem_stage
  import riscv_pkg::*;
(
  input  logic      clk_i,
  // rst_ni is also sampled by the simulation-only assertions (disable iff),
  // which Verilator reports as a synchronous use of an async reset.
  /* verilator lint_off SYNCASYNCNET */
  input  logic      rst_ni,
  /* verilator lint_on SYNCASYNCNET */

  input  ex_mem_t   ex_mem_i,
  input  logic      advance_i,        // MEM/WB loads this cycle (!stall)

  input  logic      dmem_rsp_valid_i,
  input  mem_rsp_t  dmem_rsp_i,

  // CSR file state
  input  word_t     csr_rdata_i,      // CSR addressed by ex_mem_i.instr[31:20]
  input  logic      irq_pend_i,
  input  exc_code_t irq_code_i,
  input  logic      irq_block_i,      // EX holds an unaccepted D request (D-033)
  input  word_t     mtvec_i,
  input  word_t     mepc_i,

  output logic      mem_wait_o,       // sent a request, response not here yet
  output logic      rsp_err_o,        // sent a request, response carries err

  // Commit decisions
  output logic      can_commit_o,     // valid, not waiting, no exception
  output logic      trap_take_o,
  output logic      irq_take_o,
  output logic      ser_commit_o,
  output logic      kill_o,           // trap_take || irq_take || ser_commit
  output word_t     redirect_pc_o,    // fetch target when kill_o

  // CSR file commands
  output logic      csr_we_o,
  output word_t     csr_wdata_o,
  output logic      trap_o,
  output logic      trap_irq_o,
  output exc_code_t trap_code_o,
  output word_t     trap_epc_o,
  output word_t     trap_tval_o,
  output logic      mret_o,
  output logic      retire_o,

  output mem_wb_t   mem_wb_o
);

  // ---------------------------------------------------------------------------
  // Response capture
  // ---------------------------------------------------------------------------
  logic     rsp_held_q;
  mem_rsp_t rsp_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      rsp_held_q <= 1'b0;
      rsp_q      <= '0;
    end else if (advance_i) begin
      rsp_held_q <= 1'b0;
    end else if (dmem_rsp_valid_i) begin
      rsp_held_q <= 1'b1;
      rsp_q      <= dmem_rsp_i;
    end
  end

  logic     rsp_present;
  mem_rsp_t rsp;

  assign rsp_present = dmem_rsp_valid_i || rsp_held_q;
  assign rsp         = rsp_held_q ? rsp_q : dmem_rsp_i;

  assign mem_wait_o  = ex_mem_i.valid && ex_mem_i.req_sent && !rsp_present;
  assign rsp_err_o   = ex_mem_i.valid && ex_mem_i.req_sent && rsp_present && rsp.err;

  // ---------------------------------------------------------------------------
  // Commit decisions (P2.5)
  // ---------------------------------------------------------------------------
  logic exc_valid, serial;

  assign exc_valid    = ex_mem_i.valid && ((ex_mem_i.exc != '0) || rsp_err_o);
  assign serial       = is_serializing(ex_mem_i.sys_op);
  assign can_commit_o = ex_mem_i.valid && !mem_wait_o && !exc_valid;

  assign trap_take_o  = exc_valid;                          // exceptions beat interrupts
  // Not on a serializing instruction (P2.5), and not while EX holds an
  // asserted, unaccepted D-port request that kill_ex would withdraw (D-033).
  assign irq_take_o   = irq_pend_i && can_commit_o && !serial && !irq_block_i;
  assign ser_commit_o = can_commit_o && serial;
  assign kill_o       = trap_take_o || irq_take_o || ser_commit_o;

  always_comb begin
    if (trap_take_o || irq_take_o)           redirect_pc_o = mtvec_i;   // direct mode
    else if (ex_mem_i.sys_op == SYS_MRET)    redirect_pc_o = mepc_i;
    else                                     redirect_pc_o = ex_mem_i.next_pc;  // pc + 4
  end

  // ---------------------------------------------------------------------------
  // CSR file commands
  // ---------------------------------------------------------------------------
  // CSR instruction: the operand (rs1 or uimm) arrives in ex_mem.result.
  always_comb begin
    unique case (ex_mem_i.sys_op)
      SYS_CSRRS: csr_wdata_o = csr_rdata_i | ex_mem_i.result;
      SYS_CSRRC: csr_wdata_o = csr_rdata_i & ~ex_mem_i.result;
      default:   csr_wdata_o = ex_mem_i.result;                 // SYS_CSRRW
    endcase
  end
  assign csr_we_o = ser_commit_o && is_csr_op(ex_mem_i.sys_op) && ex_mem_i.csr_we;
  assign mret_o   = ser_commit_o && (ex_mem_i.sys_op == SYS_MRET);

  // Trap entry: an exception uses the cause/tval chosen in EX, or an access
  // fault from the response (tval = the address, carried in ex_mem.tval).
  always_comb begin
    trap_o      = trap_take_o || irq_take_o;
    trap_irq_o  = !trap_take_o;
    trap_epc_o  = trap_take_o ? ex_mem_i.pc : ex_mem_i.next_pc;
    trap_tval_o = trap_take_o ? ex_mem_i.tval : '0;
    if (!trap_take_o)             trap_code_o = irq_code_i;
    else if (ex_mem_i.exc != '0)  trap_code_o = ex_mem_i.exc_cause;
    else if (ex_mem_i.mem_op == MEM_STORE) trap_code_o = EXC_STORE_ACCESS;
    else                          trap_code_o = EXC_LOAD_ACCESS;
  end

  // Retirement: the instruction leaves MEM without an exception. This includes
  // an instruction that carries an interrupt.
  assign retire_o = can_commit_o && advance_i;

  // ---------------------------------------------------------------------------
  // MEM/WB
  // ---------------------------------------------------------------------------
  word_t load_data;
  assign load_data = load_extract(ex_mem_i.mem_size, ex_mem_i.mem_unsigned,
                                  rsp.rdata, ex_mem_i.addr_off);

  always_comb begin
    mem_wb_o       = '0;
    mem_wb_o.valid = ex_mem_i.valid;
    mem_wb_o.pc    = ex_mem_i.pc;
    mem_wb_o.instr = ex_mem_i.instr;
    mem_wb_o.rd    = ex_mem_i.rd;
    // An instruction that traps never writes the register file.
    mem_wb_o.rd_we = ex_mem_i.rd_we && !exc_valid;
    mem_wb_o.trap  = exc_valid;
    unique case (ex_mem_i.wb_sel)
      WB_MEM:  mem_wb_o.wdata = load_data;
      WB_CSR:  mem_wb_o.wdata = csr_rdata_i;               // old CSR value
      default: mem_wb_o.wdata = ex_mem_i.result;
    endcase
  end

`ifndef SYNTHESIS
  // At most one D-port request is in flight, and it belongs to MEM (4.6).
  a_rsp_owner: assert property (@(posedge clk_i) disable iff (!rst_ni)
                                dmem_rsp_valid_i |-> (ex_mem_i.valid && ex_mem_i.req_sent && !rsp_held_q))
    else $fatal(1, "[mem_stage] D-port response with no request outstanding in MEM");

  // P2.5 rules, checked on the implementation.
  a_no_irq_on_serial: assert property (@(posedge clk_i) disable iff (!rst_ni)
                                       !(irq_take_o && serial))
    else $fatal(1, "[mem_stage] interrupt taken on a serializing instruction");
  a_trap_irq_excl: assert property (@(posedge clk_i) disable iff (!rst_ni)
                                    !(trap_take_o && irq_take_o))
    else $fatal(1, "[mem_stage] exception and interrupt taken in the same cycle");
  a_kill_advances: assert property (@(posedge clk_i) disable iff (!rst_ni)
                                    kill_o |-> advance_i)
    else $fatal(1, "[mem_stage] trap/interrupt/serializing commit while stalled");
  // A serializing instruction is never an exception: an exception flag gives
  // the decoder's NOP control word (sys_op = SYS_NONE).
  a_serial_no_exc: assert property (@(posedge clk_i) disable iff (!rst_ni)
                                    !(ex_mem_i.valid && serial && exc_valid))
    else $fatal(1, "[mem_stage] serializing instruction with an exception");
`endif

endmodule : mem_stage
