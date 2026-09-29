// =============================================================================
// core_top
// -----------------------------------------------------------------------------
// Purpose    : 5-stage RV32I + Zicsr + Zifencei pipeline (IF, ID, EX, MEM,
//              WB) with M-mode CSRs, precise traps and interrupts. Instantiates
//              the stages and the CSR file, holds the four pipeline registers
//              and applies stall/flush with the priorities of
//              docs/architecture.md 4.5.
// Interfaces : clk_i, rst_ni (async assert, sync de-assert, synchronised
//              outside); instruction and data ports (valid/ready request,
//              valid-only response, in-order, >= 1 cycle latency; section 2);
//              level-sensitive interrupt lines MSIP/MTIP/MEIP (synchronous to
//              clk_i).
// Timing     : * stall comes only from the D-side (4.4/4.6) and holds all
//                four pipeline registers; the fetch unit keeps running.
//              * redirect (flush_id) beats stall on IF/ID; load-use holds
//                IF/ID and inserts a bubble into EX for exactly one cycle.
//              * the commit point is the end of MEM (P2.5): a trap, an
//                interrupt or a serializing instruction (CSR*, MRET, FENCE.I)
//                there raises kill_ex, which flushes IF/ID/EX, blocks EX's
//                D-port request and redirects fetch (MEM beats EX).
//              * register-file writes happen in WB; the regfile bypasses
//                them to ID in the same cycle.
// =============================================================================
module core_top
  import riscv_pkg::*;
