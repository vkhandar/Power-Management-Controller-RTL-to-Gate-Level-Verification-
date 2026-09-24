package pmic_pkg;
  localparam [7:0] ADDR_CTRL   = 8'h00;
  localparam [7:0] ADDR_VSET   = 8'h04;
  localparam [7:0] ADDR_STATUS = 8'h08;
  localparam [7:0] ADDR_FAULT  = 8'h0c;
  localparam [7:0] ADDR_TIMING = 8'h10;

  localparam [1:0] MODE_PWM = 2'd0;
  localparam [1:0] MODE_PFM = 2'd1;
  localparam [1:0] MODE_ECO = 2'd2;

  localparam [2:0] FAULT_OC = 3'b001;
  localparam [2:0] FAULT_UV = 3'b010;
  localparam [2:0] FAULT_OV = 3'b100;

  function automatic [15:0] voltage_mv(input [1:0] sel);
    case (sel)
      2'd0: voltage_mv = 16'd800;
      2'd1: voltage_mv = 16'd1000;
      2'd2: voltage_mv = 16'd1200;
      default: voltage_mv = 16'd1500;
    endcase
  endfunction
endpackage

