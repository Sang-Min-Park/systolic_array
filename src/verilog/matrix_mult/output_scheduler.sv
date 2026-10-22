module output_scheduler #(
    parameter WIDTH             = 8,
    parameter ARRAY_ACCUM_WIDTH = 18,
    parameter ACCUM_WIDTH       = 16,
    parameter O_SIZE            = 1024
) (
    input  logic                               clk_i,
    input  logic                               rstn_i,
    input  logic                               active_i,
    input  logic [3:0]                         cycle_i,
    input  wire signed [ARRAY_ACCUM_WIDTH-1:0] psum_i [3:0],
    output logic                               mem_cenb_o,
    output logic                               mem_wenb_o,
    output logic [$clog2(O_SIZE)-1:0]          mem_addr_o,
    output logic [3:0][ACCUM_WIDTH-1:0]        mem_data_o,
    output logic                               done_o
);
logic signed [ARRAY_ACCUM_WIDTH-1:0] psum_delay_col0 [2:0];
logic signed [ARRAY_ACCUM_WIDTH-1:0] psum_delay_col1 [1:0];
logic signed [ARRAY_ACCUM_WIDTH-1:0] psum_delay_col2;
wire  signed [ARRAY_ACCUM_WIDTH-1:0] psum_aligned [3:0];

localparam logic signed [WIDTH-1:0] MAX_RESULT = {1'b0, {(WIDTH-1){1'b1}}}; //max clipping
localparam logic signed [WIDTH-1:0] MIN_RESULT = {1'b1, {(WIDTH-1){1'b0}}}; //min clipping

//column0 3delay, 
//column1 2delay, 
//column2 1delay, 
//column3 no delay  
always_ff @(posedge clk_i) begin
    if (!rstn_i) begin
        psum_delay_col0 <= '{default: '0};
        psum_delay_col1 <= '{default: '0};
        psum_delay_col2 <= '0;
    end else if (!active_i) begin
        psum_delay_col0 <= '{default: '0};
        psum_delay_col1 <= '{default: '0};
        psum_delay_col2 <= '0;
    end else begin
        psum_delay_col0[0] <= psum_i[0];
        psum_delay_col0[1] <= psum_delay_col0[0];
        psum_delay_col0[2] <= psum_delay_col0[1];
        psum_delay_col1[0] <= psum_i[1];
        psum_delay_col1[1] <= psum_delay_col1[0];
        psum_delay_col2    <= psum_i[2];
    end
end

assign psum_aligned[0] = psum_delay_col0[2];
assign psum_aligned[1] = psum_delay_col1[1];
assign psum_aligned[2] = psum_delay_col2;
assign psum_aligned[3] = psum_i[3];

//memory write control
always_comb begin
    mem_cenb_o = 1'b1;
    mem_wenb_o = 1'b1;
    mem_addr_o = '0;
    mem_data_o = '0;
    done_o     = 1'b0;
    if (active_i && cycle_i >= 8 && cycle_i <= 11) begin
        mem_cenb_o = 1'b0;
        mem_wenb_o = 1'b0;
        mem_addr_o = cycle_i - 8;
        for (integer c = 0; c < 4; c++) begin
            if (psum_aligned[c] > MAX_RESULT)
                mem_data_o[c] = ACCUM_WIDTH'($signed(MAX_RESULT));
            else if (psum_aligned[c] < MIN_RESULT)
                mem_data_o[c] = ACCUM_WIDTH'($signed(MIN_RESULT));
            else
                mem_data_o[c] = ACCUM_WIDTH'(psum_aligned[c]);
        end
        done_o = cycle_i == 11;
    end
end
endmodule
