module input_scheduler #(
    parameter WIDTH  = 8,
    parameter I_SIZE = 1024,
    parameter M      = 64
) (
    input  logic                      clk_i,
    input  logic                      rstn_i,
    input  logic                      active_i,
    input  logic                      read_en_i,
    input  logic                      ext_en_i,
    input  logic                      ext_valid_i,
    input  logic [3:0][WIDTH-1:0]     ext_data_i,
    input  logic [$clog2(M)-1:0]      cycle_i,
    input  logic [$clog2(M+1)-1:0]    act_m_size_i,
    input  logic [$clog2(I_SIZE)-1:0] act_k_col_base_i,
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
logic [$clog2((M >> 2)+1)-1:0] act_m_tile_idx;
logic [1:0] act_row_in_tile;

logic [3:0][WIDTH-1:0] act_selected;
logic                 act_valid;

assign act_selected = ext_en_i ? ext_data_i : mem_data_i;
assign act_valid    = ext_en_i ? ext_valid_i : response_valid;

// Coordinates of the activation word currently requested from memory.
assign act_m_tile_idx = (read_en_i && cycle_i < act_m_size_i) ? (cycle_i >> 2) : '0;
assign act_row_in_tile = cycle_i[1:0];

assign mem_cenb_o      = !(read_en_i && cycle_i < act_m_size_i && !ext_en_i);
assign mem_wenb_o      = 1'b1;
assign mem_addr_o      = act_k_col_base_i + act_m_tile_idx * 4 + act_row_in_tile;
// The final response of one tile arrives during cycle 0 of the next tile.
always_ff @(posedge clk_i) begin
    if (!rstn_i)
        response_valid <= 1'b0;
    else
        response_valid <= !ext_en_i && read_en_i && cycle_i < act_m_size_i;
end

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
      act_delay_row1    <= act_valid ? act_selected[1] : '0;
      act_delay_row2[0] <= act_valid ? act_selected[2] : '0;
      act_delay_row2[1] <= act_delay_row2[0];
      act_delay_row3[0] <= act_valid ? act_selected[3] : '0;
      act_delay_row3[1] <= act_delay_row3[0];
      act_delay_row3[2] <= act_delay_row3[1];
    end
end

assign act_o[0] = act_valid ? act_selected[0] : '0;
assign act_o[1] = act_delay_row1;
assign act_o[2] = act_delay_row2[1];
assign act_o[3] = act_delay_row3[2];

endmodule
