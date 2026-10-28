module tb_matrix_mult_tiled;
   import matrix_mult_pkg::*;
   // Matrix Dimensions: [# rows, # cols]
   //     Input * Weight = Output
   //    [M, K] * [K, N] = [M, N]
   parameter M             = 4;
   parameter N             = 4;
   parameter K             = 4;

   // Tiling / Hardware Tile Parameters
   parameter Tm            = 4;            // Hardware array tile rows
   parameter Tn            = 4;            // Hardware array tile cols
   parameter Tk            = 4;            // Hardware tile K depth

   // Matrix Mult parameters
   parameter WIDTH         = 8;            // datawidth
   parameter ACCUM_WIDTH   = 16;           // accumulator width (output/psum memory)
   parameter ROW           = Tm;           // systolic array # of rows (mapped to Tm)
   parameter COL           = Tn;           // systolic array # of cols (mapped to Tn)
   parameter W_SIZE        = 1024;         // weight memory height
   parameter I_SIZE        = 1024;         // input act memory height
   parameter O_SIZE        = 1024;         // output memory height
   parameter DRIVER_WIDTH  = WIDTH * ( Tm + Tn );

   parameter CLOCK_PERIOD  = 10;
   parameter real DUTY_CYCLE = 0.5;
   parameter real OFFSET   = 2.5;
    
   // --- Matrix Mult Signals --- //
   logic                         clk_i;
   logic                         rst_n;

   // output buffer memory - Read Port
   logic                         ob_mem_cenb_R_o;
   logic                         ob_mem_wenb_R_o;
   logic [$clog2(O_SIZE)-1:0]    ob_mem_addr_R_o;
   logic [Tn-1:0][ACCUM_WIDTH-1:0] ob_mem_data_R_i;
   logic [Tn-1:0][ACCUM_WIDTH-1:0] ob_mem_data_R_o;

   // output buffer memory - Write Port
   logic                         ob_mem_cenb_W_o;
   logic                         ob_mem_wenb_W_o;
   logic [$clog2(O_SIZE)-1:0]    ob_mem_addr_W_o;
   logic [Tn-1:0][ACCUM_WIDTH-1:0] ob_mem_data_W_i;
   logic [Tn-1:0][ACCUM_WIDTH-1:0] ob_mem_data_W_o;

   // input buffer memory
   logic                         ib_mem_cenb_o;
   logic                         ib_mem_wenb_o;
   logic [$clog2(I_SIZE)-1:0]    ib_mem_addr_o;
   logic [Tm-1:0][WIDTH-1:0]     ib_mem_data_i;

   // weights buffer memory
   logic                         wb_mem_cenb_o;
   logic                         wb_mem_wenb_o;
   logic [$clog2(W_SIZE)-1:0]    wb_mem_addr_o;
   logic [Tn-1:0][WIDTH-1:0]     wb_mem_data_i;

   logic                         start_i;
   logic                         done_o;

   // Wrapper control signals
   logic                         en_i;
   logic                         ext_en_i;
   test_config_struct            test_config_i;
   data_config_struct            data_config_i;
   external_inputs_struct        ext_inputs_i;
   extra_output_bits_struct      extra_output_bits;

   // Wrapper monitor signals
   logic [Tn-1:0][WIDTH-1:0]    ext_result_o;
   logic                         ext_valid_o;

   // testbench variables
   logic [1000:0]                testname;
   logic                         write_files;
   integer                       returnval;
   string                        filename;

   string                        current_test;


   // Instantiate clock
   initial begin
      #OFFSET;
      forever begin
         clk_i = 1'b0;
         #(CLOCK_PERIOD-(CLOCK_PERIOD*DUTY_CYCLE)) clk_i = 1'b1;
         #(CLOCK_PERIOD*DUTY_CYCLE);
      end
   end

   // -- Memory Instance: Input Buffer Memory -- //
   mem_emulator_3 #(.WIDTH(Tm*WIDTH), .SIZE(I_SIZE))
      ib_mem (
         .clk_i   (clk_i),
         .cenb_i  (ib_mem_cenb_o),
         .wenb_i  (ib_mem_wenb_o),
         .addr_i  (ib_mem_addr_o),
         .d_i     (),
         .q_o     (ib_mem_data_i)
   );

   // -- Memory Instance: Weight Buffer Memory -- //
   mem_emulator_3 #(.WIDTH(Tn*WIDTH), .SIZE(W_SIZE))
      wb_mem (
         .clk_i   (clk_i),
         .cenb_i  (wb_mem_cenb_o),
         .wenb_i  (wb_mem_wenb_o),
         .addr_i  (wb_mem_addr_o),
         .d_i     (),
         .q_o     (wb_mem_data_i)
   );

   // -- Memory Instance: Output Buffer Memory -- //
   mem2p_emulator_3 #(.WIDTH(Tn*ACCUM_WIDTH), .SIZE(O_SIZE))
      ob_mem (
         .clk_i    (clk_i),
         .cenb_a_i (ob_mem_cenb_R_o),
         .wenb_a_i (ob_mem_wenb_R_o),
         .addr_a_i (ob_mem_addr_R_o),
         .d_a_i    (ob_mem_data_R_o),
         .q_a_o    (ob_mem_data_R_i),

         .cenb_b_i (ob_mem_cenb_W_o),
         .wenb_b_i (ob_mem_wenb_W_o),
         .addr_b_i (ob_mem_addr_W_o),
         .d_b_i    (ob_mem_data_W_o),
         .q_b_o    (ob_mem_data_W_i)
   );

   // -- DUT Instance: Matrix Mult -- //
   matrix_mult_3 #(
      .WIDTH       (WIDTH),
      .ACCUM_WIDTH (ACCUM_WIDTH),
      .W_SIZE      (W_SIZE),
      .I_SIZE      (I_SIZE),
      .O_SIZE      (O_SIZE)
   ) matrix_mult_0 (
      .clk_i               (clk_i),
      .rstn_i              (rst_n),
      .start_i             (start_i),
      .done_o              (done_o),
      .data_config_i       (data_config_i),
      .ext_en_i            (ext_en_i),
      .ext_inputs_i        (ext_inputs_i),
      .ext_result_o        (ext_result_o),
      .ext_valid_o         (ext_valid_o),
      .extra_output_bits_o (extra_output_bits),

      .ib_mem_cenb_o       (ib_mem_cenb_o),
      .ib_mem_wenb_o       (ib_mem_wenb_o),
      .ib_mem_addr_o       (ib_mem_addr_o),
      .ib_mem_data_i       (ib_mem_data_i),

      .wb_mem_cenb_o       (wb_mem_cenb_o),
      .wb_mem_wenb_o       (wb_mem_wenb_o),
      .wb_mem_addr_o       (wb_mem_addr_o),
      .wb_mem_data_i       (wb_mem_data_i),

      .ob_mem_cenb_R_o     (ob_mem_cenb_R_o),
      .ob_mem_wenb_R_o     (ob_mem_wenb_R_o),
      .ob_mem_addr_R_o     (ob_mem_addr_R_o),
      .ob_mem_data_R_o     (ob_mem_data_R_o),
      .ob_mem_data_R_i     (ob_mem_data_R_i),
      .ob_mem_cenb_W_o     (ob_mem_cenb_W_o),
      .ob_mem_wenb_W_o     (ob_mem_wenb_W_o),
      .ob_mem_addr_W_o     (ob_mem_addr_W_o),
      .ob_mem_data_W_o     (ob_mem_data_W_o),
      .ob_mem_data_W_i     (ob_mem_data_W_i)
   );

   integer matrix_a [0:63][0:63];
   integer matrix_b [0:63][0:63];
   integer golden   [0:63][0:63];
   integer writes, weight_reads, tests;
   integer compute_cycles, act_reads;
   integer relu_enable;

   always @(posedge clk_i) begin
      if (matrix_mult_0.active) begin
         compute_cycles = compute_cycles + 1;
         if (!ib_mem_cenb_o)
            act_reads = act_reads + 1;
         else if (act_reads != data_config_i.i_rows *
                  (data_config_i.w_rows / 4) * (data_config_i.w_cols / 4))
            $fatal(1, "Bubble in activation reads between weight tiles");

         if (!ob_mem_cenb_W_o && !ob_mem_wenb_W_o)
            writes = writes + 1;
         else if (writes > 0 && writes < data_config_i.i_rows *
                  (data_config_i.w_rows / 4) * (data_config_i.w_cols / 4))
            $fatal(1, "Bubble in output writes between weight tiles");

         if (!ob_mem_cenb_R_o && !ob_mem_cenb_W_o &&
             ob_mem_addr_R_o == ob_mem_addr_W_o)
            $fatal(1, "Output memory read/write address collision");
      end
      if (!wb_mem_cenb_o) begin
         if (wb_mem_addr_o !== data_config_i.w_offset + weight_reads)
            $fatal(1, "Weight tiles are not read in column-major order");
         weight_reads = weight_reads + 1;
      end
   end


   task automatic run_case(
      input integer rows, cols, depth, pattern, input_offset, weight_offset, output_offset
   );
      integer sum, part, addr;
      begin
         writes = 0;
         weight_reads = 0;
         compute_cycles = 0;
         act_reads = 0;
         data_config_i = '0;
         data_config_i.extra_config_i[0] = relu_enable[0];
         data_config_i.i_rows = rows;
         data_config_i.w_cols = cols;
         data_config_i.w_rows = depth;
         data_config_i.i_offset = input_offset;
         data_config_i.w_offset = weight_offset;
         data_config_i.psum_offset = output_offset;
         for (integer r = 0; r < rows; r++)
            for (integer k = 0; k < depth; k++) begin
               if (pattern == 3 || pattern == 5)
                  matrix_a[r][k] = -128;
               else if (pattern == 1 || pattern == 2 || pattern == 4)
                  matrix_a[r][k] = 127;
               else
                  matrix_a[r][k] = $urandom_range(0, 14) - 7;
               addr = input_offset + (k / 4) * rows + r;
               ib_mem.data[addr][(k % 4)*8 +: 8] = matrix_a[r][k];
            end
         for (integer k = 0; k < depth; k++)
            for (integer c = 0; c < cols; c++) begin
               if (pattern == 5)
                  matrix_b[k][c] = -128;
               else if (pattern == 1 || pattern == 3)
                  matrix_b[k][c] = 127;
               else if (pattern == 4)
                  matrix_b[k][c] = k < 4 ? -127 : 127;
               else if (pattern == 2)
                  matrix_b[k][c] = k < 4 ? 127 : -127;
               else
                  matrix_b[k][c] = $urandom_range(0, 14) - 7;
               addr = weight_offset + (c / 4) * depth + k;
               wb_mem.data[addr][(c % 4)*8 +: 8] = matrix_b[k][c];
            end
         for (integer r = 0; r < rows; r++)
            for (integer c = 0; c < cols; c++) begin
               sum = 0;
               for (integer kt = 0; kt < depth / 4; kt++) begin
                  part = 0;
                  for (integer k = 0; k < 4; k++)
                     part = part + matrix_a[r][kt*4+k]*matrix_b[kt*4+k][c];
                  sum = sum + part;
                  if (kt != depth / 4 - 1) begin
                     if (sum > 32767) sum = 32767;
                     if (sum < -32768) sum = -32768;
                  end
               end
               if (sum > 127) sum = 127;
               if (sum < -128) sum = -128;
               if (relu_enable && sum < 0) sum = 0;
               golden[r][c] = sum;
               addr = output_offset + (c / 4) * rows + r;
               ob_mem.data[addr] = 'x;
            end
         @(negedge clk_i);
         start_i = 1;
         @(negedge clk_i);
         start_i = 0;
         if (done_o !== 0) $fatal(1, "DONE did not clear on accepted start");
         if (extra_output_bits.extra_config_o !== {7'b0, relu_enable[0]})
            $fatal(1, "ReLU scan readback mismatch");
         @(posedge done_o);
         @(negedge clk_i);
         for (integer r = 0; r < rows; r++)
            for (integer c = 0; c < cols; c++) begin
               addr = output_offset + (c / 4) * rows + r;
               if ($signed(ob_mem.data[addr][(c % 4)*16 +: 16]) !== golden[r][c])
                  $fatal(1, "M=%0d N=%0d K=%0d C[%0d][%0d] got=%0d expected=%0d",
                     rows, cols, depth, r, c,
                     $signed(ob_mem.data[addr][(c % 4)*16 +: 16]), golden[r][c]);
            end
         if (weight_reads != depth * (cols / 4))
            $fatal(1, "Weight tile was not read exactly once");
         if (writes != rows * (depth / 4) * (cols / 4))
            $fatal(1, "Unexpected partial-sum write count");
         if (compute_cycles != rows * (depth / 4) * (cols / 4) + 8)
            $fatal(1, "Unexpected compute cycles: %0d", compute_cycles);
         repeat (3) begin
            @(negedge clk_i);
            if (done_o !== 1) $fatal(1, "DONE did not remain high after completion");
         end
         tests++;
         $display("PASS: M=%0d N=%0d K=%0d pattern=%0d cycles=%0d",
            rows, cols, depth, pattern, compute_cycles);
      end
   endtask

   initial begin
      if (!$value$plusargs("RELU=%d", relu_enable))
         relu_enable = 0;
      if (relu_enable != 0 && relu_enable != 1)
         $fatal(1, "RELU must be 0 or 1");
      rst_n = 0;
      start_i = 0;
      ext_en_i = 0;
      ext_inputs_i = '0;
      data_config_i = '0;
      writes = 0;
      weight_reads = 0;
      tests = 0;
      compute_cycles = 0;
      act_reads = 0;
      repeat (3) @(negedge clk_i);
      rst_n = 1;
      run_case(4, 4, 4, 0, 0, 0, 0);
      run_case(8, 8, 8, 0, 0, 0, 0);
      run_case(12, 8, 16, 0, 11, 7, 13);
      run_case(4, 12, 8, 0, 0, 0, 0);
      run_case(16, 4, 12, 0, 3, 5, 9);
      run_case(8, 8, 8, 1, 0, 0, 0);
      run_case(8, 8, 8, 2, 0, 0, 0);
      run_case(8, 8, 8, 3, 0, 0, 0);
      run_case(8, 8, 8, 4, 0, 0, 0);
      run_case(8, 8, 8, 5, 0, 0, 0);
      run_case(64, 64, 64, 0, 0, 0, 0);
      for (integer test_id = 0; test_id < 20; test_id++)
         run_case(4*$urandom_range(1,4), 4*$urandom_range(1,4),
                  4*$urandom_range(1,4), 0, 5, 9, 7);
      $display("PASS: %0d tiled matrix tests", tests);
      $finish;
   end
endmodule
