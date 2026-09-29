// =============================================================================
// core_tb_top  (testbench only)
// -----------------------------------------------------------------------------
// Purpose    : Verilator testbench for the bare core: core_top + mem_model +
//              sim_ctrl (interrupt lines) + tohost_monitor, a timeout,
//              simulation checks, hazard event counters and the interrupt
//              coverage counters of docs/architecture.md P2.13.
// Plusargs   : +hex=<file> +tohost=<hex> [+mem=ideal|random] [+seed=N]
//              [+irq=on|off] [+irq_min=N +irq_max=N] [+irq_count=<hex>]
//              [+timeout=<cycles>, default 200000]
//              +irq_count is the address of the software handler's counter
//              (symbol irq_handled), when the program has one.
// Output     : one line "RESULT: PASS" or "RESULT: FAIL <reason>", and one
//              line "STATS: key=value ..." with cycles, retired instructions,
//              hazard event counts and interrupt counts. scripts/
//              run_riscv_tests.py parses both.
// Checks     : at the end of the run (P2.9): interrupt entries == IRQ_ACK
//              writes == irq_handled; raised - acked == lines still high. On
//              every interrupt entry: MIE was 1, the source is enabled and
//              high, and no higher-priority enabled line is high.
// Timing     : 100 MHz clock; reset asserted for 5 cycles and released on a
//              falling edge (synchronous de-assertion).
// =============================================================================
module core_tb_top;

  import riscv_pkg::*;

  logic clk;
  logic rst_n;

  initial begin
    clk = 1'b0;
    forever #5ns clk = ~clk;
  end

  initial begin
    rst_n = 1'b0;
    repeat (5) @(posedge clk);
    @(negedge clk);
    rst_n = 1'b1;
  end

  // ---------------------------------------------------------------------------
  // DUT and environment
  // ---------------------------------------------------------------------------
  logic     imem_req_valid, imem_req_ready, imem_rsp_valid;
  mem_req_t imem_req;
  mem_rsp_t imem_rsp;
  logic     dmem_req_valid, dmem_req_ready, dmem_rsp_valid;
  mem_req_t dmem_req;
  mem_rsp_t dmem_rsp;
  logic     irq_sw, irq_timer, irq_ext;
  logic     sc_valid;
  mem_req_t sc_req;
  word_t    sc_rdata;

  core_top u_core (
    .clk_i            (clk),
    .rst_ni           (rst_n),
    .imem_req_valid_o (imem_req_valid),
    .imem_req_ready_i (imem_req_ready),
    .imem_req_o       (imem_req),
    .imem_rsp_valid_i (imem_rsp_valid),
    .imem_rsp_i       (imem_rsp),
    .dmem_req_valid_o (dmem_req_valid),
    .dmem_req_ready_i (dmem_req_ready),
    .dmem_req_o       (dmem_req),
    .dmem_rsp_valid_i (dmem_rsp_valid),
    .dmem_rsp_i       (dmem_rsp),
    .irq_software_i   (irq_sw),
    .irq_timer_i      (irq_timer),
    .irq_external_i   (irq_ext)
  );

  mem_model u_mem (
    .clk_i            (clk),
    .rst_ni           (rst_n),
    .imem_req_valid_i (imem_req_valid),
    .imem_req_ready_o (imem_req_ready),
    .imem_req_i       (imem_req),
    .imem_rsp_valid_o (imem_rsp_valid),
    .imem_rsp_o       (imem_rsp),
    .dmem_req_valid_i (dmem_req_valid),
    .dmem_req_ready_o (dmem_req_ready),
    .dmem_req_i       (dmem_req),
    .dmem_rsp_valid_o (dmem_rsp_valid),
    .dmem_rsp_o       (dmem_rsp),
    .sc_valid_o       (sc_valid),
    .sc_req_o         (sc_req),
    .sc_rdata_i       (sc_rdata)
  );

  sim_ctrl u_sc (
    .clk_i          (clk),
    .rst_ni         (rst_n),
    .acc_valid_i    (sc_valid),
    .acc_req_i      (sc_req),
    .rdata_o        (sc_rdata),
    .irq_software_o (irq_sw),
    .irq_timer_o    (irq_timer),
    .irq_external_o (irq_ext)
  );

  logic  done, pass;
  word_t testnum;

  tohost_monitor u_tohost (
    .clk_i            (clk),
    .rst_ni           (rst_n),
    .dmem_req_valid_i (dmem_req_valid),
    .dmem_req_ready_i (dmem_req_ready),
    .dmem_req_i       (dmem_req),
    .done_o           (done),
    .pass_o           (pass),
    .testnum_o        (testnum)
  );

  // ---------------------------------------------------------------------------
  // Hazard event counters (hierarchical probes; architecture.md section 8).
  // Each event is counted once, when the instruction concerned moves on.
  // ---------------------------------------------------------------------------
  longint unsigned cycles, retired;
  longint unsigned n_fwd_exmem, n_fwd_memwb, n_wb_bypass, n_load_use;
  longint unsigned n_redirect, n_fetch_drop, n_stall;

  logic ex_moves, id_moves;
  assign ex_moves = !u_core.stall && u_core.id_ex_q.valid;
  assign id_moves = !u_core.stall && !u_core.load_use && !u_core.redirect && u_core.if_id_q.valid;

  function automatic longint unsigned count_fwd(logic uses, fwd_sel_e sel, fwd_sel_e want);
    return (uses && (sel == want)) ? 1 : 0;
  endfunction

  function automatic longint unsigned count_bypass(logic uses, reg_addr_t rs);
    return (uses && (rs != '0) && u_core.mem_wb_q.valid && u_core.mem_wb_q.rd_we
            && (u_core.mem_wb_q.rd == rs)) ? 1 : 0;
  endfunction

  // ---------------------------------------------------------------------------
  // Trap and interrupt counters (P2.13). Signals from the commit point.
  // ---------------------------------------------------------------------------
  longint unsigned n_irq, n_exc;
  longint unsigned n_irq_ex_memop, n_irq_ex_memop_held, n_irq_ldst, n_irq_redirect;
  longint unsigned n_defer_csr, n_defer_mret, n_defer_fencei, n_exc_irq;

  logic    irq_take, trap_take, irq_pend, can_commit;
  sys_op_e mem_sys_op;
  logic    ex_memop_blocked;   // EX holds a load/store that would issue now or wait
  logic    stall_q;            // the pipeline was stalled in the previous cycle

  assign irq_take   = u_core.irq_take;
  assign trap_take  = u_core.trap_take;
  assign irq_pend   = u_core.irq_pend;
  assign can_commit = u_core.can_commit;
  assign mem_sys_op = u_core.ex_mem_q.sys_op;
  assign ex_memop_blocked = u_core.ex_mem_op && !u_core.ex_self_exc;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      cycles       <= 0;
      retired      <= 0;
      n_fwd_exmem  <= 0;
      n_fwd_memwb  <= 0;
      n_wb_bypass  <= 0;
      n_load_use   <= 0;
      n_redirect   <= 0;
      n_fetch_drop <= 0;
      n_stall      <= 0;
      n_irq               <= 0;
      n_exc               <= 0;
      n_irq_ex_memop      <= 0;
      n_irq_ex_memop_held <= 0;
      n_irq_ldst          <= 0;
      n_irq_redirect      <= 0;
      n_defer_csr         <= 0;
      n_defer_mret        <= 0;
      n_defer_fencei      <= 0;
      n_exc_irq           <= 0;
      stall_q             <= 1'b0;
    end else begin
      cycles  <= cycles + 1;
      stall_q <= u_core.stall;
      if (u_core.retire) retired <= retired + 1;
      if (ex_moves) begin
        n_fwd_exmem <= n_fwd_exmem
                     + count_fwd(u_core.id_ex_q.ctrl.uses_rs1, u_core.fwd_rs1, FWD_EXMEM)
                     + count_fwd(u_core.id_ex_q.ctrl.uses_rs2, u_core.fwd_rs2, FWD_EXMEM);
        n_fwd_memwb <= n_fwd_memwb
                     + count_fwd(u_core.id_ex_q.ctrl.uses_rs1, u_core.fwd_rs1, FWD_MEMWB)
                     + count_fwd(u_core.id_ex_q.ctrl.uses_rs2, u_core.fwd_rs2, FWD_MEMWB);
      end
      if (id_moves) begin
        n_wb_bypass <= n_wb_bypass
                     + count_bypass(u_core.id_ctrl.uses_rs1, u_core.id_rs1)
                     + count_bypass(u_core.id_ctrl.uses_rs2, u_core.id_rs2);
      end
      if (u_core.load_use && !u_core.stall && !u_core.redirect) n_load_use <= n_load_use + 1;
      if (u_core.redirect)             n_redirect   <= n_redirect + 1;
      if (u_core.u_if.rsp_stale)       n_fetch_drop <= n_fetch_drop + 1;
      if (u_core.stall)                n_stall      <= n_stall + 1;

      if (trap_take) n_exc <= n_exc + 1;
      if (irq_take) begin
        n_irq <= n_irq + 1;
        // E1: EX holds a load/store whose request kill_ex blocks this cycle;
        // "held": the issue rule had already held it for >= 1 cycle.
        if (ex_memop_blocked)            n_irq_ex_memop      <= n_irq_ex_memop + 1;
        if (ex_memop_blocked && stall_q) n_irq_ex_memop_held <= n_irq_ex_memop_held + 1;
        // E2: the interrupt rides on a committing load or store.
        if (u_core.ex_mem_q.mem_op != MEM_NONE) n_irq_ldst <= n_irq_ldst + 1;
        // E3: EX wanted to redirect in this very cycle; MEM's redirect wins.
        if (u_core.ex_redirect && !u_core.u_hazard.ex_redirected_q)
          n_irq_redirect <= n_irq_redirect + 1;
      end
      // E4: an enabled, pending interrupt deferred by a serializing commit.
      if (irq_pend && can_commit) begin
        if (is_csr_op(mem_sys_op))       n_defer_csr    <= n_defer_csr + 1;
        if (mem_sys_op == SYS_MRET)      n_defer_mret   <= n_defer_mret + 1;
        if (mem_sys_op == SYS_FENCE_I)   n_defer_fencei <= n_defer_fencei + 1;
      end
      // E5: an exception is taken while an interrupt is pending.
      if (trap_take && irq_pend) n_exc_irq <= n_exc_irq + 1;
    end
  end

  // ---------------------------------------------------------------------------
  // Interrupt entry check (P2.9 check 3), independent of the core's priority
  // encoder: MIE set, the source enabled and high, nothing higher pending.
  // ---------------------------------------------------------------------------
  logic [2:0] en_lines;   // {MEI, MSI, MTI}, enabled and high
  assign en_lines = {irq_ext   && u_core.u_csr.meie_q,
                     irq_sw    && u_core.u_csr.msie_q,
                     irq_timer && u_core.u_csr.mtie_q};

  always @(posedge clk) begin
    if (rst_n && irq_take) begin
      exc_code_t want;
      want = en_lines[2] ? IRQ_MEI : en_lines[1] ? IRQ_MSI : IRQ_MTI;
      if (!u_core.u_csr.mie_q)
        finish($sformatf("FAIL interrupt taken with mstatus.MIE=0 at pc=%08h", u_core.ex_mem_q.pc));
      else if (en_lines == '0)
        finish($sformatf("FAIL interrupt taken with no enabled line high at pc=%08h", u_core.ex_mem_q.pc));
      else if (u_core.trap_code != want)
        finish($sformatf("FAIL interrupt cause %0d, expected %0d (MEI > MSI > MTI)", u_core.trap_code, want));
    end
  end

  // ---------------------------------------------------------------------------
  // Debug trace (+trace): retirements, accepted D-port requests, trap entries
  // ---------------------------------------------------------------------------
  bit trace_on;
  initial trace_on = $test$plusargs("trace");

  always @(posedge clk) begin
    if (rst_n && trace_on) begin
      if (u_core.retire)
        $display("%8d RET pc=%08h instr=%08h%s", cycles, u_core.ex_mem_q.pc, u_core.ex_mem_q.instr,
                 u_core.mem_out.rd_we && (u_core.mem_out.rd != 0)
                   ? $sformatf(" x%0d=%08h", u_core.mem_out.rd, u_core.mem_out.wdata) : "");
      if (dmem_req_valid && dmem_req_ready)
        $display("%8d DREQ %s addr=%08h be=%b wdata=%08h", cycles, dmem_req.we ? "W" : "R",
                 dmem_req.addr, dmem_req.be, dmem_req.wdata);
      if (u_core.csr_trap)
        $display("%8d TRAP %s code=%0d pc=%08h epc=%08h tval=%08h", cycles,
                 trap_take ? "exc" : "irq", u_core.trap_code, u_core.ex_mem_q.pc,
                 u_core.trap_epc, u_core.trap_tval);
    end
  end

  // ---------------------------------------------------------------------------
  // End of test
  // ---------------------------------------------------------------------------
  longint unsigned timeout;
  word_t           irq_count_addr;
  bit              has_irq_count;

  initial begin
    timeout = 200000;
    void'($value$plusargs("timeout=%d", timeout));
    has_irq_count = $value$plusargs("irq_count=%h", irq_count_addr);
  end

  function automatic longint unsigned sum3(longint unsigned a [3]);
    return a[0] + a[1] + a[2];
  endfunction

  task automatic finish(string result);
    $display("RESULT: %s", result);
    $display("STATS: cycles=%0d retired=%0d fwd_exmem=%0d fwd_memwb=%0d wb_bypass=%0d load_use=%0d redirect=%0d fetch_drop=%0d stall=%0d exc=%0d irq=%0d irq_raised=%0d irq_acked=%0d irq_forced=%0d irq_ex_memop=%0d irq_ex_memop_held=%0d irq_ldst=%0d irq_redirect=%0d irq_defer_csr=%0d irq_defer_mret=%0d irq_defer_fencei=%0d exc_irq=%0d",
             cycles, retired, n_fwd_exmem, n_fwd_memwb, n_wb_bypass, n_load_use,
             n_redirect, n_fetch_drop, n_stall, n_exc, n_irq,
             sum3(u_sc.raised), sum3(u_sc.acked), u_sc.forced,
             n_irq_ex_memop, n_irq_ex_memop_held, n_irq_ldst, n_irq_redirect,
             n_defer_csr, n_defer_mret, n_defer_fencei, n_exc_irq);
    $finish;
  endtask

  // P2.9 checks 1 and 2, at the tohost store. Returns "" when they hold.
  function automatic string irq_checks();
    longint unsigned acked, raised, high, handled;
    acked  = sum3(u_sc.acked);
    raised = sum3(u_sc.raised);
    high   = longint'(irq_sw) + longint'(irq_timer) + longint'(irq_ext);
    if (n_irq != acked)
      return $sformatf("interrupt entries %0d != IRQ_ACK writes %0d", n_irq, acked);
    if (has_irq_count) begin
      word_t off;
      off     = irq_count_addr - soc_pkg::MEM_BASE;
      handled = 64'({u_mem.mem[off + 3], u_mem.mem[off + 2], u_mem.mem[off + 1], u_mem.mem[off]});
      if (handled != acked)
        return $sformatf("irq_handled %0d != IRQ_ACK writes %0d", handled, acked);
    end
    if (raised - acked != high)
      return $sformatf("lines raised %0d - acked %0d != lines high %0d", raised, acked, high);
    return "";
  endfunction

  always @(posedge clk) begin
    if (rst_n) begin
      if (done) begin
        string chk;
        chk = irq_checks();
        if (!pass)          finish($sformatf("FAIL test=%0d", testnum));
        else if (chk != "") finish({"FAIL ", chk});
        else                finish("PASS");
      end else if (cycles >= timeout) begin
        finish($sformatf("FAIL timeout after %0d cycles", cycles));
      end
    end
  end

endmodule : core_tb_top
