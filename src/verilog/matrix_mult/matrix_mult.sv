import matrix_mult_pkg::*;

module matrix_mult #(
    parameter WIDTH             = 8,
    parameter ACCUM_WIDTH       = 16,
    parameter ARRAY_ACCUM_WIDTH = 18,
    parameter Tm                = 4,
    parameter Tn                = 4,
    parameter Tk                = 4,
    parameter M                 = 64,
    parameter N                 = 64,
    parameter K                 = 64,
    parameter W_SIZE            = 1024,
    parameter I_SIZE            = 1024,
    parameter O_SIZE            = 1024
    ) (
    input  logic                                              clk_i,
    input  logic                                              rstn_i,

    //for top-level reasons, please use the *_R_* ports as the read port to psum/output memory
    output logic                                              ob_mem_cenb_R_o,
    output logic                                              ob_mem_wenb_R_o,
    output logic                    [$clog2(O_SIZE)-1:0]      ob_mem_addr_R_o,
    output logic                    [Tn-1:0][ACCUM_WIDTH-1:0] ob_mem_data_R_o,        //read port, so output data port goes unused
    input  logic                    [Tn-1:0][ACCUM_WIDTH-1:0] ob_mem_data_R_i,

    //for top-level reasons, please use the *_W_* ports as the write port to psum/output memory
    output logic                                              ob_mem_cenb_W_o,
    output logic                                              ob_mem_wenb_W_o,
    output logic                    [$clog2(O_SIZE)-1:0]      ob_mem_addr_W_o,
    output logic                    [Tn-1:0][ACCUM_WIDTH-1:0] ob_mem_data_W_o,
    input  logic                    [Tn-1:0][ACCUM_WIDTH-1:0] ob_mem_data_W_i,        //write port, so input data port goes unused

    output logic                                              ib_mem_cenb_o,
    output logic                                              ib_mem_wenb_o,
    output logic                    [$clog2(I_SIZE)-1:0]      ib_mem_addr_o,
    input  logic                    [Tm-1:0][WIDTH-1:0]       ib_mem_data_i,

    output logic                                              wb_mem_cenb_o,
    output logic                                              wb_mem_wenb_o,
    output logic                    [$clog2(W_SIZE)-1:0]      wb_mem_addr_o,
    input  logic                    [Tn-1:0][WIDTH-1:0]       wb_mem_data_i,

    input  logic                                              ext_en_i,
    input  external_inputs_struct                             ext_inputs_i,
    output logic                    [Tn-1:0][WIDTH-1:0]       ext_result_o,
    output logic                                              ext_valid_o,

    input  logic                                              start_i,
    output logic                                              done_o,
    input  data_config_struct                                 data_config_i,
    output extra_output_bits_struct                           extra_output_bits_o
    );

typedef enum logic [1:0] {
    IDLE, 
    COMPUTE, 
    DONE
    } matrix_mult_state;

matrix_mult_state current_state, next_state;

logic start_d;
logic [3:0] cycle;
logic output_done;
logic active;


// Start edge detector by delaying
always_ff @(posedge clk_i) begin
    if (!rstn_i)
        start_d <= 1'b0;
    else
        start_d <= start_i;
end

// State transition
always_ff @(posedge clk_i) begin
    if (!rstn_i)
        current_state <= IDLE;
    else
        current_state <= next_state;
end

// Next-state logic.
always_comb begin
    next_state = current_state;
    case (current_state)
        IDLE: begin
            if (start_i && !start_d)
                next_state = COMPUTE;
        end
        COMPUTE: begin
            if (output_done)
                next_state = DONE;
        end
        DONE: begin
            next_state = IDLE;
        end
        default: next_state = IDLE;
    endcase
end

// Registered outputs and compute-cycle counter.
always_ff @(posedge clk_i) begin
    if (!rstn_i) begin
        cycle  <= '0;
        done_o <= 1'b0;
    end else begin
        case (current_state)
            IDLE: begin
            end
            COMPUTE: begin
                if (output_done) begin
                    cycle  <= '0;
                    done_o <= 1'b1;
                end else
                    cycle <= cycle + 1'b1;
            end
            DONE: begin
                done_o <= 1'b0;
            end
        endcase
    end
