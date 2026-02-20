module vproc_core import vproc_pkg::*; #(
        parameter int unsigned           INSTR_ID_W               = 0,
        parameter int unsigned           VMEM_W                   = 0,
        parameter vreg_type              VREG_TYPE                = vproc_config::VREG_TYPE,
        parameter int unsigned           VREG_W                   = vproc_config::VREG_W,
        parameter int unsigned           VPORT_RD_CNT             = vproc_config::VPORT_RD_CNT,
        parameter int unsigned           VPORT_RD_W[VPORT_RD_CNT] = vproc_config::VPORT_RD_W,
        parameter int unsigned           VPORT_WR_CNT             = vproc_config::VPORT_WR_CNT,
        parameter int unsigned           VPORT_WR_W[VPORT_WR_CNT] = vproc_config::VPORT_WR_W,
        parameter int unsigned           PIPE_CNT                 = vproc_config::PIPE_CNT,
        parameter bit [UNIT_CNT-1:0]     PIPE_UNITS    [PIPE_CNT] = vproc_config::PIPE_UNITS,
        parameter int unsigned           PIPE_W        [PIPE_CNT] = vproc_config::PIPE_W,
        parameter int unsigned           PIPE_VPORT_CNT[PIPE_CNT] = vproc_config::PIPE_VPORT_CNT,
        parameter int unsigned           PIPE_VPORT_IDX[PIPE_CNT] = vproc_config::PIPE_VPORT_IDX,
        parameter int unsigned           PIPE_VPORT_WR [PIPE_CNT] = vproc_config::PIPE_VPORT_WR,
        parameter int unsigned           VLSU_QUEUE_SZ            = vproc_config::VLSU_QUEUE_SZ,
        parameter bit [VLSU_FLAGS_W-1:0] VLSU_FLAGS               = vproc_config::VLSU_FLAGS,
        parameter mul_type               MUL_TYPE                 = vproc_config::MUL_TYPE,
        parameter int unsigned           INSTR_QUEUE_SZ           = vproc_config::INSTR_QUEUE_SZ,
        parameter bit [BUF_FLAGS_W-1:0]  BUF_FLAGS                = vproc_config::BUF_FLAGS,
        parameter bit                    DONT_CARE_ZERO           = 1'b0,
        parameter bit                    ASYNC_RESET              = 1'b0
    )(
        input  logic                     clk_i,
        input  logic                     rst_ni,

        input  logic                     issue_valid_i,
        output logic                     issue_ready_o,
        input  logic [31:0]              issue_instr_i,
        input  logic [1:0]               issue_mode_i,
        input  logic [INSTR_ID_W-1:0]    issue_id_i,
        input  logic [31:0]              issue_rs1_i,
        input  logic [31:0]              issue_rs2_i,
        input  logic [1:0]               issue_rs_valid_i,
        output logic                     issue_accept_o,
        output logic                     issue_writeback_o,
        output logic                     issue_dualwrite_o,
        output logic [2:0]               issue_dualread_o,
        output logic                     issue_loadstore_o,
        output logic                     issue_exc_o,

        input  logic                     commit_valid_i,
        input  logic [INSTR_ID_W-1:0]    commit_id_i,
        input  logic                     commit_kill_i,

        output logic                     vlsu_mem_valid_o,
        input  logic                     vlsu_mem_ready_i,
        output logic [INSTR_ID_W-1:0]    vlsu_mem_id_o,
        output logic [31:0]              vlsu_mem_addr_o,
        output logic                     vlsu_mem_we_o,
        output logic [VMEM_W/8-1:0]      vlsu_mem_be_o,
        output logic [VMEM_W-1:0]        vlsu_mem_wdata_o,
        output logic                     vlsu_mem_last_o,
        output logic                     vlsu_mem_spec_o,
        input  logic                     vlsu_mem_resp_exc_i,
        input  logic [5:0]               vlsu_mem_resp_exccode_i,
        input  logic                     vlsu_mem_result_valid_i,
        input  logic [INSTR_ID_W-1:0]    vlsu_mem_result_id_i,
        input  logic [VMEM_W-1:0]        vlsu_mem_result_rdata_i,
        input  logic                     vlsu_mem_result_err_i,

        output logic                     result_valid_o,
        input  logic                     result_ready_i,
        output logic [INSTR_ID_W-1:0]    result_id_o,
        output logic [31:0]              result_data_o,
        output logic [4:0]               result_rd_o,
        output logic                     result_we_o,
        output logic                     result_exc_o,
        output logic [5:0]               result_exccode_o,
        output logic                     result_err_o,
        output logic                     result_dbg_o,

        output logic                     pending_load_o,
        output logic                     pending_store_o,

        output logic [31:0]              csr_vtype_o,
        output logic [31:0]              csr_vl_o,
        output logic [31:0]              csr_vlenb_o,
        input  logic [31:0]              csr_vstart_i,
        output logic [31:0]              csr_vstart_o,
        output logic                     csr_vstart_set_o,
        input  logic [1:0]               csr_vxrm_i,
        output logic [1:0]               csr_vxrm_o,
        output logic                     csr_vxrm_set_o,
        input  logic                     csr_vxsat_i,
        output logic                     csr_vxsat_o,
        output logic                     csr_vxsat_set_o,

    `ifdef RISCV_ZVE32F
        output logic                     fpr_wr_req_valid_o,
        output logic [4:0]               fpr_wr_req_addr_o,
        output logic                     fpr_res_valid_o,
        input  fpnew_pkg::roundmode_e    float_round_mode_i,
        input  logic                     fpu_res_acc_i,
        input  logic [INSTR_ID_W-1:0]    fpu_res_id_i,
    `endif

        output logic [31:0]              pend_vreg_wr_map_o
    );

    localparam int unsigned XIF_ID_W   = INSTR_ID_W;
    localparam int unsigned XIF_MEM_W  = VMEM_W;
    localparam int unsigned XIF_ID_CNT = 1 << XIF_ID_W;

    if ((VREG_W & (VREG_W - 1)) != 0 || VREG_W < 64) begin
        $fatal(1, "The vector register width VREG_W must be at least 64 and a power of two.  ",
                  "The current value of %d is invalid.", VREG_W);
    end

    generate
        for (genvar i = 0; i < VPORT_RD_CNT; i++) begin
            if ((VPORT_RD_W[i] & (VPORT_RD_W[i] - 1)) != 0 || VPORT_RD_W[i] < 32) begin
                $fatal(1, "Vector register read port %d is %d bits wide, ", i, VPORT_RD_W[i],
                          "but a power of two between 32 and %d is required.", VREG_W);
            end
        end
        for (genvar i = 0; i < VPORT_WR_CNT; i++) begin
            if ((VPORT_WR_W[i] & (VPORT_WR_W[i] - 1)) != 0 || VPORT_WR_W[i] < 32) begin
                $fatal(1, "Vector register write port %d is %d bits wide, ", i, VPORT_WR_W[i],
                          "but a power of two between 32 and %d is required.", VREG_W);
            end
        end
    endgenerate

    generate
        for (genvar i = 0; i < PIPE_CNT; i++) begin
            if (PIPE_UNITS[i][UNIT_LSU] & (PIPE_W[i] != XIF_MEM_W)) begin
                $fatal(1, "The vector pipeline containing the VLSU must have a datapath width ",
                          "equal to the memory interface width.  However, pipeline %d ", i,
                          "containing the VLSU has a width of %d bits ", PIPE_W[i],
                          "while the memory interface is %d bits wide.", XIF_MEM_W);
            end
        end
    endgenerate

    typedef int unsigned ASSIGN_VADDR_RD_W_RET_T[VPORT_RD_CNT];
    typedef int unsigned ASSIGN_VADDR_WR_W_RET_T[VPORT_WR_CNT];
    function static ASSIGN_VADDR_RD_W_RET_T ASSIGN_VADDR_RD_W();
        for (int i = 0; i < VPORT_RD_CNT; i++) begin
            ASSIGN_VADDR_RD_W[i] = 5 + $clog2(VREG_W / VPORT_RD_W[i]);
        end
    endfunction
    function static ASSIGN_VADDR_WR_W_RET_T ASSIGN_VADDR_WR_W();
        for (int i = 0; i < VPORT_WR_CNT; i++) begin
            ASSIGN_VADDR_WR_W[i] = 5 + $clog2(VREG_W / VPORT_WR_W[i]);
        end
    endfunction

    localparam int unsigned VADDR_RD_W[VPORT_RD_CNT] = ASSIGN_VADDR_RD_W();
    localparam int unsigned VADDR_WR_W[VPORT_WR_CNT] = ASSIGN_VADDR_WR_W();

    function static int unsigned MAX_VPORT_RD_SLICE(
        int unsigned SRC[VPORT_RD_CNT], int unsigned OFFSET, int unsigned CNT
    );
        MAX_VPORT_RD_SLICE = 0;
        for (int i = 0; i < CNT; i++) begin
            if (SRC[i] > MAX_VPORT_RD_SLICE) begin
                MAX_VPORT_RD_SLICE = SRC[OFFSET + i];
            end
        end
    endfunction
    function static int unsigned MAX_VPORT_WR_SLICE(
        int unsigned SRC[VPORT_WR_CNT], int unsigned OFFSET, int unsigned CNT
    );
        MAX_VPORT_WR_SLICE = 0;
        for (int i = 0; i < CNT; i++) begin
            if (SRC[OFFSET + i] > MAX_VPORT_WR_SLICE) begin
                MAX_VPORT_WR_SLICE = SRC[OFFSET + i];
            end
        end
    endfunction

    localparam int unsigned MAX_VPORT_RD_W = MAX_VPORT_RD_SLICE(VPORT_RD_W, 0, VPORT_RD_CNT);
    localparam int unsigned MAX_VADDR_RD_W = MAX_VPORT_RD_SLICE(VADDR_RD_W, 0, VPORT_RD_CNT);
    localparam int unsigned MAX_VPORT_WR_W = MAX_VPORT_WR_SLICE(VPORT_WR_W, 0, VPORT_WR_CNT);
    localparam int unsigned MAX_VADDR_WR_W = MAX_VPORT_WR_SLICE(VADDR_WR_W, 0, VPORT_WR_CNT);
    localparam int unsigned MAX_VPORT_W    = (MAX_VPORT_RD_W > MAX_VPORT_WR_W) ? MAX_VPORT_RD_W : MAX_VPORT_WR_W;
    localparam int unsigned MAX_VADDR_W    = (MAX_VADDR_RD_W > MAX_VPORT_WR_W) ? MAX_VADDR_RD_W : MAX_VADDR_WR_W;

    localparam int unsigned CFG_VL_W = $clog2(VREG_W);
    localparam int unsigned INSTR_ID_CNT = 1 << INSTR_ID_W;

    logic async_rst_n, sync_rst_n;
    assign async_rst_n = ASYNC_RESET ? rst_ni : 1'b1  ;
    assign sync_rst_n  = ASYNC_RESET ? 1'b1   : rst_ni;




    ///////////////////////////////////////////////////////////////////////////
    // CONFIGURATION STATE

    cfg_vsew             vsew_q,     vsew_d;
    cfg_lmul             lmul_q,     lmul_d;
    logic [1:0]          agnostic_q, agnostic_d;
    logic                vl_0_q,     vl_0_d;
    logic [CFG_VL_W-1:0] vl_q,       vl_d;
    logic [CFG_VL_W  :0] vl_csr_q,   vl_csr_d;
    logic [CFG_VL_W-1:0] vstart_q;
    cfg_vxrm             vxrm_q;
    logic                vxsat_q;

    always_ff @(posedge clk_i or negedge async_rst_n) begin : vproc_cfg_reg
        if (~async_rst_n) begin
            vsew_q     <= VSEW_INVALID;
            lmul_q     <= LMUL_1;
            agnostic_q <= '0;
            vl_0_q     <= 1'b0;
            vl_q       <= '0;
            vl_csr_q   <= '0;
        end
        else if (~sync_rst_n) begin
            vsew_q     <= VSEW_INVALID;
            lmul_q     <= LMUL_1;
            agnostic_q <= '0;
            vl_0_q     <= 1'b0;
            vl_q       <= '0;
            vl_csr_q   <= '0;
        end else begin
            vsew_q     <= vsew_d;
            lmul_q     <= lmul_d;
            agnostic_q <= agnostic_d;
            vl_0_q     <= vl_0_d;
            vl_q       <= vl_d;
            vl_csr_q   <= vl_csr_d;
        end
    end

    assign vstart_q = csr_vstart_i[CFG_VL_W-1:0];
    assign vxrm_q   = cfg_vxrm'(csr_vxrm_i);
    assign vxsat_q  = csr_vxsat_i;

    logic cfg_valid;
    assign cfg_valid = vsew_q != VSEW_INVALID;

    assign csr_vtype_o  = cfg_valid ? {24'b0, agnostic_q, 1'b0, vsew_q, lmul_q} : 32'h80000000;
    assign csr_vl_o     = cfg_valid ? {{(32-CFG_VL_W-1){1'b0}}, vl_csr_q} : '0;
    assign csr_vlenb_o  = 32'(VREG_W / 8);


    ///////////////////////////////////////////////////////////////////////////
    // VECTOR INSTRUCTION DECODER INTERFACE

    typedef struct packed {
        logic [INSTR_ID_W-1:0] id;
        cfg_vsew             vsew;
        cfg_emul             emul;
        cfg_vxrm             vxrm;
        logic                vl_0;
        logic [CFG_VL_W-1:0] vl;
        op_unit              unit;
        op_mode              mode;
        op_widenarrow        widenarrow;
        op_regs              rs1;
        op_regs              rs2;
        op_regd              rd;
        logic                pend_load;
        logic                pend_store;
    } decoder_data;

    logic        dec_ready,       dec_valid,       dec_clear;
    logic        dec_buf_valid_q, dec_buf_valid_d;
    decoder_data dec_data_q,      dec_data_d;
    always_ff @(posedge clk_i or negedge async_rst_n) begin : vproc_dec_buf_valid
        if (~async_rst_n) begin
            dec_buf_valid_q <= 1'b0;
        end
        else if (~sync_rst_n) begin
            dec_buf_valid_q <= 1'b0;
        end else begin
            dec_buf_valid_q <= dec_buf_valid_d;
        end
    end
    always_ff @(posedge clk_i) begin : vproc_dec_buf_data
        if (dec_ready) begin
            dec_data_q <= dec_data_d;
        end
    end
    assign dec_buf_valid_d = (~dec_ready | dec_valid) & ~dec_clear;

    logic source_xreg_valid;
    assign source_xreg_valid = (!dec_data_d.rs1.xreg | issue_rs_valid_i[0]) & (!dec_data_d.rs2.xreg | issue_rs_valid_i[1]);

    logic instr_valid, issue_id_used;
    assign instr_valid = issue_valid_i & ~issue_id_used & source_xreg_valid;

    logic dec_vl_override;

    op_unit instr_unit;
    op_mode instr_mode;
    vproc_decoder #(
        .VREG_W             ( VREG_W                              ),
        .CFG_VL_W           ( CFG_VL_W                            ),
        .XIF_MEM_W          ( XIF_MEM_W                           ),
        .ALIGNED_UNITSTRIDE ( VLSU_FLAGS[VLSU_ALIGNED_UNITSTRIDE] ),
        .DONT_CARE_ZERO     ( DONT_CARE_ZERO                      )
    ) dec (
        .instr_i            ( issue_instr_i                       ),
        .instr_valid_i      ( instr_valid                         ),
        .x_rs1_i            ( issue_rs1_i                         ),
        .x_rs2_i            ( issue_rs2_i                         ),
        .vsew_i             ( vsew_q                              ),
        .lmul_i             ( lmul_q                              ),
        .vxrm_i             ( vxrm_q                              ),
        .vl_i               ( vl_q                                ),
    `ifdef RISCV_ZVE32F
        .fpr_wr_req_valid   ( fpr_wr_req_valid_o                  ),
        .fpr_wr_req_addr_o  ( fpr_wr_req_addr_o                   ),
        .float_round_mode_i ( float_round_mode_i                  ),
    `endif
        .valid_o            ( dec_valid                           ),
        .vsew_o             ( dec_data_d.vsew                     ),
        .emul_o             ( dec_data_d.emul                     ),
        .vxrm_o             ( dec_data_d.vxrm                     ),
        .vl_o               ( dec_data_d.vl                       ),
        .unit_o             ( instr_unit                          ),
        .mode_o             ( instr_mode                          ),
        .widenarrow_o       ( dec_data_d.widenarrow               ),
        .rs1_o              ( dec_data_d.rs1                      ),
        .rs2_o              ( dec_data_d.rs2                      ),
        .rd_o               ( dec_data_d.rd                       ),
        .vl_override_o      ( dec_vl_override                     )
    );
    assign dec_data_d.id         = issue_id_i;
    assign dec_data_d.vl_0       = vl_0_q & ~dec_vl_override;
    assign dec_data_d.unit       = instr_unit;
    assign dec_data_d.mode       = instr_mode;
    assign dec_data_d.pend_load  = (instr_unit == UNIT_LSU) & ~instr_mode.lsu.store;
    assign dec_data_d.pend_store = (instr_unit == UNIT_LSU) &  instr_mode.lsu.store;

    assign issue_ready_o     = dec_ready & ~issue_id_used & source_xreg_valid;
    assign issue_accept_o    = dec_valid;
    assign issue_writeback_o = dec_valid & (((instr_unit == UNIT_ELEM) & instr_mode.elem.xreg) | (instr_unit == UNIT_CFG));
    assign issue_dualwrite_o = '0;
    assign issue_dualread_o  = '0;
    assign issue_loadstore_o = dec_valid & (instr_unit == UNIT_LSU);
    assign issue_exc_o       = dec_valid & (instr_unit == UNIT_LSU);


    ///////////////////////////////////////////////////////////////////////////
    // VECTOR INSTRUCTION COMMIT STATE

    instr_state [INSTR_ID_CNT-1:0] instr_state_q,     instr_state_d;
    logic       [INSTR_ID_CNT-1:0] instr_empty_res_q, instr_empty_res_d;
    always_ff @(posedge clk_i or negedge async_rst_n) begin : vproc_commit_buf
        if (~async_rst_n) begin
            instr_state_q    <= '{default: INSTR_INVALID};
        end
        else if (~sync_rst_n) begin
            instr_state_q    <= '{default: INSTR_INVALID};
        end else begin
            instr_state_q    <= instr_state_d;
        end
    end
    always_ff @(posedge clk_i) begin
        instr_empty_res_q <= instr_empty_res_d;
    end

    assign issue_id_used = instr_state_q[issue_id_i] != INSTR_INVALID;

    logic [PIPE_CNT-1:0]                  instr_complete_valid;
    logic [PIPE_CNT-1:0][INSTR_ID_W-1:0]  instr_complete_id;

    logic                  result_empty_valid, result_csr_valid;
    logic                                      result_csr_ready;
    logic [INSTR_ID_W-1:0] result_empty_id,    result_csr_id;
    logic [4:0]                                result_csr_addr;
    logic                                      result_csr_delayed;
    logic [31:0]                               result_csr_data;

    logic queue_ready, queue_push;
    assign queue_push = dec_buf_valid_q & (dec_data_q.unit != UNIT_CFG);

    assign dec_ready = ~dec_buf_valid_q | (queue_ready & queue_push);

    logic instr_offload;
    assign instr_offload = issue_valid_i & issue_ready_o & issue_accept_o;

    always_comb begin
        instr_state_d      = instr_state_q;
        instr_empty_res_d  = instr_empty_res_q;
        result_csr_valid   = 1'b0;
        result_csr_id      = dec_data_q.id;
        result_csr_addr    = dec_data_q.rd.addr;
        result_empty_valid = 1'b0;
        result_empty_id    = commit_id_i;
        dec_clear          = 1'b0;

        if (instr_offload) begin
            instr_state_d    [issue_id_i] = INSTR_SPECULATIVE;
            instr_empty_res_d[issue_id_i] = ~issue_writeback_o & ~issue_loadstore_o;
        end

        if (commit_valid_i & (instr_state_q[commit_id_i] != INSTR_INVALID)) begin
            result_empty_valid = instr_empty_res_q[commit_id_i];
        end

        if (commit_valid_i & (
            (instr_offload & (issue_id_i == commit_id_i)) |
            (instr_state_q[commit_id_i] != INSTR_INVALID)
        )) begin
            if (dec_buf_valid_q & (dec_data_q.unit == UNIT_CFG) & (dec_data_q.id == commit_id_i)) begin
                result_csr_valid = ~commit_kill_i;
                if (result_csr_ready | commit_kill_i) begin
                    dec_clear                    = 1'b1;
                    instr_state_d[dec_data_q.id] = INSTR_INVALID;
                end else begin
                    instr_state_d[commit_id_i] = commit_kill_i ?
                                                             INSTR_KILLED : INSTR_COMMITTED;
                end
            end else begin
                instr_state_d[commit_id_i] = commit_kill_i ?
                                                         INSTR_KILLED : INSTR_COMMITTED;
            end
        end
        if (dec_buf_valid_q & (dec_data_q.unit == UNIT_CFG) & (
            (instr_state_q[dec_data_q.id] == INSTR_COMMITTED) |
            (instr_state_q[dec_data_q.id] == INSTR_KILLED   )
        )) begin
            result_csr_valid = instr_state_q[dec_data_q.id] == INSTR_COMMITTED;
            if (result_csr_ready | (instr_state_q[dec_data_q.id] == INSTR_KILLED)) begin
                dec_clear                    = 1'b1;
                instr_state_d[dec_data_q.id] = INSTR_INVALID;
            end
        end
        for (int i = 0; i < PIPE_CNT; i++) begin
            if (instr_complete_valid[i]) begin
                instr_state_d   [instr_complete_id[i]] = INSTR_INVALID;
            end
        end
    end


    ///////////////////////////////////////////////////////////////////////////
    // VSET[I]VL[I] CONFIGURATION UPDATE LOGIC

    logic [33:0] cfg_avl;
    always_comb begin
        cfg_avl = DONT_CARE_ZERO ? '0 : 'x;
        unique case (dec_data_q.mode.cfg.vsew)
            VSEW_8:  cfg_avl = {2'b00, dec_data_q.rs1.r.xval - 1       };
            VSEW_16: cfg_avl = {1'b0 , dec_data_q.rs1.r.xval - 1, 1'b1 };
            VSEW_32: cfg_avl = {       dec_data_q.rs1.r.xval - 1, 2'b11};
            default: ;
        endcase
    end

    logic [CFG_VL_W-1:0] vstart_next;
    logic [1:0]          vxrm_next;
    logic                vxsat_next;
    logic                vstart_wr, vxrm_wr, vxsat_wr;
    always_comb begin
        vsew_d      = vsew_q;
        lmul_d      = lmul_q;
        agnostic_d  = agnostic_q;
        vl_0_d      = vl_0_q;
        vl_d        = vl_q;
        vl_csr_d    = vl_csr_q;
        vstart_next = vstart_q;
        vxrm_next   = vxrm_q;
        vxsat_next  = vxsat_q;
        vstart_wr   = 1'b0;
        vxrm_wr     = 1'b0;
        vxsat_wr    = 1'b0;

        result_csr_delayed = DONT_CARE_ZERO ? '0 : 'x;
        result_csr_data    = DONT_CARE_ZERO ? '0 : 'x;

        if (result_csr_valid) begin
            result_csr_delayed = 1'b0;
            unique case (dec_data_q.mode.cfg.csr_op)
                CFG_VTYPE_READ:   result_csr_data = csr_vtype_o;
                CFG_VL_READ:      result_csr_data = csr_vl_o;
                CFG_VLENB_READ:   result_csr_data = csr_vlenb_o;
                CFG_VSTART_WRITE,
                CFG_VSTART_SET,
                CFG_VSTART_CLEAR: result_csr_data = {{(32-CFG_VL_W){1'b0}}, vstart_q};
                CFG_VXSAT_WRITE,
                CFG_VXSAT_SET,
                CFG_VXSAT_CLEAR:  result_csr_data = {31'b0, vxsat_q};
                CFG_VXRM_WRITE,
                CFG_VXRM_SET,
                CFG_VXRM_CLEAR:   result_csr_data = {30'b0, vxrm_q};
                CFG_VCSR_WRITE,
                CFG_VCSR_SET,
                CFG_VCSR_CLEAR:   result_csr_data = {29'b0, vxrm_q, vxsat_q};
                default: ;
            endcase
            unique case (dec_data_q.mode.cfg.csr_op)
                CFG_VSTART_WRITE: begin vstart_next =  dec_data_q.rs1.r.xval[CFG_VL_W-1:0]; vstart_wr = 1'b1; end
                CFG_VSTART_SET:   begin vstart_next = vstart_q |  dec_data_q.rs1.r.xval[CFG_VL_W-1:0]; vstart_wr = 1'b1; end
                CFG_VSTART_CLEAR: begin vstart_next = vstart_q & ~dec_data_q.rs1.r.xval[CFG_VL_W-1:0]; vstart_wr = 1'b1; end
                CFG_VXSAT_WRITE:  begin vxsat_next  =  dec_data_q.rs1.r.xval[0:0]; vxsat_wr = 1'b1; end
                CFG_VXSAT_SET:    begin vxsat_next  = vxsat_q |  dec_data_q.rs1.r.xval[0:0]; vxsat_wr = 1'b1; end
                CFG_VXSAT_CLEAR:  begin vxsat_next  = vxsat_q & ~dec_data_q.rs1.r.xval[0:0]; vxsat_wr = 1'b1; end
                CFG_VXRM_WRITE:   begin vxrm_next   =  dec_data_q.rs1.r.xval[1:0]; vxrm_wr = 1'b1; end
                CFG_VXRM_SET:     begin vxrm_next   = vxrm_q |  dec_data_q.rs1.r.xval[1:0]; vxrm_wr = 1'b1; end
                CFG_VXRM_CLEAR:   begin vxrm_next   = vxrm_q & ~dec_data_q.rs1.r.xval[1:0]; vxrm_wr = 1'b1; end
                CFG_VCSR_WRITE:   begin {vxrm_next, vxsat_next} =  dec_data_q.rs1.r.xval[2:0]; vxrm_wr = 1'b1; vxsat_wr = 1'b1; end
                CFG_VCSR_SET:     begin {vxrm_next, vxsat_next} = {vxrm_q, vxsat_q} |  dec_data_q.rs1.r.xval[2:0]; vxrm_wr = 1'b1; vxsat_wr = 1'b1; end
                CFG_VCSR_CLEAR:   begin {vxrm_next, vxsat_next} = {vxrm_q, vxsat_q} & ~dec_data_q.rs1.r.xval[2:0]; vxrm_wr = 1'b1; vxsat_wr = 1'b1; end
                default: ;
            endcase
        end

        if (result_csr_valid & (dec_data_q.mode.cfg.csr_op == CFG_VSETVL)) begin
            vsew_d             = dec_data_q.mode.cfg.vsew;
            lmul_d             = dec_data_q.mode.cfg.lmul;
            agnostic_d         = dec_data_q.mode.cfg.agnostic;
            result_csr_delayed = 1'b1;
            if (dec_data_q.mode.cfg.keep_vl) begin
                vl_d = DONT_CARE_ZERO ? '0 : 'x;
                unique case ({vsew_q, dec_data_q.mode.cfg.vsew})
                    {VSEW_8 , VSEW_32}: begin
                        vl_d = {vl_q[CFG_VL_W-3:0], 2'b11};
                        unique case ({lmul_q, dec_data_q.mode.cfg.lmul})
                            {LMUL_F8, LMUL_F2},{LMUL_F4, LMUL_1},{LMUL_F2, LMUL_2},{LMUL_1, LMUL_4},{LMUL_2, LMUL_8}: ;
                            default: vsew_d = VSEW_INVALID;
                        endcase
                    end
                    {VSEW_8 , VSEW_16},{VSEW_16, VSEW_32}: begin
                        vl_d = {vl_q[CFG_VL_W-2:0], 1'b1};
                        unique case ({lmul_q, dec_data_q.mode.cfg.lmul})
                            {LMUL_F8, LMUL_F4},{LMUL_F4, LMUL_F2},{LMUL_F2, LMUL_1},{LMUL_1, LMUL_2},{LMUL_2, LMUL_4},{LMUL_4, LMUL_8}: ;
                            default: vsew_d = VSEW_INVALID;
                        endcase
                    end
                    {VSEW_8 , VSEW_8},{VSEW_16, VSEW_16},{VSEW_32, VSEW_32}: begin
                        vl_d = vl_q;
                        if (lmul_q != dec_data_q.mode.cfg.lmul) vsew_d = VSEW_INVALID;
                    end
                    {VSEW_16, VSEW_8},{VSEW_32, VSEW_16}: begin
                        vl_d = {1'b0, vl_q[CFG_VL_W-1:1]};
                        unique case ({lmul_q, dec_data_q.mode.cfg.lmul})
                            {LMUL_F4, LMUL_F8},{LMUL_F2, LMUL_F4},{LMUL_1, LMUL_F2},{LMUL_2, LMUL_1},{LMUL_4, LMUL_2},{LMUL_8, LMUL_4}: ;
                            default: vsew_d = VSEW_INVALID;
                        endcase
                    end
                    {VSEW_32, VSEW_8}: begin
                        vl_d = {2'b00, vl_q[CFG_VL_W-1:2]};
                        unique case ({lmul_q, dec_data_q.mode.cfg.lmul})
                            {LMUL_F2, LMUL_F8},{LMUL_1, LMUL_F4},{LMUL_2, LMUL_F2},{LMUL_4, LMUL_1},{LMUL_8, LMUL_2}: ;
                            default: vsew_d = VSEW_INVALID;
                        endcase
                    end
                    default: ;
                endcase
            end else begin
                vl_0_d = 1'b0;
                vl_d   = DONT_CARE_ZERO ? '0 : 'x;
                unique case (dec_data_q.mode.cfg.lmul)
                    LMUL_F4: vl_d = ((cfg_avl[33:CFG_VL_W-5] == '0) & ~dec_data_q.mode.cfg.vlmax) ? cfg_avl[CFG_VL_W-1:0] : {5'b00000, {(CFG_VL_W-5){1'b1}}};
                    LMUL_F2: vl_d = ((cfg_avl[33:CFG_VL_W-4] == '0) & ~dec_data_q.mode.cfg.vlmax) ? cfg_avl[CFG_VL_W-1:0] : {4'b0000,  {(CFG_VL_W-4){1'b1}}};
                    LMUL_1 : vl_d = ((cfg_avl[33:CFG_VL_W-3] == '0) & ~dec_data_q.mode.cfg.vlmax) ? cfg_avl[CFG_VL_W-1:0] : {3'b000,   {(CFG_VL_W-3){1'b1}}};
                    LMUL_2 : vl_d = ((cfg_avl[33:CFG_VL_W-2] == '0) & ~dec_data_q.mode.cfg.vlmax) ? cfg_avl[CFG_VL_W-1:0] : {2'b00,    {(CFG_VL_W-2){1'b1}}};
                    LMUL_4 : vl_d = ((cfg_avl[33:CFG_VL_W-1] == '0) & ~dec_data_q.mode.cfg.vlmax) ? cfg_avl[CFG_VL_W-1:0] : {1'b0,     {(CFG_VL_W-1){1'b1}}};
                    LMUL_8 : vl_d = ((cfg_avl[33:CFG_VL_W  ] == '0) & ~dec_data_q.mode.cfg.vlmax) ? cfg_avl[CFG_VL_W-1:0] :            { CFG_VL_W   {1'b1}} ;
                    default: ;
                endcase
                vl_csr_d = DONT_CARE_ZERO ? '0 : 'x;
                unique case ({dec_data_q.mode.cfg.lmul, dec_data_q.mode.cfg.vsew})
                    {LMUL_F4, VSEW_8 },{LMUL_F2, VSEW_16},{LMUL_1, VSEW_32}: vl_csr_d = ((dec_data_q.rs1.r.xval[31:CFG_VL_W-5] == '0) & ~dec_data_q.mode.cfg.vlmax) ? dec_data_q.rs1.r.xval[CFG_VL_W:0] : {6'b1, {(CFG_VL_W-5){1'b0}}};
                    {LMUL_F2, VSEW_8 },{LMUL_1, VSEW_16},{LMUL_2, VSEW_32}: vl_csr_d = ((dec_data_q.rs1.r.xval[31:CFG_VL_W-4] == '0) & ~dec_data_q.mode.cfg.vlmax) ? dec_data_q.rs1.r.xval[CFG_VL_W:0] : {5'b1, {(CFG_VL_W-4){1'b0}}};
                    {LMUL_1, VSEW_8 },{LMUL_2, VSEW_16},{LMUL_4, VSEW_32}: vl_csr_d = ((dec_data_q.rs1.r.xval[31:CFG_VL_W-3] == '0) & ~dec_data_q.mode.cfg.vlmax) ? dec_data_q.rs1.r.xval[CFG_VL_W:0] : {4'b1, {(CFG_VL_W-3){1'b0}}};
                    {LMUL_2, VSEW_8 },{LMUL_4, VSEW_16},{LMUL_8, VSEW_32}: vl_csr_d = ((dec_data_q.rs1.r.xval[31:CFG_VL_W-2] == '0) & ~dec_data_q.mode.cfg.vlmax) ? dec_data_q.rs1.r.xval[CFG_VL_W:0] : {3'b1, {(CFG_VL_W-2){1'b0}}};
                    {LMUL_4, VSEW_8 },{LMUL_8, VSEW_16}: vl_csr_d = ((dec_data_q.rs1.r.xval[31:CFG_VL_W-1] == '0) & ~dec_data_q.mode.cfg.vlmax) ? dec_data_q.rs1.r.xval[CFG_VL_W:0] : {2'b1, {(CFG_VL_W-1){1'b0}}};
                    {LMUL_8, VSEW_8 }: vl_csr_d = ((dec_data_q.rs1.r.xval[31:CFG_VL_W  ] == '0) & ~dec_data_q.mode.cfg.vlmax) ? dec_data_q.rs1.r.xval[CFG_VL_W:0] : {1'b1, {(CFG_VL_W  ){1'b0}}};
                    default: vsew_d = VSEW_INVALID;
                endcase
            end
            if ((dec_data_q.rs1.r.xval == 32'b0) & ~dec_data_q.mode.cfg.vlmax & ~dec_data_q.mode.cfg.keep_vl) begin
                vl_0_d   = 1'b1;
                vl_d     = {CFG_VL_W{1'b0}};
                vl_csr_d = '0;
            end
        end
    end

    assign csr_vstart_o     = {{(32-CFG_VL_W){1'b0}}, vstart_next};
    assign csr_vstart_set_o = vstart_wr;
    assign csr_vxrm_o       = vxrm_next;
    assign csr_vxrm_set_o   = vxrm_wr;
    assign csr_vxsat_o      = vxsat_next;
    assign csr_vxsat_set_o  = vxsat_wr;


    ///////////////////////////////////////////////////////////////////////////
    // INSTRUCTION QUEUE

    logic op_ack;
    logic        queue_valid_q,      queue_valid_d;
    decoder_data queue_data_q,       queue_data_d;
    logic [31:0] queue_pending_wr_q, queue_pending_wr_d;
    generate
        if (BUF_FLAGS[BUF_DEQUEUE]) begin
            always_ff @(posedge clk_i or negedge async_rst_n) begin : vproc_queue_valid
                if (~async_rst_n) begin
                    queue_valid_q <= 1'b0;
                end
                else if (~sync_rst_n) begin
                    queue_valid_q <= 1'b0;
                end
                else if ((~queue_valid_q) | op_ack) begin
                    queue_valid_q <= queue_valid_d;
                end
            end
            always_ff @(posedge clk_i) begin : vproc_queue_data
                if ((~queue_valid_q) | op_ack) begin
                    queue_data_q       <= queue_data_d;
                    queue_pending_wr_q <= queue_pending_wr_d;
                end
            end
        end else begin
            assign queue_valid_q      = queue_valid_d;
            assign queue_data_q       = queue_data_d;
            assign queue_pending_wr_q = queue_pending_wr_d;
        end
    endgenerate

    decoder_data queue_flags_any;
    generate
        if (INSTR_QUEUE_SZ > 0) begin
            vproc_queue #(
                .WIDTH        ( $bits(decoder_data)     ),
                .DEPTH        ( INSTR_QUEUE_SZ          )
            ) instr_queue (
                .clk_i        ( clk_i                   ),
                .async_rst_ni ( async_rst_n             ),
                .sync_rst_ni  ( sync_rst_n              ),
                .enq_ready_o  ( queue_ready             ),
                .enq_valid_i  ( queue_push              ),
                .enq_data_i   ( dec_data_q              ),
                .deq_ready_i  ( ~queue_valid_q | op_ack ),
                .deq_valid_o  ( queue_valid_d           ),
                .deq_data_o   ( queue_data_d            ),
                .flags_any_o  ( queue_flags_any         ),
                .flags_all_o  (                         )
            );
        end else begin
            assign queue_valid_d = queue_push;
            assign queue_ready   = ~queue_valid_q | op_ack;
            assign queue_data_d  = dec_data_q;
        end
    endgenerate

    vproc_pending_wr #(
        .CFG_VL_W       ( CFG_VL_W                ),
        .VREG_W         ( VREG_W                  ),
        .DONT_CARE_ZERO ( DONT_CARE_ZERO          )
    ) queue_pending_wr (
        .vsew_i         ( queue_data_d.vsew       ),
        .emul_i         ( queue_data_d.emul       ),
        .vl_i           ( queue_data_d.vl         ),
        .unit_i         ( queue_data_d.unit       ),
        .mode_i         ( queue_data_d.mode       ),
        .widenarrow_i   ( queue_data_d.widenarrow ),
        .rd_i           ( queue_data_d.rd         ),
        .pending_wr_o   ( queue_pending_wr_d      )
    );

    logic pending_load_lsu, pending_store_lsu;
    assign pending_load_o  = (dec_buf_valid_q & dec_data_q.pend_load      ) |
                                                queue_flags_any.pend_load   |
                             (queue_valid_q   & queue_data_q.pend_load    ) |
                             pending_load_lsu;
    assign pending_store_o = (dec_buf_valid_q & dec_data_q.pend_store     ) |
                                                queue_flags_any.pend_store  |
                             (queue_valid_q   & queue_data_q.pend_store   ) |
                             pending_store_lsu;


    ///////////////////////////////////////////////////////////////////////////
    // DISPATCHER

    logic [PIPE_CNT-1:0] pipe_instr_valid;
    logic [PIPE_CNT-1:0] pipe_instr_ready;
    decoder_data         pipe_instr_data;
    logic [31:0]         pend_vreg_wr_map;
    logic [31:0]         pend_vreg_wr_clr;
    vproc_dispatcher #(
        .PIPE_CNT           ( PIPE_CNT           ),
        .PIPE_UNITS         ( PIPE_UNITS         ),
        .MAX_VADDR_W        ( 5                  ),
        .DECODER_DATA_T     ( decoder_data       ),
        .DONT_CARE_ZERO     ( DONT_CARE_ZERO     )
    ) dispatcher (
        .clk_i              ( clk_i              ),
        .async_rst_ni       ( async_rst_n        ),
        .sync_rst_ni        ( sync_rst_n         ),
        .instr_valid_i      ( queue_valid_q      ),
        .instr_ready_o      ( op_ack             ),
        .instr_data_i       ( queue_data_q       ),
        .instr_vreg_wr_i    ( queue_pending_wr_q ),
        .dispatch_valid_o   ( pipe_instr_valid   ),
        .dispatch_ready_i   ( pipe_instr_ready   ),
        .dispatch_data_o    ( pipe_instr_data    ),
        .pend_vreg_wr_map_o ( pend_vreg_wr_map   ),
        .pend_vreg_wr_clr_i ( pend_vreg_wr_clr   )
    );
    assign pend_vreg_wr_map_o = pend_vreg_wr_map;


    ///////////////////////////////////////////////////////////////////////////
    // REGISTER FILE AND EXECUTION UNITS

    logic [VPORT_WR_CNT-1:0]               vregfile_wr_en_q,   vregfile_wr_en_d;
    logic [VPORT_WR_CNT-1:0][4:0]          vregfile_wr_addr_q, vregfile_wr_addr_d;
    logic [VPORT_WR_CNT-1:0][VREG_W  -1:0] vregfile_wr_data_q, vregfile_wr_data_d;
    logic [VPORT_WR_CNT-1:0][VREG_W/8-1:0] vregfile_wr_mask_q, vregfile_wr_mask_d;
    logic [VPORT_RD_CNT-1:0][4:0]          vregfile_rd_addr;
    logic [VPORT_RD_CNT-1:0][VREG_W  -1:0] vregfile_rd_data;
    vproc_vregfile #(
        .VREG_W       ( VREG_W             ),
        .MAX_PORT_W   ( MAX_VPORT_W        ),
        .MAX_ADDR_W   ( MAX_VADDR_W        ),
        .PORT_RD_CNT  ( VPORT_RD_CNT       ),
        .PORT_RD_W    ( VPORT_RD_W         ),
        .PORT_WR_CNT  ( VPORT_WR_CNT       ),
        .PORT_WR_W    ( VPORT_WR_W         ),
        .VREG_TYPE    ( VREG_TYPE          )
    ) vregfile (
        .clk_i        ( clk_i              ),
        .async_rst_ni ( async_rst_n        ),
        .sync_rst_ni  ( sync_rst_n         ),
        .wr_addr_i    ( vregfile_wr_addr_q ),
        .wr_data_i    ( vregfile_wr_data_q ),
        .wr_be_i      ( vregfile_wr_mask_q ),
        .wr_we_i      ( vregfile_wr_en_q   ),
        .rd_addr_i    ( vregfile_rd_addr   ),
        .rd_data_o    ( vregfile_rd_data   )
    );

    logic [VREG_W-1:0] vreg_mask;
    assign vreg_mask           = vregfile_rd_data[0];
    assign vregfile_rd_addr[0] = 5'b0;

    generate
        if (BUF_FLAGS[BUF_VREG_WR]) begin
            always_ff @(posedge clk_i) begin
                for (int i = 0; i < VPORT_WR_CNT; i++) begin
                    vregfile_wr_en_q  [i] <= vregfile_wr_en_d  [i];
                    vregfile_wr_addr_q[i] <= vregfile_wr_addr_d[i];
                    vregfile_wr_data_q[i] <= vregfile_wr_data_d[i];
                    vregfile_wr_mask_q[i] <= vregfile_wr_mask_d[i];
                end
            end
        end else begin
            always_comb begin
                for (int i = 0; i < VPORT_WR_CNT; i++) begin
                    vregfile_wr_en_q  [i] = vregfile_wr_en_d  [i];
                    vregfile_wr_addr_q[i] = vregfile_wr_addr_d[i];
                    vregfile_wr_data_q[i] = vregfile_wr_data_d[i];
                    vregfile_wr_mask_q[i] = vregfile_wr_mask_d[i];
                end
            end
        end
    endgenerate

    logic [PIPE_CNT-1:0][31:0] pipe_vreg_pend_rd_by_q, pipe_vreg_pend_rd_by_d;
    logic [PIPE_CNT-1:0][31:0] pipe_vreg_pend_rd_to_q, pipe_vreg_pend_rd_to_d;
    generate
        if (BUF_FLAGS[BUF_VREG_PEND]) begin
            always_ff @(posedge clk_i) begin
                pipe_vreg_pend_rd_by_q <= pipe_vreg_pend_rd_by_d;
                pipe_vreg_pend_rd_to_q <= pipe_vreg_pend_rd_to_d;
            end
        end else begin
            assign pipe_vreg_pend_rd_by_q = pipe_vreg_pend_rd_by_d;
            assign pipe_vreg_pend_rd_to_q = pipe_vreg_pend_rd_to_d;
        end
    endgenerate
    logic [PIPE_CNT-1:0][31:0] pipe_vreg_pend_rd_in, pipe_vreg_pend_rd_out;
    always_comb begin
        pipe_vreg_pend_rd_in   = pipe_vreg_pend_rd_to_q;
        pipe_vreg_pend_rd_by_d = pipe_vreg_pend_rd_out;
        pipe_vreg_pend_rd_to_d = '0;
        for (int i = 0; i < PIPE_CNT; i++) begin
            for (int j = 0; j < PIPE_CNT; j++) begin
                if (i != j) begin
                    pipe_vreg_pend_rd_to_d[i] |= pipe_vreg_pend_rd_by_q[j];
                end
            end
        end
    end

    logic [PIPE_CNT-1:0]               pipe_vreg_wr_valid;
    logic [PIPE_CNT-1:0]               pipe_vreg_wr_ready;
    logic [PIPE_CNT-1:0][4:0]          pipe_vreg_wr_addr;
    logic [PIPE_CNT-1:0][VREG_W  -1:0] pipe_vreg_wr_data;
    logic [PIPE_CNT-1:0][VREG_W/8-1:0] pipe_vreg_wr_be;
    logic [PIPE_CNT-1:0]               pipe_vreg_wr_clr;
    logic [PIPE_CNT-1:0][1:0]          pipe_vreg_wr_clr_cnt;

    logic                    lsu_trans_complete_valid;
    logic                    lsu_trans_complete_ready;
    logic [INSTR_ID_W-1:0]   lsu_trans_complete_id;
    logic                    lsu_trans_complete_exc;
    logic [5:0]              lsu_trans_complete_exccode;

    logic                    elem_xreg_valid;
    logic                    elem_xreg_ready;
    logic [INSTR_ID_W-1:0]   elem_xreg_id;
    logic [4:0]              elem_xreg_addr;
    logic [31:0]             elem_xreg_data;

`ifdef RISCV_ZVE32F
    logic                    elem_freg;
`endif

    generate
        for (genvar i = 0; i < PIPE_CNT; i++) begin
`ifndef VERILATOR
            localparam int unsigned PIPE_VPORT_W[PIPE_VPORT_CNT[i]]  = VPORT_RD_W[PIPE_VPORT_IDX[i] +: PIPE_VPORT_CNT[i]];
            localparam int unsigned PIPE_VADDR_W[PIPE_VPORT_CNT[i]]  = VADDR_RD_W[PIPE_VPORT_IDX[i] +: PIPE_VPORT_CNT[i]];
`endif
            localparam int unsigned PIPE_MAX_VPORT_W = MAX_VPORT_RD_SLICE(VPORT_RD_W, PIPE_VPORT_IDX[i], PIPE_VPORT_CNT[i]);
            localparam int unsigned PIPE_MAX_VADDR_W = MAX_VPORT_RD_SLICE(VADDR_RD_W, PIPE_VPORT_IDX[i], PIPE_VPORT_CNT[i]);

            localparam bit [PIPE_VPORT_CNT[i]-1:0] PIPE_VPORT_BUFFER = {{(PIPE_VPORT_CNT[i]-1){1'b0}}, 1'b1};

            logic [PIPE_VPORT_CNT[i]-1:0][4       :0] vreg_rd_addr;
            logic [PIPE_VPORT_CNT[i]-1:0][VREG_W-1:0] vreg_rd_data;
            always_comb begin
                vregfile_rd_addr[PIPE_VPORT_IDX[i]+PIPE_VPORT_CNT[i]-1:PIPE_VPORT_IDX[i]] = vreg_rd_addr[PIPE_VPORT_CNT[i]-1:0];
                for (int j = 0; j < PIPE_VPORT_CNT[i]; j++) begin
                    vreg_rd_data[j] = vregfile_rd_data[PIPE_VPORT_IDX[i] + j];
                end
            end

            logic                    pending_load, pending_store;
            logic                    trans_complete_valid;
            logic                    trans_complete_ready;
            logic [INSTR_ID_W-1:0]   trans_complete_id;
            logic                    trans_complete_exc;
            logic [5:0]              trans_complete_exccode;

            logic                    pipe_vlsu_mem_valid;
            logic                    pipe_vlsu_mem_ready;
            logic [INSTR_ID_W-1:0]   pipe_vlsu_mem_id;
            logic [31:0]             pipe_vlsu_mem_addr;
            logic                    pipe_vlsu_mem_we;
            logic [VMEM_W/8-1:0]     pipe_vlsu_mem_be;
            logic [VMEM_W-1:0]       pipe_vlsu_mem_wdata;
            logic                    pipe_vlsu_mem_last;
            logic                    pipe_vlsu_mem_spec;
            logic                    pipe_vlsu_mem_resp_exc;
            logic [5:0]              pipe_vlsu_mem_resp_exccode;
            logic                    pipe_vlsu_mem_result_valid;
            logic [INSTR_ID_W-1:0]   pipe_vlsu_mem_result_id;
            logic [VMEM_W-1:0]       pipe_vlsu_mem_result_rdata;
            logic                    pipe_vlsu_mem_result_err;

            logic                    xreg_valid;
            logic                    xreg_ready;
            logic [INSTR_ID_W-1:0]   xreg_id;
            logic [4:0]              xreg_addr;
            logic [31:0]             xreg_data;
        `ifdef RISCV_ZVE32F
            logic freg_res;
        `endif

            vproc_pipeline_wrapper #(
                .VREG_W                   ( VREG_W                     ),
                .CFG_VL_W                 ( CFG_VL_W                   ),
                .XIF_ID_W                 ( XIF_ID_W                   ),
                .XIF_ID_CNT               ( XIF_ID_CNT                 ),
                .UNITS                    ( PIPE_UNITS[i]              ),
                .MAX_VPORT_W              ( PIPE_MAX_VPORT_W           ),
                .MAX_VADDR_W              ( PIPE_MAX_VADDR_W           ),
                .VPORT_CNT                ( PIPE_VPORT_CNT[i]          ),
`ifdef VERILATOR
                .VPORT_OFFSET             ( PIPE_VPORT_IDX[i]          ),
                .VREGFILE_VPORT_CNT       ( VPORT_RD_CNT               ),
                .VREGFILE_VPORT_W         ( VPORT_RD_W                 ),
                .VREGFILE_VADDR_W         ( VADDR_RD_W                 ),
`else
                .VPORT_W                  ( PIPE_VPORT_W               ),
                .VADDR_W                  ( PIPE_VADDR_W               ),
`endif
                .VPORT_BUFFER             ( PIPE_VPORT_BUFFER          ),
                .VPORT_V0                 ( 1'b1                       ),
                .MAX_OP_W                 ( PIPE_W[i]                  ),
                .VLSU_QUEUE_SZ            ( VLSU_QUEUE_SZ              ),
                .VLSU_FLAGS               ( VLSU_FLAGS                 ),
                .MUL_TYPE                 ( MUL_TYPE                   ),
                .DECODER_DATA_T           ( decoder_data               ),
                .DONT_CARE_ZERO           ( DONT_CARE_ZERO             )
            ) pipe (
                .clk_i                    ( clk_i                      ),
                .async_rst_ni             ( async_rst_n                ),
                .sync_rst_ni              ( sync_rst_n                 ),
                .pipe_in_valid_i          ( pipe_instr_valid[i]        ),
                .pipe_in_ready_o          ( pipe_instr_ready[i]        ),
                .pipe_in_data_i           ( pipe_instr_data            ),
                .vreg_pend_wr_i           ( pend_vreg_wr_map           ),
                .vreg_pend_rd_o           ( pipe_vreg_pend_rd_out[i]   ),
                .vreg_pend_rd_i           ( pipe_vreg_pend_rd_in [i]   ),
                .instr_state_i            ( instr_state_q              ),
                .instr_done_valid_o       ( instr_complete_valid[i]    ),
                .instr_done_id_o          ( instr_complete_id   [i]    ),
                .vreg_rd_addr_o           ( vreg_rd_addr               ),
                .vreg_rd_data_i           ( vreg_rd_data               ),
                .vreg_rd_v0_i             ( vreg_mask                  ),
                .vreg_wr_valid_o          ( pipe_vreg_wr_valid  [i]    ),
                .vreg_wr_ready_i          ( pipe_vreg_wr_ready  [i]    ),
                .vreg_wr_addr_o           ( pipe_vreg_wr_addr   [i]    ),
                .vreg_wr_be_o             ( pipe_vreg_wr_be     [i]    ),
                .vreg_wr_data_o           ( pipe_vreg_wr_data   [i]    ),
                .vreg_wr_clr_o            ( pipe_vreg_wr_clr    [i]    ),
                .vreg_wr_clr_cnt_o        ( pipe_vreg_wr_clr_cnt[i]    ),
                .pending_load_o           ( pending_load               ),
                .pending_store_o          ( pending_store              ),
                .vlsu_mem_valid_o         ( pipe_vlsu_mem_valid        ),
                .vlsu_mem_ready_i         ( pipe_vlsu_mem_ready        ),
                .vlsu_mem_id_o            ( pipe_vlsu_mem_id           ),
                .vlsu_mem_addr_o          ( pipe_vlsu_mem_addr         ),
                .vlsu_mem_we_o            ( pipe_vlsu_mem_we           ),
                .vlsu_mem_be_o            ( pipe_vlsu_mem_be           ),
                .vlsu_mem_wdata_o         ( pipe_vlsu_mem_wdata        ),
                .vlsu_mem_last_o          ( pipe_vlsu_mem_last         ),
                .vlsu_mem_spec_o          ( pipe_vlsu_mem_spec         ),
                .vlsu_mem_resp_exc_i      ( pipe_vlsu_mem_resp_exc     ),
                .vlsu_mem_resp_exccode_i  ( pipe_vlsu_mem_resp_exccode ),
                .vlsu_mem_result_valid_i  ( pipe_vlsu_mem_result_valid ),
                .vlsu_mem_result_id_i     ( pipe_vlsu_mem_result_id    ),
                .vlsu_mem_result_rdata_i  ( pipe_vlsu_mem_result_rdata ),
                .vlsu_mem_result_err_i    ( pipe_vlsu_mem_result_err   ),
                .trans_complete_valid_o   ( trans_complete_valid       ),
                .trans_complete_ready_i   ( trans_complete_ready       ),
                .trans_complete_id_o      ( trans_complete_id          ),
                .trans_complete_exc_o     ( trans_complete_exc         ),
                .trans_complete_exccode_o ( trans_complete_exccode     ),
            `ifdef RISCV_ZVE32F
                .freg_res                 ( freg_res                   ),
            `endif
                .xreg_valid_o             ( xreg_valid                 ),
                .xreg_ready_i             ( xreg_ready                 ),
                .xreg_id_o                ( xreg_id                    ),
                .xreg_addr_o              ( xreg_addr                  ),
                .xreg_data_o              ( xreg_data                  )
            );

            if (PIPE_UNITS[i][UNIT_LSU]) begin
                assign pending_load_lsu          = pending_load;
                assign pending_store_lsu         = pending_store;
                assign vlsu_mem_valid_o          = pipe_vlsu_mem_valid;
                assign pipe_vlsu_mem_ready        = vlsu_mem_ready_i;
                assign vlsu_mem_id_o              = pipe_vlsu_mem_id;
                assign vlsu_mem_addr_o            = pipe_vlsu_mem_addr;
                assign vlsu_mem_we_o              = pipe_vlsu_mem_we;
                assign vlsu_mem_be_o              = pipe_vlsu_mem_be;
                assign vlsu_mem_wdata_o           = pipe_vlsu_mem_wdata;
                assign vlsu_mem_last_o            = pipe_vlsu_mem_last;
                assign vlsu_mem_spec_o            = pipe_vlsu_mem_spec;
                assign pipe_vlsu_mem_resp_exc     = vlsu_mem_resp_exc_i;
                assign pipe_vlsu_mem_resp_exccode = vlsu_mem_resp_exccode_i;
                assign pipe_vlsu_mem_result_valid = vlsu_mem_result_valid_i;
                assign pipe_vlsu_mem_result_id    = vlsu_mem_result_id_i;
                assign pipe_vlsu_mem_result_rdata = vlsu_mem_result_rdata_i;
                assign pipe_vlsu_mem_result_err   = vlsu_mem_result_err_i;
                assign lsu_trans_complete_valid   = trans_complete_valid;
                assign trans_complete_ready       = lsu_trans_complete_ready;
                assign lsu_trans_complete_id      = trans_complete_id;
                assign lsu_trans_complete_exc     = trans_complete_exc;
                assign lsu_trans_complete_exccode = trans_complete_exccode;
            end
            if (PIPE_UNITS[i][UNIT_ELEM]) begin
                assign elem_xreg_valid = xreg_valid;
                assign xreg_ready      = elem_xreg_ready;
                assign elem_xreg_id    = xreg_id;
                assign elem_xreg_addr  = xreg_addr;
                assign elem_xreg_data  = xreg_data;
            `ifdef RISCV_ZVE32F
                assign elem_freg = freg_res;
            `endif
            end

        end
    endgenerate

    vproc_vreg_wr_mux #(
        .VREG_W             ( VREG_W                              ),
        .VPORT_WR_CNT       ( VPORT_WR_CNT                        ),
        .PIPE_CNT           ( PIPE_CNT                            ),
        .PIPE_UNITS         ( PIPE_UNITS                          ),
        .PIPE_VPORT_WR      ( PIPE_VPORT_WR                       ),
        .TIMEPRED           ( BUF_FLAGS[BUF_VREG_WR_MUX_TIMEPRED] ),
        .DONT_CARE_ZERO     ( DONT_CARE_ZERO                      )
    ) vreg_wr_mux (
        .clk_i              ( clk_i                               ),
        .async_rst_ni       ( async_rst_n                         ),
        .sync_rst_ni        ( sync_rst_n                          ),
        .vreg_wr_valid_i    ( pipe_vreg_wr_valid                  ),
        .vreg_wr_ready_o    ( pipe_vreg_wr_ready                  ),
        .vreg_wr_addr_i     ( pipe_vreg_wr_addr                   ),
        .vreg_wr_be_i       ( pipe_vreg_wr_be                     ),
        .vreg_wr_data_i     ( pipe_vreg_wr_data                   ),
        .vreg_wr_clr_i      ( pipe_vreg_wr_clr                    ),
        .vreg_wr_clr_cnt_i  ( pipe_vreg_wr_clr_cnt                ),
        .pend_vreg_wr_clr_o ( pend_vreg_wr_clr                    ),
        .vregfile_wr_en_o   ( vregfile_wr_en_d                    ),
        .vregfile_wr_addr_o ( vregfile_wr_addr_d                  ),
        .vregfile_wr_be_o   ( vregfile_wr_mask_d                  ),
        .vregfile_wr_data_o ( vregfile_wr_data_d                  )
    );


    ///////////////////////////////////////////////////////////////////////////
    // RESULT INTERFACE

    vproc_result #(
        .XIF_ID_W                  ( XIF_ID_W                   ),
        .DONT_CARE_ZERO            ( DONT_CARE_ZERO             )
    ) result_if (
        .clk_i                     ( clk_i                      ),
        .async_rst_ni              ( async_rst_n                ),
        .sync_rst_ni               ( sync_rst_n                 ),
        .result_empty_valid_i      ( result_empty_valid         ),
        .result_empty_id_i         ( result_empty_id            ),
        .result_lsu_valid_i        ( lsu_trans_complete_valid   ),
        .result_lsu_ready_o        ( lsu_trans_complete_ready   ),
        .result_lsu_id_i           ( lsu_trans_complete_id      ),
        .result_lsu_exc_i          ( lsu_trans_complete_exc     ),
        .result_lsu_exccode_i      ( lsu_trans_complete_exccode ),
        .result_xreg_valid_i       ( elem_xreg_valid            ),
        .result_xreg_ready_o       ( elem_xreg_ready            ),
        .result_xreg_id_i          ( elem_xreg_id               ),
        .result_xreg_addr_i        ( elem_xreg_addr             ),
        .result_xreg_data_i        ( elem_xreg_data             ),
    `ifdef RISCV_ZVE32F
        .result_freg_i             ( elem_freg                  ),
        .result_freg_o             ( fpr_res_valid_o            ),
        .fpu_res_acc               ( fpu_res_acc_i              ),
        .fpu_res_id                ( fpu_res_id_i               ),
    `endif
        .result_csr_valid_i        ( result_csr_valid           ),
        .result_csr_ready_o        ( result_csr_ready           ),
        .result_csr_id_i           ( result_csr_id              ),
        .result_csr_addr_i         ( result_csr_addr            ),
        .result_csr_delayed_i      ( result_csr_delayed         ),
        .result_csr_data_i         ( result_csr_data            ),
        .result_csr_data_delayed_i ( csr_vl_o                   ),
        .commit_valid_i            ( commit_valid_i             ),
        .commit_id_i               ( commit_id_i                ),
        .commit_kill_i             ( commit_kill_i              ),
        .result_valid_o            ( result_valid_o             ),
        .result_ready_i            ( result_ready_i             ),
        .result_id_o               ( result_id_o                ),
        .result_data_o             ( result_data_o              ),
        .result_rd_o               ( result_rd_o                ),
        .result_we_o               ( result_we_o                ),
        .result_exc_o              ( result_exc_o               ),
        .result_exccode_o          ( result_exccode_o           ),
        .result_err_o              ( result_err_o               ),
        .result_dbg_o              ( result_dbg_o               )
    );

endmodule
