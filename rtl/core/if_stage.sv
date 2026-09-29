// =============================================================================
// if_stage
// -----------------------------------------------------------------------------
// Purpose    : Decoupled fetch unit (docs/architecture.md 3.1, 3.2).
//              Issues I-port requests under a credit limit, discards responses
//              made stale by a redirect (counter `drop_q`), buffers returned
//              instructions in a 2-entry fetch queue, and presents the oldest
//              one to ID. Fetch only targets the executable region; any other
//              address yields a local fetch-fault entry and no bus request.
// Interfaces : I-port (valid/ready request, valid-only response);
//              redirect_i/redirect_pc_i from EX; if_o/pop_i towards ID.
// Timing     : * imem_req_valid_o never depends on imem_req_ready_i or on the
//                pipeline stall (protocol rule 2); it depends on registered
//                state, the response valid, and the redirect.
//              * A redirect issues the target in the same cycle when there is
//                credit and no request is pending (2-cycle branch penalty).
//              * An unaccepted request is held in `pend_q` so its valid and
//                address stay stable until accepted (protocol rule 1). A
//                redirect while a request is pending marks it stale.
//              * When the queue is empty, a live response bypasses to ID in
//                the cycle it arrives.
// =============================================================================
module if_stage
  import riscv_pkg::*;
