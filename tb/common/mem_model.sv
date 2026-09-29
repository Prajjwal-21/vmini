// =============================================================================
// mem_model  (testbench only, not synthesizable)
// -----------------------------------------------------------------------------
// Purpose    : Dual-port memory for core-level simulation: an instruction port
//              and a data port onto one byte array of SIZE bytes at BASE.
// Interfaces : per port, the core memory protocol (docs/architecture.md 2):
//              valid/ready request; valid-only response, in order, at least one
//              cycle after acceptance, never combinational on the request.
// Timing     : +mem=ideal  (default) ready always 1, response exactly 1 cycle
//                          after acceptance.
//              +mem=random per port, independently: ready is dropped with
//                          probability 1/4 each cycle, and each response comes
//                          1..6 cycles after acceptance (still in order).
//                          Seeded by +seed=N (xorshift32), so every run is
//                          reproducible (D-017).
//              Accesses outside [BASE, BASE+SIZE) respond with err=1, except
//              D-port accesses to the simulation-control window
//              [SC_BASE, SC_BASE+SC_SIZE) (D-029): those are passed to sim_ctrl
//              at acceptance (sc_valid_o/sc_req_o, read data sc_rdata_i) and
//              respond like memory, without err.
//              Reads and writes take effect at acceptance.
// Checks     : protocol rule 1 on both ports: once asserted without ready,
//              req_valid stays high and the payload stays stable until accepted.
// Loading    : +hex=<file> is read with $readmemh (objcopy -O verilog output,
//              addresses relative to BASE).
// =============================================================================
module mem_model
  import riscv_pkg::*;
