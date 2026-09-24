package pmic_tb_pkg;
  import uvm_pkg::*;
  import pmic_pkg::*;
  `include "uvm_macros.svh"

  typedef enum int {BUS_WRITE, BUS_READ, WAIT_CYCLES, SET_LOAD,
                    INJECT_FAULT, CLEAR_INJECTION} pmic_action_e;

  class pmic_item extends uvm_sequence_item;
    rand pmic_action_e action;
    rand bit [7:0] addr;
    rand bit [31:0] data;
    rand int unsigned cycles;
    rand bit [15:0] load_ma;
    rand bit [2:0] injected_fault;
    bit [31:0] read_data;

    constraint c_addr { addr inside {ADDR_CTRL, ADDR_VSET, ADDR_STATUS,
                                     ADDR_FAULT, ADDR_TIMING}; }
    constraint c_cycles { cycles inside {[1:80]}; }
    constraint c_load { load_ma inside {[0:900]}; }
    constraint c_fault { injected_fault inside {FAULT_OC, FAULT_UV, FAULT_OV}; }

    `uvm_object_utils_begin(pmic_item)
      `uvm_field_enum(pmic_action_e, action, UVM_DEFAULT)
      `uvm_field_int(addr, UVM_HEX)
      `uvm_field_int(data, UVM_HEX)
      `uvm_field_int(cycles, UVM_DEC)
      `uvm_field_int(load_ma, UVM_DEC)
      `uvm_field_int(injected_fault, UVM_BIN)
      `uvm_field_int(read_data, UVM_HEX | UVM_NOCOMPARE)
    `uvm_object_utils_end
    function new(string name="pmic_item"); super.new(name); endfunction
  endclass

  class pmic_sample extends uvm_sequence_item;
    bit bus_valid, bus_write;
    bit [7:0] addr;
    bit [31:0] wdata, rdata;
    bit [15:0] load_ma, vout_mv, command_mv;
    bit force_ov, force_uv, over_current;
    bit pwm_out, power_enable, pgood;
    bit [2:0] fault_status;
    bit [1:0] mode, vset;
    `uvm_object_utils(pmic_sample)
    function new(string name="pmic_sample"); super.new(name); endfunction
  endclass

  class pmic_sequencer extends uvm_sequencer #(pmic_item);
    `uvm_component_utils(pmic_sequencer)
    function new(string name, uvm_component parent); super.new(name,parent); endfunction
  endclass

  class pmic_driver extends uvm_driver #(pmic_item);
    `uvm_component_utils(pmic_driver)
    virtual pmic_if vif;
    function new(string name, uvm_component parent); super.new(name,parent); endfunction
    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      if (!uvm_config_db#(virtual pmic_if)::get(this,"","vif",vif))
        `uvm_fatal("NOVIF","pmic_if was not configured")
    endfunction
    task run_phase(uvm_phase phase);
      vif.cfg_req = 0; vif.cfg_write = 0; vif.cfg_addr = 0; vif.cfg_wdata = 0;
      vif.load_ma = 16'd100; vif.force_ov = 0; vif.force_uv = 0;
      vif.over_current = 0;
      forever begin
        seq_item_port.get_next_item(req);
        case (req.action)
          BUS_WRITE, BUS_READ: drive_bus(req);
          WAIT_CYCLES: repeat (req.cycles) @(vif.drv_cb);
          SET_LOAD: begin vif.drv_cb.load_ma <= req.load_ma; @(vif.drv_cb); end
          INJECT_FAULT: begin
            vif.drv_cb.over_current <= req.injected_fault[0];
            vif.drv_cb.force_uv <= req.injected_fault[1];
            vif.drv_cb.force_ov <= req.injected_fault[2];
            @(vif.drv_cb);
          end
          CLEAR_INJECTION: begin
            vif.drv_cb.over_current <= 0; vif.drv_cb.force_uv <= 0;
            vif.drv_cb.force_ov <= 0; @(vif.drv_cb);
          end
        endcase
        seq_item_port.item_done();
      end
    endtask
    task drive_bus(pmic_item tr);
      @(vif.drv_cb);
      vif.drv_cb.cfg_addr <= tr.addr;
      vif.drv_cb.cfg_wdata <= tr.data;
      vif.drv_cb.cfg_write <= (tr.action == BUS_WRITE);
      vif.drv_cb.cfg_req <= 1;
      do @(vif.drv_cb); while (!vif.drv_cb.cfg_ready);
      if (tr.action == BUS_READ) tr.read_data = vif.drv_cb.cfg_rdata;
      vif.drv_cb.cfg_req <= 0;
      vif.drv_cb.cfg_write <= 0;
    endtask
  endclass

  class pmic_monitor extends uvm_monitor;
    `uvm_component_utils(pmic_monitor)
    virtual pmic_if vif;
    uvm_analysis_port #(pmic_sample) ap;
    function new(string name, uvm_component parent); super.new(name,parent); ap=new("ap",this); endfunction
    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      if (!uvm_config_db#(virtual pmic_if)::get(this,"","vif",vif))
        `uvm_fatal("NOVIF","pmic_if was not configured")
    endfunction
    task run_phase(uvm_phase phase);
      pmic_sample s;
      forever begin
        @(vif.mon_cb);
        if (!vif.arst_n) continue;
        s = pmic_sample::type_id::create("s");
        s.bus_valid=vif.mon_cb.cfg_req && vif.mon_cb.cfg_ready;
        s.bus_write=vif.mon_cb.cfg_write; s.addr=vif.mon_cb.cfg_addr;
        s.wdata=vif.mon_cb.cfg_wdata; s.rdata=vif.mon_cb.cfg_rdata;
        s.load_ma=vif.mon_cb.load_ma; s.force_ov=vif.mon_cb.force_ov;
        s.force_uv=vif.mon_cb.force_uv; s.over_current=vif.mon_cb.over_current;
        s.vout_mv=vif.mon_cb.vout_mv; s.command_mv=vif.mon_cb.command_mv;
        s.pwm_out=vif.mon_cb.pwm_out; s.power_enable=vif.mon_cb.power_enable;
        s.pgood=vif.mon_cb.pgood; s.fault_status=vif.mon_cb.fault_status;
        s.mode=vif.mon_cb.operating_mode; s.vset=vif.mon_cb.voltage_select;
        ap.write(s);
      end
    endtask
  endclass

  class pmic_agent extends uvm_agent;
    `uvm_component_utils(pmic_agent)
    pmic_sequencer seqr; pmic_driver drv; pmic_monitor mon;
    function new(string name, uvm_component parent); super.new(name,parent); endfunction
    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      mon=pmic_monitor::type_id::create("mon",this);
      if (get_is_active()==UVM_ACTIVE) begin
        seqr=pmic_sequencer::type_id::create("seqr",this);
        drv=pmic_driver::type_id::create("drv",this);
      end
    endfunction
    function void connect_phase(uvm_phase phase);
      if (get_is_active()==UVM_ACTIVE) drv.seq_item_port.connect(seqr.seq_item_export);
    endfunction
  endclass

  // Transaction-level reference model for software-visible state.  Dynamic
  // analog/status bits come from the observation at the read edge; programmed
  // state is predicted independently from accepted bus writes.
  class pmic_reference_model extends uvm_object;
    `uvm_object_utils(pmic_reference_model)
    bit exp_enable, exp_auto_retry;
    bit [1:0] exp_mode=MODE_PWM, exp_vset=1;
    bit [7:0] exp_soft=4, exp_good=8;
    function new(string name="pmic_reference_model"); super.new(name); endfunction
    function bit [31:0] expected_read(bit [7:0] addr, pmic_sample t);
      case(addr)
        ADDR_CTRL: expected_read={28'd0,exp_auto_retry,exp_mode,exp_enable};
        ADDR_VSET: expected_read={30'd0,exp_vset};
        ADDR_STATUS: expected_read={24'd0,t.vset,t.mode,|t.fault_status,
                                    t.pgood,t.rdata[1],t.power_enable};
        ADDR_FAULT: expected_read={29'd0,t.fault_status};
        ADDR_TIMING: expected_read={16'd0,exp_good,exp_soft};
        default: expected_read=32'hdead_bad0;
      endcase
    endfunction
    function void apply_write(pmic_sample t);
      case(t.addr)
        ADDR_CTRL: begin exp_enable=t.wdata[0]; exp_mode=t.wdata[2:1]; exp_auto_retry=t.wdata[3]; end
        ADDR_VSET: exp_vset=t.wdata[1:0];
        ADDR_TIMING: begin exp_soft=(t.wdata[7:0]==0)?1:t.wdata[7:0]; exp_good=(t.wdata[15:8]==0)?1:t.wdata[15:8]; end
        default: ;
      endcase
    endfunction
  endclass

  class pmic_scoreboard extends uvm_subscriber #(pmic_sample);
    `uvm_component_utils(pmic_scoreboard)
    pmic_reference_model model;
    int checks, errors;
    bit previous_fault;
    function new(string name, uvm_component parent);
      super.new(name,parent); model=pmic_reference_model::type_id::create("model");
    endfunction
    function void write(pmic_sample t);
      bit [31:0] exp;
      checks++;
      if (t.mode !== model.exp_mode || t.vset !== model.exp_vset) begin
        errors++; `uvm_error("MIRROR",$sformatf("DUT mode/vset %0d/%0d expected %0d/%0d",t.mode,t.vset,model.exp_mode,model.exp_vset))
      end
      if (t.pgood && (!t.power_enable || |t.fault_status)) begin
        errors++; `uvm_error("PGOOD","PGOOD high while disabled or faulted")
      end
      if (previous_fault && t.power_enable) begin
        errors++; `uvm_error("SHUTDOWN","power_enable remained high after a latched fault")
      end
      previous_fault = |t.fault_status;
      if (t.bus_valid && !t.bus_write) begin
        exp=model.expected_read(t.addr,t);
        if (t.rdata !== exp) begin
          errors++; `uvm_error("READBACK",$sformatf("addr %02h read %08h expected %08h",t.addr,t.rdata,exp))
        end
      end
      if (t.bus_valid && t.bus_write) model.apply_write(t);
    endfunction
    function void report_phase(uvm_phase phase);
      `uvm_info("SCOREBOARD",$sformatf("%0d samples checked, %0d local errors",checks,errors),UVM_LOW)
      if (checks==0) `uvm_error("SCOREBOARD","No observations received")
    endfunction
  endclass

  class pmic_coverage extends uvm_subscriber #(pmic_sample);
    `uvm_component_utils(pmic_coverage)
    bit [1:0] mode, vset;
    bit [1:0] load_class;
    bit [2:0] fault;
    bit recovery;
    bit [2:0] prev_fault;
    covergroup pmic_cg;
      option.per_instance=1;
      cp_mode: coverpoint mode { bins pwm={0}; bins pfm={1}; bins eco={2}; illegal_bins reserved={3}; }
      cp_vset: coverpoint vset { bins settings[]={0,1,2,3}; }
      cp_load: coverpoint load_class { bins light={0}; bins mid_load={1}; bins heavy={2}; }
      cp_fault: coverpoint fault { bins none={0}; bins oc={1}; bins uv={2}; bins ov={4}; bins multiple=default; }
      cp_recovery: coverpoint recovery { bins no={0}; bins yes={1}; }
      operating_scenarios: cross cp_mode,cp_vset,cp_load,cp_fault,cp_recovery {
        ignore_bins no_fault_cannot_recover =
          binsof(cp_fault.none) && binsof(cp_recovery.yes);
      }
    endgroup
    function new(string name, uvm_component parent); super.new(name,parent); pmic_cg=new; endfunction
    function void write(pmic_sample t);
      mode=t.mode; vset=t.vset;
      load_class=(t.load_ma<200)?0:((t.load_ma<600)?1:2);
      recovery=(prev_fault!=0 && t.fault_status==0);
      fault=recovery ? prev_fault : t.fault_status;
      pmic_cg.sample(); prev_fault=t.fault_status;
    endfunction
    function void report_phase(uvm_phase phase);
      `uvm_info("COVERAGE",$sformatf("functional coverage %.2f%%",pmic_cg.get_inst_coverage()),UVM_LOW)
    endfunction
  endclass

  class pmic_env extends uvm_env;
    `uvm_component_utils(pmic_env)
    pmic_agent agent; pmic_scoreboard sb; pmic_coverage cov;
    function new(string name, uvm_component parent); super.new(name,parent); endfunction
    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      agent=pmic_agent::type_id::create("agent",this);
      sb=pmic_scoreboard::type_id::create("sb",this);
      cov=pmic_coverage::type_id::create("cov",this);
    endfunction
    function void connect_phase(uvm_phase phase);
      agent.mon.ap.connect(sb.analysis_export);
      agent.mon.ap.connect(cov.analysis_export);
    endfunction
  endclass

  class pmic_base_sequence extends uvm_sequence #(pmic_item);
    `uvm_object_utils(pmic_base_sequence)
    function new(string name="pmic_base_sequence"); super.new(name); endfunction
    task send(pmic_action_e a, bit [7:0] addr=0, bit [31:0] data=0,
              int unsigned cycles=1, bit [15:0] load=100, bit [2:0] fault=0);
      pmic_item tr=pmic_item::type_id::create("tr");
      start_item(tr); tr.action=a; tr.addr=addr; tr.data=data;
      tr.cycles=cycles; tr.load_ma=load; tr.injected_fault=fault; finish_item(tr);
    endtask
    task write_reg(bit [7:0] a, bit [31:0] d); send(BUS_WRITE,a,d); endtask
    task read_reg(bit [7:0] a); send(BUS_READ,a); endtask
    task wait_clks(int n); send(WAIT_CYCLES,0,0,n); endtask
  endclass

  class pmic_smoke_sequence extends pmic_base_sequence;
    `uvm_object_utils(pmic_smoke_sequence)
    function new(string name="pmic_smoke_sequence"); super.new(name); endfunction
    task body();
      write_reg(ADDR_TIMING,{16'd0,8'd4,8'd2});
      write_reg(ADDR_VSET,2); write_reg(ADDR_CTRL,1); wait_clks(160);
      read_reg(ADDR_STATUS); read_reg(ADDR_VSET);
      send(SET_LOAD,0,0,1,700); wait_clks(30);
      send(INJECT_FAULT,0,0,1,0,FAULT_OC); wait_clks(4);
      send(CLEAR_INJECTION); write_reg(ADDR_FAULT,FAULT_OC); wait_clks(160);
      read_reg(ADDR_FAULT); read_reg(ADDR_STATUS);
    endtask
  endclass

  class pmic_corner_sequence extends pmic_base_sequence;
    `uvm_object_utils(pmic_corner_sequence)
    function new(string name="pmic_corner_sequence"); super.new(name); endfunction
    task body();
      int m,v,l,f;
      write_reg(ADDR_TIMING,{16'd0,8'd2,8'd2});
      for (m=0;m<3;m++) for(v=0;v<4;v++) begin
        write_reg(ADDR_VSET,v); write_reg(ADDR_CTRL,(m<<1)|1); wait_clks(150);
        for(l=0;l<3;l++) begin
          send(SET_LOAD,0,0,1,(l==0)?50:((l==1)?350:800)); wait_clks(20);
          for(f=0;f<3;f++) begin
            send(INJECT_FAULT,0,0,1,0,(1<<f)); wait_clks(8);
            send(CLEAR_INJECTION); write_reg(ADDR_FAULT,(1<<f)); wait_clks(150);
          end
        end
      end
    endtask
  endclass

  class pmic_random_sequence extends pmic_base_sequence;
    `uvm_object_utils(pmic_random_sequence)
    function new(string name="pmic_random_sequence"); super.new(name); endfunction
    task body();
      pmic_item r;
      int count=80;
      void'($value$plusargs("RANDOM_OPS=%d",count));
      write_reg(ADDR_TIMING,{16'd0,8'd3,8'd2});
      repeat(count) begin
        r=pmic_item::type_id::create("random_op");
        assert(r.randomize() with { action dist {BUS_WRITE:=3,BUS_READ:=2,WAIT_CYCLES:=4,SET_LOAD:=3,INJECT_FAULT:=2,CLEAR_INJECTION:=2};
                                    cycles inside {[2:40]}; });
        if (r.action==BUS_WRITE) begin
          case ($urandom_range(0,2))
            0: begin r.addr=ADDR_CTRL; r.data={$urandom}%16; r.data[2:1]=$urandom_range(0,2); end
            1: begin r.addr=ADDR_VSET; r.data=$urandom_range(0,3); end
            default: begin r.addr=ADDR_FAULT; r.data=7; end
          endcase
        end
        start_item(r); finish_item(r);
      end
      send(CLEAR_INJECTION); write_reg(ADDR_FAULT,7); wait_clks(180);
    endtask
  endclass

  class pmic_base_test extends uvm_test;
    `uvm_component_utils(pmic_base_test)
    pmic_env env;
    function new(string name, uvm_component parent); super.new(name,parent); endfunction
    function void build_phase(uvm_phase phase);
      super.build_phase(phase); env=pmic_env::type_id::create("env",this);
    endfunction
    task reset_phase(uvm_phase phase);
      phase.raise_objection(this); #1; phase.drop_objection(this);
    endtask
  endclass
  class pmic_smoke_test extends pmic_base_test;
    `uvm_component_utils(pmic_smoke_test)
    function new(string name,uvm_component parent);super.new(name,parent);endfunction
    task run_phase(uvm_phase phase); pmic_smoke_sequence s=pmic_smoke_sequence::type_id::create("s"); phase.raise_objection(this); s.start(env.agent.seqr); phase.drop_objection(this); endtask
  endclass
  class pmic_corner_test extends pmic_base_test;
    `uvm_component_utils(pmic_corner_test)
    function new(string name,uvm_component parent);super.new(name,parent);endfunction
    task run_phase(uvm_phase phase); pmic_corner_sequence s=pmic_corner_sequence::type_id::create("s"); phase.raise_objection(this); s.start(env.agent.seqr); phase.drop_objection(this); endtask
  endclass
  class pmic_random_test extends pmic_base_test;
    `uvm_component_utils(pmic_random_test)
    function new(string name,uvm_component parent);super.new(name,parent);endfunction
    task run_phase(uvm_phase phase); pmic_random_sequence s=pmic_random_sequence::type_id::create("s"); phase.raise_objection(this); s.start(env.agent.seqr); phase.drop_objection(this); endtask
  endclass
endpackage