#(
  parameter word_t RESET_PC  = soc_pkg::RESET_PC,
  parameter word_t EXEC_BASE = soc_pkg::MEM_BASE,
  parameter word_t EXEC_SIZE = soc_pkg::MEM_SIZE
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

  // Redirect: taken branch/JAL/JALR in EX, or from the commit point (trap,
  // interrupt, CSR*/MRET/FENCE.I), architecture.md P2.7
  input  logic     redirect_i,
  input  word_t    redirect_pc_i,

  // Towards ID
  output if_id_t   if_o,      // if_o.valid: an instruction is available
  input  logic     pop_i      // ID takes if_o this cycle (ignored if !if_o.valid)
);

  // ---------------------------------------------------------------------------
  // State
  // ---------------------------------------------------------------------------
  typedef struct packed {
    word_t pc;
    inst_t instr;
    logic  fault;
  } fq_entry_t;

  localparam int unsigned FQ_DEPTH = 2;

  fq_entry_t  fq_q [FQ_DEPTH];
  logic [1:0] fq_cnt_q;        // 0..2 entries
  logic [1:0] inflight_q;      // accepted requests without a response, 0..2
  logic [1:0] drop_q;          // how many of those are stale, <= inflight_q
  word_t      fetch_pc_q;      // next address to request
  word_t      rsp_pc_q;        // pc of the next live response
  logic       pend_q;          // a request is asserted but not yet accepted
  logic       pend_stale_q;    // ...and a redirect has made it stale
  word_t      pend_addr_q;
  logic       paused_q;        // a local fetch-fault entry was created

  // ---------------------------------------------------------------------------
  // Request side
  // ---------------------------------------------------------------------------
  function automatic logic in_exec(word_t addr);
    return (addr - EXEC_BASE) < EXEC_SIZE;
  endfunction

  logic  rsp_fire, req_fire, credit, fetch_en, issue_new, fire_stale;
  logic  rsp_stale, rsp_live, fault_create;
  word_t new_addr;

  assign rsp_fire = imem_rsp_valid_i;
  assign new_addr = redirect_i ? redirect_pc_i : fetch_pc_q;

  // Credit: never more requests in flight than the queue can absorb (3.1/3.2).
  // On a redirect the queue is being cleared, so only in-flight requests count.
  assign credit = redirect_i
                ? ((inflight_q - {1'b0, rsp_fire}) < 2'd2)
                : (({1'b0, fq_cnt_q} + {1'b0, inflight_q}) < 3'd2);

  assign fetch_en  = !paused_q || redirect_i;
  assign issue_new = !pend_q && fetch_en && credit && in_exec(new_addr);

  assign imem_req_valid_o = pend_q || issue_new;
  assign imem_req_o = '{
    addr:  pend_q ? pend_addr_q : new_addr,
    we:    1'b0,
    be:    4'b1111,
    wdata: '0
  };

  assign req_fire   = imem_req_valid_o && imem_req_ready_i;
  // A pending (old-path) request accepted after, or in the cycle of, a redirect.
  assign fire_stale = req_fire && pend_q && (pend_stale_q || redirect_i);

  // ---------------------------------------------------------------------------
  // Response side
  // ---------------------------------------------------------------------------
  assign rsp_stale = rsp_fire && ((drop_q != '0) || redirect_i);
  assign rsp_live  = rsp_fire && !rsp_stale;

  // Local fetch-fault entry (3.1): only when nothing at all is in flight or
  // pending, so it is ordered behind every older fetch; never in a redirect
  // cycle (the redirect would discard it anyway).
  assign fault_create = !redirect_i && !paused_q && !pend_q && !in_exec(fetch_pc_q)
                     && (inflight_q == '0) && (fq_cnt_q < 2'd2);

  // ---------------------------------------------------------------------------
  // Output to ID: queue head, or a live response bypassing an empty queue.
  // Nothing is delivered in a redirect cycle (the redirect flushes IF).
  // ---------------------------------------------------------------------------
  logic      head_from_q, pop;
  fq_entry_t head;

  assign head_from_q = (fq_cnt_q != '0);
  assign head = head_from_q ? fq_q[0]
                            : '{pc: rsp_pc_q, instr: imem_rsp_i.rdata, fault: imem_rsp_i.err};

  always_comb begin
    if_o              = '0;
    if_o.valid        = !redirect_i && (head_from_q || rsp_live);
    if_o.pc           = head.pc;
    if_o.instr        = head.fault ? '0 : head.instr;
    if_o.exc.if_fault = head.fault;
  end

  assign pop = pop_i && if_o.valid;

  // ---------------------------------------------------------------------------
  // Next state
  // ---------------------------------------------------------------------------
  fq_entry_t  fq_d [FQ_DEPTH];
  logic [1:0] fq_cnt_d;

  always_comb begin
    fq_d     = fq_q;
    fq_cnt_d = fq_cnt_q;
    if (redirect_i) begin
      fq_cnt_d = '0;                                   // discard every entry
    end else begin
      if (pop && head_from_q) begin
        fq_d[0]  = fq_q[1];
        fq_cnt_d = fq_cnt_d - 2'd1;
      end
      if (rsp_live && !(pop && !head_from_q)) begin    // not consumed by bypass
        fq_d[fq_cnt_d[0]] = '{pc: rsp_pc_q, instr: imem_rsp_i.rdata, fault: imem_rsp_i.err};
        fq_cnt_d          = fq_cnt_d + 2'd1;
      end else if (fault_create) begin
        fq_d[fq_cnt_d[0]] = '{pc: fetch_pc_q, instr: '0, fault: 1'b1};
        fq_cnt_d          = fq_cnt_d + 2'd1;
      end
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      fq_q         <= '{default: '0};
      fq_cnt_q     <= '0;
      inflight_q   <= '0;
      drop_q       <= '0;
      fetch_pc_q   <= RESET_PC;
      rsp_pc_q     <= RESET_PC;
      pend_q       <= 1'b0;
      pend_stale_q <= 1'b0;
      pend_addr_q  <= '0;
      paused_q     <= 1'b0;
    end else begin
      fq_q       <= fq_d;
      fq_cnt_q   <= fq_cnt_d;
      inflight_q <= inflight_q + {1'b0, req_fire} - {1'b0, rsp_fire};

      // Stale-response counter (3.2)
      drop_q <= (redirect_i ? (inflight_q - {1'b0, rsp_fire})
                            : (drop_q - {1'b0, rsp_fire && (drop_q != '0)}))
              + {1'b0, fire_stale};

      // Held request (protocol rule 1)
      if (req_fire) begin
        pend_q       <= 1'b0;
        pend_stale_q <= 1'b0;
      end else if (issue_new) begin
        pend_q       <= 1'b1;
        pend_stale_q <= 1'b0;
        pend_addr_q  <= new_addr;
      end else if (pend_q) begin
        pend_stale_q <= pend_stale_q || redirect_i;
      end

      // Next fetch address: advances once a request is committed to the port;
      // otherwise a redirect target waits here for credit.
      if (issue_new)       fetch_pc_q <= new_addr + 32'd4;
      else if (redirect_i) fetch_pc_q <= redirect_pc_i;

      if (redirect_i)    rsp_pc_q <= redirect_pc_i;
      else if (rsp_live) rsp_pc_q <= rsp_pc_q + 32'd4;

      if (redirect_i)        paused_q <= 1'b0;
      else if (fault_create) paused_q <= 1'b1;
    end
  end

`ifndef SYNTHESIS
  // Internal invariants of the credit scheme.
  a_inflight: assert property (@(posedge clk_i) disable iff (!rst_ni) inflight_q <= 2'd2)
    else $fatal(1, "[if_stage] inflight_q overflow");
  a_fq_cnt:   assert property (@(posedge clk_i) disable iff (!rst_ni) fq_cnt_d <= 2'd2)
    else $fatal(1, "[if_stage] push into a full fetch queue");
  a_drop:     assert property (@(posedge clk_i) disable iff (!rst_ni) drop_q <= inflight_q)
    else $fatal(1, "[if_stage] drop_q > inflight_q");
  a_rsp:      assert property (@(posedge clk_i) disable iff (!rst_ni) !rsp_fire || (inflight_q != '0))
    else $fatal(1, "[if_stage] I-port response with no request in flight");
`endif

endmodule : if_stage
