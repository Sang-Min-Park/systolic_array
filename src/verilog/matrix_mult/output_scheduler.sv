module output_scheduler_3 #(
    parameter WIDTH             = 8,
    parameter ARRAY_ACCUM_WIDTH = 18,
    parameter ACCUM_WIDTH       = 16,
    parameter O_SIZE            = 1024,
    parameter M                 = 64,
    parameter N                 = 64,
    parameter K                 = 64
) (
    input  logic                               clk_i,
    input  logic                               rstn_i,
    input  logic                               active_i,
    input  logic                               ext_en_i,
    input  logic                               relu_en_i,
    input  logic                               ext_act_valid_i,
    output logic [3:0][WIDTH-1:0]              ext_result_o,
    output logic                               ext_valid_o,
    input  logic                               act_request_i,
    input  logic                               zero_tile_skip_i,
    input  logic [$clog2(M+1)-1:0]             rst_m_size_i,
    input  logic [$clog2(N+1)-1:0]             rst_n_size_i,
    input  logic [$clog2(K+1)-1:0]             wgt_k_size_i,
    input  logic [$clog2(O_SIZE)-1:0]          rst_mem_offset_i,
    input  logic [3:0][ACCUM_WIDTH-1:0]        mem_data_R_i,
    output logic                               mem_cenb_R_o,
    output logic                               mem_wenb_R_o,
    output logic [$clog2(O_SIZE)-1:0]          mem_addr_R_o,
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
localparam logic signed [WIDTH-1:0] MIN_RESULT = {1'b1, {(WIDTH-1){1'b0}}};

//column0 3delay, 
//column1 2delay, 
//column2 1delay, 
//column3 no delay  
always_ff @(posedge clk_i) begin
    if (!rstn_i) begin
        psum_delay_col0 <= '{default: '0};
        psum_delay_col1 <= '{default: '0};
        psum_delay_col2 <= '0;
    end else if (!(active_i || ext_en_i)) begin
        psum_delay_col0 <= '{default: '0};
        psum_delay_col1 <= '{default: '0};
        psum_delay_col2 <= '0;
    end else begin
        psum_delay_col0[0] <= psum_i[0];
        psum_delay_col0[1] <= psum_delay_col0[0];
        psum_delay_col0[2] <= psum_delay_col0[1];
        psum_delay_col1[0] <= psum_i[1];
        psum_delay_col1[1] <= psum_delay_col1[0];
        psum_delay_col2 <= psum_i[2];
    end
end

assign psum_aligned[0] = psum_delay_col0[2];
assign psum_aligned[1] = psum_delay_col1[1];
assign psum_aligned[2] = psum_delay_col2;
assign psum_aligned[3] = psum_i[3];

// Delay request validity to the aligned result, independent of input tiles.
logic [7:0] rst_valid_pipe;
logic [6:0] zero_tile_skip_pipe;
logic rst_read_valid, rst_aligned_valid;
logic [$clog2(M+1)-1:0] rst_read_row_idx;
// K-tile accumulation iteration; advances after all M rows (0 to K/4 - 1).
logic [$clog2((K >> 2)+1)-1:0] rst_k_iteration_idx;
logic [$clog2((N >> 2)+1)-1:0] rst_read_n_tile_idx;
logic [$clog2((M >> 2)+1)-1:0] rst_read_m_tile_idx, rst_m_tile_idx;
logic [1:0] rst_read_row_in_tile, rst_row_in_tile;
logic [$clog2((N >> 2)+1)-1:0] rst_n_tile_idx;
logic [$clog2(O_SIZE)-1:0] rst_read_addr;
logic rst_first_k_tile, rst_last_k_tile, rst_last_word;
localparam SUM_WIDTH = ((ARRAY_ACCUM_WIDTH > ACCUM_WIDTH) ?
                        ARRAY_ACCUM_WIDTH : ACCUM_WIDTH) + 1;
logic signed [SUM_WIDTH-1:0] accumulated [3:0];
logic [3:0][WIDTH-1:0] final_result;
localparam logic signed [ACCUM_WIDTH-1:0] MAX_PSUM =
    {1'b0, {(ACCUM_WIDTH-1){1'b1}}};
localparam logic signed [ACCUM_WIDTH-1:0] MIN_PSUM =
    {1'b1, {(ACCUM_WIDTH-1){1'b0}}};

// Prefetch the stored partial sum one cycle before the aligned array result.
assign rst_read_valid = active_i && rst_valid_pipe[6];
assign rst_aligned_valid = active_i && rst_valid_pipe[7];
// External inputs reach the array one clock earlier than memory responses.
assign ext_valid_o = ext_en_i && rst_valid_pipe[6];
assign ext_result_o = ext_en_i ? final_result : '0;
assign rst_read_m_tile_idx = (rst_read_row_idx >> 2);
assign rst_read_row_in_tile = rst_read_row_idx[1:0];
assign rst_read_addr = rst_mem_offset_i + rst_read_n_tile_idx * rst_m_size_i
                    + rst_read_m_tile_idx * 4 + rst_read_row_in_tile;

