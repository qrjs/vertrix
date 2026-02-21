// Copyright 2024 TU Munich
// Licensed under the Solderpad Hardware License v2.1, see LICENSE.txt for details
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1


module vproc_fpu #(
        parameter int unsigned        FPU_OP_W       = 64,   // DIV unit operand width in bits.  Operates on 32 bit wide operands (SEW8 and SEW16 should be extended in regunpack)
        parameter type                CTRL_T         = logic,
        `ifdef RISCV_ZVFH
        parameter fpnew_pkg::fpu_features_t       FPU_FEATURES       = vproc_pkg::RV32ZVFH,           //TODO:Need to pass these all the way to the top level for easy adjustments
        `else
        parameter fpnew_pkg::fpu_features_t       FPU_FEATURES       = fpnew_pkg::RV32F,           //TODO:Need to pass these all the way to the top level for easy adjustments
        `endif
        
        `ifdef RISCV_ZVFH
        parameter fpnew_pkg::fpu_implementation_t FPU_IMPLEMENTATION = vproc_pkg::ZVFH_NOREGS
        `else
        parameter fpnew_pkg::fpu_implementation_t FPU_IMPLEMENTATION = fpnew_pkg::DEFAULT_NOREGS
        `endif
            )(
        input  logic                  clk_i,
        input  logic                  async_rst_ni,
        input  logic                  sync_rst_ni,

        input  logic                  pipe_in_valid_i,
        output logic                  pipe_in_ready_o,
        input  CTRL_T                 pipe_in_ctrl_i,
        input  logic [FPU_OP_W  -1:0] pipe_in_op1_i,
        input  logic [FPU_OP_W  -1:0] pipe_in_op2_i,
        input  logic [FPU_OP_W  -1:0] pipe_in_op3_i,
        input  logic [FPU_OP_W/8-1:0] pipe_in_mask_i,

        output logic                  pipe_out_valid_o,
        input  logic                  pipe_out_ready_i,
        output CTRL_T                 pipe_out_ctrl_o,
        output logic [FPU_OP_W  -1:0] pipe_out_res_o,
        output logic [FPU_OP_W/8-1:0] pipe_out_mask_o


    );

    import vproc_pkg::*;
    import fpnew_pkg::*;

    //Struct for tag data to pass through FPU
    typedef struct packed {
        CTRL_T     ctrl;
        logic      last_cycle;
    } fpu_tag; 

    ///////////////////////////////////////////////////////////////////////////
    //Input buffer defines
    ///////////////////////////////////////////////////////////////////////////

    logic [FPU_OP_W  -1:0] pipe_in_op1_i_d, pipe_in_op2_i_d, pipe_in_op3_i_d;
    logic [FPU_OP_W  -1:0] pipe_in_op1_i_q, pipe_in_op2_i_q, pipe_in_op3_i_q;
    CTRL_T                unit_ctrl_d, unit_ctrl_q;

    logic                 data_valid_i_d, data_valid_i_q;

    ///////////////////////////////////////////////////////////////////////////
    //Control logic for Reductions Ops Defines
    ///////////////////////////////////////////////////////////////////////////

    //store the intermediate result of the reduction operation here
    logic [31:0] reduction_buffer_d, reduction_buffer_q;

    logic last_cycle;


    ///////////////////////////////////////////////////////////////////////////
    // FPU ARITHMETIC defines
    // Each FPU unit handles one 32 bit result.
    // Signals for connections to the FPU
    ///////////////////////////////////////////////////////////////////////////
    logic [FPU_OP_W/ 32 - 1:0] pipe_in_ready_fpu;
    logic [FPU_OP_W/ 32 - 1:0] pipe_out_valid_fpu;

    // Forward declarations for vfrsqrt7 state machine (defined below)
    logic rsqrt_active;
    logic all_rsqrt_lanes_valid;
    logic rsqrt_div_valid;

    fpu_tag unit_in_fpu_tag;
    assign unit_in_fpu_tag.ctrl = unit_ctrl_q;
    assign unit_in_fpu_tag.last_cycle = last_cycle;

    fpu_tag [FPU_OP_W/ 32 - 1:0] unit_out_fpu_tag;


    logic [FPU_OP_W  -1:0] operand_0_fpu, operand_1_fpu, operand_2_fpu;

    // Per-lane active mask derived from input-side VL (fixes vl>1 deadlock)
    logic [FPU_OP_W/8-1:0]  fpu_in_vl_mask;
    logic [FPU_OP_W/32-1:0] fpu_active_lanes;
    logic                    all_active_lanes_valid;



    ///////////////////////////////////////////////////////////////////////////
    //Input Connections - Connect to buffers
    ///////////////////////////////////////////////////////////////////////////
    always_comb begin                                                
            unit_ctrl_d     = pipe_in_ctrl_i;
            data_valid_i_d  = pipe_in_valid_i;
            pipe_in_op1_i_d = pipe_in_op1_i;
            pipe_in_op2_i_d = pipe_in_op2_i;
            pipe_in_op3_i_d = pipe_in_op3_i;

    end


    ///////////////////////////////////////////////////////////////////////////
    //Output Connections
    ///////////////////////////////////////////////////////////////////////////

    always_comb begin
        if (rsqrt_active) begin
            pipe_in_ready_o  = 1'b0;  // block upstream during 2-phase rsqrt
            pipe_out_valid_o = (rsqrt_state_q == RSQRT_DIV_WAIT) & all_rsqrt_lanes_valid;
            pipe_out_ctrl_o  = rsqrt_tag_q.ctrl;
        end else if (|fpu_active_lanes) begin
            // Normal path: at least one FPU lane is active
            pipe_in_ready_o  = &(pipe_in_ready_fpu | ~fpu_active_lanes);
            pipe_out_valid_o = all_active_lanes_valid & (~unit_out_fpu_tag[0].ctrl.mode.fpu.op_reduction | unit_out_fpu_tag[0].last_cycle);
            pipe_out_ctrl_o  = unit_out_fpu_tag[0].ctrl;
        end else begin
            // No FPU lanes active (VL < VLMAX inactive beat): pass through
            // immediately with correct metadata from input register, not stale fpnew tags
            pipe_in_ready_o  = 1'b1;
            pipe_out_valid_o = data_valid_i_q;
            pipe_out_ctrl_o  = unit_ctrl_q;
            pipe_out_ctrl_o.last_cycle = last_cycle;
        end
        reduction_buffer_d = pipe_out_res_o[31:0];
    end

    ///////////////////////////////////////////////////////////////////////////
    //Determine the input and output formats and vectorial operation based on SEW
    ///////////////////////////////////////////////////////////////////////////

    fp_format_e src_fmt, dst_fmt;
    int_format_e int_fmt;

    logic vectorial_op;
    always_comb begin
        unique case ({unit_ctrl_q.eew, unit_ctrl_q.mode.fpu.src_1_narrow, unit_ctrl_q.mode.fpu.src_2_narrow})
            //Single Width SEW32
            {VSEW_32, 1'b0, 1'b0} : begin
                src_fmt = FP32;
                dst_fmt = FP32;
                int_fmt = INT32;
                vectorial_op = 0;
            end
            //Single Width SEW16
            {VSEW_16, 1'b0, 1'b0} : begin
                src_fmt = FP16;
                dst_fmt = FP16;
                int_fmt = INT16;
                vectorial_op = 1;
            end
            //Widening From SEW16
            {VSEW_32, 1'b1, 1'b1} : begin
                src_fmt = FP16;
                dst_fmt = FP32;
                int_fmt = INT32;
                vectorial_op = 0;
            end

            default : begin
                src_fmt = FP32;
                dst_fmt = FP32;
                int_fmt = INT32;
                vectorial_op = 0;
            end
        endcase

    end

    ///////////////////////////////////////////////////////////////////////////
    //Input buffers
    ///////////////////////////////////////////////////////////////////////////

    always_ff @(posedge clk_i) begin

        pipe_in_op1_i_q <= pipe_in_op1_i_d;
        pipe_in_op2_i_q <= pipe_in_op2_i_d;
        pipe_in_op3_i_q <= pipe_in_op3_i_d;
        unit_ctrl_q <= unit_ctrl_d;
        data_valid_i_q <= data_valid_i_d;
        reduction_buffer_q <= reduction_buffer_d;
            
    end

    ///////////////////////////////////////////////////////////////////////////
    //Control logic for Reductions Ops
    ///////////////////////////////////////////////////////////////////////////
    always_comb begin
        last_cycle = 0;
        if ((unit_ctrl_q.last_cycle) | (unit_ctrl_q.last_vl_part & unit_ctrl_d.vl_part_0)) begin
            last_cycle = 1'b1;
        end else begin
            last_cycle = 1'b0;
        end
        
    end

    ///////////////////////////////////////////////////////////////////////////
    // Mask out generation
    ///////////////////////////////////////////////////////////////////////////

    // result byte mask
    logic [FPU_OP_W/8-1:0] vl_mask;

    assign vl_mask        = ~pipe_out_ctrl_o.vl_part_0 ? ({(FPU_OP_W/8){1'b1}} >> (~pipe_out_ctrl_o.vl_part)) : '0;
    assign pipe_out_mask_o = (pipe_out_ctrl_o.mode.fpu.masked ? pipe_in_mask_i : {(FPU_OP_W/8){1'b1}}) & vl_mask; //TODO: may need to buffer or pass the input operand mask as metadata for masked operations

    ///////////////////////////////////////////////////////////////////////////
    // Per-lane active mask from input VL (fixes deadlock when VL < pipeline width)
    ///////////////////////////////////////////////////////////////////////////

    assign fpu_in_vl_mask = ~unit_ctrl_q.vl_part_0 ?
        ({(FPU_OP_W/8){1'b1}} >> (~unit_ctrl_q.vl_part)) : '0;

    generate
        for (genvar gl = 0; gl < FPU_OP_W / 32; gl++) begin : gen_active_lanes
            assign fpu_active_lanes[gl] = |fpu_in_vl_mask[4*gl +: 4];
        end
    endgenerate

    // All active lanes have produced valid output
    assign all_active_lanes_valid = &(pipe_out_valid_fpu | ~fpu_active_lanes);

    ///////////////////////////////////////////////////////////////////////////
    // vfrsqrt7 two-phase state machine: SQRT(vs2) then DIV(1.0, sqrt_result)
    ///////////////////////////////////////////////////////////////////////////
    typedef enum logic [1:0] {
        RSQRT_IDLE,
        RSQRT_SQRT_WAIT,
        RSQRT_DIV_PEND,
        RSQRT_DIV_WAIT
    } rsqrt_state_e;

    rsqrt_state_e rsqrt_state_d, rsqrt_state_q;
    logic [FPU_OP_W-1:0]    rsqrt_buffer_d, rsqrt_buffer_q;
    fpu_tag                  rsqrt_tag_d, rsqrt_tag_q;
    logic [FPU_OP_W/32-1:0] rsqrt_active_lanes_d, rsqrt_active_lanes_q;

    assign rsqrt_active = (rsqrt_state_q != RSQRT_IDLE);
    assign all_rsqrt_lanes_valid = &(pipe_out_valid_fpu | ~rsqrt_active_lanes_q);

    logic rsqrt_div_accepted;
    assign rsqrt_div_accepted = &(pipe_in_ready_fpu | ~rsqrt_active_lanes_q);

    // Compute out_ready for fpnew: use saved active lanes during rsqrt,
    // and add back-pressure from downstream during the final DIV phase.
    logic fpu_out_ready;
    always_comb begin
        unique case (rsqrt_state_q)
            RSQRT_DIV_WAIT:  fpu_out_ready = all_rsqrt_lanes_valid & pipe_out_ready_i;
            RSQRT_SQRT_WAIT,
            RSQRT_DIV_PEND:  fpu_out_ready = all_rsqrt_lanes_valid;
            default:         fpu_out_ready = all_active_lanes_valid;
        endcase
    end

    always_comb begin
        rsqrt_state_d        = rsqrt_state_q;
        rsqrt_buffer_d       = rsqrt_buffer_q;
        rsqrt_tag_d          = rsqrt_tag_q;
        rsqrt_active_lanes_d = rsqrt_active_lanes_q;
        rsqrt_div_valid      = 1'b0;

        unique case (rsqrt_state_q)
            RSQRT_IDLE: begin
                if (data_valid_i_q
                    & (unit_ctrl_q.mode.fpu.op == SQRT)
                    & (unit_ctrl_q.mode.fpu.op_mod == 1'b1)) begin
                    rsqrt_state_d        = RSQRT_SQRT_WAIT;
                    rsqrt_tag_d          = unit_in_fpu_tag;
                    rsqrt_active_lanes_d = fpu_active_lanes;
                end
            end
            RSQRT_SQRT_WAIT: begin
                if (all_rsqrt_lanes_valid) begin
                    rsqrt_buffer_d = pipe_out_res_o;
                    rsqrt_state_d  = RSQRT_DIV_PEND;
                end
            end
            RSQRT_DIV_PEND: begin
                rsqrt_div_valid = 1'b1;
                if (rsqrt_div_accepted) begin
                    rsqrt_state_d = RSQRT_DIV_WAIT;
                end
            end
            RSQRT_DIV_WAIT: begin
                if (all_rsqrt_lanes_valid & pipe_out_ready_i) begin
                    rsqrt_state_d = RSQRT_IDLE;
                end
            end
        endcase
    end

    always_ff @(posedge clk_i or negedge async_rst_ni) begin
        if (~async_rst_ni) begin
            rsqrt_state_q        <= RSQRT_IDLE;
            rsqrt_buffer_q       <= '0;
            rsqrt_active_lanes_q <= '0;
        end else if (~sync_rst_ni) begin
            rsqrt_state_q <= RSQRT_IDLE;
        end else begin
            rsqrt_state_q        <= rsqrt_state_d;
            rsqrt_buffer_q       <= rsqrt_buffer_d;
            rsqrt_tag_q          <= rsqrt_tag_d;
            rsqrt_active_lanes_q <= rsqrt_active_lanes_d;
        end
    end

    ///////////////////////////////////////////////////////////////////////////
    //Input connections to FPU
    ///////////////////////////////////////////////////////////////////////////

    //Operand order/mapping depends on op selected
    //each opgroup has uses different input operands for FPU.  Pipeline always provides rd as operand 3 and other operands as 1 and 2.
    //FPNEW Operands are numbered 0, 1, 2

    always_comb begin
        operand_0_fpu = '0;
        operand_1_fpu = '0;
        operand_2_fpu = '0;


        if (unit_ctrl_q.mode.fpu.op_reduction == 1'b1 & unit_ctrl_q.mode.fpu.op == ADD) begin
            if(unit_ctrl_q.first_cycle == 1'b1) begin
                operand_0_fpu = '0;//This operand is unused by these operations;
                operand_1_fpu = {'0, pipe_in_op1_i_q[31:0]};//First cycle of reduction operation uses vs1[0]  //TODO: MAKE THESE GENERIC
                operand_2_fpu = {'0, pipe_in_op2_i_q[31:0]};

            end else begin
                operand_0_fpu = '0;//This operand is unused by these operations;
                operand_1_fpu = {'0, reduction_buffer_q[31:0]};//all other cycles use previous result
                operand_2_fpu = {'0, pipe_in_op2_i_q[31:0]};

            end           

        end else if (unit_ctrl_q.mode.fpu.op_reduction == 1'b1 & unit_ctrl_q.mode.fpu.op == MINMAX) begin

            if(unit_ctrl_q.first_cycle == 1'b1) begin
                operand_0_fpu = {'0, pipe_in_op2_i_q[31:0]};
                operand_1_fpu = {'0, pipe_in_op1_i_q[31:0]};//First cycle of reduction operation uses vs1[0]  //TODO: MAKE THESE GENERIC
                operand_2_fpu = '0;//This operand is unused by these operations
            end else begin
                operand_0_fpu = {'0, pipe_in_op2_i_q[31:0]};
                operand_1_fpu = {'0, reduction_buffer_q[31:0]};//all other cycles use previous result
                operand_2_fpu = '0;//This operand is unused by these operations;
            end     

        end else if (unit_ctrl_q.mode.fpu.op == ADD) begin

            if (unit_ctrl_q.mode.fpu.op_rev == 1'b1) begin
                //Reverse input operands
                operand_0_fpu = 32'b0;//This operand is unused by these operations;
                operand_1_fpu = pipe_in_op1_i_q;
                operand_2_fpu = pipe_in_op2_i_q;
            end else begin
                operand_0_fpu = 32'b0;//This operand is unused by these operations;
                operand_1_fpu = pipe_in_op2_i_q;
                operand_2_fpu = pipe_in_op1_i_q;
            end
        
         end else if (unit_ctrl_q.mode.fpu.op == DIV) begin

            if (unit_ctrl_q.mode.fpu.op_mod == 1'b1) begin
                // vfrec7: compute 1.0 / vs2 using full-precision division
                operand_0_fpu = {(FPU_OP_W/32){32'h3f800000}}; // 1.0f replicated across all lanes
                operand_1_fpu = pipe_in_op2_i_q;
                operand_2_fpu = '0;
            end else if (unit_ctrl_q.mode.fpu.op_rev == 1'b1) begin
                //Reverse input operands
                operand_0_fpu = pipe_in_op1_i_q;
                operand_1_fpu = pipe_in_op2_i_q;
                operand_2_fpu = 32'b0;//This operand is unused by these operations
            end else begin
                operand_0_fpu = pipe_in_op2_i_q;
                operand_1_fpu = pipe_in_op1_i_q;
                operand_2_fpu = 32'b0;//This operand is unused by these operations
            end

        end else if (unit_ctrl_q.mode.fpu.op == MINMAX | unit_ctrl_q.mode.fpu.op == MUL | unit_ctrl_q.mode.fpu.op == SGNJ ) begin
            
            operand_0_fpu = pipe_in_op2_i_q;
            operand_1_fpu = pipe_in_op1_i_q;
            operand_2_fpu = 32'b0;//This operand is unused by these operations

        end else if (unit_ctrl_q.mode.fpu.op == FMADD | unit_ctrl_q.mode.fpu.op == FNMSUB) begin

            if (unit_ctrl_q.mode.fpu.op_rev == 1'b1) begin
                //Reverse input operands
                operand_0_fpu = pipe_in_op3_i_q;
                operand_1_fpu = pipe_in_op1_i_q;
                operand_2_fpu = pipe_in_op2_i_q;
            end else begin
                operand_0_fpu = pipe_in_op2_i_q;
                operand_1_fpu = pipe_in_op1_i_q;
                operand_2_fpu = pipe_in_op3_i_q;
            end


        end else if (unit_ctrl_q.mode.fpu.op == SQRT) begin

            operand_0_fpu = pipe_in_op2_i_q;
            operand_1_fpu = 32'b0;//This operand is unused by these operations
            operand_2_fpu = 32'b0;//This operand is unused by these operations

        end else if (unit_ctrl_q.mode.fpu.op == CLASSIFY | unit_ctrl_q.mode.fpu.op == F2I | unit_ctrl_q.mode.fpu.op == I2F) begin

            operand_0_fpu = pipe_in_op2_i_q;
            operand_1_fpu = 32'b0;//This operand is unused by these operations
            operand_2_fpu = 32'b0;//This operand is unused by these operations

        end

        // Override operands for vfrsqrt7 DIV phase (1.0 / sqrt(vs2))
        if (rsqrt_div_valid) begin
            operand_0_fpu = {(FPU_OP_W/32){32'h3f800000}};  // 1.0f replicated
            operand_1_fpu = rsqrt_buffer_q;                   // sqrt(vs2)
            operand_2_fpu = '0;
        end

        // NaN-box FP16 operands for widening operations.
        // When src_fmt=FP16 and vectorial_op=0 (widening FP16->FP32), each
        // 32-bit element contains a zero-extended FP16 value in the lower 16
        // bits.  fpnew requires NaN-boxing (upper bits = 0xFFFF) for
        // non-vectorial FP16 operands; without it the classifier treats them
        // as NaN and produces incorrect results.
        if (src_fmt == FP16 && !vectorial_op) begin
            for (int g = 0; g < FPU_OP_W / 32; g++) begin
                operand_0_fpu[32*g+16 +: 16] = 16'hFFFF;
                operand_1_fpu[32*g+16 +: 16] = 16'hFFFF;
            end
        end

    end

    ///////////////////////////////////////////////////////////////////////////
    // FPU ARITHMETIC
    // Each FPU unit handles one 32 bit result.
    
    generate
        for (genvar g = 0; g < FPU_OP_W/ 32; g++) begin
              fpnew_top #(
                    `ifdef RISCV_ZVFH
                    .DivSqrtSel    (fpnew_pkg::PULP),                    // Multi-format div/sqrt for FP16+FP32 support
                    `else
                    .DivSqrtSel    (fpnew_pkg::TH32),                    // FP32-only div/sqrt path for Zve32f
                    `endif
                    .Features      (FPU_FEATURES),        //TODO:Pass in from top level ideally (or define as part of package? if so cant swap them)
                    .Implementation(FPU_IMPLEMENTATION),  //TODO:Pass in from top level ideally (or define as part of package? if so cant swap them)
                    .TagType       (fpu_tag)              // Type for metadata to pass through with instruction.  allows for pipelined operation
                    //Missing 2 config parameters :TrueSIMDClass and EnableSIMDMask - may be necessary for FP16 SIMD OPERATION
                ) fpnew_i (
                    .clk_i         (clk_i),                               
                    .rst_ni        (async_rst_ni),          
                    .operands_i    ({operand_2_fpu[32*g +: 32], operand_1_fpu[32*g +: 32], operand_0_fpu[32*g +: 32]}),  
                    .rnd_mode_i    (rsqrt_div_valid ? rsqrt_tag_q.ctrl.mode.fpu.rnd_mode : unit_ctrl_q.mode.fpu.rnd_mode),
                    .op_i          (rsqrt_div_valid ? fpnew_pkg::DIV : unit_ctrl_q.mode.fpu.op),
                    .op_mod_i      ((rsqrt_div_valid | unit_ctrl_q.mode.fpu.op == DIV | unit_ctrl_q.mode.fpu.op == SQRT) ? 1'b0 : unit_ctrl_q.mode.fpu.op_mod),
                    .src_fmt_i     (rsqrt_div_valid ? fpnew_pkg::FP32 : src_fmt),
                    .dst_fmt_i     (rsqrt_div_valid ? fpnew_pkg::FP32 : dst_fmt),
                    .int_fmt_i     (int_fmt),
                    .vectorial_op_i(rsqrt_div_valid ? 1'b0 : vectorial_op),
                    .tag_i         (rsqrt_div_valid ? rsqrt_tag_q : unit_in_fpu_tag),
                    .simd_mask_i   (2'b11),
                    .in_valid_i    (rsqrt_div_valid ? rsqrt_active_lanes_q[g] :
                                    (rsqrt_active ? 1'b0 : (data_valid_i_q & fpu_active_lanes[g]))),
                    .in_ready_o    (pipe_in_ready_fpu[g]),
                    .flush_i       (~sync_rst_ni),
                    .result_o      (pipe_out_res_o[32*g +: 32]),
                    .status_o      (),
                    .tag_o         (unit_out_fpu_tag[g]),
                    .out_valid_o   (pipe_out_valid_fpu[g]),
                    .out_ready_i   (fpu_out_ready),
                    .busy_o        ()
                );


        end
    endgenerate
endmodule
