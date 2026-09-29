// =============================================================================
// hazard_unit
// -----------------------------------------------------------------------------
// Purpose    : Pipeline control (docs/architecture.md 4.2-4.6):
//              * load-use detection (1-cycle IF/ID hold + bubble into EX);
//              * the data-request issue rule: a D-port request leaves the core
//                only if the instruction issuing it is certain to commit;
//              * the global stall (D-side only);
//              * the redirect/flush_id: from MEM (trap, interrupt, serializing
//                commit; kill_ex_i) or from EX (taken branch/jump), fired once
//                per EX instruction even while stalled. MEM wins (P2.7).
// Interfaces : see ports. kill_ex_i = trap_take || irq_take || ser_commit from
//              the commit point (architecture.md P2.5).
//              irq_block_o: EX asserted a D-port request last cycle that was
//              not accepted. Protocol rule 1 forbids withdrawing it, so the
//              commit point must not take an interrupt (the only kill that can
//              still arise while it is held; D-033).
// Timing     : dmem_req_valid_o depends only on pipeline registers, the
//              D-response valid/err, the EX exception flags and kill_ex_i:
//              never on any ready (protocol rule 2). Only stall_o uses
//              dmem_req_ready_i, and stall_o feeds no valid signal.
// =============================================================================
module hazard_unit
  import riscv_pkg::*;
(
  input  logic      clk_i,
  input  logic      rst_ni,

  // ID
  input  logic      id_valid_i,
  input  reg_addr_t id_rs1_i,
  input  reg_addr_t id_rs2_i,
  input  logic      id_uses_rs1_i,
  input  logic      id_uses_rs2_i,

  // EX
  input  logic      ex_valid_i,
  input  logic      ex_is_load_i,
  input  reg_addr_t ex_rd_i,
  input  logic      ex_mem_op_i,       // valid load/store in EX
  input  logic      ex_self_exc_i,     // EX instruction will trap
  input  logic      ex_redirect_i,     // EX wants to redirect (taken, legal)

  // MEM
  input  logic      mem_valid_i,
  input  logic      mem_exc_i,         // MEM instruction carries an exception
  input  logic      mem_wait_i,        // MEM sent a request, no response yet
  input  logic      mem_rsp_err_i,     // MEM sent a request, response has err
  input  logic      mem_serial_i,      // MEM holds a CSR op, MRET or FENCE.I

  // Trap, interrupt or serializing commit at the commit point: flushes
  // IF/ID/EX and redirects fetch from MEM
  input  logic      kill_ex_i,

  input  logic      dmem_req_ready_i,

  output logic      load_use_o,
  output logic      mem_unsafe_o,
  output logic      dmem_req_valid_o,
  output logic      stall_o,
  output logic      redirect_o,        // = flush_id; to the fetch unit
  output logic      ex_redirect_fire_o,// the EX branch/jump redirects this cycle
  output logic      irq_block_o        // a D-port request is held unaccepted
);

  // Load-use (4.2)
  assign load_use_o = id_valid_i && ex_valid_i && ex_is_load_i && (ex_rd_i != '0)
                   && ((id_uses_rs1_i && (id_rs1_i == ex_rd_i))
                    || (id_uses_rs2_i && (id_rs2_i == ex_rd_i)));

  // Issue rule and global stall (4.6)
  logic ex_issue_wait;

  assign mem_unsafe_o     = mem_valid_i && (mem_exc_i || mem_wait_i || mem_rsp_err_i
                                             || mem_serial_i);
  assign dmem_req_valid_o = ex_mem_op_i && !ex_self_exc_i && !mem_unsafe_o && !kill_ex_i;
  assign ex_issue_wait    = ex_mem_op_i && !ex_self_exc_i && !kill_ex_i
                         && !(dmem_req_valid_o && dmem_req_ready_i);
  assign stall_o          = mem_wait_i || ex_issue_wait;

  // A request asserted without ready must stay asserted (protocol rule 1).
  // While it is held, MEM is frozen and was safe at issue (no exception, not
  // waiting, not serializing), so only an interrupt could raise kill_ex:
  // irq_block_o defers it until the request is accepted (D-033). Registered,
  // so dmem_req_valid_o still never depends combinationally on ready.
  logic dreq_hold_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) dreq_hold_q <= 1'b0;
    else         dreq_hold_q <= dmem_req_valid_o && !dmem_req_ready_i;
  end

  assign irq_block_o = dreq_hold_q;

  // An EX redirect fires once per EX instruction, even while the pipeline is
  // stalled (4.3): ex_redirected_q remembers that it already fired. A redirect
  // from MEM (kill_ex_i) wins and discards the EX one: the branch is flushed.
  // kill_ex_i implies !stall_o, so ex_redirected_q is also cleared then.
  logic ex_redirected_q;

  assign ex_redirect_fire_o = ex_redirect_i && !ex_redirected_q && !kill_ex_i;
  assign redirect_o         = kill_ex_i || ex_redirect_fire_o;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni)      ex_redirected_q <= 1'b0;
    else if (stall_o) ex_redirected_q <= ex_redirected_q || ex_redirect_fire_o;  // EX held
    else              ex_redirected_q <= 1'b0;                                  // EX changes
  end

endmodule : hazard_unit
