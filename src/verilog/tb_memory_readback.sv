`timescale 1ns/1ps
module tb_memory_readback;
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
    wire [31:0] ib_write_data, wb_write_data;
    wire ob_read_cenb, ob_read_wenb, ob_write_cenb, ob_write_wenb;
    wire [63:0] ob_read_data, ob_read_unused, ob_write_data, ob_write_unused;
    integer reads = 0;
    integer writes = 0;
    integer readback_checks = 0;
    integer matrix_tests = 0;
    integer access_checks = 0;
    integer ib_reads = 0, ib_writes = 0, wb_reads = 0, wb_writes = 0;
    logic [31:0] activation_words [0:1023];
    logic [31:0] weight_words [0:1023];
    integer relu_enable = 0;
    integer memory_observe = 0;
    integer zero_tile_enable = 0;
    integer skipped_tiles_total = 0, cycles_saved_total = 0;
    logic observe_writes = 0;
    logic [63:0] expected_signature, expected_registered;
    logic expected_signature_valid, expected_registered_valid;
    logic monitor_started = 0;
    logic monitor_start_d = 0;
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
        .ib_mem_data_o(ib_write_data),
        .wb_mem_cenb_o(wb_cenb), .wb_mem_wenb_o(wb_wenb),
        .wb_mem_addr_o(wb_addr), .wb_mem_data_i(wb_data),
        .wb_mem_data_o(wb_write_data),
        .ob_mem_cenb_R_o(ob_read_cenb), .ob_mem_wenb_R_o(ob_read_wenb),
        .ob_mem_addr_R_o(ob_read_addr), .ob_mem_data_R_i(ob_read_data),
        .ob_mem_data_R_o(ob_read_unused),
        .ob_mem_cenb_W_o(ob_write_cenb), .ob_mem_wenb_W_o(ob_write_wenb),
        .ob_mem_addr_W_o(ob_write_addr), .ob_mem_data_W_o(ob_write_data),
        .ob_mem_data_W_i(ob_write_unused)
    );

    mem_emulator_3 #(.WIDTH(32), .SIZE(1024)) ib_mem (
        .clk_i(clk_i), .cenb_i(ib_cenb), .wenb_i(ib_wenb),
        .addr_i(ib_addr), .d_i(ib_write_data), .q_o(ib_data)
    );
    mem_emulator_3 #(.WIDTH(32), .SIZE(1024)) wb_mem (
        .clk_i(clk_i), .cenb_i(wb_cenb), .wenb_i(wb_wenb),
        .addr_i(wb_addr), .d_i(wb_write_data), .q_o(wb_data)
    );
    mem2p_emulator_3 #(.WIDTH(64), .SIZE(1024)) ob_mem (
        .clk_i(clk_i),
        .cenb_a_i(ob_read_cenb), .wenb_a_i(ob_read_wenb), .addr_a_i(ob_read_addr),
        .d_a_i(ob_read_unused), .q_a_o(ob_read_data),
        .cenb_b_i(ob_write_cenb), .wenb_b_i(ob_write_wenb), .addr_b_i(ob_write_addr),
        .d_b_i(ob_write_data), .q_b_o(ob_write_unused)
    );

    always @(posedge clk_i) begin
        if (rstn_async_i) begin
            if (!ib_cenb) begin
                if (ib_wenb) ib_reads++; else ib_writes++;
            end
            if (!wb_cenb) begin
                if (wb_wenb) wb_reads++; else wb_writes++;
            end
            if (!ob_read_cenb) begin
                if (!ob_read_wenb)
                    $fatal(1, "Readback/psum read port attempted a write");
                reads++;
            end
            if (!ob_write_cenb && !ob_write_wenb)
                writes++;
            if (!ob_read_cenb && !ob_write_cenb && !ob_write_wenb &&
                ob_read_addr == ob_write_addr)
                $fatal(1, "Read/write address collision");
        end
    end

    // Check direct writes before the edge and registered/compressed outputs after it.
    always @(posedge clk_i) begin
        if (observe_writes && en_i) begin
            if (start_i && !monitor_start_d && !monitor_started) begin
                monitor_started = 1;
                expected_signature = {ext_inputs.ext_psum, ext_inputs.ext_input};
                expected_registered = expected_signature;
                expected_signature_valid = 0;
                expected_registered_valid = 0;
                checked_writes = 0;
            end else if (monitor_started) begin
                if (memory_observe == 1) begin
                    if (ext_valid !== (!ob_write_cenb && !ob_write_wenb))
                        $fatal(1, "Direct memory write valid mismatch");
                    if (ext_valid && ext_result !== ob_write_data)
                        $fatal(1, "Direct memory write data mismatch");
                end
                expected_registered_valid = !ob_write_cenb && !ob_write_wenb;
                if (expected_registered_valid) begin
                    if (checked_writes >= golden_write_count ||
                        ob_write_addr !== golden_write_addresses[checked_writes][9:0] ||
                        ob_write_data !== golden_write_words[checked_writes])
                        $fatal(1, "Partial-sum write mismatch at word %0d: addr=%0d data=%h expected=%h",
                               checked_writes, ob_write_addr, ob_write_data, golden_write_words[checked_writes]);
                    expected_registered = golden_write_words[checked_writes];
                    expected_signature = {expected_signature[62:0],
                        expected_signature[62] ^ expected_signature[61] ^
                        expected_signature[60] ^ expected_signature[51]} ^ expected_registered;
                    checked_writes++;
                end
                if (done && !expected_registered_valid)
                    expected_signature_valid = 1;
            end
            monitor_start_d = start_i;
            #2;
            if (memory_observe == 0 &&
                (ext_valid !== expected_signature_valid || ext_result !== expected_signature))
                $fatal(1, "Memory MISR signature/valid mismatch: got=%h expected=%h", ext_result, expected_signature);
            if (memory_observe == 2 &&
                (ext_valid !== expected_registered_valid || ext_result !== expected_registered))
                $fatal(1, "Registered memory write data/valid mismatch");
        end
    end

    function automatic [63:0] raw_word(input integer address);
        raw_word = 64'h80ff_7f00_abcd_1234 ^ (64'h0102_0304_0506_0709 * address);
    endfunction

    task automatic reset_dut;
        begin
            en_i = 1;
            rstn_async_i = 0;
            start_i = 0;
            ext_en_i = 0;
            test_config = '0;
            test_config.bypass[1:0] = 2'b10;
            ext_inputs = '0;
            data_config = '0;
            data_config.extra_config_i[0] = relu_enable[0];
            repeat (3) @(negedge clk_i);
            rstn_async_i = 1;
            repeat (4) @(negedge clk_i);
            if (ext_valid)
                $fatal(1, "Result valid survived reset");
            if (done !== 1'b0)
                $fatal(1, "DONE survived reset");
        end
    endtask

    task automatic expect_read(input [63:0] expected_word, input integer previous_reads);
        integer clocks;
        begin
            clocks = 0;
            while (!ext_valid && clocks < 8) begin
                @(negedge clk_i);
                clocks++;
            end
            if (!ext_valid || ext_result !== expected_word)
                $fatal(1, "Readback got=%h expected=%h valid=%b", ext_result, expected_word, ext_valid);
            if (clocks != 2 || reads != previous_reads + 1)
                $fatal(1, "Readback latency/read count mismatch: clocks=%0d reads=%0d",
                       clocks, reads - previous_reads);
            repeat (3) begin
                @(negedge clk_i);
                if (!ext_valid || ext_result !== expected_word || reads != previous_reads + 1)
                    $fatal(1, "Readback result did not hold without another read");
            end
            readback_checks++;
        end
    endtask

    task automatic read_word(input integer address, input [63:0] expected_word,
                             input logic hold_request, input logic pause_clock);
        integer previous_reads;
        begin
            test_config.bypass[1:0] = 2'b10;
            test_config.mode[0] = 0;
            data_config.extra_config_i[3] = 0;
            data_config.psum_offset = address;
            @(negedge clk_i);
            previous_reads = reads;
            data_config.extra_config_i[3] = 1;
            @(negedge clk_i);
            if (ext_valid)
                $fatal(1, "Readback valid did not clear on an accepted request");
            // Change the live address before SRAM sampling to verify address latching.
            data_config.psum_offset = (address + 37) % 1024;
            if (pause_clock) begin
                en_i = 0;
                repeat (4) begin
                    @(negedge clk_i);
                    if (reads != previous_reads || ext_valid)
                        $fatal(1, "Readback advanced while its functional clock was stopped");
                end
                en_i = 1;
            end
            if (!hold_request)
                data_config.extra_config_i[3] = 0;
            expect_read(expected_word, previous_reads);
            data_config.extra_config_i[3] = 0;
            @(negedge clk_i);
        end
    endtask

    task automatic memory_access(input logic [1:0] memory_select,
                                 input logic write_enable, input integer address,
                                 input logic [31:0] write_data,
                                 input logic [63:0] expected_word, input logic pause_access);
        test_config_struct saved_config;
        integer previous_total;
        begin
            saved_config = test_config;
            data_config.extra_config_i[3] = 0;
            @(negedge clk_i);
            previous_total = ib_reads + ib_writes + wb_reads + wb_writes + reads;
            test_config.bypass[1:0] = memory_select;
            test_config.mode[0] = write_enable;
            data_config.psum_offset = address;
            ext_inputs.ext_weight = write_data;
            data_config.extra_config_i[3] = 1;
            @(negedge clk_i);
            if (ext_valid) $fatal(1, "Memory access did not clear previous completion");
            // Change every live command field to check that the accepted command was latched.
            test_config.bypass[1:0] = 2'b11;
            test_config.mode[0] = !write_enable;
            data_config.psum_offset = (address + 37) % 1024;
            ext_inputs.ext_weight = ~write_data;
            if (pause_access) begin
                en_i = 0;
                repeat (3) @(negedge clk_i);
                if (previous_total != ib_reads + ib_writes + wb_reads + wb_writes + reads || ext_valid)
                    $fatal(1, "Paused memory access reached SRAM or completed");
                en_i = 1;
            end
            @(negedge clk_i);
            if (ext_valid) $fatal(1, "Memory access completed before capture");
            @(negedge clk_i);
            if (!ext_valid || ext_result !== (write_enable ? 64'b0 : expected_word))
                $fatal(1, "Memory access mismatch: memory=%0d address=%0d got=%h expected=%h",
                       memory_select, address, ext_result, expected_word);
            repeat (2) @(negedge clk_i);
            if (previous_total + 1 != ib_reads + ib_writes + wb_reads + wb_writes + reads)
                $fatal(1, "Held request caused a missing or repeated SRAM access");
            data_config.extra_config_i[3] = 0;
            test_config = saved_config;
            @(negedge clk_i);
            access_checks++;
        end
    endtask

    task automatic input_memory_cases;
        integer previous_total;
        begin
            for (integer mem = 0; mem < 2; mem++) begin
                for (integer pattern = 0; pattern < 4; pattern++) begin
                    memory_access(mem, 1, pattern == 3 ? 1023 : pattern,
                                  32'h80ff7f01 ^ (32'h76543210 * pattern), 0, pattern == 3);
                    memory_access(mem, 0, pattern == 3 ? 1023 : pattern, 0,
                                  {32'b0, (32'h80ff7f01 ^ (32'h76543210 * pattern))}, pattern == 2);
                end
                // External-mode entry or reset before the access edge cancels a write.
                for (integer cancel = 0; cancel < 2; cancel++) begin
                    data_config.extra_config_i[3] = 0;
                    @(negedge clk_i);
                    previous_total = ib_writes + wb_writes;
                    test_config.bypass[1:0] = mem;
                    test_config.mode[0] = 1;
                    data_config.psum_offset = 0;
                    ext_inputs.ext_weight = 32'hdeadbeef;
                    data_config.extra_config_i[3] = 1;
                    @(negedge clk_i);
                    if (cancel == 0) begin
                        ext_en_i = 1;
                        repeat (3) @(negedge clk_i);
                        ext_en_i = 0;
                    end else
                        reset_dut();
                    if (ib_writes + wb_writes != previous_total)
                        $fatal(1, "Cancelled input-memory write reached SRAM");
                    memory_access(mem, 0, 0, 0, 64'h0000000080ff7f01, 0);
                end
            end
            previous_total = ib_reads + ib_writes + wb_reads + wb_writes + reads;
            // Reserved selection and result writes must not touch any SRAM.
            for (integer invalid = 0; invalid < 2; invalid++) begin
                data_config.extra_config_i[3] = 0;
                @(negedge clk_i);
                test_config.bypass[1:0] = invalid == 0 ? 2'b11 : 2'b10;
                test_config.mode[0] = 1;
                data_config.extra_config_i[3] = 1;
                repeat (5) @(negedge clk_i);
            end
            if (previous_total != ib_reads + ib_writes + wb_reads + wb_writes + reads)
                $fatal(1, "Unsupported memory command reached SRAM");
            data_config.extra_config_i[3] = 0;
            test_config.mode[0] = 0;
            test_config.bypass[1:0] = 2'b10;
            @(negedge clk_i);
            $display("PASS: activation/weight reads, writes, command latching, clock pause, invalid commands");
        end
    endtask

    task automatic protocol_cases;
        integer previous_reads;
        logic [63:0] held_word;
        begin
            read_word(0, raw_word(0), 0, 0);
            read_word(1023, raw_word(1023), 1, 0);
            read_word(17, raw_word(17), 0, 1);

            // A request while another read is pending must not be queued.
            previous_reads = reads;
            data_config.psum_offset = 5;
            data_config.extra_config_i[3] = 1;
            @(negedge clk_i);
            data_config.extra_config_i[3] = 0;
            @(negedge clk_i);
            data_config.psum_offset = 6;
            data_config.extra_config_i[3] = 1;
            @(negedge clk_i);
            if (!ext_valid || ext_result !== raw_word(5))
                $fatal(1, "Pending request replaced an in-flight read");
            repeat (4) @(negedge clk_i);
            if (reads != previous_reads + 1 || ext_result !== raw_word(5))
                $fatal(1, "Busy readback request was queued or retriggered");
            readback_checks++;
            data_config.extra_config_i[3] = 0;
            @(negedge clk_i);

            // Switching to external mode cancels a pending read before SRAM access.
            previous_reads = reads;
            data_config.psum_offset = 8;
            data_config.extra_config_i[3] = 1;
            @(negedge clk_i);
            ext_en_i = 1;
            test_config.bypass = 3'b101;
            repeat (3) @(negedge clk_i);
            if (reads != previous_reads || ext_valid)
                $fatal(1, "Mode switch did not cancel a pending read");
            ext_en_i = 0;
            data_config.extra_config_i[3] = 0;
            @(negedge clk_i);

            // Emulate preparing scan-controlled inputs with the functional clock stopped.
            read_word(5, raw_word(5), 0, 0);
            held_word = ext_result;
            previous_reads = reads;
            en_i = 0;
            repeat (6) begin
                data_config.psum_offset = $urandom_range(0, 1023);
                data_config.extra_config_i[3] = !data_config.extra_config_i[3];
                @(negedge clk_i);
                if (reads != previous_reads || !ext_valid || ext_result !== held_word)
                    $fatal(1, "Stopped-clock input updates changed the held result");
            end
            data_config.psum_offset = 23;
            data_config.extra_config_i[3] = 1;
            en_i = 1;
            @(negedge clk_i);
            if (ext_valid)
                $fatal(1, "Scan-style request was not accepted after clock resume");
            expect_read(raw_word(23), previous_reads);
            data_config.extra_config_i[3] = 0;
            @(negedge clk_i);

            // External mode must retain its own output and SRAM ownership rules.
            previous_reads = reads;
            ext_en_i = 1;
            test_config.bypass = 3'b101;
            data_config.extra_config_i[3] = 1;
            repeat (4) @(negedge clk_i);
            ext_en_i = 0;
            repeat (3) @(negedge clk_i);
            if (reads != previous_reads || ext_valid)
                $fatal(1, "External request leaked into memory readback");
            data_config.extra_config_i[3] = 0;
            @(negedge clk_i);
            read_word(6, raw_word(6), 0, 0);

            // Reset cancels a pending transaction and clears its result-valid state.
            data_config.psum_offset = 0;
            data_config.extra_config_i[3] = 1;
            @(negedge clk_i);
            reset_dut();
            read_word(0, raw_word(0), 0, 0);
            $display("PASS: readback protocol, clock pause, mode switch, and reset");
        end
    endtask

    task automatic matrix_case(input integer rows, cols, depth, pattern,
                               input integer input_offset, weight_offset, output_offset,
                               input integer abort_readback, input logic request_at_done);
        integer sum, part, address, previous_reads, previous_writes, clocks;
        integer previous_ib_reads, previous_wb_reads, previous_ib_writes, previous_wb_writes;
        integer skipped_tiles, cycles_saved, expected_requests;
        logic tile_is_zero;
        logic [63:0] expected_word;
        begin
            test_config.bypass = memory_observe == 1 ? 3'b101 : 3'b001;
            test_config.mode = memory_observe == 2 ? 2'b10 : 2'b00;
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
                    activation_words[address][(k % 4)*8 +: 8] = matrix_a[r][k];
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
                    weight_words[address][(c % 4)*8 +: 8] = matrix_b[k][c];
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
            // Load and read back A/B only through the wrapper's memory-access interface.
            for (integer word_idx = 0; word_idx < rows * (depth / 4); word_idx++) begin
                address = input_offset + word_idx;
                memory_access(2'b00, 1, address, activation_words[address], 0, 0);
                memory_access(2'b00, 0, address, 0, {32'b0, activation_words[address]}, 0);
            end
            for (integer word_idx = 0; word_idx < depth * (cols / 4); word_idx++) begin
                address = weight_offset + word_idx;
                memory_access(2'b01, 1, address, weight_words[address], 0, 0);
                memory_access(2'b01, 0, address, 0, {32'b0, weight_words[address]}, 0);
            end
            data_config.psum_offset = output_offset;
            test_config.bypass[1:0] = 2'b10;
            test_config.mode[0] = 0;
            previous_reads = reads;
            previous_writes = writes;
            previous_ib_reads = ib_reads;
            previous_wb_reads = wb_reads;
            previous_ib_writes = ib_writes;
            previous_wb_writes = wb_writes;
            if (abort_readback) begin
                data_config.psum_offset = 1023;
                data_config.extra_config_i[3] = 1;
                repeat (abort_readback) @(negedge clk_i);
                data_config.extra_config_i[3] = 0;
                data_config.psum_offset = output_offset;
            end
            previous_reads = reads;
            if (request_at_done)
                data_config.extra_config_i[3] = 1;
            monitor_started = 0;
            monitor_start_d = 0;
            observe_writes = 1;
            start_i = 1;
            @(negedge clk_i);
            start_i = 0;
            // Add-on selection is latched at start, like matrix sizes and offsets.
            data_config.extra_config_i[1] = !zero_tile_enable[0];
            if (request_at_done)
                data_config.extra_config_i[3] = 0;
            if (done !== 1'b0)
                $fatal(1, "DONE did not clear on accepted start");
            if (!request_at_done) begin
                // Hold a rejected request through completion; it must not trigger later.
                data_config.psum_offset = 1023;
                data_config.extra_config_i[3] = 1;
            end
            clocks = 0;
            while (!done && clocks < rows * (depth / 4) * (cols / 4) + 16) begin
                @(negedge clk_i);
                clocks++;
                // A busy-time start pulse must not restart or release memory ownership.
                if (clocks == 3) start_i = 1;
                if (clocks == 4) start_i = 0;
                if (request_at_done && clocks == 2) begin
                    test_config.bypass[1:0] = 2'b00;
                    test_config.mode[0] = 1;
                    data_config.extra_config_i[3] = 1;
                end
                if (request_at_done && clocks == 3) begin
                    data_config.extra_config_i[3] = 0;
                    test_config.mode[0] = 0;
                    test_config.bypass[1:0] = 2'b10;
                end
                if (memory_observe == 0 && ext_valid)
                    $fatal(1, "Readback became visible during computation");
            end
            if (!done || clocks != expected_requests + 8)
                $fatal(1, "Memory computation completion/timing mismatch");
            if (checked_writes != golden_write_count)
                $fatal(1, "Missing or extra partial-sum writes");
            if (reads != previous_reads + expected_requests - rows * (cols / 4) ||
                writes != previous_writes + expected_requests)
                $fatal(1, "Readback interfered with computation memory accesses");
            if (ib_reads != previous_ib_reads + expected_requests ||
                wb_reads != previous_wb_reads + depth * (cols / 4) ||
                ib_writes != previous_ib_writes || wb_writes != previous_wb_writes)
                $fatal(1, "Memory command interfered with activation/weight computation accesses");
            if (request_at_done) begin
                observe_writes = 0;
                expected_word = '0;
                for (integer c = 0; c < 4; c++)
                    expected_word[c*16+:16] = golden[0][c];
                previous_reads = reads;
                data_config.psum_offset = output_offset;
                data_config.extra_config_i[3] = 1;
                @(negedge clk_i);
                expect_read(expected_word, previous_reads);
            end else begin
                repeat (3) @(negedge clk_i);
                if (memory_observe == 0 && (!ext_valid || ext_result !== expected_signature))
                    $fatal(1, "Completed memory signature did not hold");
                if (memory_observe != 0 && ext_valid)
                    $fatal(1, "Write-stream valid did not clear after completion");
                if (reads != previous_reads + expected_requests - rows * (cols / 4))
                    $fatal(1, "Held compute-time readback request triggered after completion");
                observe_writes = 0;
            end
            data_config.extra_config_i[3] = 0;
            @(negedge clk_i);
            // All comparisons below use wrapper readback, never hierarchical SRAM reads.
            for (integer nt = 0; nt < cols / 4; nt++)
                for (integer r = 0; r < rows; r++) begin
                    expected_word = '0;
                    for (integer c = 0; c < 4; c++)
                        expected_word[c*16+:16] = golden[r][nt*4+c];
                    read_word(output_offset + nt*rows + r, expected_word, 0, 0);
                end
            if (done !== 1'b1)
                $fatal(1, "DONE did not remain high during result readback");
            matrix_tests++;
            skipped_tiles_total += skipped_tiles;
            cycles_saved_total += cycles_saved;
            $display("PASS: memory result readback M=%0d N=%0d K=%0d pattern=%0d cycles=%0d skipped=%0d saved=%0d",
                     rows, cols, depth, pattern, clocks, skipped_tiles, cycles_saved);
        end
    endtask

    initial begin
        `ifdef FSDB
        $fsdbDumpfile("memory_readback.fsdb");
        $fsdbDumpvars(0, tb_memory_readback, "+mda");
        `endif
        if (!$value$plusargs("RELU=%d", relu_enable)) relu_enable = 0;
        if (!$value$plusargs("MEMORY_OBSERVE=%d", memory_observe)) memory_observe = 0;
        if (!$value$plusargs("ZERO_TILE=%d", zero_tile_enable)) zero_tile_enable = 0;
        if (zero_tile_enable != 0 && zero_tile_enable != 1)
            $fatal(1, "ZERO_TILE must be 0 or 1");
        if (memory_observe < 0 || memory_observe > 2)
            $fatal(1, "MEMORY_OBSERVE must be 0 (MISR), 1 (direct), or 2 (registered)");
        if (relu_enable != 0 && relu_enable != 1)
            $fatal(1, "RELU must be 0 or 1");
        `ifdef SDF
        $sdf_annotate("matrix_mult_wrapper_3.sdf", dut, , "readback_sdf.log", "MAXIMUM");
        `endif
        reset_dut();
        for (integer address = 0; address < 1024; address++)
            ob_mem.data[address] = raw_word(address);
        protocol_cases();
        input_memory_cases();
        matrix_case(4, 4, 4, 0, 0, 0, 0, 1, 0);
        matrix_case(4, 8, 8, 0, 0, 0, 0, 2, 0);
        matrix_case(8, 8, 8, 1, 0, 0, 0, 0, 0);
        matrix_case(12, 8, 16, 0, 11, 7, 13, 0, 0);
        matrix_case(8, 8, 8, 2, 0, 0, 0, 0, 0);
        matrix_case(8, 8, 8, 3, 0, 0, 0, 0, 0);
        matrix_case(64, 64, 64, 0, 0, 0, 0, 0, 0);
        matrix_case(4, 4, 4, 0, 0, 0, 1020, 0, 1);
        matrix_case(8, 8, 12, 4, 5, 7, 11, 0, 0);
        matrix_case(12, 12, 20, 9, 3, 5, 7, 0, 0);
        matrix_case(8, 8, 16, 5, 0, 0, 0, 0, 0);
        matrix_case(8, 8, 16, 7, 0, 0, 0, 0, 0);
        matrix_case(8, 8, 16, 8, 0, 0, 0, 0, 0);
        matrix_case(4, 8, 16, 6, 0, 0, 0, 0, 0);
        matrix_case(8, 8, 4, 6, 0, 0, 0, 0, 0);
        matrix_case(8, 8, 8, 6, 0, 0, 0, 0, 0);
        matrix_case(16, 12, 16, 10, 0, 0, 0, 0, 0);
        matrix_case(12, 8, 16, 11, 0, 0, 0, 0, 0);
        matrix_case(64, 64, 64, 4, 0, 0, 0, 0, 0);
        matrix_case(64, 64, 64, 6, 0, 0, 0, 0, 0);
        matrix_case(12, 8, 16, 12, 0, 0, 0, 0, 0);
        matrix_case(12, 8, 16, 13, 0, 0, 0, 0, 0);
        matrix_case(20, 12, 24, 14, 5, 7, 11, 0, 0);
        matrix_case(28, 16, 32, 14, 0, 0, 0, 0, 0);
        matrix_case(36, 8, 20, 9, 0, 0, 0, 0, 0);
        matrix_case(60, 12, 16, 14, 0, 0, 0, 0, 0);
        $display("PASS: %0d memory matrix tests, %0d readback checks (ReLU=%0d)",
                 matrix_tests, readback_checks, relu_enable);
        $display("PASS: %0d activation/weight memory access checks", access_checks);
        $display("PASS: zero tile option=%0d skipped=%0d saved=%0d", zero_tile_enable,
                 skipped_tiles_total, cycles_saved_total);
        $finish;
    end
endmodule
