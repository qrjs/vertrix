// Copyright TU Wien
// Licensed under the Solderpad Hardware License v2.1, see LICENSE.txt for details
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1


module vproc_top import vproc_pkg::*;
`ifdef RISCV_ZVE32F
    import fpnew_pkg::*;
`endif
#(
        parameter int unsigned     MEM_W         = 32,  // memory bus width in bits
        parameter int unsigned     VMEM_W        = 32,  // vector memory interface width in bits
        parameter vreg_type        VREG_TYPE     = VREG_GENERIC,
        parameter mul_type         MUL_TYPE      = MUL_GENERIC,
        parameter int unsigned     ICACHE_SZ     = 0,   // instruction cache size in bytes
        parameter int unsigned     ICACHE_LINE_W = 128, // instruction cache line width in bits
        parameter int unsigned     DCACHE_SZ     = 0,   // data cache size in bytes
        parameter int unsigned     DCACHE_LINE_W = 512  // data cache line width in bits
    )(
        input  logic               clk_i,
        input  logic               rst_ni,

        // 指令内存端口 (Harvard Architecture)
        output logic               imem_req_o,
        output logic [31:0]        imem_addr_o,
        input  logic               imem_rvalid_i,
        input  logic               imem_err_i,
        input  logic [MEM_W  -1:0] imem_rdata_i,

        // 数据内存端口 (Harvard Architecture)
        output logic               dmem_req_o,
        output logic [31:0]        dmem_addr_o,
        output logic               dmem_we_o,
        output logic [MEM_W/8-1:0] dmem_be_o,
        output logic [MEM_W  -1:0] dmem_wdata_o,
        input  logic               dmem_rvalid_i,
        input  logic               dmem_err_i,
        input  logic [MEM_W  -1:0] dmem_rdata_i,

        output logic [31:0]        pend_vreg_wr_map_o,
        output logic               core_sleep_o
    );

    if ((MEM_W & (MEM_W - 1)) != 0 || MEM_W < 32) begin
        $fatal(1, "The memory bus width MEM_W must be at least 32 and a power of two.  ",
                  "The current value of %d is invalid.", MEM_W);
    end

    // Reset synchronizer (sync reset is used for Vicuna by default, async reset for the core)
    logic [3:0] rst_sync_qn;
    logic sync_rst_n;
    always_ff @(posedge clk_i) begin
        rst_sync_qn[0] <= rst_ni;
        for (int i = 1; i < 4; i++) begin
            rst_sync_qn[i] <= rst_sync_qn[i-1];
        end
    end
    assign sync_rst_n = rst_sync_qn[3];


    ///////////////////////////////////////////////////////////////////////////
    // MAIN CORE INTEGRATION

    // Instruction fetch interface
    logic        instr_req;
    logic [31:0] instr_addr;
    logic        instr_gnt;
    logic        instr_rvalid;
    logic        instr_err;
    logic [31:0] instr_rdata;

    // Data load & store interface
    logic        sdata_req;
    logic [31:0] sdata_addr;
    logic        sdata_we;
    logic  [3:0] sdata_be;
    logic [31:0] sdata_wdata;
    logic        sdata_gnt;
    logic        sdata_rvalid;
    logic        sdata_err;
    logic [31:0] sdata_rdata;

    // Vector Unit Interface
    localparam int unsigned X_ID_WIDTH = 3;
    logic        vect_pending_load;
    logic        vect_pending_store;
    logic        issue_valid;
    logic        issue_ready;
    logic [31:0] issue_instr;
    logic [1:0]  issue_mode;
    logic [X_ID_WIDTH-1:0] issue_id;
    logic [31:0] issue_rs1;
    logic [31:0] issue_rs2;
    logic [1:0]  issue_rs_valid;
    logic        issue_accept;
    logic        issue_writeback;
    logic        issue_dualwrite;
    logic [2:0]  issue_dualread;
    logic        issue_loadstore;
    logic        issue_exc;
    logic        commit_valid;
    logic [X_ID_WIDTH-1:0] commit_id;
    logic        commit_kill;
    logic        result_valid;
    logic        result_ready;
    logic [X_ID_WIDTH-1:0] result_id;
    logic [31:0] result_data;
    logic [4:0]  result_rd;
    logic        result_we;
    logic        result_exc;
    logic [5:0]  result_exccode;
    logic        result_err;
    logic        result_dbg;
    logic        vlsu_mem_valid;
    logic        vlsu_mem_ready;
    logic [X_ID_WIDTH-1:0] vlsu_mem_id;
    logic [31:0] vlsu_mem_addr;
    logic        vlsu_mem_we;
    logic [VMEM_W/8-1:0] vlsu_mem_be;
    logic [VMEM_W-1:0] vlsu_mem_wdata;
    logic        vlsu_mem_last;
    logic        vlsu_mem_spec;
    logic        vlsu_mem_resp_exc;
    logic [5:0]  vlsu_mem_resp_exccode;
    logic        vlsu_mem_result_valid;
    logic [X_ID_WIDTH-1:0] vlsu_mem_result_id;
    logic [VMEM_W-1:0] vlsu_mem_result_rdata;
    logic        vlsu_mem_result_err;

    logic [2:0]  fcsr_frm;

    logic [31:0] vcsr_vtype;
    logic [31:0] vcsr_vl;
    logic [31:0] vcsr_vlenb;
    logic [31:0] vcsr_vstart;
    logic [1:0]  vcsr_vxrm;
    logic        vcsr_vxsat;

