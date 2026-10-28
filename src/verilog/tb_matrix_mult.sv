module tb_matrix_mult;
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

   logic [Tn-1:0][ACCUM_WIDTH-1:0] expected_result [3:0];


   initial begin : TEST_CASE
      string data_dir;
      integer relu_enable;

      if (!$value$plusargs("RELU=%d", relu_enable))
         relu_enable = 0;
      if (relu_enable != 0 && relu_enable != 1)
         $fatal(1, "RELU must be 0 or 1");

      `ifdef FSDB
      $fsdbDumpfile("matrix_mult.fsdb");
      $fsdbDumpon;
      $fsdbDumpvars(0, tb_matrix_mult, "+mda", "+all", "+trace_process");
      `endif
      `ifdef SDF 
         $sdf_annotate("./matrix_mult.wc.sdf", matrix_mult_0, "./sdf.max.cfg");
      `endif


      // Reset and initialize control inputs.
      rst_n         = 1'b0;
      start_i       = 1'b0;
      ext_en_i      = 1'b0;
      ext_inputs_i  = '0;
      data_config_i = '0;
      data_config_i.extra_config_i[0] = relu_enable[0];
      data_config_i.i_rows = M;
      data_config_i.w_cols = N;
      data_config_i.w_rows = K;
      repeat (3) @(negedge clk_i);
      rst_n = 1'b1;

      // Select test data; paths are relative to sim/behav.
      if (!$value$plusargs("DATA_DIR=%s", data_dir))
         data_dir = "../../src/verilog/tests/example";
      $readmemh({data_dir, "/ACT_MEM_2.hex"}, ib_mem.data, 0, 3);
      $readmemh({data_dir, "/WEIGHT_MEM_2.hex"}, wb_mem.data, 0, 3);
      $readmemh({data_dir, "/OUTPUT_MEM_2.hex"}, expected_result, 0, 3);

      // Apply ReLU to the supplied expectations only when enabled.
      for (integer row = 0; row < 4; row++)
         for (integer col = 0; col < 4; col++)
            if (relu_enable && $signed(expected_result[row][col][WIDTH-1:0]) < 0)
               expected_result[row][col] = '0;

      //start
      @(negedge clk_i);
      start_i = 1'b1;
      @(negedge clk_i);
      start_i = 1'b0;
      if (extra_output_bits.extra_config_o !== {7'b0, relu_enable[0]})
         $fatal(1, "ReLU scan readback mismatch");
      @(posedge done_o);
      @(negedge clk_i);

      // compare with expected output and print result
      for (integer row = 0; row < 4; row++) begin
         for (integer col = 0; col < 4; col++) begin
            if ($isunknown(expected_result[row][col][7:0]) ||
                ob_mem.data[row][col*ACCUM_WIDTH +: WIDTH]
                !== expected_result[row][col][WIDTH-1:0])
               $fatal(1, "Mismatch at C[%0d][%0d]", row, col);
         end
      end
      $display("PASS: Output memory matches expected output (ReLU=%0d)", relu_enable);
      $finish;
   end

endmodule
