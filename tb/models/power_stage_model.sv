module power_stage_model (
  input  wire        clk,
  input  wire        arst_n,
  input  wire        power_enable,
  input  wire [15:0] command_mv,
  input  wire [15:0] load_ma,
  input  wire        force_ov,
  input  wire        force_uv,
  output reg  [15:0] vout_mv
);
  integer desired;
  integer next_v;
  integer droop;
  always @(posedge clk or negedge arst_n) begin
    if (!arst_n)
      vout_mv <= 0;
    else begin
      droop = load_ma / 20;
      if (!power_enable)
        desired = 0;
      else if (force_ov)
        desired = command_mv + 220;
      else if (force_uv)
        desired = (command_mv > 220) ? command_mv - 220 : 0;
      else
        desired = (command_mv > droop) ? command_mv - droop : 0;

      // First-order response: 1/4 of the remaining error each clock.
      next_v = $signed({1'b0, vout_mv}) +
               (desired - $signed({1'b0, vout_mv})) / 4;
      if (next_v < 0) vout_mv <= 0;
      else if (next_v > 65535) vout_mv <= 16'hffff;
      else vout_mv <= next_v[15:0];
    end
  end
endmodule

