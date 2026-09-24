interface pmic_if(input logic clk);
  logic arst_n;
  logic cfg_req, cfg_write;
  logic [7:0] cfg_addr;
  logic [31:0] cfg_wdata, cfg_rdata;
  logic cfg_ready;
  logic [15:0] load_ma;
  logic force_ov, force_uv, over_current;
  logic [15:0] vout_mv, command_mv;
  logic pwm_out, power_enable, pgood;
  logic [2:0] fault_status;
  logic [1:0] operating_mode, voltage_select;

  clocking drv_cb @(posedge clk);
    default input #1step output #1step;
    output cfg_req, cfg_write, cfg_addr, cfg_wdata;
    output load_ma, force_ov, force_uv, over_current;
    input cfg_rdata, cfg_ready, vout_mv, command_mv, pwm_out;
    input power_enable, pgood, fault_status, operating_mode, voltage_select;
  endclocking

  clocking mon_cb @(posedge clk);
    default input #1step;
    input cfg_req, cfg_write, cfg_addr, cfg_wdata, cfg_rdata, cfg_ready;
    input load_ma, force_ov, force_uv, over_current;
    input vout_mv, command_mv, pwm_out, power_enable, pgood;
    input fault_status, operating_mode, voltage_select;
  endclocking
endinterface

