module pe_3 #(
    parameter WIDTH = 8,
    parameter ACCUM_WIDTH = 18
) (
    input  logic                          clk_i,
    input  logic                          rstn_i,

    input  logic                          weight_en_i,
    output logic                          weight_en_o,
    input  logic signed [WIDTH-1:0]       weight_i,

    input  logic signed [WIDTH-1:0]       act_i,
    output logic signed [WIDTH-1:0]       act_o,

    input  logic signed [ACCUM_WIDTH-1:0] psum_i,
    output logic signed [ACCUM_WIDTH-1:0] psum_o
);

//weight fixed, only enable signal shifts down
//enable 1 cycle pulse
//enable column1->column2->column3->column4

logic signed [WIDTH-1:0] weight_reg;

always_ff @(posedge clk_i) begin
    if (!rstn_i)
        weight_en_o <= 1'b0;
    else
        weight_en_o <= weight_en_i;
end

always_ff @ (posedge clk_i) begin //weight
    if(!rstn_i) begin
        weight_reg <= 'd0;
    end else if(weight_en_i) begin
        weight_reg <= weight_i;
    end
end

always_ff @ (posedge clk_i) begin //act
    if(!rstn_i) begin
        act_o <= 'd0;
    end else begin
        act_o <= act_i;
    end
end

always_ff @ (posedge clk_i) begin //psum, MAC
    if(!rstn_i) begin
        psum_o <= 'd0;
    end else begin
        psum_o <= psum_i + act_i * (weight_en_i ? weight_i : weight_reg); //caution, weight only once
    end
end

endmodule
