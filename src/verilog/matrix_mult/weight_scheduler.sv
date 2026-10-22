module weight_scheduler #(
    parameter WIDTH  = 8,
    parameter W_SIZE = 1024
) (
    input  logic                      clk_i,
    input  logic                      rstn_i,
    input  logic                      active_i,
    input  logic [3:0]                cycle_i,
    input  logic [3:0][WIDTH-1:0]     mem_data_i,

    output logic                      mem_cenb_o,
    output logic                      mem_wenb_o,
    output logic [$clog2(W_SIZE)-1:0] mem_addr_o,
    output logic [3:0]                weight_en_o,
    output wire signed [WIDTH-1:0]    weight_o [3:0]
);

logic [WIDTH-1:0] weight_delay_col1;
logic [WIDTH-1:0] weight_delay_col2 [1:0];
logic [WIDTH-1:0] weight_delay_col3 [2:0];
logic                 load_pulse;
logic [2:0]           load_delay;

//memory controller
assign mem_cenb_o = !(active_i && cycle_i < 4);
assign mem_wenb_o = 1'b1;
assign mem_addr_o = (active_i && cycle_i < 4) ? cycle_i : '0; //initial weight setting

assign load_pulse = active_i && cycle_i == 1;

//first  column no delay,
//second column  1 delay,
//third  column  2 delay,
//fourth column  3 delay,
always_ff @(posedge clk_i) begin
    if (!rstn_i) begin
        weight_delay_col1 <= '0;
        weight_delay_col2 <= '{default: '0};
        weight_delay_col3 <= '{default: '0};
        load_delay       <= '0;
    end else if (!active_i) begin
        weight_delay_col1 <= '0;
        weight_delay_col2 <= '{default: '0};
        weight_delay_col3 <= '{default: '0};
        load_delay       <= '0;
    end else begin
        weight_delay_col1    <= mem_data_i[1];
        weight_delay_col2[0] <= mem_data_i[2];
        weight_delay_col2[1] <= weight_delay_col2[0];
        weight_delay_col3[0] <= mem_data_i[3];
        weight_delay_col3[1] <= weight_delay_col3[0];
        weight_delay_col3[2] <= weight_delay_col3[1];
        load_delay[0]      <= load_pulse;
        load_delay[1]      <= load_delay[0];
        load_delay[2]      <= load_delay[1];
    end
end

assign weight_o[0] = mem_data_i[0];
assign weight_o[1] = weight_delay_col1;
assign weight_o[2] = weight_delay_col2[1];
assign weight_o[3] = weight_delay_col3[2];
assign weight_en_o = active_i ? {load_delay, load_pulse} : 4'b0000; //load pulse 1cycle each for 4columns

endmodule
