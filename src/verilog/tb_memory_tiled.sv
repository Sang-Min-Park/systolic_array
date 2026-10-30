`timescale 1ns/1ps
module tb_memory_tiled;
    import matrix_mult_pkg::*;

    parameter real CLOCK_PERIOD = 10.0;
    logic clk_i = 0;
    always #(CLOCK_PERIOD / 2.0) clk_i = ~clk_i;
    logic rstn_async_i = 0;
    logic en_i = 1;
    logic start_i = 0;
    logic ext_en_i = 0;
    test_config_struct test_config = '0;
    data_config_struct data_config = '0;
    external_inputs_struct ext_inputs = '0;
    extra_output_bits_struct extra_output_bits;
    wire [63:0] ext_result;
    wire ext_valid, done;
    wire ib_cenb, ib_wenb, wb_cenb, wb_wenb;
    wire [9:0] ib_addr, wb_addr, ob_read_addr, ob_write_addr;
    wire [31:0] ib_data, wb_data;
    wire ob_read_cenb, ob_read_wenb, ob_write_cenb, ob_write_wenb;
    wire [63:0] ob_read_data, ob_read_unused, ob_write_data, ob_write_unused;
    integer reads = 0;
    integer writes = 0;
    integer result_checks = 0;
    logic checking_results = 0;
    integer matrix_tests = 0;
    integer ib_reads = 0, wb_reads = 0;
    integer relu_enable = 0;
    integer zero_tile_enable = 0;
    integer skipped_tiles_total = 0, cycles_saved_total = 0;
    integer matrix_a [0:63][0:63];
    integer matrix_b [0:63][0:63];
    integer golden [0:63][0:63];
    integer reference_partial [0:63][0:63];
    logic [63:0] golden_write_words [0:16383];
    integer golden_write_addresses [0:16383];
    logic expected_skip [0:15][0:15];
    integer golden_write_count, checked_writes;

    matrix_mult_wrapper_3 dut (
        .clk_i(clk_i), .rstn_async_i(rstn_async_i), .en_i(en_i),
        .start_i(start_i), .ext_en_i(ext_en_i),
        .test_config_i(test_config), .data_config_i(data_config),
        .ext_inputs_i(ext_inputs), .ext_result_o(ext_result),
        .ext_valid_o(ext_valid), .done_o(done),
        .extra_output_bits_o(extra_output_bits),
        .ib_mem_cenb_o(ib_cenb), .ib_mem_wenb_o(ib_wenb),
        .ib_mem_addr_o(ib_addr), .ib_mem_data_i(ib_data),
        .wb_mem_cenb_o(wb_cenb), .wb_mem_wenb_o(wb_wenb),
        .wb_mem_addr_o(wb_addr), .wb_mem_data_i(wb_data),
        .ob_mem_cenb_R_o(ob_read_cenb), .ob_mem_wenb_R_o(ob_read_wenb),
        .ob_mem_addr_R_o(ob_read_addr), .ob_mem_data_R_i(ob_read_data),
        .ob_mem_data_R_o(ob_read_unused),
        .ob_mem_cenb_W_o(ob_write_cenb), .ob_mem_wenb_W_o(ob_write_wenb),
        .ob_mem_addr_W_o(ob_write_addr), .ob_mem_data_W_o(ob_write_data),
        .ob_mem_data_W_i(ob_write_unused)
    );

    mem_emulator_3 #(.WIDTH(32), .SIZE(1024)) ib_mem (
        .clk_i(clk_i), .cenb_i(ib_cenb), .wenb_i(ib_wenb),
        .addr_i(ib_addr), .d_i(32'b0), .q_o(ib_data)
    );
    mem_emulator_3 #(.WIDTH(32), .SIZE(1024)) wb_mem (
        .clk_i(clk_i), .cenb_i(wb_cenb), .wenb_i(wb_wenb),
        .addr_i(wb_addr), .d_i(32'b0), .q_o(wb_data)
    );
    mem2p_emulator_3 #(.WIDTH(64), .SIZE(1024)) ob_mem (
        .clk_i(clk_i),
        .cenb_a_i(ob_read_cenb), .wenb_a_i(ob_read_wenb), .addr_a_i(ob_read_addr),
        .d_a_i(ob_read_unused), .q_a_o(ob_read_data),
        .cenb_b_i(ob_write_cenb), .wenb_b_i(ob_write_wenb), .addr_b_i(ob_write_addr),
        .d_b_i(ob_write_data), .q_b_o(ob_write_unused)
    );

    // The SRAMs are outside the wrapper. This testbench loads and checks them.
    always @(posedge clk_i) begin
        if (rstn_async_i) begin
            if (!ib_cenb) begin
                if (!ib_wenb) $fatal(1, "Activation SRAM write requested by DUT");
                ib_reads++;
            end
            if (!wb_cenb) begin
                if (!wb_wenb) $fatal(1, "Weight SRAM write requested by DUT");
                wb_reads++;
            end
            if (!ob_read_cenb) begin
                if (!ob_read_wenb) $fatal(1, "Partial-sum read port attempted a write");
                reads++;
            end
            if (!ob_write_cenb && !ob_write_wenb) begin
                writes++;
                if (checking_results) begin
                    if (checked_writes >= golden_write_count ||
                        ob_write_addr !== golden_write_addresses[checked_writes][9:0] ||
                        ob_write_data !== golden_write_words[checked_writes])
                        $fatal(1, "Partial-sum write mismatch: index=%0d address=%0d data=%h expected=%h",
                               checked_writes, ob_write_addr, ob_write_data, golden_write_words[checked_writes]);
                    checked_writes++;
                end
            end
            if (!ob_read_cenb && !ob_write_cenb && !ob_write_wenb && ob_read_addr == ob_write_addr)
                $fatal(1, "Read/write address collision");
            if (checking_results && (ext_valid !== 1'b0 || ext_result !== 64'b0))
                $fatal(1, "Memory results leaked into the external/analyzer output");
        end
    end

    task automatic reset_dut;
        begin
            en_i = 1;
            rstn_async_i = 0;
            start_i = 0;
            ext_en_i = 0;
            test_config = '0;
            test_config.bypass = 3'b101;
            ext_inputs = '0;
            data_config = '0;
            repeat (3) @(negedge clk_i);
            rstn_async_i = 1;
            repeat (4) @(negedge clk_i);
            if (done !== 0 || ext_valid !== 0)
                $fatal(1, "Reset did not clear completion outputs");
        end
    endtask

    task automatic matrix_case(input integer rows, cols, depth, pattern,
                               input integer input_offset, weight_offset, output_offset);
        integer sum, part, address, previous_reads, previous_writes, clocks;
        integer previous_ib_reads, previous_wb_reads;
        integer skipped_tiles, cycles_saved, expected_requests;
        logic tile_is_zero;
        logic [63:0] expected_word;
        begin
            test_config.bypass = 3'b101;
            test_config.mode = 2'b00;
            ext_inputs.ext_input = 32'h1234abcd ^ rows;
            ext_inputs.ext_psum = 32'hfedc5678 ^ depth;
            data_config = '0;
            data_config.extra_config_i[0] = relu_enable[0];
            data_config.extra_config_i[1] = zero_tile_enable[0];
            data_config.i_rows = rows;
            data_config.w_rows = depth;
            data_config.w_cols = cols;
            data_config.i_offset = input_offset;
            data_config.w_offset = weight_offset;
            data_config.psum_offset = output_offset;
            for (integer r = 0; r < rows; r++)
                for (integer k = 0; k < depth; k++) begin
                    matrix_a[r][k] = (pattern == 0 || (pattern >= 4 && pattern != 11))
                                   ? $urandom_range(0, 14) - 7 : 127;
                    address = input_offset + (k / 4) * rows + r;
                    ib_mem.data[address][(k % 4)*8 +: 8] = matrix_a[r][k];
                end
            for (integer k = 0; k < depth; k++)
                for (integer c = 0; c < cols; c++) begin
                    if (pattern == 0)
                        matrix_b[k][c] = $urandom_range(0, 14) - 7;
                    else if (pattern == 1)
                        matrix_b[k][c] = 127;
                    else if (pattern == 2)
                        matrix_b[k][c] = k < 4 ? 127 : -127;
                    else if (pattern == 3)
                        matrix_b[k][c] = k < 4 ? -127 : 127;
                    else begin
                        matrix_b[k][c] = $urandom_range(0, 14) - 7;
                        case (pattern)
                            4: if (k >= 4 && k < depth - 4) matrix_b[k][c] = 0;
                            5: if (k < 4 || k >= depth - 4) matrix_b[k][c] = 0;
                            6: matrix_b[k][c] = 0;
                            7: matrix_b[k][c] = (k % 4 == 3 && c % 4 == 3) ? 1 : 0;
                            8: matrix_b[k][c] = (k % 4 == 0 && c % 4 == 0) ? -1 : 0;
                            9: if ((k / 4 + c / 4) % 2 == 1) matrix_b[k][c] = 0;
                            10: if (k / 4 == 1 && c / 4 == 1) matrix_b[k][c] = 0;
                            11: matrix_b[k][c] = k < 4 ? 127 : (k >= depth - 4 ? -127 : 0);
                            12: matrix_b[k][c] = (k % 4 == 1 && c % 4 == 1) ? -128 : 0;
                            13: matrix_b[k][c] = (k % 4 == 2 && c % 4 == 2) ? 127 : 0;
                            14: if ((k / 4 * 7 + c / 4 * 11) % 5 < 3) matrix_b[k][c] = 0;
                        endcase
                    end
                    address = weight_offset + (c / 4) * depth + k;
                    wb_mem.data[address][(c % 4)*8 +: 8] = matrix_b[k][c];
                end
            skipped_tiles = 0;
            for (integer nt = 0; nt < cols / 4; nt++) begin
                for (integer kt = 0; kt < depth / 4; kt++)
                    expected_skip[nt][kt] = 0;
                for (integer kt = 1; kt < depth / 4 - 1; kt++) begin
                    tile_is_zero = 1;
                    for (integer r = 0; r < 4; r++)
                        for (integer c = 0; c < 4; c++)
                            if (matrix_b[kt*4+r][nt*4+c] != 0) tile_is_zero = 0;
                    if (zero_tile_enable && rows > 5 && tile_is_zero) begin
                        skipped_tiles++;
                        expected_skip[nt][kt] = 1;
                    end
                end
            end
            cycles_saved = skipped_tiles * (rows - 5);
            expected_requests = rows * (depth / 4) * (cols / 4) - cycles_saved;
            for (integer r = 0; r < rows; r++)
                for (integer c = 0; c < cols; c++) begin
                    sum = 0;
                    for (integer kt = 0; kt < depth / 4; kt++) begin
                        part = 0;
                        for (integer k = 0; k < 4; k++)
                            part += matrix_a[r][kt*4+k] * matrix_b[kt*4+k][c];
                        sum += part;
                        if (kt != depth / 4 - 1) begin
                            if (sum > 32767) sum = 32767;
                            if (sum < -32768) sum = -32768;
                        end
                    end
                    if (sum > 127) sum = 127;
                    if (sum < -128) sum = -128;
                    if (relu_enable && sum < 0) sum = 0;
                    golden[r][c] = sum;
                    address = output_offset + (c / 4) * rows + r;
                    ob_mem.data[address] = 'x;
                end
            // Independent arithmetic reference for every intermediate write and its address.
            golden_write_count = 0;
            for (integer nt = 0; nt < cols / 4; nt++) begin
                for (integer kt = 0; kt < depth / 4; kt++) begin
                    for (integer r = 0; r < rows; r++) begin
                        expected_word = '0;
                        for (integer c = 0; c < 4; c++) begin
                            sum = kt == 0 ? 0 : reference_partial[r][nt*4+c];
                            for (integer k = 0; k < 4; k++)
                                sum += matrix_a[r][kt*4+k] * matrix_b[kt*4+k][nt*4+c];
                            if (kt == depth / 4 - 1) begin
                                if (sum > 127) sum = 127;
                                if (sum < -128) sum = -128;
                                if (relu_enable && sum < 0) sum = 0;
                            end else begin
                                if (sum > 32767) sum = 32767;
                                if (sum < -32768) sum = -32768;
                            end
                            reference_partial[r][nt*4+c] = sum;
                            expected_word[c*16+:16] = sum;
                        end
                        if (!expected_skip[nt][kt] || r < 5) begin
                            golden_write_words[golden_write_count] = expected_word;
                            golden_write_addresses[golden_write_count] = output_offset + nt*rows + r;
                            golden_write_count++;
                        end
                    end
                end
            end
            previous_reads = reads;
            previous_writes = writes;
            previous_ib_reads = ib_reads;
            previous_wb_reads = wb_reads;
            checked_writes = 0;
            checking_results = 1;
            // Extra bit 3 has no memory-access function in the DUT.
            data_config.extra_config_i[3] = 1;
            @(negedge clk_i);
            start_i = 1;
            @(negedge clk_i);
            start_i = 0;
            if (done !== 0) $fatal(1, "DONE did not clear on start");
            // Options and offsets must remain latched during computation.
            data_config.extra_config_i[1] = !zero_tile_enable[0];
            data_config.psum_offset = 1023;
            clocks = 0;
            while (!done && clocks < rows * (depth / 4) * (cols / 4) + 16) begin
                @(negedge clk_i);
                clocks++;
                data_config.extra_config_i[3] = !data_config.extra_config_i[3];
            end
            if (!done || clocks != expected_requests + 8)
                $fatal(1, "Computation timing mismatch: got=%0d expected=%0d", clocks, expected_requests + 8);
            if (checked_writes != golden_write_count || writes != previous_writes + expected_requests ||
                reads != previous_reads + expected_requests - rows * (cols / 4) ||
                ib_reads != previous_ib_reads + expected_requests ||
                wb_reads != previous_wb_reads + depth * (cols / 4))
                $fatal(1, "Memory access count mismatch");
            repeat (3) begin
                @(negedge clk_i);
                if (done !== 1) $fatal(1, "DONE did not remain high");
            end
            checking_results = 0;
            for (integer nt = 0; nt < cols / 4; nt++)
                for (integer r = 0; r < rows; r++) begin
                    expected_word = '0;
                    for (integer c = 0; c < 4; c++)
                        expected_word[c*16+:16] = golden[r][nt*4+c];
                    if (ob_mem.data[output_offset + nt*rows + r] !== expected_word)
                        $fatal(1, "Stored result mismatch at tile column=%0d row=%0d", nt, r);
                    result_checks++;
                end
            matrix_tests++;
            skipped_tiles_total += skipped_tiles;
            cycles_saved_total += cycles_saved;
            $display("PASS: memory M=%0d N=%0d K=%0d pattern=%0d cycles=%0d skipped=%0d saved=%0d",
                     rows, cols, depth, pattern, clocks, skipped_tiles, cycles_saved);
        end
    endtask

    initial begin
        `ifdef FSDB
        $fsdbDumpfile("memory_tiled.fsdb");
        $fsdbDumpvars(0, tb_memory_tiled, "+mda");
        `endif
        `ifdef SDF
        $sdf_annotate("matrix_mult_wrapper_3.sdf", dut, , "memory_tiled_sdf.log", "MAXIMUM");
        `endif
        if (!$value$plusargs("RELU=%d", relu_enable)) relu_enable = 0;
        if (!$value$plusargs("ZERO_TILE=%d", zero_tile_enable)) zero_tile_enable = 0;
        if ((relu_enable != 0 && relu_enable != 1) || (zero_tile_enable != 0 && zero_tile_enable != 1))
            $fatal(1, "RELU and ZERO_TILE must be 0 or 1");
        reset_dut();
        matrix_case(4, 4, 4, 0, 0, 0, 0);
        matrix_case(4, 8, 8, 0, 0, 0, 0);
        matrix_case(8, 8, 8, 1, 0, 0, 0);
        matrix_case(12, 8, 16, 0, 11, 7, 13);
        matrix_case(8, 8, 8, 2, 0, 0, 0);
        matrix_case(8, 8, 8, 3, 0, 0, 0);
        matrix_case(64, 64, 64, 0, 0, 0, 0);
        matrix_case(4, 4, 4, 0, 0, 0, 1020);
        matrix_case(8, 8, 12, 4, 5, 7, 11);
        matrix_case(12, 12, 20, 9, 3, 5, 7);
        matrix_case(8, 8, 16, 5, 0, 0, 0);
        matrix_case(8, 8, 16, 7, 0, 0, 0);
        matrix_case(8, 8, 16, 8, 0, 0, 0);
        matrix_case(4, 8, 16, 6, 0, 0, 0);
        matrix_case(8, 8, 4, 6, 0, 0, 0);
        matrix_case(8, 8, 8, 6, 0, 0, 0);
        matrix_case(16, 12, 16, 10, 0, 0, 0);
        matrix_case(12, 8, 16, 11, 0, 0, 0);
        matrix_case(64, 64, 64, 4, 0, 0, 0);
        matrix_case(64, 64, 64, 6, 0, 0, 0);
        matrix_case(12, 8, 16, 12, 0, 0, 0);
        matrix_case(12, 8, 16, 13, 0, 0, 0);
        matrix_case(20, 12, 24, 14, 5, 7, 11);
        matrix_case(28, 16, 32, 14, 0, 0, 0);
        matrix_case(36, 8, 20, 9, 0, 0, 0);
        matrix_case(60, 12, 16, 14, 0, 0, 0);
        $display("PASS: %0d memory matrix tests, %0d stored-word checks (ReLU=%0d zero=%0d)",
                 matrix_tests, result_checks, relu_enable, zero_tile_enable);
        $display("PASS: zero tiles skipped=%0d saved cycles=%0d", skipped_tiles_total, cycles_saved_total);
        $finish;
    end
endmodule
