// =============================================================================
// sim_ctrl  (testbench only, not synthesizable)
// -----------------------------------------------------------------------------
// Purpose    : Simulation-control device (docs/architecture.md P2.9, D-029).
//              Owns the three interrupt lines driven into the core and
//              provides the registers software uses to acknowledge and force
//              them:
//                0x0 IRQ_ACK   W  cause code 3/7/11: lower that line, count an ack
//                0x4 IRQ_FORCE W  bits 3/7/11: raise those lines
//                0x8 IRQ_LINES R  current line state, bits 3/7/11
//                0xC IRQ_RANDOM W 0: pause the random generator, 1: resume
//                               (reads back the state; no effect with +irq=off)
//              at soc_pkg::SIMCTRL_BASE (reserved, simulation only).
// Interfaces : acc_valid_i/acc_req_i: a D-port request in the window, in the
//              cycle mem_model accepts it; rdata_o is the read data for that
//              request (combinational on the address and the line state).
//              irq_*_o: the lines (flip-flops).
// Timing     : a write takes effect at the acceptance edge, so a line changes
//              from the cycle after acceptance.
//              Random generator (+irq=on, default off): for each line
//              independently, while the line is low wait a delay uniform in
//              [+irq_min, +irq_max] cycles (default 100..1000), then raise it;
//              it stays high until acknowledged. Seeded from +seed on a stream
//              separate from mem_model's (xorshift32), so every run is
//              reproducible.
// Checks     : acknowledging a line that is low, or an access that is not a
//              full-word access, stops the simulation.
// =============================================================================
module sim_ctrl
  import riscv_pkg::*;
(
  input  logic     clk_i,
  input  logic     rst_ni,

  input  logic     acc_valid_i,
  input  mem_req_t acc_req_i,
  output word_t    rdata_o,

  output logic     irq_software_o,
  output logic     irq_timer_o,
  output logic     irq_external_o
);

  localparam logic [11:0] OFF_ACK   = 12'h000;
  localparam logic [11:0] OFF_FORCE = 12'h004;
  localparam logic [11:0] OFF_LINES = 12'h008;
  localparam logic [11:0] OFF_RAND  = 12'h00C;

  localparam int NLINES = 3;
  localparam int unsigned LINE_BIT [NLINES] = '{MIP_MSIP, MIP_MTIP, MIP_MEIP};

  bit          gen_on;
  int unsigned seed, dly_min, dly_max;

  initial begin
    string mode;
    mode = "off";
    void'($value$plusargs("irq=%s", mode));
    if (mode == "on")       gen_on = 1'b1;
    else if (mode == "off") gen_on = 1'b0;
    else $fatal(1, "[sim_ctrl] +irq=%s: expected on or off", mode);
    seed    = 1;
    dly_min = 100;
    dly_max = 1000;
    void'($value$plusargs("seed=%d", seed));
    void'($value$plusargs("irq_min=%d", dly_min));
    void'($value$plusargs("irq_max=%d", dly_max));
    if (dly_min == 0 || dly_max < dly_min)
      $fatal(1, "[sim_ctrl] need 0 < +irq_min <= +irq_max");
    $display("[sim_ctrl] irq=%s seed=%0d delay=%0d..%0d", mode, seed, dly_min, dly_max);
  end

  // ---------------------------------------------------------------------------
  // State. Statistics are read hierarchically by the testbench.
  // ---------------------------------------------------------------------------
  logic            line_q  [NLINES];
  int unsigned     wait_q  [NLINES];     // cycles until the generator raises the line
  logic [31:0]     rng_q;
  logic            paused_q;             // IRQ_RANDOM = 0
  longint unsigned raised  [NLINES];     // low -> high transitions
  longint unsigned acked   [NLINES];
  longint unsigned forced;               // IRQ_FORCE writes

  word_t lines;
  always_comb begin
    lines = '0;
    for (int i = 0; i < NLINES; i++) lines[LINE_BIT[i]] = line_q[i];
  end

  assign irq_software_o = line_q[0];
  assign irq_timer_o    = line_q[1];
  assign irq_external_o = line_q[2];

  always_comb begin
    unique case (acc_req_i.addr[11:0])
      OFF_LINES: rdata_o = lines;
      OFF_RAND:  rdata_o = word_t'(!paused_q);
      default:   rdata_o = '0;
    endcase
  end

  function automatic logic [31:0] xorshift32(logic [31:0] x);
    x = x ^ (x << 13);
    x = x ^ (x >> 17);
    x = x ^ (x << 5);
    return x;
  endfunction

  // Uniform delay in [dly_min, dly_max], advancing the generator state.
  function automatic int unsigned next_delay(ref logic [31:0] r);
    r = xorshift32(r);
    return dly_min + (r % (dly_max - dly_min + 1));
  endfunction

  function automatic int line_of_code(word_t code);
    for (int i = 0; i < NLINES; i++) if (code == word_t'(LINE_BIT[i])) return i;
    return -1;
  endfunction

  /* verilator lint_off BLKSEQ */
  always @(posedge clk_i) begin
    if (!rst_ni) begin
      rng_q = (seed * 32'h85EB_CA6B) ^ 32'h5A5A_1234;
      if (rng_q == '0) rng_q = 32'h1;
      forced = 0;
      paused_q <= 1'b0;
      for (int i = 0; i < NLINES; i++) begin
        line_q[i] <= 1'b0;
        raised[i] = 0;
        acked[i]  = 0;
        wait_q[i] = next_delay(rng_q);
      end
    end else begin
      logic next_line [NLINES];
      for (int i = 0; i < NLINES; i++) next_line[i] = line_q[i];

      // Software access (at acceptance)
      if (acc_valid_i && acc_req_i.we) begin
        if (acc_req_i.be != 4'b1111)
          $fatal(1, "[sim_ctrl] store to %08h must be a full word (be=%b)", acc_req_i.addr, acc_req_i.be);
        unique case (acc_req_i.addr[11:0])
          OFF_ACK: begin
            int l;
            l = line_of_code(acc_req_i.wdata);
            if (l < 0)
              $fatal(1, "[sim_ctrl] IRQ_ACK of %0d: not an interrupt code (3, 7, 11)", acc_req_i.wdata);
            if (!line_q[l])
              $fatal(1, "[sim_ctrl] IRQ_ACK of code %0d while its line is low", acc_req_i.wdata);
            next_line[l] = 1'b0;
            acked[l]++;
            wait_q[l] = next_delay(rng_q);
          end
          OFF_FORCE: begin
            forced++;
            for (int i = 0; i < NLINES; i++)
              if (acc_req_i.wdata[LINE_BIT[i]]) next_line[i] = 1'b1;
          end
          OFF_RAND: paused_q <= !acc_req_i.wdata[0];
          default: ;
        endcase
      end

      // Random generator
      for (int i = 0; i < NLINES; i++) begin
        if (gen_on && !paused_q && !line_q[i] && !next_line[i]) begin
          if (wait_q[i] == 0) next_line[i] = 1'b1;
          else                wait_q[i]--;
        end
        if (next_line[i] && !line_q[i]) raised[i]++;
        line_q[i] <= next_line[i];
      end
    end
  end
  /* verilator lint_on BLKSEQ */

endmodule : sim_ctrl
