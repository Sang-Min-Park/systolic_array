module input_scheduler #(
    parameter WIDTH  = 8,
    parameter I_SIZE = 1024
) (
    input  logic                      clk_i,
    input  logic                      rstn_i,
    input  logic                      active_i,
    input  logic [3:0]                cycle_i,
    input  logic [3:0][WIDTH-1:0]     mem_data_i,
    output logic                      mem_cenb_o,
    output logic                      mem_wenb_o,
    output logic [$clog2(I_SIZE)-1:0] mem_addr_o,
    output wire signed [WIDTH-1:0]    act_o [3:0]
);
logic [WIDTH-1:0] act_delay_row1;
logic [WIDTH-1:0] act_delay_row2 [1:0];
logic [WIDTH-1:0] act_delay_row3 [2:0];
logic             response_valid;

assign mem_cenb_o      = !(active_i && cycle_i < 4);
assign mem_wenb_o      = 1'b1;
assign mem_addr_o      = cycle_i;
assign response_valid = active_i && cycle_i >= 1 && cycle_i <= 4;

//row 0 no delay
//row 1 1  delay
//row 2 2  delay
//row 3 3  delay
always_ff @(posedge clk_i) begin
    if (!rstn_i) begin
        act_delay_row1 <= '0;
        act_delay_row2 <= '{default: '0};
        act_delay_row3 <= '{default: '0};
    end else if (!active_i) begin
        act_delay_row1 <= '0;
        act_delay_row2 <= '{default: '0};
        act_delay_row3 <= '{default: '0};
    end else begin
        act_delay_row1    <= response_valid ? mem_data_i[1] : '0; //only when response valid, after read request
        act_delay_row2[0] <= response_valid ? mem_data_i[2] : '0;
        act_delay_row2[1] <= act_delay_row2[0];
        act_delay_row3[0] <= response_valid ? mem_data_i[3] : '0;
        act_delay_row3[1] <= act_delay_row3[0];
        act_delay_row3[2] <= act_delay_row3[1];
    end
end

assign act_o[0] = response_valid ? mem_data_i[0] : '0;
assign act_o[1] = act_delay_row1;
assign act_o[2] = act_delay_row2[1];
assign act_o[3] = act_delay_row3[2];

endmodule
