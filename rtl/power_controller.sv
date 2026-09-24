module power_controller (
  input  wire        clk,
  input  wire        arst_n,
  input  wire        cfg_req,
  input  wire        cfg_write,
  input  wire [7:0]  cfg_addr,
  input  wire [31:0] cfg_wdata,
  output reg  [31:0] cfg_rdata,
  output wire        cfg_ready,
  input  wire [15:0] vout_mv,
  input  wire        over_current,
  output reg         pwm_out,
  output reg         power_enable,
  output reg  [15:0] command_mv,
  output reg         pgood,
  output reg  [2:0]  fault_status,
  output wire [1:0]  operating_mode,
  output wire [1:0]  voltage_select
);
  import pmic_pkg::*;

  reg enable_reg, auto_retry;
  reg [1:0] mode_reg, vset_reg;
  reg [7:0] soft_div, pgood_cycles;
  reg [7:0] soft_count, good_count, retry_count;
  reg [7:0] pwm_count;
  reg [15:0] target_mv;
  reg soft_active;
  wire fault_any = |fault_status;
  wire uv_event = power_enable && !soft_active &&
                  (vout_mv < target_mv - 16'd120);
  wire ov_event = power_enable && (vout_mv > target_mv + 16'd120);
  wire fault_event = over_current || uv_event || ov_event;

  assign cfg_ready = cfg_req;
  assign operating_mode = mode_reg;
  assign voltage_select = vset_reg;

  always @* begin
    target_mv = voltage_mv(vset_reg);
    case (cfg_addr)
      ADDR_CTRL:   cfg_rdata = {28'd0, auto_retry, mode_reg, enable_reg};
      ADDR_VSET:   cfg_rdata = {30'd0, vset_reg};
      ADDR_STATUS: cfg_rdata = {24'd0, vset_reg, mode_reg, fault_any,
                                pgood, soft_active, power_enable};
      ADDR_FAULT:  cfg_rdata = {29'd0, fault_status};
      ADDR_TIMING: cfg_rdata = {16'd0, pgood_cycles, soft_div};
      default:     cfg_rdata = 32'hdead_bad0;
    endcase
  end

  always @(posedge clk or negedge arst_n) begin
    if (!arst_n) begin
      enable_reg   <= 1'b0;
      auto_retry   <= 1'b0;
      mode_reg     <= MODE_PWM;
      vset_reg     <= 2'd1;
      soft_div     <= 8'd4;
      pgood_cycles <= 8'd8;
      soft_count   <= 0;
      good_count   <= 0;
      retry_count  <= 0;
      pwm_count    <= 0;
      command_mv   <= 0;
      power_enable <= 0;
      pgood         <= 0;
      fault_status <= 0;
      soft_active  <= 0;
      pwm_out      <= 0;
    end else begin
      pwm_count <= pwm_count + 1'b1;

      if (cfg_req && cfg_write) begin
        case (cfg_addr)
          ADDR_CTRL: begin
            enable_reg <= cfg_wdata[0];
            mode_reg   <= cfg_wdata[2:1];
            auto_retry <= cfg_wdata[3];
          end
          ADDR_VSET: vset_reg <= cfg_wdata[1:0];
          ADDR_FAULT: fault_status <= fault_status & ~cfg_wdata[2:0];
          ADDR_TIMING: begin
            soft_div <= (cfg_wdata[7:0] == 0) ? 1 : cfg_wdata[7:0];
            pgood_cycles <= (cfg_wdata[15:8] == 0) ? 1 : cfg_wdata[15:8];
          end
          default: ;
        endcase
      end

      if (over_current)
        fault_status[0] <= 1'b1;
      if (uv_event)
        fault_status[1] <= 1'b1;
      if (ov_event)
        fault_status[2] <= 1'b1;

      if (!enable_reg) begin
        power_enable <= 0;
        command_mv <= 0;
        soft_active <= 0;
        pgood <= 0;
        good_count <= 0;
        retry_count <= 0;
      end else if (fault_any || fault_event) begin
        power_enable <= 0;
        command_mv <= 0;
        soft_active <= 0;
        pgood <= 0;
        good_count <= 0;
        if (auto_retry && !over_current) begin
          retry_count <= retry_count + 1'b1;
          if (retry_count == 8'd63) begin
            fault_status <= 0;
            retry_count <= 0;
          end
        end
      end else begin
        power_enable <= 1;
        retry_count <= 0;
        if (!power_enable) begin
          command_mv <= 0;
          soft_active <= 1;
          soft_count <= 0;
        end else if (soft_active) begin
          if (soft_count >= soft_div - 1'b1) begin
            soft_count <= 0;
            if (command_mv + 16'd50 >= target_mv) begin
              command_mv <= target_mv;
              soft_active <= 0;
            end else
              command_mv <= command_mv + 16'd50;
          end else
            soft_count <= soft_count + 1'b1;
        end else begin
          command_mv <= target_mv;
        end

        if (!soft_active && vout_mv >= target_mv - 16'd40 &&
            vout_mv <= target_mv + 16'd40) begin
          if (good_count < pgood_cycles)
            good_count <= good_count + 1'b1;
          if (good_count >= pgood_cycles - 1'b1)
            pgood <= 1;
        end else begin
          good_count <= 0;
          pgood <= 0;
        end
      end

      if (!power_enable || fault_any)
        pwm_out <= 0;
      else if (mode_reg == MODE_PFM)
        pwm_out <= (vout_mv + 16'd10 < command_mv) && (pwm_count[2:0] == 0);
      else if (mode_reg == MODE_ECO)
        pwm_out <= (vout_mv < command_mv) && !pwm_count[0];
      else
        // 12% PWM-count duty per volt.  Keep the intermediate below 16 bits.
        pwm_out <= (pwm_count < ((command_mv * 5'd12) / 16'd100));
    end
  end
endmodule