#(
  parameter word_t RESET_PC = soc_pkg::RESET_PC
) (
  input  logic     clk_i,
  // rst_ni is also sampled by the simulation-only assertions (disable iff),
  // which Verilator reports as a synchronous use of an async reset.
  /* verilator lint_off SYNCASYNCNET */
  input  logic     rst_ni,
  /* verilator lint_on SYNCASYNCNET */

  // Instruction port
  output logic     imem_req_valid_o,
  input  logic     imem_req_ready_i,
  output mem_req_t imem_req_o,
  input  logic     imem_rsp_valid_i,
  input  mem_rsp_t imem_rsp_i,

  // Data port
  output logic     dmem_req_valid_o,
  input  logic     dmem_req_ready_i,
  output mem_req_t dmem_req_o,
  input  logic     dmem_rsp_valid_i,
  input  mem_rsp_t dmem_rsp_i,

  // Interrupt lines (level-sensitive; CLINT/PLIC from Phase 6)
  input  logic     irq_software_i,
  input  logic     irq_timer_i,
  input  logic     irq_external_i
);

  // ---------------------------------------------------------------------------
  // Pipeline registers and control
  // ---------------------------------------------------------------------------
  if_id_t  if_id_q;
  id_ex_t  id_ex_q;
  ex_mem_t ex_mem_q;
  // mem_wb_q.pc/.instr are carried for the Phase 3 retirement (RVFI) trace and
  // are read today only by the testbench.
  /* verilator lint_off UNUSEDSIGNAL */
  mem_wb_t mem_wb_q;
  /* verilator lint_on UNUSEDSIGNAL */

  logic stall, load_use, redirect, mem_unsafe;
  logic kill_ex;           // trap_take || irq_take || ser_commit (commit point)

  // ---------------------------------------------------------------------------
  // IF
  // ---------------------------------------------------------------------------
  if_id_t if_out;
  word_t  redirect_pc, ex_redirect_pc, mem_redirect_pc;

  // MEM's redirect wins over EX's (P2.7).
  assign redirect_pc = kill_ex ? mem_redirect_pc : ex_redirect_pc;

  if_stage #(
    .RESET_PC (RESET_PC)
  ) u_if (
    .clk_i            (clk_i),
    .rst_ni           (rst_ni),
    .imem_req_valid_o (imem_req_valid_o),
    .imem_req_ready_i (imem_req_ready_i),
    .imem_req_o       (imem_req_o),
    .imem_rsp_valid_i (imem_rsp_valid_i),
    .imem_rsp_i       (imem_rsp_i),
    .redirect_i       (redirect),
    .redirect_pc_i    (redirect_pc),
    .if_o             (if_out),
    .pop_i            (!redirect && !stall && !load_use)
  );

  // IF/ID: flush_id > stall/load_use (hold) > load (a bubble if IF is empty)
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni)                 if_id_q       <= '0;
    else if (redirect)           if_id_q.valid <= 1'b0;
    else if (!stall && !load_use) if_id_q      <= if_out;
  end

  // ---------------------------------------------------------------------------
  // ID
  // ---------------------------------------------------------------------------
  reg_addr_t id_rs1, id_rs2, id_rd;
  ctrl_t     id_ctrl;
  word_t     id_imm, id_rs1_data, id_rs2_data;
  logic      id_illegal, id_ecall, id_ebreak;

  assign id_rs1 = if_id_q.instr[19:15];
  assign id_rs2 = if_id_q.instr[24:20];
  assign id_rd  = if_id_q.instr[11:7];

  decoder u_decoder (
    .instr_i   (if_id_q.instr),
    .ctrl_o    (id_ctrl),
    .imm_o     (id_imm),
    .illegal_o (id_illegal),
    .ecall_o   (id_ecall),
    .ebreak_o  (id_ebreak)
  );

  regfile u_regfile (
    .clk_i    (clk_i),
    .raddr1_i (id_rs1),
    .rdata1_o (id_rs1_data),
    .raddr2_i (id_rs2),
    .rdata2_o (id_rs2_data),
    .we_i     (mem_wb_q.valid && mem_wb_q.rd_we),
    .waddr_i  (mem_wb_q.rd),
    .wdata_i  (mem_wb_q.wdata)
  );

  id_ex_t id_out;
  always_comb begin
    id_out             = '0;
    id_out.valid       = if_id_q.valid;
    id_out.pc          = if_id_q.pc;
    id_out.instr       = if_id_q.instr;
    id_out.rs1         = id_rs1;
    id_out.rs2         = id_rs2;
    id_out.rd          = id_rd;
    id_out.rs1_data    = id_rs1_data;
    id_out.rs2_data    = id_rs2_data;
    id_out.imm         = id_imm;
    id_out.ctrl        = id_ctrl;
    id_out.exc         = if_id_q.exc;
    id_out.exc.illegal = id_illegal;
    id_out.exc.ecall   = id_ecall;
    id_out.exc.ebreak  = id_ebreak;
  end

  // ID/EX: kill_ex > stall (hold) > flush_id/load_use (bubble) > load
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni)                   id_ex_q <= '0;
    else if (kill_ex)              id_ex_q <= '0;
    else if (stall)                id_ex_q <= id_ex_q;
    else if (redirect || load_use) id_ex_q <= '0;
    else                           id_ex_q <= id_out;
  end

  // ---------------------------------------------------------------------------
  // EX
  // ---------------------------------------------------------------------------
  fwd_sel_e fwd_rs1, fwd_rs2;
  ex_mem_t  ex_out;
  logic     ex_redirect, ex_mem_op, ex_self_exc;

  forwarding_unit u_fwd (
    .ex_rs1_i      (id_ex_q.rs1),
    .ex_rs2_i      (id_ex_q.rs2),
    .exmem_valid_i (ex_mem_q.valid),
    .exmem_rd_we_i (ex_mem_q.rd_we),
    .exmem_rd_i    (ex_mem_q.rd),
    .memwb_valid_i (mem_wb_q.valid),
    .memwb_rd_we_i (mem_wb_q.rd_we),
    .memwb_rd_i    (mem_wb_q.rd),
    .fwd_rs1_o     (fwd_rs1),
    .fwd_rs2_o     (fwd_rs2)
  );

  ex_stage u_ex (
    .id_ex_i        (id_ex_q),
    .fwd_rs1_i      (fwd_rs1),
    .fwd_rs2_i      (fwd_rs2),
    .exmem_result_i (ex_mem_q.result),
    .memwb_wdata_i  (mem_wb_q.wdata),
    .ex_mem_o       (ex_out),
    .redirect_o     (ex_redirect),
    .redirect_pc_o  (ex_redirect_pc),
    .mem_op_o       (ex_mem_op),
    .self_exc_o     (ex_self_exc),
    .dmem_req_o     (dmem_req_o)
  );

  // EX/MEM: kill_ex (bubble) > stall (hold) > load
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni)      ex_mem_q <= '0;
    else if (kill_ex) ex_mem_q <= '0;
    else if (!stall) begin
      ex_mem_q          <= ex_out;
      ex_mem_q.valid    <= id_ex_q.valid;
      ex_mem_q.req_sent <= dmem_req_valid_o && dmem_req_ready_i;
    end
  end

  // ---------------------------------------------------------------------------
  // MEM (commit point) and CSR file
  // ---------------------------------------------------------------------------
  mem_wb_t   mem_out;
  logic      mem_wait, mem_rsp_err;
  logic      trap_take, irq_take;
  // can_commit/ser_commit are read by the testbench's coverage counters only.
  /* verilator lint_off UNUSEDSIGNAL */
  logic      can_commit, ser_commit;
  /* verilator lint_on UNUSEDSIGNAL */
  word_t     csr_rdata, csr_wdata, mtvec, mepc, trap_epc, trap_tval;
  logic      csr_we, csr_trap, trap_irq, mret, retire, irq_pend;
  exc_code_t irq_code, trap_code;

  mem_stage u_mem (
    .clk_i            (clk_i),
    .rst_ni           (rst_ni),
    .ex_mem_i         (ex_mem_q),
    .advance_i        (!stall),
    .dmem_rsp_valid_i (dmem_rsp_valid_i),
    .dmem_rsp_i       (dmem_rsp_i),
    .csr_rdata_i      (csr_rdata),
    .irq_pend_i       (irq_pend),
    .irq_code_i       (irq_code),
    .irq_block_i      (irq_block),
    .mtvec_i          (mtvec),
    .mepc_i           (mepc),
    .mem_wait_o       (mem_wait),
    .rsp_err_o        (mem_rsp_err),
    .can_commit_o     (can_commit),
    .trap_take_o      (trap_take),
    .irq_take_o       (irq_take),
    .ser_commit_o     (ser_commit),
    .kill_o           (kill_ex),
    .redirect_pc_o    (mem_redirect_pc),
    .csr_we_o         (csr_we),
    .csr_wdata_o      (csr_wdata),
    .trap_o           (csr_trap),
    .trap_irq_o       (trap_irq),
    .trap_code_o      (trap_code),
    .trap_epc_o       (trap_epc),
    .trap_tval_o      (trap_tval),
    .mret_o           (mret),
    .retire_o         (retire),
    .mem_wb_o         (mem_out)
  );

  csr_file #(
    .MTVEC_RESET (RESET_PC)
  ) u_csr (
    .clk_i          (clk_i),
    .rst_ni         (rst_ni),
    .irq_software_i (irq_software_i),
    .irq_timer_i    (irq_timer_i),
    .irq_external_i (irq_external_i),
    .raddr_i        (ex_mem_q.instr[31:20]),
    .rdata_o        (csr_rdata),
    .csr_we_i       (csr_we),
    .csr_wdata_i    (csr_wdata),
    .trap_i         (csr_trap),
    .trap_irq_i     (trap_irq),
    .trap_code_i    (trap_code),
    .trap_epc_i     (trap_epc),
    .trap_tval_i    (trap_tval),
    .mret_i         (mret),
    .retire_i       (retire),
    .mtvec_o        (mtvec),
    .mepc_o         (mepc),
    .irq_pend_o     (irq_pend),
    .irq_code_o     (irq_code)
  );

  // MEM/WB: stall (hold) > load
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni)     mem_wb_q <= '0;
    else if (!stall) mem_wb_q <= mem_out;
  end

  // ---------------------------------------------------------------------------
  // Hazards, issue rule, stall, redirect
  // ---------------------------------------------------------------------------
  logic ex_redirect_fire, irq_block;

  hazard_unit u_hazard (
    .clk_i            (clk_i),
    .rst_ni           (rst_ni),
    .id_valid_i       (if_id_q.valid),
    .id_rs1_i         (id_rs1),
    .id_rs2_i         (id_rs2),
    .id_uses_rs1_i    (id_ctrl.uses_rs1),
    .id_uses_rs2_i    (id_ctrl.uses_rs2),
    .ex_valid_i       (id_ex_q.valid),
    .ex_is_load_i     (id_ex_q.ctrl.mem_op == MEM_LOAD),
    .ex_rd_i          (id_ex_q.rd),
    .ex_mem_op_i      (ex_mem_op),
    .ex_self_exc_i    (ex_self_exc),
    .ex_redirect_i    (ex_redirect),
    .mem_valid_i      (ex_mem_q.valid),
    .mem_exc_i        (ex_mem_q.exc != '0),
    .mem_wait_i       (mem_wait),
    .mem_rsp_err_i    (mem_rsp_err),
    .mem_serial_i     (is_serializing(ex_mem_q.sys_op)),
    .kill_ex_i        (kill_ex),
    .dmem_req_ready_i (dmem_req_ready_i),
    .load_use_o       (load_use),
    .mem_unsafe_o     (mem_unsafe),
    .dmem_req_valid_o (dmem_req_valid_o),
    .stall_o          (stall),
    .redirect_o       (redirect),
    .ex_redirect_fire_o (ex_redirect_fire),
    .irq_block_o      (irq_block)
  );

`ifndef SYNTHESIS
  // The data-request issue rule (4.6): no D-port request while the instruction
  // in MEM could still trap, is waiting for its response or serializes, nor in
  // a cycle where a trap, interrupt or serializing commit flushes EX.
  a_no_unsafe_issue: assert property (@(posedge clk_i) disable iff (!rst_ni)
                                      !(dmem_req_valid_o && (mem_unsafe || kill_ex)))
    else $fatal(1, "[core] D-port request issued while MEM is unsafe or EX is killed");

  // Trap and interrupt entry go to the mtvec base (direct mode, P2.2).
  a_trap_target: assert property (@(posedge clk_i) disable iff (!rst_ni)
                                  (trap_take || irq_take) |-> (redirect && (redirect_pc == mtvec)))
    else $fatal(1, "[core] trap redirect target %08h is not mtvec %08h", redirect_pc, mtvec);

  // Protocol rule 1 from the core's side: a D-port request asserted without
  // ready is asserted again, unchanged, in the next cycle (D-033).
  a_dreq_stable: assert property (@(posedge clk_i) disable iff (!rst_ni)
                                  (dmem_req_valid_o && !dmem_req_ready_i) |=>
                                  (dmem_req_valid_o && $stable(dmem_req_o)))
    else $fatal(1, "[core] D-port request withdrawn or changed before acceptance");

  // kill_ex redirects, and the EX redirect never fires with it.
  a_kill_redirect: assert property (@(posedge clk_i) disable iff (!rst_ni)
                                    kill_ex |-> (redirect && !ex_redirect_fire))
    else $fatal(1, "[core] kill_ex without a MEM redirect");
`endif

endmodule : core_top
