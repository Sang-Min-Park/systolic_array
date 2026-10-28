`timescale 1ns/1ps
module tb_external_bist;
import matrix_mult_pkg::*;
logic clk_i = 0;
always #5 clk_i = ~clk_i;
logic rstn_async_i = 0;
logic ext_en_i = 1;
logic start_i = 0;
logic en_i = 1;
test_config_struct test_config;
data_config_struct data_config;
external_inputs_struct ext_inputs;
extra_output_bits_struct extra_output_bits;
wire [63:0] ext_result;
wire ext_valid;
wire ib_cenb, wb_cenb, ob_read_cenb, ob_write_cenb;
integer weight_matrix [0:3][0:3];
logic [31:0] expected_rows [0:511];
logic [31:0] expected_row;
logic [63:0] expected_signature;
integer inputs_seen = 0;
integer outputs_seen = 0;
integer tests = 0;
logic check_signature = 0;
logic check_sa_register = 0;
logic expected_sa_valid = 0;
integer registered_outputs_seen = 0;
integer product_sum;
integer relu_enable = 0;
integer zero_tile_enable = 0;

matrix_mult_wrapper_3 dut (
    .clk_i(clk_i), .rstn_async_i(rstn_async_i), .en_i(en_i),
    .start_i(start_i), .test_config_i(test_config), .data_config_i(data_config),
    .ext_en_i(ext_en_i), .ext_inputs_i(ext_inputs),
    .ext_result_o(ext_result), .ext_valid_o(ext_valid),
    .extra_output_bits_o(extra_output_bits),
    .ib_mem_cenb_o(ib_cenb), .wb_mem_cenb_o(wb_cenb),
    .ob_mem_cenb_R_o(ob_read_cenb), .ob_mem_cenb_W_o(ob_write_cenb),
    .ib_mem_data_i(32'b0), .wb_mem_data_i(32'b0),
    .ob_mem_data_R_i(64'b0), .ob_mem_data_W_i(64'b0)
);

function automatic [63:0] next_pattern(input [63:0] state);
    next_pattern = {state[62:0], state[63] ^ state[62] ^ state[61] ^ state[52]};
endfunction

function automatic [63:0] next_signature(input [63:0] state);
    next_signature = {state[62:0], state[62] ^ state[61] ^ state[60] ^ state[51]};
endfunction

always @(posedge clk_i) begin
    if (dut.rstn_i && ext_en_i) begin
        if (!ib_cenb || !wb_cenb || !ob_read_cenb || !ob_write_cenb)
            $fatal(1, "External/BIST accessed a memory");
        if (dut.ext_valid_i_w) begin
            for (integer col = 0; col < 4; col++) begin
                product_sum = 0;
                for (integer k = 0; k < 4; k++)
                    product_sum = product_sum + $signed(dut.ext_input_w[k])*weight_matrix[k][col];
                if (product_sum < -128) product_sum = -128;
                if (relu_enable && product_sum < 0) product_sum = 0;
                if (product_sum > 127) product_sum = 127;
                expected_rows[inputs_seen][col*8+:8] = product_sum;
            end
            inputs_seen++;
        end
        if (dut.ext_valid_o_w) begin
            if (outputs_seen >= inputs_seen)
                $fatal(1, "Unexpected output valid");
            expected_row = expected_rows[outputs_seen];
            if (dut.ext_result_w !== expected_row)
                $fatal(1, "Output %0d: got=%h expected=%h", outputs_seen, dut.ext_result_w, expected_row);
            if (check_signature) begin
                if (dut.sa_stop_w)
                    $fatal(1, "Analyzer stopped on a valid result");
                expected_signature = next_signature(expected_signature) ^ {32'b0, expected_row};
            end else if (!check_sa_register &&
                         (!ext_valid || ext_result !== {32'b0, expected_row}))
                $fatal(1, "External wrapper output mismatch");
            outputs_seen++;
        end
        if (check_sa_register) begin
            if (ext_valid !== expected_sa_valid)
                $fatal(1, "Analyzer register valid latency mismatch");
            if (ext_valid) begin
                if (registered_outputs_seen >= outputs_seen ||
                    ext_result !== {32'b0, expected_rows[registered_outputs_seen]})
                    $fatal(1, "Analyzer register data mismatch");
                registered_outputs_seen++;
            end
        end
        expected_sa_valid <= dut.ext_valid_o_w;
    end else begin
        expected_sa_valid <= 1'b0;
    end
end

task automatic prepare(input logic bist_test, input integer pattern_count);
    logic [63:0] seed, stop_code;
    begin
        rstn_async_i = 0;
        test_config = '0;
        data_config = '0;
        data_config.extra_config_i[0] = relu_enable[0];
        data_config.extra_config_i[1] = zero_tile_enable[0];
        ext_inputs = '0;
        inputs_seen = 0;
        outputs_seen = 0;
        check_signature = bist_test;
        check_sa_register = 0;
        registered_outputs_seen = 0;
        seed = 64'h123456789abcdef0 ^ tests;
        stop_code = seed;
        for (integer i = 0; i < pattern_count; i++)
            stop_code = next_pattern(stop_code);
        test_config.bypass = bist_test ? 3'b000 : 3'b101;
        test_config.mode = 2'b00;
        test_config.driver_stop_code = stop_code;
        ext_inputs.ext_input = seed[63:32];
        ext_inputs.ext_psum = seed[31:0];
        expected_signature = {seed[31:0], seed[63:32]};
        repeat (3) @(negedge clk_i);
        rstn_async_i = 1;
        repeat (5) @(negedge clk_i);
        if (extra_output_bits.extra_config_o !== {7'b0, relu_enable[0]})
            $fatal(1, "ReLU scan readback mismatch");
        // Send four unskewed weight rows with a four-clock load window.
        ext_inputs.ext_weight_en = 1;
        for (integer row = 0; row < 4; row++) begin
            for (integer col = 0; col < 4; col++) begin
                weight_matrix[row][col] = $urandom_range(0, 14) - 7;
                ext_inputs.ext_weight[col] = weight_matrix[row][col];
            end
            @(negedge clk_i);
        end
        ext_inputs.ext_weight_en = 0;
        repeat (5) @(negedge clk_i);
    end
endtask

task automatic external_case(input integer row_count, input logic insert_bubbles);
    begin
        prepare(0, 4);
        for (integer row = 0; row < row_count; row++) begin
            ext_inputs.ext_valid = 1;
            for (integer k = 0; k < 4; k++)
                ext_inputs.ext_input[k] = $urandom_range(0, 255);
            @(negedge clk_i);
            if (insert_bubbles && row % 3 == 1) begin
                ext_inputs.ext_valid = 0;
                repeat (2) @(negedge clk_i);
            end
        end
        ext_inputs.ext_valid = 0;
        repeat (12) @(negedge clk_i);
        if (inputs_seen != row_count || outputs_seen != row_count)
            $fatal(1, "External input/output count mismatch");
        tests++;
        $display("PASS: external rows=%0d bubbles=%0d", row_count, insert_bubbles);
    end
endtask

task automatic registered_case(input logic register_driver);
    begin
        prepare(0, 4);
        check_sa_register = 1;
        test_config.bypass = register_driver ? 3'b000 : 3'b001;
        test_config.mode = {1'b1, register_driver};
        for (integer row = 0; row < 9; row++) begin
            ext_inputs.ext_valid = !register_driver;
            test_config.driver_valid = register_driver;
            for (integer k = 0; k < 4; k++)
                ext_inputs.ext_input[k] = $urandom_range(0, 255);
            @(negedge clk_i);
            if (row % 3 == 1) begin
                ext_inputs.ext_valid = 0;
                test_config.driver_valid = 0;
                repeat (2) @(negedge clk_i);
            end
        end
        ext_inputs.ext_valid = 0;
        test_config.driver_valid = 0;
        repeat (14) @(negedge clk_i);
        if (inputs_seen != 9 || outputs_seen != 9 || registered_outputs_seen != 9)
            $fatal(1, "Registered input/output count mismatch");
        if (ext_valid)
            $fatal(1, "Analyzer register valid remained high after the stream");
        tests++;
        $display("PASS: registered analyzer driver_register=%0d", register_driver);
    end
endtask

task automatic external_misr_case(input integer row_count,
                                  input logic register_driver,
                                  input logic long_pause,
                                  input logic stop_with_last);
    integer clocks;
    begin
        prepare(0, 4);
        check_signature = 1;
        test_config.bypass = register_driver ? 3'b000 : 3'b001;
        test_config.mode = {1'b0, register_driver};
        for (integer row = 0; row < row_count; row++) begin
            ext_inputs.ext_valid = !register_driver;
            test_config.driver_valid = register_driver;
            for (integer k = 0; k < 4; k++)
                ext_inputs.ext_input[k] = $urandom_range(0, 255);
            if (stop_with_last && row == row_count - 1)
                data_config.extra_config_i[2] = 1;
            @(negedge clk_i);
            data_config.extra_config_i[2] = 0;
            if (long_pause && row == 0) begin
                ext_inputs.ext_valid = 0;
                test_config.driver_valid = 0;
                repeat (14) @(negedge clk_i);
                if (dut.sa_pending_count != 0 || ext_valid || dut.sa_stop_w)
                    $fatal(1, "External MISR stopped during an unfinished stream");
            end
        end
        ext_inputs.ext_valid = 0;
        test_config.driver_valid = 0;
        if (!stop_with_last || row_count == 0) begin
            repeat (12) @(negedge clk_i);
            if (ext_valid || dut.sa_stop_w)
                $fatal(1, "External MISR completed without a stop request");
            data_config.extra_config_i[2] = 1;
            @(negedge clk_i);
            data_config.extra_config_i[2] = 0;
        end
        clocks = 0;
        while (!ext_valid && clocks < 32) begin
            @(negedge clk_i);
            clocks++;
        end
        if (!ext_valid)
            $fatal(1, "External MISR did not complete after its stop request");
        if (inputs_seen != row_count || outputs_seen != row_count ||
            dut.sa_pending_count != 0 || ext_result !== expected_signature)
            $fatal(1, "External MISR count/signature mismatch");
        repeat (3) begin
            @(negedge clk_i);
            if (!ext_valid || ext_result !== expected_signature)
                $fatal(1, "External MISR signature and valid did not remain stable");
        end
        tests++;
        $display("PASS: external MISR rows=%0d driver_register=%0d pause=%0d stop_with_last=%0d",
                 row_count, register_driver, long_pause, stop_with_last);
    end
endtask

task automatic pending_underflow_case;
    begin
        prepare(0, 4);
        test_config.bypass = 3'b001;
        // Inject an unmatched result to exercise the zero-count guard.
        force dut.sa_dut_valid_w = 1'b1;
        @(negedge clk_i);
        release dut.sa_dut_valid_w;
        if (dut.sa_pending_count !== 0)
            $fatal(1, "Pending count wrapped below zero");
        tests++;
        $display("PASS: pending underflow guard");
    end
endtask

task automatic bist_case(input integer row_count, input logic insert_bubbles);
    integer clocks;
    begin
        prepare(1, row_count);
        clocks = 0;
        test_config.driver_valid = 1;
        while (!dut.driver_done_w) begin
            @(negedge clk_i);
            clocks++;
            test_config.driver_valid = !insert_bubbles || clocks % 7 != 2;
        end
        test_config.driver_valid = 0;
        wait (ext_valid);
        @(negedge clk_i);
        if (inputs_seen != row_count || outputs_seen != row_count)
            $fatal(1, "BIST count mismatch: in=%0d out=%0d expected=%0d", inputs_seen, outputs_seen, row_count);
        if (ext_result !== expected_signature)
            $fatal(1, "Signature got=%h expected=%h", ext_result, expected_signature);
        if (dut.sa_pending_count !== 0)
            $fatal(1, "Pending count did not drain");
        repeat (3) begin
            @(negedge clk_i);
            if (!ext_valid || ext_result !== expected_signature)
                $fatal(1, "MISR signature and valid did not remain stable");
        end
        tests++;
        $display("PASS: BIST rows=%0d bubbles=%0d signature=%h", row_count, insert_bubbles, ext_result);
        repeat (2) @(negedge clk_i);
    end
endtask

initial begin : TEST_CASE
    string run_mode;
    `ifdef FSDB
    string fsdb_file;
    `endif

    if (!$value$plusargs("ZERO_TILE=%d", zero_tile_enable))
        zero_tile_enable = 0;
    if (zero_tile_enable != 0 && zero_tile_enable != 1)
        $fatal(1, "ZERO_TILE must be 0 or 1");
    if (!$value$plusargs("RELU=%d", relu_enable))
        relu_enable = 0;
    if (relu_enable != 0 && relu_enable != 1)
        $fatal(1, "RELU must be 0 or 1");

    if (!$value$plusargs("MODE=%s", run_mode))
        run_mode = "all";
    if (run_mode != "all" && run_mode != "external" && run_mode != "bist")
        $fatal(1, "MODE must be all, external, or bist");

    `ifdef FSDB
    if (!$value$plusargs("FSDB=%s", fsdb_file))
        fsdb_file = "external_bist.fsdb";
    $fsdbDumpfile(fsdb_file);
    $fsdbDumpvars(0, tb_external_bist, "+mda");
    `endif

    test_config = '0; data_config = '0; ext_inputs = '0;
    if (run_mode == "all" || run_mode == "external") begin
        external_case(1, 0);
        external_case(4, 0);
        external_case(32, 0);
        external_case(20, 1);
        registered_case(0);
        registered_case(1);
        external_misr_case(0, 0, 0, 0);
        external_misr_case(1, 0, 0, 1);
        external_misr_case(32, 0, 0, 1);
        external_misr_case(9, 0, 1, 0);
        external_misr_case(1, 1, 0, 1);
        external_misr_case(9, 1, 1, 1);
        pending_underflow_case;
    end
    if (run_mode == "all" || run_mode == "bist") begin
        bist_case(1, 0);
        bist_case(4, 0);
        bist_case(32, 0);
        bist_case(25, 1);
    end
    if (run_mode == "all")
        $display("PASS: all %0d external/BIST cases", tests);
    else
        $display("PASS: all %0d %s cases", tests, run_mode);
    $finish;
end
endmodule
