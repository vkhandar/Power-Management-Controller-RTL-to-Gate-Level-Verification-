module pmic_assertions (
  input wire clk, arst_n,
  input wire cfg_req, cfg_ready,
  input wire power_enable, pwm_out, pgood,
  input wire [2:0] fault_status,
  input wire [15:0] command_mv
);
  property p_request_acknowledged;
    @(posedge clk) disable iff (!arst_n) cfg_req |-> cfg_ready;
  endproperty
  property p_fault_shutdown;
    @(posedge clk) disable iff (!arst_n) (|fault_status) |=> !power_enable;
  endproperty
  property p_pgood_is_safe;
    @(posedge clk) disable iff (!arst_n) pgood |-> (power_enable && !(|fault_status));
  endproperty
  property p_pwm_off_when_disabled;
    @(posedge clk) disable iff (!arst_n) !power_enable |=> !pwm_out;
  endproperty
  property p_command_zero_after_disable;
    @(posedge clk) disable iff (!arst_n) !power_enable |=> (command_mv==0);
  endproperty
  a_request_acknowledged: assert property(p_request_acknowledged);
  a_fault_shutdown: assert property(p_fault_shutdown);
  a_pgood_is_safe: assert property(p_pgood_is_safe);
  a_pwm_off_when_disabled: assert property(p_pwm_off_when_disabled);
  a_command_zero_after_disable: assert property(p_command_zero_after_disable);
  c_fault_then_shutdown: cover property(@(posedge clk) disable iff(!arst_n)
                                        (|fault_status) ##1 !power_enable);
  c_power_good: cover property(@(posedge clk) disable iff(!arst_n) pgood);
endmodule