end

//don't care
assign ob_mem_cenb_R_o     = 1'b1;
assign ob_mem_wenb_R_o     = 1'b1;
assign ob_mem_addr_R_o     =   '0;
assign ob_mem_data_R_o     =   '0;
assign ext_result_o        =   '0;
assign ext_valid_o         = 1'b0;
assign extra_output_bits_o =   '0;

//active
assign active = (current_state == COMPUTE);

////////////**PE Instantiation**///////////////

// Scheduler signals
logic signed [WIDTH-1:0] act_scheduled [3:0];
logic signed [WIDTH-1:0] weight_scheduled [3:0];
logic              [3:0] weight_en;

// Inter-PE connections
logic signed [WIDTH-1:0] act_link [3:0][4:0];

logic weight_en_link [4:0][3:0];

logic signed [ARRAY_ACCUM_WIDTH-1:0] psum_link [4:0][3:0];

// Outputs to the output scheduler
logic signed [ARRAY_ACCUM_WIDTH-1:0] psum_result [3:0];

// West boundary
for (genvar r = 0; r < 4; r++) begin : gen_west
    assign act_link[r][0] = act_scheduled[r];
end

// North boundary
for (genvar c = 0; c < 4; c++) begin : gen_north
    assign weight_en_link[0][c] = weight_en[c];
    assign psum_link[0][c]   = '0;
end

// South boundary
for (genvar c = 0; c < 4; c++) begin : gen_south
    assign psum_result[c] = psum_link[4][c];
end

// 4x4 PE array
for (genvar r = 0; r < 4; r++) begin : gen_row
    for (genvar c = 0; c < 4; c++) begin : gen_col
        pe #(
            .WIDTH             (WIDTH),
            .ACCUM_WIDTH       (ARRAY_ACCUM_WIDTH)
        ) u_pe (
            .clk_i             (clk_i),
            .rstn_i            (rstn_i),

            .weight_en_i       (weight_en_link[r][c]),
            .weight_en_o       (weight_en_link[r+1][c]),
            .weight_i          (weight_scheduled[c]),

            .act_i             (act_link[r][c]),
            .act_o             (act_link[r][c+1]),

            .psum_i            (psum_link[r][c]),
            .psum_o            (psum_link[r+1][c])
        );
    end
end

weight_scheduler #(
    .WIDTH             (WIDTH),
    .W_SIZE            (W_SIZE)
) u_weight_scheduler (
    .clk_i             (clk_i),
    .rstn_i            (rstn_i),
    .active_i          (active),
    .cycle_i           (cycle),
    .mem_data_i        (wb_mem_data_i),
    .mem_cenb_o        (wb_mem_cenb_o),
    .mem_wenb_o        (wb_mem_wenb_o),
    .mem_addr_o        (wb_mem_addr_o),
    .weight_en_o       (weight_en),
    .weight_o          (weight_scheduled)
);

input_scheduler #(
    .WIDTH             (WIDTH),
    .I_SIZE            (I_SIZE)
) u_input_scheduler (
    .clk_i             (clk_i),
    .rstn_i            (rstn_i),
    .active_i          (active),
    .cycle_i           (cycle),
    .mem_data_i        (ib_mem_data_i),
    .mem_cenb_o        (ib_mem_cenb_o),
    .mem_wenb_o        (ib_mem_wenb_o),
    .mem_addr_o        (ib_mem_addr_o),
    .act_o             (act_scheduled)
);

output_scheduler #(
    .WIDTH             (WIDTH),
    .ARRAY_ACCUM_WIDTH (ARRAY_ACCUM_WIDTH),
    .ACCUM_WIDTH       (ACCUM_WIDTH),
    .O_SIZE            (O_SIZE)
) u_output_scheduler (
    .clk_i             (clk_i),
    .rstn_i            (rstn_i),
    .active_i          (active),
    .cycle_i           (cycle),
    .psum_i            (psum_result),
    .mem_cenb_o        (ob_mem_cenb_W_o),
    .mem_wenb_o        (ob_mem_wenb_W_o),
    .mem_addr_o        (ob_mem_addr_W_o),
    .mem_data_o        (ob_mem_data_W_o),
    .done_o            (output_done)
);

endmodule