`ifdef MAIN_CORE_IBEX

    logic        cpi_instr_valid;
    logic [31:0] cpi_instr;
    logic [31:0] cpi_x_rs1;
    logic [31:0] cpi_x_rs2;
    logic        cpi_instr_gnt;
    logic        cpi_instr_illegal;
    logic        cpi_misaligned_ls;
    logic        cpi_xreg_wait;
    logic        cpi_result_valid;
    logic        cpi_xreg_valid;
    logic [31:0] cpi_xreg;
    logic        cpi_is_matrix;
    logic        mat_instr_gnt;
    logic        mat_instr_illegal;
    logic        mat_wait;
    logic        mat_res_valid;
    logic [31:0] mat_res;
    logic        mdata_req;
    logic [31:0] mdata_addr;
    logic        mdata_we;
    logic [7:0]  mdata_be;
    logic [63:0] mdata_wdata;
    logic        mdata_gnt;
    logic        mdata_rvalid;
    logic        mdata_err;
    logic [63:0] mdata_rdata;

    ibex_top #(
        .DmHaltAddr             ( 32'h00000000                       ),
        .DmExceptionAddr        ( 32'h00000000                       ),
        .RV32M                  ( ibex_pkg::RV32MFast                ),
        .ExternalCSRs           ( 0                                  ),  // No external CSRs, use vector CSR interface
        .VLEN                   ( vproc_config::VREG_W               ),  // Vector register length from config
        // LOAD-FP, STORE-FP, VECTOR and CUSTOM-0 opcodes
        .CoprocOpcodes          ( 32'h00200E06                       )
    ) u_core (
        .clk_i                  ( clk_i                              ),
        .rst_ni                 ( rst_ni                             ),

        .test_en_i              ( 1'b0                               ),
        .ram_cfg_i              ( prim_ram_1p_pkg::ram_1p_cfg_t'('0) ),

        .hart_id_i              ( 32'b0                              ),
        .boot_addr_i            ( 32'h00000000                       ),

        .instr_req_o            ( instr_req                          ),
        .instr_gnt_i            ( instr_gnt                          ),
        .instr_rvalid_i         ( instr_rvalid                       ),
        .instr_addr_o           ( instr_addr                         ),
        .instr_rdata_i          ( instr_rdata                        ),
        .instr_err_i            ( instr_err                          ),

        .data_req_o             ( sdata_req                          ),
        .data_gnt_i             ( sdata_gnt                          ),
        .data_rvalid_i          ( sdata_rvalid                       ),
        .data_we_o              ( sdata_we                           ),
        .data_be_o              ( sdata_be                           ),
        .data_addr_o            ( sdata_addr                         ),
        .data_wdata_o           ( sdata_wdata                        ),
        .data_rdata_i           ( sdata_rdata                        ),
        .data_err_i             ( sdata_err                          ),

        .cpi_req_o              ( cpi_instr_valid                    ),
        .cpi_instr_o            ( cpi_instr                          ),
        .cpi_rs1_o              ( cpi_x_rs1                          ),
        .cpi_rs2_o              ( cpi_x_rs2                          ),
        .cpi_gnt_i              ( cpi_instr_gnt                      ),
        .cpi_instr_illegal_i    ( cpi_instr_illegal                  ),
        .cpi_wait_i             ( cpi_xreg_wait                      ),
        .cpi_res_valid_i        ( cpi_result_valid                   ),
        .cpi_res_i              ( cpi_xreg                           ),

        .irq_software_i         ( 1'b0                               ),
        .irq_timer_i            ( 1'b0                               ),
        .irq_external_i         ( 1'b0                               ),
        .irq_fast_i             ( 15'b0                              ),
        .irq_nm_i               ( 1'b0                               ),

        .ecsr_addr_i            ( '{default: 12'h0}                  ),  // No external CSRs
        .ecsr_rdata_i           ( '{default: 32'h0}                  ),
        .ecsr_we_o              (                                    ),
        .ecsr_wdata_o           (                                    ),

        .fcsr_frm_o             ( fcsr_frm                           ),

        .vcsr_vtype_o           ( vcsr_vtype                         ),
        .vcsr_vl_o              ( vcsr_vl                            ),
        .vcsr_vlenb_o           ( vcsr_vlenb                         ),
        .vcsr_vstart_o          ( vcsr_vstart                        ),
        .vcsr_vstart_i          ( csr_vstart_wr                      ),
        .vcsr_vstart_set_o      ( csr_vstart_wren                    ),
        .vcsr_vxrm_o            ( vcsr_vxrm                          ),
        .vcsr_vxrm_i            ( csr_vxrm_wr                        ),
        .vcsr_vxrm_set_o        ( csr_vxrm_wren                      ),
        .vcsr_vxsat_o           ( vcsr_vxsat                         ),
        .vcsr_vxsat_i           ( csr_vxsat_wr                       ),
        .vcsr_vxsat_set_o       ( csr_vxsat_wren                     ),
        .vcsr_vl_i              ( csr_vl                             ),  // vl from vector core
        .vcsr_vl_set_i          ( csr_vl_changed                     ),  // write when vl changes
        .vcsr_vtype_i           ( csr_vtype                          ),  // vtype from vector core
        .vcsr_vtype_set_i       ( csr_vtype_changed                  ),  // write when vtype changes

        .debug_req_i            ( 1'b0                               ),
        .crash_dump_o           (                                    ),

        .fetch_enable_i         ( 1'b1                               ),
        .alert_minor_o          (                                    ),
        .alert_major_o          (                                    ),
        .core_sleep_o           ( core_sleep_o                       ),

        .scan_rst_ni            ( 1'b1                               )
    );

    logic [X_ID_WIDTH-1:0] cpi_instr_id_q, cpi_instr_id_q2, cpi_instr_id_d;
    logic                  cpi_commit_q,                    cpi_commit_d;
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (~rst_ni) begin
            cpi_instr_id_q  <= '0;
            cpi_instr_id_q2 <= '0;
            cpi_commit_q    <= '0;
        end else begin
            cpi_instr_id_q  <= cpi_instr_id_d;
            cpi_instr_id_q2 <= cpi_instr_id_q;
            cpi_commit_q    <= cpi_commit_d;
        end
    end
    always_comb begin
        cpi_instr_id_d = cpi_instr_id_q;
        if (issue_ready & issue_valid) begin
            cpi_instr_id_d = cpi_instr_id_q + {{X_ID_WIDTH-1{1'b0}}, 1'b1};
        end
    end
    assign cpi_commit_d = issue_valid & issue_ready & issue_accept;

    assign cpi_is_matrix  = cpi_instr_valid & (cpi_instr[6:0] == 7'b0001011);
    
    logic mat_instr_active_q;
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (~rst_ni) begin
            mat_instr_active_q <= 1'b0;
        end else begin
            if (cpi_is_matrix & mat_instr_gnt) begin
                mat_instr_active_q <= 1'b1;
            end else if (mat_res_valid) begin
                mat_instr_active_q <= 1'b0;
            end
        end
    end
    
    logic mat_active;
    assign mat_active = cpi_is_matrix | mat_instr_active_q;
    
    assign issue_valid    = cpi_instr_valid & ~cpi_is_matrix;
    assign issue_instr    = cpi_instr;
    assign issue_mode     = '0;
    assign issue_id       = cpi_instr_id_q;
    assign issue_rs1      = cpi_x_rs1;
    assign issue_rs2      = cpi_x_rs2;
    assign issue_rs_valid = 2'b11;

    assign cpi_instr_gnt     = cpi_is_matrix ? mat_instr_gnt : issue_ready;
    assign cpi_instr_illegal = cpi_is_matrix ? mat_instr_illegal : ~issue_accept;
    assign cpi_xreg_wait     = mat_active ? mat_wait : issue_writeback;

    assign commit_valid = cpi_commit_q;
    assign commit_id    = cpi_instr_id_q2;
    assign commit_kill  = 1'b0;

    assign result_ready   = 1'b1;
    assign cpi_result_valid = mat_active ? mat_res_valid : (result_valid & result_we);
    assign cpi_xreg         = mat_active ? mat_res : result_data;

    outer_product_matrix_unit #(
        .MEM_WIDTH       ( 64               )
    ) mat_unit (
        .clk_i           ( clk_i            ),
        .rst_ni          ( rst_ni           ),
        .instr_valid_i   ( cpi_is_matrix    ),
        .instr_i         ( cpi_instr        ),
        .rs1_i           ( cpi_x_rs1        ),
        .rs2_i           ( cpi_x_rs2        ),
        .instr_gnt_o     ( mat_instr_gnt    ),
        .instr_illegal_o ( mat_instr_illegal ),
        .wait_o          ( mat_wait         ),
        .res_valid_o     ( mat_res_valid    ),
        .res_o           ( mat_res          ),
        .mem_req_o       ( mdata_req        ),
        .mem_addr_o      ( mdata_addr       ),
        .mem_we_o        ( mdata_we         ),
        .mem_be_o        ( mdata_be         ),
        .mem_wdata_o     ( mdata_wdata      ),
        .mem_gnt_i       ( mdata_gnt        ),
        .mem_rvalid_i    ( mdata_rvalid     ),
        .mem_err_i       ( mdata_err        ),
        .mem_rdata_i     ( mdata_rdata      )
    );

`else
    $fatal(1, "MAIN_CORE_IBEX must be defined to select the main core.");
