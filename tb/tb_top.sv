`timescale 1ns/1ps
`include "uvm_macros.svh"
module tb_top;
  import uvm_pkg::*;
  import pmic_pkg::*;
  import pmic_tb_pkg::*;
  reg clk=0;
  always #5 clk=~clk;
  pmic_if intf(clk);

  power_controller dut (
    .clk(clk), .arst_n(intf.arst_n), .cfg_req(intf.cfg_req),
    .cfg_write(intf.cfg_write), .cfg_addr(intf.cfg_addr),
    .cfg_wdata(intf.cfg_wdata), .cfg_rdata(intf.cfg_rdata),
    .cfg_ready(intf.cfg_ready), .vout_mv(intf.vout_mv),
    .over_current(intf.over_current), .pwm_out(intf.pwm_out),
    .power_enable(intf.power_enable), .command_mv(intf.command_mv),
    .pgood(intf.pgood), .fault_status(intf.fault_status),
    .operating_mode(intf.operating_mode), .voltage_select(intf.voltage_select)
  );
  power_stage_model plant (
    .clk(clk), .arst_n(intf.arst_n), .power_enable(intf.power_enable),
    .command_mv(intf.command_mv), .load_ma(intf.load_ma),
    .force_ov(intf.force_ov), .force_uv(intf.force_uv), .vout_mv(intf.vout_mv)
  );
  pmic_assertions sva (
    .clk(clk), .arst_n(intf.arst_n), .cfg_req(intf.cfg_req),
    .cfg_ready(intf.cfg_ready), .power_enable(intf.power_enable),
    .pwm_out(intf.pwm_out), .pgood(intf.pgood),
    .fault_status(intf.fault_status), .command_mv(intf.command_mv)
  );

  initial begin
    intf.arst_n=0;
    repeat(5) @(posedge clk); #1 intf.arst_n=1;
  end
  initial begin
    uvm_config_db#(virtual pmic_if)::set(null,"uvm_test_top.env.agent.*","vif",intf);
    run_test();
  end
  initial begin
    #10ms; `uvm_fatal("TIMEOUT","Simulation exceeded 10 ms")
  end
endmodule