#(
  parameter word_t       BASE    = soc_pkg::MEM_BASE,
  parameter int unsigned SIZE    = soc_pkg::MEM_SIZE,
  parameter word_t       SC_BASE = soc_pkg::SIMCTRL_BASE,
  parameter word_t       SC_SIZE = soc_pkg::SIMCTRL_SIZE
) (
  input  logic     clk_i,
  input  logic     rst_ni,

  input  logic     imem_req_valid_i,
  output logic     imem_req_ready_o,
  input  mem_req_t imem_req_i,
  output logic     imem_rsp_valid_o,
  output mem_rsp_t imem_rsp_o,

  input  logic     dmem_req_valid_i,
  output logic     dmem_req_ready_o,
  input  mem_req_t dmem_req_i,
  output logic     dmem_rsp_valid_o,
  output mem_rsp_t dmem_rsp_o,

  // Simulation-control window (D-port only)
  output logic     sc_valid_o,     // a D-port request to the window is accepted
  output mem_req_t sc_req_o,
  input  word_t    sc_rdata_i
);

  localparam int NPORTS  = 2;   // 0 = instruction, 1 = data
  localparam int QDEPTH  = 16;
  localparam int MAX_LAT = 6;

  logic [7:0] mem [SIZE];

  bit          random_mode;
  int unsigned seed;

  initial begin
    string hex, mode;
    if ($value$plusargs("hex=%s", hex)) $readmemh(hex, mem);
    else $display("[mem_model] warning: no +hex=, memory is uninitialised");
    mode = "ideal";
    void'($value$plusargs("mem=%s", mode));
    if (mode == "random")     random_mode = 1'b1;
    else if (mode == "ideal") random_mode = 1'b0;
    else $fatal(1, "[mem_model] +mem=%s: expected ideal or random", mode);
    seed = 1;
    void'($value$plusargs("seed=%d", seed));
    $display("[mem_model] mode=%s seed=%0d", mode, seed);
  end

  // ---------------------------------------------------------------------------
  // Port views as arrays
  // ---------------------------------------------------------------------------
  logic     req_valid [NPORTS];
  mem_req_t req       [NPORTS];
  logic     ready_q   [NPORTS];
  logic     rsp_valid_q [NPORTS];
  mem_rsp_t rsp_q     [NPORTS];

  assign req_valid[0] = imem_req_valid_i;
  assign req[0]       = imem_req_i;
  assign req_valid[1] = dmem_req_valid_i;
  assign req[1]       = dmem_req_i;

  assign imem_req_ready_o = ready_q[0];
  assign dmem_req_ready_o = ready_q[1];
  assign imem_rsp_valid_o = rsp_valid_q[0];
  assign imem_rsp_o       = rsp_q[0];
  assign dmem_rsp_valid_o = rsp_valid_q[1];
  assign dmem_rsp_o       = rsp_q[1];

  function automatic logic in_sc_window(word_t addr);
    return (addr - SC_BASE) < SC_SIZE;
  endfunction

  assign sc_valid_o = dmem_req_valid_i && ready_q[1] && in_sc_window(dmem_req_i.addr);
  assign sc_req_o   = dmem_req_i;

  // ---------------------------------------------------------------------------
  // Model state. Internal bookkeeping uses blocking updates inside one clocked
  // process (a behavioural model, not RTL); the port outputs ready_q,
  // rsp_valid_q and rsp_q use non-blocking assignments so the core samples
  // them race-free, one cycle after they are decided.
  // ---------------------------------------------------------------------------
  mem_rsp_t        pq_rsp  [NPORTS][QDEPTH];
  longint unsigned pq_due  [NPORTS][QDEPTH];
  int unsigned     pq_head [NPORTS];
  int unsigned     pq_cnt  [NPORTS];
  longint unsigned last_due[NPORTS];
  logic [31:0]     rng     [NPORTS];
  logic            prev_pending [NPORTS];
  mem_req_t        prev_req     [NPORTS];
  longint unsigned cycle;

  function automatic logic [31:0] xorshift32(logic [31:0] x);
    x = x ^ (x << 13);
    x = x ^ (x >> 17);
    x = x ^ (x << 5);
    return x;
  endfunction

  function automatic mem_rsp_t access(int p, mem_req_t r);
    word_t    off = r.addr - BASE;
    word_t    a;
    mem_rsp_t rsp;
    if (p == 1 && in_sc_window(r.addr)) return '{rdata: sc_rdata_i, err: 1'b0};
    if (off >= SIZE) return '{rdata: '0, err: 1'b1};
    a = {off[31:2], 2'b00};
    if (r.we) begin
      for (int b = 0; b < 4; b++) begin
        if (r.be[b]) mem[a + b] = r.wdata[8*b +: 8];
      end
    end
    rsp.rdata = {mem[a + 3], mem[a + 2], mem[a + 1], mem[a]};
    rsp.err   = 1'b0;
    return rsp;
  endfunction

  /* verilator lint_off BLKSEQ */
  always @(posedge clk_i) begin
    if (!rst_ni) begin
      cycle = 0;
      for (int p = 0; p < NPORTS; p++) begin
        pq_head[p]      = 0;
        pq_cnt[p]       = 0;
        last_due[p]     = 0;
        rng[p]          = (seed * 32'h9E37_79B9) ^ (32'h1234_5678 + p);
        if (rng[p] == '0) rng[p] = 32'h1;
        prev_pending[p] = 1'b0;
        ready_q[p]      <= 1'b0;
        rsp_valid_q[p]  <= 1'b0;
        rsp_q[p]        <= '0;
      end
    end else begin
      // D-port first, so a store and a fetch of the same word in one cycle see
      // the store (the order is otherwise unobservable to a correct program).
      for (int p = NPORTS - 1; p >= 0; p--) begin
        // Protocol rule 1
        if (prev_pending[p]) begin
          if (!req_valid[p] || (req[p] != prev_req[p]))
            $fatal(1, "[mem_model] port %0d: request withdrawn or changed before it was accepted", p);
        end
        prev_pending[p] = req_valid[p] && !ready_q[p];
        prev_req[p]     = req[p];

        // Accept
        if (req_valid[p] && ready_q[p]) begin
          longint unsigned due;
          longint unsigned lat;
          lat = 1;
          if (random_mode) begin
            rng[p] = xorshift32(rng[p]);
            lat    = 64'(rng[p] % 32'(MAX_LAT)) + 1;
          end
          due = cycle + lat;
          if (pq_cnt[p] != 0 && due <= last_due[p]) due = last_due[p] + 1;  // in order
          if (pq_cnt[p] == QDEPTH) $fatal(1, "[mem_model] port %0d: response queue overflow", p);
          pq_rsp[p][(pq_head[p] + pq_cnt[p]) % QDEPTH] = access(p, req[p]);
          pq_due[p][(pq_head[p] + pq_cnt[p]) % QDEPTH] = due;
          pq_cnt[p]++;
          last_due[p] = due;
        end

        // Response for the next cycle
        rsp_valid_q[p] <= 1'b0;
        if (pq_cnt[p] != 0 && pq_due[p][pq_head[p]] <= cycle + 1) begin
          rsp_valid_q[p] <= 1'b1;
          rsp_q[p]       <= pq_rsp[p][pq_head[p]];
          pq_head[p]     = (pq_head[p] + 1) % QDEPTH;
          pq_cnt[p]--;
        end

        // Ready for the next cycle
        if (random_mode) begin
          rng[p]     = xorshift32(rng[p]);
          ready_q[p] <= (rng[p][1:0] != 2'b00);
        end else begin
          ready_q[p] <= 1'b1;
        end
      end
      cycle++;
    end
  end
  /* verilator lint_on BLKSEQ */

endmodule : mem_model
