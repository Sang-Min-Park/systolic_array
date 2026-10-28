import matrix_mult_pkg::*;

module matrix_mult_wrapper_3 #(
    parameter WIDTH             = 8, 
    parameter ACCUM_WIDTH       = 16,
    parameter ARRAY_ACCUM_WIDTH = 18,
    parameter ROW               = 4, 
    parameter COL               = 4, 
    parameter Tm                = 4,
    parameter Tn                = 4,
    parameter Tk                = 4,
    parameter M                 = 64,
    parameter N                 = 64,
    parameter K                 = 64,
    parameter W_SIZE            = 1024, 
    parameter I_SIZE            = 1024, 
    parameter O_SIZE            = 1024,
    parameter MEM_R_WIDTH       = WIDTH * Tm,
    parameter MEM_C_WIDTH       = WIDTH * Tn,
    parameter MEM_C_ACCUM_WIDTH = ACCUM_WIDTH * Tn,
    parameter DRIVER_WIDTH      = WIDTH * ( Tm + Tn )
) (
  input  logic                            clk_i,            // clock signal
  input  logic                            rstn_async_i,     // active low reset signal
  input  logic                            en_i,             // global clock enable
  input  logic                            start_i,          // active high start calculation, must reset back to 0 first to start a new calculation
  input  test_config_struct               test_config_i,    // test controls
  input  data_config_struct               data_config_i,    // data controls
  // output buffer memory - Read Port
  output  logic                           ob_mem_cenb_R_o,  // memory enable, active low
  output  logic                           ob_mem_wenb_R_o,  // write enable, active low
  output  logic [$clog2(O_SIZE)-1:0]      ob_mem_addr_R_o,  // address
  input   logic [MEM_C_ACCUM_WIDTH-1:0] ob_mem_data_R_i,  // input data
  output  logic [MEM_C_ACCUM_WIDTH-1:0] ob_mem_data_R_o,  // output data
  // output buffer memory - Write Port
  output  logic                           ob_mem_cenb_W_o,  // memory enable, active low
  output  logic                           ob_mem_wenb_W_o,  // write enable, active low
  output  logic [$clog2(O_SIZE)-1:0]      ob_mem_addr_W_o,  // address
  input   logic [MEM_C_ACCUM_WIDTH-1:0] ob_mem_data_W_i,  // input data
  output  logic [MEM_C_ACCUM_WIDTH-1:0] ob_mem_data_W_o,  // output data
  // input buffer memory
  output  logic                           ib_mem_cenb_o,    // memory enable, active low
  output  logic                           ib_mem_wenb_o,    // write enable, active low
  output  logic [$clog2(I_SIZE)-1:0]      ib_mem_addr_o,    // address
  input   logic [MEM_R_WIDTH-1:0]         ib_mem_data_i,    // input data
  output  logic [MEM_R_WIDTH-1:0]         ib_mem_data_o,    // idle-time memory write data
  // weights buffer memory
  output  logic                           wb_mem_cenb_o,    // memory enable, active low
  output  logic                           wb_mem_wenb_o,    // write enable, active low
  output  logic [$clog2(W_SIZE)-1:0]      wb_mem_addr_o,    // address
  input   logic [MEM_C_WIDTH-1:0]         wb_mem_data_i,    // input data
  output  logic [MEM_C_WIDTH-1:0]         wb_mem_data_o,    // idle-time memory write data
  // external mode
  input  logic                            ext_en_i,         // external mode enable, active high
  input  external_inputs_struct           ext_inputs_i,     // external inputs
  output logic [DRIVER_WIDTH-1:0]         ext_result_o,     // external outputs
  output logic                            ext_valid_o,      // external valid output

  // done
  output logic                            done_o,            // Holds high after memory completion until the next start or reset.
  output extra_output_bits_struct         extra_output_bits_o
);

  logic                       rstn_i;
  logic                       dut_bypass_w;
  logic                       g_clk;

  logic                       driver_bypass_w;
  logic                       driver_mode_w;
  logic [DRIVER_WIDTH-1:0]    driver_seed_w;
  logic                       driver_valid_o_w;
  logic [DRIVER_WIDTH-1:0]    driver_data_w;
  logic                       driver_done_w;

  logic                       sa_bypass_w;
  logic                       sa_mode_w;
  logic                       sa_dut_valid_w;
  logic [DRIVER_WIDTH-1:0]    sa_dut_data_w;
  logic                       sa_valid_w;
  logic [DRIVER_WIDTH-1:0]    sa_data_w;
  logic [DRIVER_WIDTH-1:0]    sa_seed_w;
  logic                       sa_stop_w;
  logic                       sa_compress_mode_w;
  logic                       bist_mode_w;
  logic                       external_sa_stop_pending;
  logic [3:0]                 sa_pending_count;

  typedef enum logic [1:0] {
    MEM_ACCESS_IDLE,
    MEM_ACCESS_EXECUTE,
    MEM_ACCESS_COMPLETE
  } mem_access_state_e;

  mem_access_state_e mem_access_state, mem_access_next_state;
  logic                            wrapper_start_d;
  logic                            compute_busy_w;
  logic                            compute_start_w;
  logic                            mem_access_request_d;
  logic                            mem_access_request_w;
  logic                            mem_access_cancel_w;
  logic                            mem_access_active_w;
  logic                            mem_access_output_w;
  logic                            mem_access_done;
  logic [$clog2(O_SIZE)-1:0]       mem_access_addr;
  logic [MEM_C_ACCUM_WIDTH-1:0]    mem_access_read_data;
  logic [1:0]                      mem_access_target;
  logic                            mem_access_write_en;
  logic [MEM_C_WIDTH-1:0]          mem_access_write_data;
  logic                            ib_mem_cenb_core_w, ib_mem_wenb_core_w;
  logic                            wb_mem_cenb_core_w, wb_mem_wenb_core_w;
  logic [$clog2(I_SIZE)-1:0]       ib_mem_addr_core_w;
  logic [$clog2(W_SIZE)-1:0]       wb_mem_addr_core_w;
  logic                            ob_mem_cenb_R_core_w;
  logic                            ob_mem_wenb_R_core_w;
  logic [$clog2(O_SIZE)-1:0]       ob_mem_addr_R_core_w;

  logic [Tm-1:0][WIDTH-1:0]        ext_input_w;
  logic                            ext_valid_i_w;
  logic [Tn-1:0][WIDTH-1:0]        ext_psum_w;
  logic [Tn-1:0][WIDTH-1:0]        ext_result_w;
  logic                            ext_valid_o_w;

  external_inputs_struct           ext_inputs_w;

  logic [Tn-1:0][ACCUM_WIDTH-1:0]  ob_mem_data_R_i_w;
  logic [Tn-1:0][ACCUM_WIDTH-1:0]  ob_mem_data_R_o_w;
  logic [Tn-1:0][ACCUM_WIDTH-1:0]  ob_mem_data_W_i_w;
  logic [Tn-1:0][ACCUM_WIDTH-1:0]  ob_mem_data_W_o_w;
  logic [Tm-1:0][WIDTH-1:0]        ib_mem_data_i_w;
  logic [Tn-1:0][WIDTH-1:0]        wb_mem_data_i_w;

  // explicitly convert 1D arrays to 2D arrays
  assign ob_mem_data_R_i_w = ob_mem_data_R_i ;
  assign ob_mem_data_R_o   = ob_mem_data_R_o_w ;
  assign ob_mem_data_W_i_w = ob_mem_data_W_i ;
  assign ob_mem_data_W_o   = ob_mem_data_W_o_w ;
  assign ib_mem_data_i_w   = ib_mem_data_i ;
  assign wb_mem_data_i_w   = wb_mem_data_i ;

  // Global clock
  assign g_clk             = clk_i & en_i; 

  // Track array computation separately from idle-time SRAM access.
  assign compute_start_w = !ext_en_i && !compute_busy_w && start_i && !wrapper_start_d;

  always_ff @(posedge g_clk or negedge rstn_i) begin
    if (!rstn_i) begin
      wrapper_start_d <= 1'b0;
      compute_busy_w <= 1'b0;
    end else begin
      wrapper_start_d <= start_i;
      if (compute_start_w)
        compute_busy_w <= 1'b1;
      else if (done_o)
        compute_busy_w <= 1'b0;
    end
  end

  // Bit 3 requests idle-time SRAM access; psum_offset supplies the word address.
  // bypass[1:0]: 00 activation, 01 weight, 10 result; mode[0]: 0 read, 1 write.
  // Only activation/weight writes are supported; ext_weight supplies 32-bit data.
  // Busy/external requests, reserved selections, and result writes are not queued.
  // After acceptance: SRAM access on the next edge, read data/write ack on the following edge.
  // Sample the request low on a functional clock before requesting another word.
  assign mem_access_cancel_w = ext_en_i || compute_start_w || (compute_busy_w && !done_o);
  assign mem_access_request_w = data_config_i.extra_config_i[3] && !mem_access_request_d
                           && (mem_access_state == MEM_ACCESS_IDLE) && !mem_access_cancel_w
                           && (test_config_i.bypass[1:0] != 2'b11)
                           && !(test_config_i.bypass[1:0] == 2'b10 && test_config_i.mode[0]);

  always_ff @(posedge g_clk or negedge rstn_i) begin
    if (!rstn_i)
      mem_access_state       <= MEM_ACCESS_IDLE;
    else
      mem_access_state       <= mem_access_next_state;
  end

  always_comb begin
    mem_access_next_state = mem_access_state;
    if (mem_access_cancel_w)
      mem_access_next_state = MEM_ACCESS_IDLE;
    else begin
      case (mem_access_state)
        MEM_ACCESS_IDLE: begin
          if (mem_access_request_w)
            mem_access_next_state = MEM_ACCESS_EXECUTE;
        end
        MEM_ACCESS_EXECUTE: mem_access_next_state = MEM_ACCESS_COMPLETE;
        MEM_ACCESS_COMPLETE: mem_access_next_state = MEM_ACCESS_IDLE;
        default: mem_access_next_state = MEM_ACCESS_IDLE;
      endcase
    end
  end

  always_ff @(posedge g_clk or negedge rstn_i) begin
    if (!rstn_i) begin
      mem_access_request_d   <= 1'b0;
      mem_access_addr        <= '0;
      mem_access_read_data   <= '0;
      mem_access_target      <= '0;
      mem_access_write_en    <= 1'b0;
      mem_access_write_data  <= '0;
      mem_access_done        <= 1'b0;
    end else begin
      mem_access_request_d   <= data_config_i.extra_config_i[3];
      if (mem_access_cancel_w)
        mem_access_done        <= 1'b0;
      else begin
        case (mem_access_state)
          MEM_ACCESS_IDLE: begin
            if (mem_access_request_w) begin
              mem_access_addr        <= data_config_i.psum_offset;
              mem_access_target      <= test_config_i.bypass[1:0];
              mem_access_write_en    <= test_config_i.mode[0];
              mem_access_write_data  <= ext_inputs_i.ext_weight;
              mem_access_done        <= 1'b0;
            end
          end
          MEM_ACCESS_COMPLETE: begin
            if (mem_access_write_en)
              mem_access_read_data   <= '0;
            else begin
              case (mem_access_target)
                2'b00: mem_access_read_data <= ib_mem_data_i;
                2'b01: mem_access_read_data <= wb_mem_data_i;
                default: mem_access_read_data <= ob_mem_data_R_i;
              endcase
            end
            mem_access_done        <= 1'b1;
          end
          default: begin
          end
        endcase
      end
    end
  end

  assign mem_access_active_w = (mem_access_state == MEM_ACCESS_EXECUTE)
                              && !mem_access_cancel_w && en_i;
  assign ob_mem_wenb_R_o = ob_mem_wenb_R_core_w;
  assign ib_mem_data_o = mem_access_write_data;
  assign wb_mem_data_o = mem_access_write_data;

  // The compute schedulers own the SRAM ports except during an accepted access.
  always_comb begin
    ib_mem_cenb_o   = ib_mem_cenb_core_w;
    ib_mem_wenb_o   = ib_mem_wenb_core_w;
    ib_mem_addr_o   = ib_mem_addr_core_w;
    wb_mem_cenb_o   = wb_mem_cenb_core_w;
    wb_mem_wenb_o   = wb_mem_wenb_core_w;
    wb_mem_addr_o   = wb_mem_addr_core_w;
    ob_mem_cenb_R_o = ob_mem_cenb_R_core_w;
    ob_mem_addr_R_o = ob_mem_addr_R_core_w;
    if (mem_access_active_w) begin
      case (mem_access_target)
        2'b00: begin
          ib_mem_cenb_o = 1'b0;
          ib_mem_wenb_o = !mem_access_write_en;
          ib_mem_addr_o = mem_access_addr;
        end
        2'b01: begin
          wb_mem_cenb_o = 1'b0;
          wb_mem_wenb_o = !mem_access_write_en;
          wb_mem_addr_o = mem_access_addr;
        end
        2'b10: begin
          ob_mem_cenb_R_o = 1'b0;
          ob_mem_addr_R_o = mem_access_addr;
        end
        default: begin
        end
      endcase
    end
  end

  // test control signals
  assign driver_bypass_w   = test_config_i.bypass[0];
  assign dut_bypass_w      = test_config_i.bypass[1];
  assign sa_bypass_w       = test_config_i.bypass[2];

  assign driver_mode_w     = test_config_i.mode[0];
  assign sa_mode_w         = test_config_i.mode[1];

  // connect seeds
  assign driver_seed_w     = { ext_inputs_i.ext_input, ext_inputs_i.ext_psum };
  assign sa_seed_w         = { ext_inputs_i.ext_psum, ext_inputs_i.ext_input };

  // bypass external inputs that never go through the driver
  assign ext_inputs_w.ext_weight_en   = ext_inputs_i.ext_weight_en;
  assign ext_inputs_w.ext_input       = ext_input_w;
  assign ext_inputs_w.ext_valid       = ext_valid_i_w;
  assign ext_inputs_w.ext_weight      = ext_inputs_i.ext_weight ;
  assign ext_inputs_w.ext_psum        = ext_psum_w;

  //-------------------------------------------------------------------------//
  //    Reset synchronizer                                                   //
  //-------------------------------------------------------------------------//
  async_nreset_synchronizer_3 async_nreset_synchronizer_0 (
     .clk_i            (g_clk            )
    ,.async_nreset_i   (rstn_async_i     )
    ,.rstn_o           (rstn_i           )
  );

  //-------------------------------------------------------------------------//
  //    Driver                                                               //
  //-------------------------------------------------------------------------//
  pseudo_rand_num_gen_3 #(.DATA_WIDTH (64))
    driver_0 (
      .clk_i        (g_clk                            ),
      .rstn_i       (rstn_i                           ),
      .bypass_i     (driver_mode_w                    ),
      .valid_i      (test_config_i.driver_valid       ),
      .seed_i       (driver_seed_w                    ),
      .stop_code_i  (test_config_i.driver_stop_code   ),
      .valid_o      (driver_valid_o_w                 ),
      .data_o       (driver_data_w                    ),
      .done_o       (driver_done_w                    )
    );

  // driver bypass
  assign { ext_input_w, ext_psum_w } = ( driver_bypass_w)  ? { ext_inputs_i.ext_input, ext_inputs_i.ext_psum } : driver_data_w;
  assign ext_valid_i_w               = ( driver_bypass_w)  ? ext_inputs_i.ext_valid : driver_valid_o_w; 

  //-------------------------------------------------------------------------//
  //    Matrix mult                                                          //
  //-------------------------------------------------------------------------//
  matrix_mult_3 #(
      .WIDTH            (WIDTH),
      .ACCUM_WIDTH      (ACCUM_WIDTH),
      .ARRAY_ACCUM_WIDTH(ARRAY_ACCUM_WIDTH),
      .Tm               (Tm),
      .Tn               (Tn),
      .Tk               (Tk),
      .M                (M),
      .N                (N),
      .K                (K),
      .W_SIZE           (W_SIZE),
      .I_SIZE           (I_SIZE),
      .O_SIZE           (O_SIZE)
  ) matrix_mult_0 (
      .clk_i                (g_clk                ),
      .rstn_i               (rstn_i               ),
      .start_i              (start_i              ),
      .data_config_i        (data_config_i        ),
      .ob_mem_cenb_R_o      (ob_mem_cenb_R_core_w ),
      .ob_mem_wenb_R_o      (ob_mem_wenb_R_core_w ),
      .ob_mem_addr_R_o      (ob_mem_addr_R_core_w ),
      .ob_mem_data_R_o      (ob_mem_data_R_o_w    ),
      .ob_mem_data_R_i      (ob_mem_data_R_i_w    ),
      .ob_mem_cenb_W_o      (ob_mem_cenb_W_o      ),
      .ob_mem_wenb_W_o      (ob_mem_wenb_W_o      ),
      .ob_mem_addr_W_o      (ob_mem_addr_W_o      ),
      .ob_mem_data_W_o      (ob_mem_data_W_o_w    ),
      .ob_mem_data_W_i      (ob_mem_data_W_i_w    ),
      .ib_mem_cenb_o        (ib_mem_cenb_core_w   ),
      .ib_mem_wenb_o        (ib_mem_wenb_core_w   ),
      .ib_mem_addr_o        (ib_mem_addr_core_w   ),
      .ib_mem_data_i        (ib_mem_data_i_w      ),
      .wb_mem_cenb_o        (wb_mem_cenb_core_w   ),
      .wb_mem_wenb_o        (wb_mem_wenb_core_w   ),
      .wb_mem_addr_o        (wb_mem_addr_core_w   ),
      .wb_mem_data_i        (wb_mem_data_i_w      ),
      .ext_en_i             (ext_en_i             ),
      .ext_inputs_i         (ext_inputs_w         ),
      .ext_result_o         (ext_result_w         ),
      .ext_valid_o          (ext_valid_o_w        ),
      .done_o               (done_o               ),
      .extra_output_bits_o  (extra_output_bits_o  )
    );

  // Memory mode observes every SRAM write, including intermediate partial sums.
  assign sa_dut_data_w = ext_en_i
                      ? (dut_bypass_w ? {ext_input_w, ext_psum_w}
                                      : {{(WIDTH*Tm){1'b0}}, ext_result_w})
                      : ob_mem_data_W_o;
  assign sa_dut_valid_w = ext_en_i
                       ? (dut_bypass_w ? ext_valid_i_w : ext_valid_o_w)
                       : (!ob_mem_cenb_W_o && !ob_mem_wenb_W_o);
  // Wait until every accepted pattern has reached the signature analyzer.
  assign sa_compress_mode_w = ext_en_i && !sa_bypass_w && !sa_mode_w;
  assign bist_mode_w = sa_compress_mode_w && !driver_bypass_w && !driver_mode_w;
  assign sa_stop_w = ext_en_i
                   ? (sa_compress_mode_w
                      && (bist_mode_w ? driver_done_w : external_sa_stop_pending)
                      && (sa_pending_count == 0) && !ext_valid_i_w && !sa_dut_valid_w)
                   : (done_o && !sa_bypass_w && !sa_mode_w && !sa_dut_valid_w);

  // Extra scan bit 2 requests external-stream completion after all results drain.
  always_ff @(posedge g_clk or negedge rstn_i) begin
    if (!rstn_i)
      external_sa_stop_pending <= 1'b0;
    else if (!sa_compress_mode_w || bist_mode_w)
      external_sa_stop_pending <= 1'b0;
    else if (data_config_i.extra_config_i[2])
      external_sa_stop_pending <= 1'b1;
  end

  always_ff @(posedge g_clk or negedge rstn_i) begin
    if (!rstn_i)
      sa_pending_count <= '0;
    else if (!sa_compress_mode_w)
      sa_pending_count <= '0;
    else begin
      case ({ext_valid_i_w, sa_dut_valid_w})
        2'b10: sa_pending_count <= sa_pending_count + 1'b1;
        2'b01: begin
          if (sa_pending_count != 0)
            sa_pending_count <= sa_pending_count - 1'b1;
        end
        default: begin
        end
      endcase
    end
  end

  //-------------------------------------------------------------------------//
  //    Monitor                                                              //
  //-------------------------------------------------------------------------//
  signature_analyzer_3 #(.DATA_WIDTH (DRIVER_WIDTH) )
    monitor_0 (
      .clk_i        (g_clk          ),
      .rstn_i       (rstn_i         ),
      .clear_i      (compute_start_w),
      .bypass_i     (sa_mode_w      ),     
      .stop_i       (sa_stop_w      ),     
      .seed_i       (sa_seed_w      ),
      .dut_valid_i  (sa_dut_valid_w ),     
      .dut_data_i   (sa_dut_data_w  ),
      .valid_o      (sa_valid_w     ),
      .data_o       (sa_data_w      )
    );

  // Memory access responses take priority over the write stream or signature.
  assign mem_access_output_w = !ext_en_i && !compute_start_w
                          && ((mem_access_state != MEM_ACCESS_IDLE) || mem_access_done);
  assign ext_result_o = mem_access_output_w ? mem_access_read_data
                     : (sa_bypass_w ? sa_dut_data_w : sa_data_w);
  assign ext_valid_o = mem_access_output_w ? mem_access_done
                    : (sa_bypass_w ? sa_dut_valid_w : sa_valid_w);

endmodule