// Share the result-valid pipeline between memory and external inputs.
always_ff @(posedge clk_i) begin
    if (!rstn_i)
        rst_valid_pipe <= '0;
    else if (!(active_i || ext_en_i))
        rst_valid_pipe <= '0;
    else
        rst_valid_pipe <= {rst_valid_pipe[6:0],
                           ext_en_i ? ext_act_valid_i : act_request_i};
end

// Advance output coordinates after the last retained zero row reaches prefetch.
// Preserve the data/valid pipeline so older tiles and retained writes still drain.
always_ff @(posedge clk_i) begin
    if (!rstn_i || !active_i)
        zero_tile_skip_pipe <= '0;
    else
        zero_tile_skip_pipe <= {zero_tile_skip_pipe[5:0], zero_tile_skip_i};
end

always_ff @(posedge clk_i) begin
    if (!rstn_i) begin
        rst_read_row_idx <= '0;
        rst_k_iteration_idx <= '0;
        rst_read_n_tile_idx <= '0;
    end else if (!active_i) begin
        rst_read_row_idx <= '0;
        rst_k_iteration_idx <= '0;
        rst_read_n_tile_idx <= '0;
    end else begin
        if (zero_tile_skip_pipe[6]) begin
            rst_read_row_idx <= '0;
            rst_k_iteration_idx <= rst_k_iteration_idx + 1'b1;
        end else if (rst_read_valid) begin
            if (rst_read_row_idx == rst_m_size_i - 1) begin
                rst_read_row_idx <= '0;
                if (rst_k_iteration_idx == (wgt_k_size_i >> 2) - 1) begin
                    rst_k_iteration_idx <= '0;
                    rst_read_n_tile_idx <= rst_read_n_tile_idx + 1'b1;
                end else
                    rst_k_iteration_idx <= rst_k_iteration_idx + 1'b1;
            end else
                rst_read_row_idx <= rst_read_row_idx + 1'b1;
        end
    end
end

// Delay the prefetch metadata to match the memory response and psum_aligned.
always_ff @(posedge clk_i) begin
    if (!rstn_i) begin
        rst_first_k_tile <= 1'b0;
        rst_last_k_tile <= 1'b0;
        rst_last_word <= 1'b0;
        rst_m_tile_idx <= '0;
        rst_n_tile_idx <= '0;
        rst_row_in_tile <= '0;
    end else begin
        if (rst_read_valid) begin
            rst_first_k_tile <= rst_k_iteration_idx == 0;
            rst_last_k_tile <= rst_k_iteration_idx == (wgt_k_size_i >> 2) - 1;
            rst_last_word <= (rst_read_row_idx == rst_m_size_i - 1) &&
                             (rst_k_iteration_idx == (wgt_k_size_i >> 2) - 1) &&
                             (rst_read_n_tile_idx == (rst_n_size_i >> 2) - 1);
            rst_m_tile_idx <= rst_read_m_tile_idx;
            rst_n_tile_idx <= rst_read_n_tile_idx;
            rst_row_in_tile <= rst_read_row_in_tile;
        end
    end
end

assign mem_wenb_R_o = 1'b1;
assign mem_cenb_R_o = !(rst_read_valid && rst_k_iteration_idx != 0);
assign mem_addr_R_o = !mem_cenb_R_o ? rst_read_addr : '0;

for (genvar c = 0; c < 4; c++) begin : gen_accumulate
    assign accumulated[c] = SUM_WIDTH'(psum_aligned[c]) +
        ((ext_en_i || rst_first_k_tile) ? SUM_WIDTH'(0) : SUM_WIDTH'($signed(mem_data_R_i[c])));
end

// ReLU is optional; signed INT8 saturation remains enabled in every mode.
always_comb begin
    for (integer c = 0; c < 4; c++) begin
        if (relu_en_i && accumulated[c] < 0)
            final_result[c] = '0;
        else if (accumulated[c] > MAX_RESULT)
            final_result[c] = MAX_RESULT;
        else if (accumulated[c] < MIN_RESULT)
            final_result[c] = MIN_RESULT;
        else
            final_result[c] = accumulated[c];
    end
end

always_comb begin
    mem_cenb_o = 1'b1;
    mem_wenb_o = 1'b1;
    mem_addr_o = '0;
    mem_data_o = '0;
    done_o     = 1'b0;
    if (rst_aligned_valid) begin
        mem_cenb_o = 1'b0;
        mem_wenb_o = 1'b0;
        mem_addr_o = rst_mem_offset_i + rst_n_tile_idx * rst_m_size_i
                   + rst_m_tile_idx * 4 + rst_row_in_tile;
        for (integer c = 0; c < 4; c++) begin
            if (rst_last_k_tile) begin
                // Apply final clipping and optional ReLU after all K tiles.
                mem_data_o[c] = $signed(final_result[c]);
            end else begin
                if (accumulated[c] > MAX_PSUM)
                    mem_data_o[c] = MAX_PSUM;
                else if (accumulated[c] < MIN_PSUM)
                    mem_data_o[c] = MIN_PSUM;
                else
                    mem_data_o[c] = ACCUM_WIDTH'(accumulated[c]);
            end
        end
        done_o = rst_last_word;
    end
end
endmodule