`endif


    ///////////////////////////////////////////////////////////////////////////
    // VECTOR CORE INTEGRATION

    // Vector CSR read/write conversion (from/to vector core)
    // CSRs are now stored in unified CSR file in ibex_cs_registers
    logic [31:0] csr_vtype;
    logic [31:0] csr_vl;
    logic [31:0] csr_vlenb;
    logic [31:0] csr_vstart_wr;   // vstart written by vector core
    logic        csr_vstart_wren;
    logic [1:0]  csr_vxrm_wr;     // vxrm written by vector core
    logic        csr_vxrm_wren;
    logic        csr_vxsat_wr;    // vxsat written by vector core
    logic        csr_vxsat_wren;

    // csr_vtype, csr_vl, csr_vlenb are driven by vproc_core outputs
    // No assignment needed here, they are connected through port connections

    // Detect changes in vproc_core CSR outputs to sync back to unified CSR
    // vtype and vl are updated by vsetvl instructions
    // vstart, vxrm and vxsat write signals are now directly driven by vproc_core
    logic [31:0] csr_vtype_q, csr_vl_q;
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (~rst_ni) begin
            csr_vtype_q   <= 32'h80000000;
            csr_vl_q      <= '0;
        end else begin
            csr_vtype_q   <= csr_vtype;
            csr_vl_q      <= csr_vl;
        end
    end

    // Generate write enables when CSRs change
    logic csr_vtype_changed, csr_vl_changed;
    assign csr_vtype_changed  = (csr_vtype != csr_vtype_q);
    assign csr_vl_changed     = (csr_vl != csr_vl_q);
    // csr_vstart_wr, csr_vstart_wren, csr_vxrm_wr, csr_vxrm_wren, csr_vxsat_wr, csr_vxsat_wren 
    // are all driven by vproc_core

    // Data read/write for Vector Unit
    logic                vdata_gnt;
    logic                vdata_rvalid;
    logic                vdata_err;
    logic [VMEM_W-1:0]   vdata_rdata;
    logic                vdata_req;
    logic [31:0]         vdata_addr;
    logic                vdata_we;
    logic [VMEM_W/8-1:0] vdata_be;
    logic [VMEM_W-1:0]   vdata_wdata;
    logic [X_ID_WIDTH-1:0] vdata_req_id;
    logic [X_ID_WIDTH-1:0] vdata_res_id;

    localparam bit [VLSU_FLAGS_W-1:0] VLSU_FLAGS = (VLSU_FLAGS_W'(1) << VLSU_ALIGNED_UNITSTRIDE);

    localparam bit [BUF_FLAGS_W -1:0] BUF_FLAGS  = (BUF_FLAGS_W'(1) << BUF_DEQUEUE  ) |
                                                   (BUF_FLAGS_W'(1) << BUF_VREG_PEND);

    vproc_core #(
        .INSTR_ID_W         ( X_ID_WIDTH         ),
        .VMEM_W             ( VMEM_W             ),
        .VREG_TYPE          ( VREG_TYPE          ),
        .MUL_TYPE           ( MUL_TYPE           ),
        .VLSU_FLAGS         ( VLSU_FLAGS         ),
        .BUF_FLAGS          ( BUF_FLAGS          ),
        .DONT_CARE_ZERO     ( 1'b0               ),
        .ASYNC_RESET        ( 1'b0               )
    ) v_core (
        .clk_i              ( clk_i              ),
        .rst_ni             ( sync_rst_n         ),

        .issue_valid_i      ( issue_valid        ),
        .issue_ready_o      ( issue_ready        ),
        .issue_instr_i      ( issue_instr        ),
        .issue_mode_i       ( issue_mode         ),
        .issue_id_i         ( issue_id           ),
        .issue_rs1_i        ( issue_rs1          ),
        .issue_rs2_i        ( issue_rs2          ),
        .issue_rs_valid_i   ( issue_rs_valid     ),
        .issue_accept_o     ( issue_accept       ),
        .issue_writeback_o  ( issue_writeback    ),
        .issue_dualwrite_o  ( issue_dualwrite    ),
        .issue_dualread_o   ( issue_dualread     ),
        .issue_loadstore_o  ( issue_loadstore    ),
        .issue_exc_o        ( issue_exc          ),
        .commit_valid_i     ( commit_valid       ),
        .commit_id_i        ( commit_id          ),
        .commit_kill_i      ( commit_kill        ),
        .vlsu_mem_valid_o   ( vlsu_mem_valid     ),
        .vlsu_mem_ready_i   ( vlsu_mem_ready     ),
        .vlsu_mem_id_o      ( vlsu_mem_id        ),
        .vlsu_mem_addr_o    ( vlsu_mem_addr      ),
        .vlsu_mem_we_o      ( vlsu_mem_we        ),
        .vlsu_mem_be_o      ( vlsu_mem_be        ),
        .vlsu_mem_wdata_o   ( vlsu_mem_wdata     ),
        .vlsu_mem_last_o    ( vlsu_mem_last      ),
        .vlsu_mem_spec_o    ( vlsu_mem_spec      ),
        .vlsu_mem_resp_exc_i     ( vlsu_mem_resp_exc      ),
        .vlsu_mem_resp_exccode_i ( vlsu_mem_resp_exccode  ),
        .vlsu_mem_result_valid_i ( vlsu_mem_result_valid  ),
        .vlsu_mem_result_id_i    ( vlsu_mem_result_id     ),
        .vlsu_mem_result_rdata_i ( vlsu_mem_result_rdata  ),
        .vlsu_mem_result_err_i   ( vlsu_mem_result_err    ),
        .result_valid_o     ( result_valid       ),
        .result_ready_i     ( result_ready       ),
        .result_id_o        ( result_id          ),
        .result_data_o      ( result_data        ),
        .result_rd_o        ( result_rd          ),
        .result_we_o        ( result_we          ),
        .result_exc_o       ( result_exc         ),
        .result_exccode_o   ( result_exccode     ),
        .result_err_o       ( result_err         ),
        .result_dbg_o       ( result_dbg         ),

        .pending_load_o     ( vect_pending_load  ),
        .pending_store_o    ( vect_pending_store ),

        // Vector CSR interface - all CSRs now stored in unified CSR file
        .csr_vtype_o        ( csr_vtype          ),  // vtype output from vector core
        .csr_vl_o           ( csr_vl             ),  // vl output from vector core
        .csr_vlenb_o        ( csr_vlenb          ),  // vlenb constant
        .csr_vstart_i       ( vcsr_vstart        ),  // vstart from unified CSR
        .csr_vstart_o       ( csr_vstart_wr      ),  // vstart write value from vector core
        .csr_vstart_set_o   ( csr_vstart_wren    ),  // vstart write enable from vector core
        .csr_vxrm_i         ( vcsr_vxrm          ),  // vxrm from unified CSR
        .csr_vxrm_o         ( csr_vxrm_wr        ),  // vxrm write value from vector core
        .csr_vxrm_set_o     ( csr_vxrm_wren      ),  // vxrm write enable from vector core
        .csr_vxsat_i        ( vcsr_vxsat         ),  // vxsat from unified CSR
        .csr_vxsat_o        ( csr_vxsat_wr       ),  // vxsat write value from vector core
        .csr_vxsat_set_o    ( csr_vxsat_wren     ),  // vxsat write enable from vector core

    `ifdef RISCV_ZVE32F
        .fpr_wr_req_valid_o (                    ),
        .fpr_wr_req_addr_o  (                    ),
        .fpr_res_valid_o    (                    ),
        .float_round_mode_i ( fpnew_pkg::roundmode_e'(fcsr_frm) ),
        .fpu_res_acc_i      ( 1'b0               ),
        .fpu_res_id_i       ( '0                 ),
    `endif

        .pend_vreg_wr_map_o ( pend_vreg_wr_map_o )
    );

    // Extract vector unit memory signals from VLSU interface
    assign vdata_req                 = vlsu_mem_valid;
    assign vlsu_mem_ready            = vdata_gnt;
    assign vdata_addr                = vlsu_mem_addr;
    assign vdata_we                  = vlsu_mem_we;
    assign vdata_be                  = vlsu_mem_be;
    assign vdata_wdata               = vlsu_mem_wdata;
    assign vdata_req_id              = vlsu_mem_id;
    assign vlsu_mem_resp_exc         = '0;
    assign vlsu_mem_resp_exccode     = '0;
    assign vlsu_mem_result_valid     = vdata_rvalid;
    assign vlsu_mem_result_id        = vdata_res_id;
    assign vlsu_mem_result_rdata     = vdata_rdata;
    assign vlsu_mem_result_err       = vdata_err;

    // Data arbiter for main core, vector unit, and matrix unit
    logic                sdata_hold;
    logic                mdata_hold;
    logic                data_req;
    logic [31:0]         data_addr;
    logic                data_we;
    logic [VMEM_W/8-1:0] data_be;
    logic [VMEM_W  -1:0] data_wdata;
    logic                data_gnt;
    logic                data_rvalid;
    logic                data_err;
    logic [VMEM_W  -1:0] data_rdata;
    localparam int unsigned VMEM_BYTES = VMEM_W / 8;
    localparam int unsigned MDATA_BYTES = 8;
    localparam int unsigned MDATA_ALIGN_BITS = $clog2(MDATA_BYTES);
    logic [$clog2(VMEM_BYTES)-1:0] mdata_byte_off_req;
    logic [$clog2(VMEM_BYTES)-1:0] mdata_lane_off_req;
    logic [$clog2(VMEM_BYTES)-1:0] mdata_byte_off_resp;
    logic [$clog2(VMEM_BYTES)-1:0] mdata_lane_off_resp;
    logic                sdata_waiting, vdata_waiting, mdata_waiting;
    logic [31:0]         sdata_wait_addr;
    logic [31:0]         mdata_wait_addr;
    logic [X_ID_WIDTH-1:0] vdata_wait_id;
    assign sdata_hold = vdata_req | vect_pending_store | (vect_pending_load & sdata_we) | mdata_req;
    assign mdata_byte_off_req = mdata_addr[$clog2(VMEM_BYTES)-1:0];
    assign mdata_lane_off_req = (mdata_byte_off_req >> MDATA_ALIGN_BITS) << MDATA_ALIGN_BITS;
    assign mdata_byte_off_resp = mdata_wait_addr[$clog2(VMEM_BYTES)-1:0];
    assign mdata_lane_off_resp = (mdata_byte_off_resp >> MDATA_ALIGN_BITS) << MDATA_ALIGN_BITS;
    assign mdata_hold = vdata_req;
    always_comb begin
        data_req   = vdata_req | (sdata_req & ~sdata_hold) | (mdata_req & ~mdata_hold);
        data_addr  = sdata_addr;
        data_we    = sdata_we;
        data_be    = {{(VMEM_W-32){1'b0}}, sdata_be} << (sdata_addr[$clog2(VMEM_W/8)-1:0] & {{$clog2(VMEM_W/32){1'b1}}, 2'b00});
        data_wdata = '0;
        for (int i = 0; i < VMEM_W / 32; i++) begin
            data_wdata[32*i +: 32] = sdata_wdata;
        end
        if (mdata_req & ~mdata_hold) begin
            data_addr  = mdata_addr;
            data_we    = mdata_we;
            data_be    = VMEM_W >= 64 ? ({{(VMEM_W > 64 ? VMEM_W-64 : 1){1'b0}}, mdata_be} << mdata_lane_off_req) : mdata_be[VMEM_W/8-1:0];
            data_wdata = '0;
            if (VMEM_W >= 64) begin
                for (int i = 0; i < VMEM_W / 64; i++) begin
                    data_wdata[64*i +: 64] = mdata_wdata;
                end
            end else begin
                data_wdata = mdata_wdata[VMEM_W-1:0];
            end
        end
        if (vdata_req) begin
            data_addr  = vdata_addr;
            data_we    = vdata_we;
            data_be    = vdata_be;
            data_wdata = vdata_wdata;
        end
    end
    assign sdata_gnt = data_gnt & sdata_req & ~sdata_hold;
    assign vdata_gnt = data_gnt & vdata_req;
    assign mdata_gnt = data_gnt & mdata_req & ~mdata_hold;
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (~rst_ni) begin
            sdata_waiting   <= 1'b0;
            vdata_waiting   <= 1'b0;
            sdata_wait_addr <= '0;
            vdata_wait_id   <= '0;
            mdata_waiting   <= 1'b0;
            mdata_wait_addr <= '0;
        end else begin
            if (sdata_gnt) begin
                sdata_waiting   <= 1'b1;
                sdata_wait_addr <= sdata_addr;
            end
            else if (sdata_rvalid) begin
                sdata_waiting <= 1'b0;
            end
            if (vdata_gnt) begin
                vdata_waiting <= 1'b1;
                vdata_wait_id <= vdata_req_id;
            end
            else if (vdata_rvalid) begin
                vdata_waiting <= 1'b0;
            end
            if (mdata_gnt) begin
                mdata_waiting   <= 1'b1;
                mdata_wait_addr <= mdata_addr;
            end
            else if (mdata_rvalid) begin
                mdata_waiting <= 1'b0;
            end
        end
    end
    assign sdata_rvalid = sdata_waiting & data_rvalid;
    assign vdata_rvalid = vdata_waiting & data_rvalid;
    assign mdata_rvalid = mdata_waiting & data_rvalid;
    assign sdata_err    = data_err;
    assign vdata_err    = data_err;
    assign mdata_err    = data_err;
    assign sdata_rdata  = data_rdata[(sdata_wait_addr[$clog2(VMEM_W)-1:0] & {3'b000, {($clog2(VMEM_W/8)-2){1'b1}}, 2'b00})*8 +: 32];
    assign vdata_rdata  = data_rdata;
    generate
        if (VMEM_W >= 64) begin : gen_mdata_rdata_wide
            assign mdata_rdata = data_rdata[mdata_lane_off_resp*8 +: 64];
        end else begin : gen_mdata_rdata_narrow
            assign mdata_rdata = {{(64-VMEM_W){1'b0}}, data_rdata};
        end
    endgenerate
    assign vdata_res_id = vdata_wait_id;


    ///////////////////////////////////////////////////////////////////////////
    // CACHES

    // instruction cache
    logic             imem_req;
    logic             imem_gnt;
    logic [31:0]      imem_addr;
    logic             imem_rvalid;
    logic [MEM_W-1:0] imem_rdata;
    logic             imem_err;
    generate
        if (ICACHE_SZ != 0) begin
            localparam int unsigned ICACHE_WAY_LEN = ICACHE_SZ / (ICACHE_LINE_W / 8) / 2;
            vproc_cache #(
                .ADDR_BIT_W   ( 32                ),
                .CPU_BYTE_W   ( 4                 ),
                .MEM_BYTE_W   ( MEM_W / 8         ),
                .LINE_BYTE_W  ( ICACHE_LINE_W / 8 ),
                .WAY_LEN      ( ICACHE_WAY_LEN    )
            ) icache (
                .clk_i        ( clk_i             ),
                .rst_ni       ( rst_ni            ),
                .hold_mem_i   ( 1'b0              ),
                .cpu_req_i    ( instr_req         ),
                .cpu_addr_i   ( instr_addr        ),
                .cpu_we_i     ( '0                ),
                .cpu_be_i     ( '0                ),
                .cpu_wdata_i  ( '0                ),
                .cpu_gnt_o    ( instr_gnt         ),
                .cpu_rvalid_o ( instr_rvalid      ),
                .cpu_rdata_o  ( instr_rdata       ),
                .cpu_err_o    ( instr_err         ),
                .mem_req_o    ( imem_req          ),
                .mem_addr_o   ( imem_addr         ),
                .mem_we_o     (                   ),
                .mem_wdata_o  (                   ),
                .mem_gnt_i    ( imem_gnt          ),
                .mem_rvalid_i ( imem_rvalid       ),
                .mem_rdata_i  ( imem_rdata        ),
                .mem_err_i    ( imem_err          )
            );
        end else begin
            assign imem_req     = instr_req;
            assign imem_addr    = instr_addr;
            assign instr_gnt    = imem_gnt;
            assign instr_rvalid = imem_rvalid;
            assign instr_rdata  = imem_rdata[31:0];
            assign instr_err    = imem_err;
        end
    endgenerate

    // data cache
    logic               dmem_req;
    logic               dmem_gnt;
    logic [31:0]        dmem_addr;
    logic               dmem_we;
    logic [MEM_W/8-1:0] dmem_be;
    logic [MEM_W  -1:0] dmem_wdata;
    logic               dmem_rvalid;
    logic               dmem_wvalid;
    logic [MEM_W  -1:0] dmem_rdata;
    logic               dmem_err;
    generate
        if (DCACHE_SZ != 0) begin
            localparam int unsigned DCACHE_WAY_LEN = DCACHE_SZ / (DCACHE_LINE_W / 8) / 2;
            // hold memory access (allows lookup only) for main core requests
            // in case of pending vector loads / stores
            logic hold_mem;
            always_ff @(posedge clk_i) begin
                hold_mem <= ~vdata_req & vect_pending_store & vect_pending_load;
            end
            vproc_cache #(
                .ADDR_BIT_W   ( 32                ),
                .CPU_BYTE_W   ( VMEM_W / 8        ),
                .MEM_BYTE_W   ( MEM_W / 8         ),
                .LINE_BYTE_W  ( DCACHE_LINE_W / 8 ),
                .WAY_LEN      ( DCACHE_WAY_LEN    )
            ) vcache (
                .clk_i        ( clk_i             ),
                .rst_ni       ( rst_ni            ),
                .hold_mem_i   ( hold_mem          ),
                .cpu_req_i    ( data_req          ),
                .cpu_addr_i   ( data_addr         ),
                .cpu_we_i     ( data_we           ),
                .cpu_be_i     ( data_be           ),
                .cpu_wdata_i  ( data_wdata        ),
                .cpu_gnt_o    ( data_gnt          ),
                .cpu_rvalid_o ( data_rvalid       ),
                .cpu_rdata_o  ( data_rdata        ),
                .cpu_err_o    ( data_err          ),
                .mem_req_o    ( dmem_req          ),
                .mem_we_o     ( dmem_we           ),
                .mem_addr_o   ( dmem_addr         ),
                .mem_wdata_o  ( dmem_wdata        ),
                .mem_gnt_i    ( dmem_gnt          ),
                .mem_rvalid_i ( dmem_rvalid       ),
                .mem_rdata_i  ( dmem_rdata        ),
                .mem_err_i    ( dmem_err          )
            );
            assign dmem_be = '1;
        end else begin
            if (MEM_W != VMEM_W) begin
                $fatal(1, "If no data cache is used, the memory bus width MEM_W and the vector ",
                          "memory interface width VMEM_W must be equal.  ",
                          "Currently, MEM_W == %d and VMEM_W == %d.", MEM_W, VMEM_W);
            end

            assign dmem_req    = data_req;
            assign dmem_addr   = data_addr;
            assign dmem_we     = data_we;
            assign dmem_be     = data_be;
            assign dmem_wdata  = data_wdata;
            assign data_gnt    = dmem_gnt;
            assign data_rvalid = dmem_rvalid | dmem_wvalid;
            assign data_rdata  = dmem_rdata;
            assign data_err    = dmem_err;
        end
    endgenerate



    ///////////////////////////////////////////////////////////////////////////
    // HARVARD ARCHITECTURE - 独立的指令和数据内存端口

    // 指令内存端口直接连接
    assign imem_req_o    = imem_req;
    assign imem_addr_o   = imem_addr;
    assign imem_gnt      = imem_req;  // 指令端口始终可用
    assign imem_rvalid   = imem_rvalid_i;
    assign imem_err      = imem_err_i;
    assign imem_rdata    = imem_rdata_i;

    // 数据内存端口直接连接
    assign dmem_req_o    = dmem_req;
    assign dmem_addr_o   = dmem_addr;
    assign dmem_we_o     = dmem_we;
    assign dmem_be_o     = dmem_be;
    assign dmem_wdata_o  = dmem_wdata;
    assign dmem_gnt      = dmem_req;  // 数据端口始终可用
    assign dmem_rvalid   = dmem_rvalid_i & ~dmem_we;
    assign dmem_wvalid   = dmem_rvalid_i &  dmem_we;
    assign dmem_err      = dmem_err_i;
    assign dmem_rdata    = dmem_rdata_i;


    ///////////////////////////////////////////////////////////////////////////
    // PERFORMANCE COUNTERS
    
    `ifdef VPROC_PERF_COUNTERS
    
    // 性能计数器
    logic [63:0] perf_total_cycles;
    logic [63:0] perf_scalar_instrs;           // 标量指令数
    logic [63:0] perf_vector_instrs;           // 向量指令数  
    logic [63:0] perf_matrix_instrs;           // 矩阵指令数
    logic [63:0] perf_vector_stalls;           // 向量指令停顿周期
    logic [63:0] perf_vload_instrs;            // 向量load指令数
    logic [63:0] perf_vstore_instrs;           // 向量store指令数
    logic [63:0] perf_vmem_transactions;       // 向量内存事务数
    logic [63:0] perf_vmem_stalls;             // 向量内存停顿周期
    logic [63:0] perf_icache_miss;             // I-Cache miss数
    logic [63:0] perf_dcache_miss;             // D-Cache miss数
    logic [63:0] perf_imem_wait_cycles;        // 指令内存等待周期
    logic [63:0] perf_dmem_wait_cycles;        // 数据内存等待周期
    
    // 辅助信号
    logic is_vload, is_vstore;
    logic vector_instr_issued;
    logic matrix_instr_issued;
    logic scalar_instr_retired;
    
    // 检测向量load/store指令 (通过opcode判断)
    assign is_vload  = issue_valid & issue_accept & (issue_instr[6:0] == 7'b0000111);  // VLE
    assign is_vstore = issue_valid & issue_accept & (issue_instr[6:0] == 7'b0100111);  // VSE
    
    // 向量指令发射
    assign vector_instr_issued = issue_valid & issue_accept & ~cpi_is_matrix;
    
    // 矩阵指令发射  
    assign matrix_instr_issued = cpi_is_matrix & mat_instr_gnt;
    
    // 标量指令退休 (非协处理器指令且指令有效)
    assign scalar_instr_retired = instr_rvalid & ~cpi_instr_valid;
    
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (~rst_ni) begin
            perf_total_cycles        <= '0;
            perf_scalar_instrs       <= '0;
            perf_vector_instrs       <= '0;
            perf_matrix_instrs       <= '0;
            perf_vector_stalls       <= '0;
            perf_vload_instrs        <= '0;
            perf_vstore_instrs       <= '0;
            perf_vmem_transactions   <= '0;
            perf_vmem_stalls         <= '0;
            perf_icache_miss         <= '0;
            perf_dcache_miss         <= '0;
            perf_imem_wait_cycles    <= '0;
            perf_dmem_wait_cycles    <= '0;
        end else begin
            // 总周期数
            perf_total_cycles <= perf_total_cycles + 64'd1;
            
            // 标量指令计数
            if (scalar_instr_retired)
                perf_scalar_instrs <= perf_scalar_instrs + 64'd1;
            
            // 向量指令计数
            if (vector_instr_issued)
                perf_vector_instrs <= perf_vector_instrs + 64'd1;
            
            // 矩阵指令计数
            if (matrix_instr_issued)
                perf_matrix_instrs <= perf_matrix_instrs + 64'd1;
                
            // 向量指令停顿 (向量核未准备好接收)
            if (issue_valid & ~issue_ready & ~cpi_is_matrix)
                perf_vector_stalls <= perf_vector_stalls + 64'd1;
            
            // 向量load/store指令
            if (is_vload)
                perf_vload_instrs <= perf_vload_instrs + 64'd1;
            if (is_vstore)
                perf_vstore_instrs <= perf_vstore_instrs + 64'd1;
                
            // 向量内存事务
            if (vlsu_mem_valid & vlsu_mem_ready)
                perf_vmem_transactions <= perf_vmem_transactions + 64'd1;
            
            // 向量内存停顿
            if (vlsu_mem_valid & ~vlsu_mem_ready)
                perf_vmem_stalls <= perf_vmem_stalls + 64'd1;
            
            // 指令内存等待周期 (请求发出但未响应)
            if (instr_req & ~instr_rvalid)
                perf_imem_wait_cycles <= perf_imem_wait_cycles + 64'd1;
            
            // 数据内存等待周期 (请求发出但未响应)
            if (sdata_req & ~sdata_rvalid)
                perf_dmem_wait_cycles <= perf_dmem_wait_cycles + 64'd1;
        end
    end
    
    // Cache miss统计
    // 注意：由于generate block层次问题，这里使用简化的检测方法
    // Cache miss可以通过 memory request 作为估计
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (~rst_ni) begin
            perf_icache_miss <= '0;
            perf_dcache_miss <= '0;
        end else begin
            // I-Cache miss估计: 指令内存请求 (简化版)
            if (ICACHE_SZ > 0 && imem_req)
                perf_icache_miss <= perf_icache_miss + 64'd1;
            
            // D-Cache miss估计: 数据内存请求 (简化版)
            if (DCACHE_SZ > 0 && dmem_req)
                perf_dcache_miss <= perf_dcache_miss + 64'd1;
        end
    end
    
    // 打印性能统计
    final begin
        $display("========================================");
        $display("=== PERFORMANCE ANALYSIS ===");
        $display("========================================");
        $display("Total Cycles:          %0d", perf_total_cycles);
        $display("");
        
        $display("--- Instruction Breakdown ---");
        $display("Scalar Instructions:   %0d (%.2f%%)", perf_scalar_instrs,
                 100.0 * perf_scalar_instrs / perf_total_cycles);
        $display("Vector Instructions:   %0d (%.2f%%)", perf_vector_instrs,
                 100.0 * perf_vector_instrs / perf_total_cycles);
        $display("Matrix Instructions:   %0d (%.2f%%)", perf_matrix_instrs,
                 100.0 * perf_matrix_instrs / perf_total_cycles);
        $display("  - Vector Loads:      %0d", perf_vload_instrs);
        $display("  - Vector Stores:     %0d", perf_vstore_instrs);
        $display("");
        
        $display("--- Stall Analysis ---");
        $display("Vector Stall Cycles:   %0d (%.2f%%)", perf_vector_stalls,
                 100.0 * perf_vector_stalls / perf_total_cycles);
        $display("VMem Stall Cycles:     %0d (%.2f%%)", perf_vmem_stalls,
                 100.0 * perf_vmem_stalls / perf_total_cycles);
        $display("IMem Wait Cycles:      %0d (%.2f%%)", perf_imem_wait_cycles,
                 100.0 * perf_imem_wait_cycles / perf_total_cycles);
        $display("DMem Wait Cycles:      %0d (%.2f%%)", perf_dmem_wait_cycles,
                 100.0 * perf_dmem_wait_cycles / perf_total_cycles);
        $display("");
        
        $display("--- Memory Subsystem ---");
        $display("VMem Transactions:     %0d", perf_vmem_transactions);
        if (ICACHE_SZ > 0)
            $display("I-Cache Misses:        %0d", perf_icache_miss);
        if (DCACHE_SZ > 0)
            $display("D-Cache Misses:        %0d", perf_dcache_miss);
        $display("");
        
        $display("--- Performance Metrics ---");
        if (perf_total_cycles > 0) begin
            $display("Overall IPC:           %.3f", 
                     1.0 * (perf_scalar_instrs + perf_vector_instrs + perf_matrix_instrs) / perf_total_cycles);
            $display("Vector IPC:            %.3f",
                     1.0 * perf_vector_instrs / perf_total_cycles);
        end
        $display("========================================");
    end
    
    `endif  // VPROC_PERF_COUNTERS

endmodule
