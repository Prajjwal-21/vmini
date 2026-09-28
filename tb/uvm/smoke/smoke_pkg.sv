// =============================================================================
// smoke_pkg
// -----------------------------------------------------------------------------
// Purpose : UVM smoke test proving the Verilator + UVM flow works end to end:
//           sequence item with a constraint, sequence, driver, monitor, agent,
//           scoreboard, env and one test. Driven by `make uvm-smoke`.
//
// Pass criterion: every one of NUM_ITEMS results is checked, with zero
// UVM_ERROR/UVM_FATAL. The test then prints "UVM SMOKE TEST PASSED".
// =============================================================================
// UVM convention: one package holds many classes, so class names cannot all
// match the file name.
/* verilator lint_off DECLFILENAME */
package smoke_pkg;

  import uvm_pkg::*;
  `include "uvm_macros.svh"

  // ---------------------------------------------------------------------------
  // Sequence item: stimulus (a, b) plus the observed result (sum).
  // ---------------------------------------------------------------------------
  class smoke_item extends uvm_sequence_item;
    rand logic [7:0] a;
    rand logic [7:0] b;
    logic      [8:0] sum;

    // A real constraint, so the smoke test also exercises Verilator's
    // constraint solver (needed later for constrained-random stimulus).
    constraint c_mostly_carry { a + b > 9'd200; }

    // Explicit methods instead of `uvm_field_* automation: clearer, faster,
    // and free of the width warnings those macros expand to under -Wall.
    `uvm_object_utils(smoke_item)

    function new(string name = "smoke_item");
      super.new(name);
    endfunction

    virtual function string convert2string();
      return $sformatf("a=%0d b=%0d sum=%0d", a, b, sum);
    endfunction

    virtual function void do_copy(uvm_object rhs);
      smoke_item that;
      super.do_copy(rhs);
      if (!$cast(that, rhs)) `uvm_fatal("COPY", "type mismatch")
      a   = that.a;
      b   = that.b;
      sum = that.sum;
    endfunction
  endclass

  // ---------------------------------------------------------------------------
  // Sequence: NUM_ITEMS randomized items.
  // ---------------------------------------------------------------------------
  class smoke_seq extends uvm_sequence #(smoke_item);
    `uvm_object_utils(smoke_seq)

    int unsigned num_items = 50;

    function new(string name = "smoke_seq");
      super.new(name);
    endfunction

    virtual task body();
      repeat (num_items) begin
        smoke_item item = smoke_item::type_id::create("item");
        start_item(item);
        if (item.randomize() != 1) `uvm_fatal("SEQ", "randomize() failed")
        finish_item(item);
      end
    endtask
  endclass

  // ---------------------------------------------------------------------------
  // Driver
  // ---------------------------------------------------------------------------
  class smoke_driver extends uvm_driver #(smoke_item);
    `uvm_component_utils(smoke_driver)

    virtual smoke_if vif;

    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction

    virtual function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      if (!uvm_config_db#(virtual smoke_if)::get(this, "", "vif", vif))
        `uvm_fatal("NOVIF", "virtual smoke_if not set")
    endfunction

    virtual task run_phase(uvm_phase phase);
      vif.valid_i <= 1'b0;
      vif.a_i     <= '0;
      vif.b_i     <= '0;
      wait (vif.rst_n === 1'b1);
      // Each item is presented for exactly one cycle, followed by one idle
      // cycle. Simple and race-free, which is all a smoke test needs.
      forever begin
        seq_item_port.get_next_item(req);
        @(posedge vif.clk);
        vif.valid_i <= 1'b1;
        vif.a_i     <= req.a;
        vif.b_i     <= req.b;
        @(posedge vif.clk);
        vif.valid_i <= 1'b0;
        seq_item_port.item_done();
      end
    endtask
  endclass

  // ---------------------------------------------------------------------------
  // Monitor: pairs each accepted input with the result one cycle later.
  // ---------------------------------------------------------------------------
  class smoke_monitor extends uvm_monitor;
    `uvm_component_utils(smoke_monitor)

    virtual smoke_if vif;
    uvm_analysis_port #(smoke_item) ap;

    function new(string name, uvm_component parent);
      super.new(name, parent);
      ap = new("ap", this);
    endfunction

    virtual function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      if (!uvm_config_db#(virtual smoke_if)::get(this, "", "vif", vif))
        `uvm_fatal("NOVIF", "virtual smoke_if not set")
    endfunction

    virtual task run_phase(uvm_phase phase);
      smoke_item pending[$];
      forever begin
        @(posedge vif.clk);
        if (vif.rst_n !== 1'b1) begin
          pending.delete();
          continue;
        end
        // Output first: it belongs to an input accepted on an earlier edge.
        if (vif.valid_o === 1'b1) begin
          if (pending.size() == 0) begin
            `uvm_error("MON", "valid_o with no outstanding input")
          end else begin
            smoke_item item = pending.pop_front();
            item.sum = vif.sum_o;
            ap.write(item);
          end
        end
        if (vif.valid_i === 1'b1) begin
          smoke_item item = smoke_item::type_id::create("observed");
          item.a = vif.a_i;
          item.b = vif.b_i;
          pending.push_back(item);
        end
      end
    endtask
  endclass

  // ---------------------------------------------------------------------------
  // Agent: sequencer + driver + monitor (always active here).
  // ---------------------------------------------------------------------------
  class smoke_agent extends uvm_agent;
    `uvm_component_utils(smoke_agent)

    uvm_sequencer #(smoke_item) sqr;
    smoke_driver                drv;
    smoke_monitor               mon;

    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction

    virtual function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      sqr = uvm_sequencer#(smoke_item)::type_id::create("sqr", this);
      drv = smoke_driver::type_id::create("drv", this);
      mon = smoke_monitor::type_id::create("mon", this);
    endfunction

    virtual function void connect_phase(uvm_phase phase);
      drv.seq_item_port.connect(sqr.seq_item_export);
    endfunction
  endclass

  // ---------------------------------------------------------------------------
  // Scoreboard: reference model is a 9-bit add.
  // ---------------------------------------------------------------------------
  class smoke_scoreboard extends uvm_scoreboard;
    `uvm_component_utils(smoke_scoreboard)

    uvm_analysis_imp #(smoke_item, smoke_scoreboard) imp;
    int unsigned num_checked;

    function new(string name, uvm_component parent);
      super.new(name, parent);
      imp = new("imp", this);
    endfunction

    virtual function void write(smoke_item item);
      logic [8:0] expected = {1'b0, item.a} + {1'b0, item.b};
      num_checked++;
      if (item.sum !== expected)
        `uvm_error("SCB", $sformatf("%0d + %0d: got %0d, expected %0d",
                                    item.a, item.b, item.sum, expected))
      if (item.a + item.b <= 9'd200)
        `uvm_error("SCB", $sformatf("constraint violated: %0d + %0d <= 200",
                                    item.a, item.b))
    endfunction
  endclass

  // ---------------------------------------------------------------------------
  // Env
  // ---------------------------------------------------------------------------
  class smoke_env extends uvm_env;
    `uvm_component_utils(smoke_env)

    smoke_agent      agent;
    smoke_scoreboard scb;

    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction

    virtual function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      agent = smoke_agent::type_id::create("agent", this);
      scb   = smoke_scoreboard::type_id::create("scb", this);
    endfunction

    virtual function void connect_phase(uvm_phase phase);
      agent.mon.ap.connect(scb.imp);
    endfunction
  endclass

  // ---------------------------------------------------------------------------
  // Test
  // ---------------------------------------------------------------------------
  class smoke_test extends uvm_test;
    `uvm_component_utils(smoke_test)

    localparam int unsigned NUM_ITEMS = 50;

    smoke_env env;

    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction

    virtual function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      env = smoke_env::type_id::create("env", this);
    endfunction

    virtual task run_phase(uvm_phase phase);
      smoke_seq seq = smoke_seq::type_id::create("seq");
      phase.raise_objection(this);
      seq.num_items = NUM_ITEMS;
      seq.start(env.agent.sqr);
      // Let the last result drain through the 1-cycle pipeline.
      repeat (3) @(posedge env.agent.drv.vif.clk);
      phase.drop_objection(this);
    endtask

    virtual function void report_phase(uvm_phase phase);
      uvm_report_server rs = uvm_report_server::get_server();
      int unsigned errors  = rs.get_severity_count(UVM_ERROR) + rs.get_severity_count(UVM_FATAL);
      if (env.scb.num_checked != NUM_ITEMS)
        `uvm_error("TEST", $sformatf("checked %0d results, expected %0d",
                                     env.scb.num_checked, NUM_ITEMS))
      else if (errors == 0)
        `uvm_info("TEST", $sformatf("%0d results checked", env.scb.num_checked), UVM_NONE)
      errors = rs.get_severity_count(UVM_ERROR) + rs.get_severity_count(UVM_FATAL);
      $display("** UVM SMOKE TEST %s **", errors == 0 ? "PASSED" : "FAILED");
    endfunction
  endclass

endpackage : smoke_pkg
/* verilator lint_on DECLFILENAME */
