// Copyright TU Wien
// Licensed under the Solderpad Hardware License v2.1, see LICENSE.txt for details
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

module matrix_unit (
    input  logic        clk_i,
    input  logic        rst_ni,
    input  logic        instr_valid_i,
    input  logic [31:0] instr_i,
    input  logic [31:0] rs1_i,
    input  logic [31:0] rs2_i,
    output logic        instr_gnt_o,
    output logic        instr_illegal_o,
    output logic        wait_o,
    output logic        res_valid_o,
    output logic [31:0] res_o,
    output logic        mem_req_o,
    output logic [31:0] mem_addr_o,
    output logic        mem_we_o,
    output logic [7:0]  mem_be_o,
    output logic [63:0] mem_wdata_o,
    input  logic        mem_gnt_i,
    input  logic        mem_rvalid_i,
    input  logic        mem_err_i,
    input  logic [63:0] mem_rdata_i
);

    localparam int unsigned MAT_DIM  = 8;
    localparam int unsigned MAT_REGS = 4;

    localparam logic [6:0] OPCODE_CUSTOM0 = 7'b0001011;
    localparam logic [2:0] FUNCT3_MVIN    = 3'b000;
    localparam logic [2:0] FUNCT3_MVOUT   = 3'b001;
    localparam logic [2:0] FUNCT3_MATMUL  = 3'b010;
    localparam logic [2:0] FUNCT3_ACC     = 3'b011;
    localparam logic [2:0] FUNCT3_MATADD  = 3'b100;

    typedef enum logic [2:0] {
        ST_IDLE,
        ST_MVIN_REQ,
        ST_MVIN_WAIT,
        ST_MVOUT_REQ,
        ST_MVOUT_WAIT,
        ST_MATMUL,
        ST_MATADD
    } mat_state_e;

    mat_state_e state_q;

    logic [2:0]  row_q;
    logic [2:0]  col_q;
    logic [2:0]  k_q;
    logic [1:0]  reg_a_q;
    logic [1:0]  reg_b_q;
    logic [1:0]  reg_dst_q;
    logic        op_acc_q;
    logic signed [31:0] accum_q;
    logic [31:0] base_addr_q;
    logic [31:0] mem_addr_q;
    logic        done_q;
    logic        mem_wide_q;

    // Systolic array控制信号
    logic systolic_start;
    logic systolic_done;
    logic signed [31:0] systolic_result [8][8];

    logic signed [7:0]  mat_regs [MAT_REGS][MAT_DIM][MAT_DIM];
    logic signed [31:0] acc_regs [MAT_DIM][MAT_DIM];

    logic unused_mem_err;
    assign unused_mem_err = mem_err_i;

    // 实例化Systolic Array
    systolic_array_8x8 systolic_inst (
        .clk_i   (clk_i),
        .rst_ni  (rst_ni),
        .start_i (systolic_start),
        .done_o  (systolic_done),
        .mat_a   (mat_regs[reg_a_q]),
        .mat_b   (mat_regs[reg_b_q]),
        .mat_c   (systolic_result)
    );

    function automatic logic signed [7:0] sat8(input logic signed [31:0] val);
        if (val > 127) begin
            sat8 = 8'sd127;
        end else if (val < -128) begin
            sat8 = -8'sd128;
        end else begin
            sat8 = $signed(val[7:0]);
        end
    endfunction

    logic [6:0] opcode;
    logic [2:0] funct3;
    logic [6:0] funct7;
    logic [4:0] rd_idx;

    assign opcode = instr_i[6:0];
    assign funct3 = instr_i[14:12];
    assign funct7 = instr_i[31:25];
    assign rd_idx = instr_i[11:7];

    logic legal_instr;
    logic legal_regs;
    logic legal_mat_ids;
    logic need_mat_ids;
    assign legal_regs    = (rd_idx[4:2] == 3'b000);
    assign legal_mat_ids = (rs1_i[31:2] == 30'b0) && (rs2_i[31:2] == 30'b0);
    assign need_mat_ids  = (funct3 == FUNCT3_MATMUL) || (funct3 == FUNCT3_ACC) || (funct3 == FUNCT3_MATADD);
    assign legal_instr = (opcode == OPCODE_CUSTOM0) &&
                         (funct7 == 7'b0000000) &&
                         ((funct3 == FUNCT3_MVIN)  ||
                          (funct3 == FUNCT3_MVOUT) ||
                          (funct3 == FUNCT3_MATMUL)||
                          (funct3 == FUNCT3_ACC)   ||
                          (funct3 == FUNCT3_MATADD))  &&
                         legal_regs &&
                         (need_mat_ids ? legal_mat_ids : 1'b1);

    logic can_accept;
    assign can_accept      = (state_q == ST_IDLE) && ~done_q;
    assign instr_gnt_o     = instr_valid_i && (done_q || (can_accept && ~legal_instr));
    assign instr_illegal_o = instr_valid_i && can_accept && ~legal_instr;
    assign wait_o          = 1'b0;
    assign res_valid_o     = 1'b0;
    assign res_o           = 32'b0;

    logic [2:0] row_start;
    logic [2:0] col_start;
    assign row_start = rs2_i[2:0];
    assign col_start = rs2_i[5:3];

    logic [5:0] elem_offset;
    assign elem_offset = {3'b000, row_q} * MAT_DIM + {3'b000, col_q};

    always_comb begin
        mem_req_o   = 1'b0;
        mem_addr_o  = 32'b0;
        mem_we_o    = 1'b0;
        mem_be_o    = 8'b00000000;
        mem_wdata_o = 64'b0;
        if (state_q == ST_MVIN_REQ) begin
            mem_req_o  = 1'b1;
            mem_addr_o = base_addr_q + (mem_wide_q ? {3'b000, row_q} * MAT_DIM : elem_offset);
            mem_we_o   = 1'b0;
            mem_be_o   = mem_wide_q ? 8'hFF : 8'hFF;
        end else if (state_q == ST_MVOUT_REQ) begin
            mem_req_o  = 1'b1;
            mem_addr_o = base_addr_q + (mem_wide_q ? {3'b000, row_q} * MAT_DIM : elem_offset);
            mem_we_o   = 1'b1;
            if (mem_wide_q) begin
                mem_be_o   = 8'hFF;
                mem_wdata_o = {
                    mat_regs[reg_dst_q][row_q][7],
                    mat_regs[reg_dst_q][row_q][6],
                    mat_regs[reg_dst_q][row_q][5],
                    mat_regs[reg_dst_q][row_q][4],
                    mat_regs[reg_dst_q][row_q][3],
                    mat_regs[reg_dst_q][row_q][2],
                    mat_regs[reg_dst_q][row_q][1],
                    mat_regs[reg_dst_q][row_q][0]
                };
            end else begin
                mem_be_o   = 8'b00000001 << mem_addr_o[2:0];
                mem_wdata_o = {8{mat_regs[reg_dst_q][row_q][col_q]}};
            end
        end
    end

    // Debug output
    always_ff @(posedge clk_i) begin
        if (instr_valid_i && instr_gnt_o) begin
            $display("[MATRIX] t=%0t Accept instr funct3=%b rd=%d state=%d", 
                     $time, funct3, rd_idx, state_q);
        end
        if (state_q == ST_MATMUL && k_q == 0 && row_q == 0 && col_q == 0) begin
            $display("[MATRIX] t=%0t Start MATMUL reg_a=%d reg_b=%d reg_dst=%d", 
                     $time, reg_a_q, reg_b_q, reg_dst_q);
        end
        if (state_q == ST_MATMUL && k_q == MAT_DIM-1 && row_q == MAT_DIM-1 && col_q == MAT_DIM-1) begin
            $display("[MATRIX] t=%0t MATMUL done, result[0][0]=%d", 
                     $time, mat_regs[reg_dst_q][0][0]);
        end
    end

    // Systolic array启动控制
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (~rst_ni) begin
            systolic_start <= 1'b0;
        end else begin
            // 在进入ST_MATMUL状态时启动systolic array
            systolic_start <= (can_accept && instr_valid_i &&
                              legal_instr && (funct3 == FUNCT3_MATMUL || funct3 == FUNCT3_ACC));
        end
    end

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (~rst_ni) begin
            state_q    <= ST_IDLE;
            row_q      <= '0;
            col_q      <= '0;
            k_q        <= '0;
            reg_a_q    <= '0;
            reg_b_q    <= '0;
            reg_dst_q  <= '0;
            op_acc_q   <= 1'b0;
            accum_q    <= '0;
            base_addr_q <= '0;
            mem_addr_q  <= '0;
            done_q     <= 1'b0;
            mem_wide_q <= 1'b0;
            for (int r = 0; r < MAT_REGS; r++) begin
                for (int i = 0; i < MAT_DIM; i++) begin
                    for (int j = 0; j < MAT_DIM; j++) begin
                        mat_regs[r][i][j] <= '0;
                    end
                end
            end
            for (int i = 0; i < MAT_DIM; i++) begin
                for (int j = 0; j < MAT_DIM; j++) begin
                    acc_regs[i][j] <= '0;
                end
            end
        end else begin
            if (instr_valid_i && done_q) begin
                done_q <= 1'b0;
            end
            case (state_q)
                ST_IDLE: begin
                    if (instr_valid_i && can_accept) begin
                        if (legal_instr) begin
                            reg_dst_q   <= rd_idx[1:0];
                            base_addr_q <= rs1_i + (row_start * MAT_DIM + col_start);
                            row_q       <= 3'b000;
                            col_q       <= 3'b000;
                            if (funct3 == FUNCT3_MVIN) begin
                                mem_wide_q <= (col_start == 3'b000) && (rs1_i[2:0] == 3'b000);
                                state_q <= ST_MVIN_REQ;
                            end else if (funct3 == FUNCT3_MVOUT) begin
                                mem_wide_q <= (col_start == 3'b000) && (rs1_i[2:0] == 3'b000);
                                state_q <= ST_MVOUT_REQ;
                            end else if (funct3 == FUNCT3_MATADD) begin
                                mem_wide_q <= 1'b0;
                                reg_a_q  <= rs1_i[1:0];
                                reg_b_q  <= rs2_i[1:0];
                                row_q    <= 3'b000;
                                col_q    <= 3'b000;
                                state_q  <= ST_MATADD;
                            end else begin
                                mem_wide_q <= 1'b0;
                                reg_a_q  <= rs1_i[1:0];
                                reg_b_q  <= rs2_i[1:0];
                                op_acc_q <= (funct3 == FUNCT3_ACC);
                                k_q      <= 3'b000;
                                accum_q  <= '0;
                                state_q  <= ST_MATMUL;
                            end
                        end
                    end
                end
                ST_MVIN_REQ: begin
                    if (mem_gnt_i) begin
                        mem_addr_q <= mem_addr_o;
                        state_q    <= ST_MVIN_WAIT;
                    end
                end
                ST_MVIN_WAIT: begin
                    if (mem_rvalid_i) begin
                        if (mem_wide_q) begin
                            for (int j = 0; j < MAT_DIM; j++) begin
                                mat_regs[reg_dst_q][row_q][j] <= mem_rdata_i[j*8 +: 8];
                            end
                        end else begin
                            mat_regs[reg_dst_q][row_q][col_q] <= mem_rdata_i[mem_addr_q[2:0]*8 +: 8];
                        end
                        if ((mem_wide_q && row_q == MAT_DIM-1) ||
                            (!mem_wide_q && row_q == MAT_DIM-1 && col_q == MAT_DIM-1)) begin
                            state_q <= ST_IDLE;
                            done_q <= 1'b1;
                        end else begin
                            if (mem_wide_q || col_q == MAT_DIM-1) begin
                                row_q <= row_q + 1'b1;
                                col_q <= '0;
                            end else begin
                                col_q <= col_q + 1'b1;
                            end
                            state_q <= ST_MVIN_REQ;
                        end
                    end
                end
                ST_MVOUT_REQ: begin
                    if (mem_gnt_i) begin
                        // For writes, we can proceed immediately after grant
                        if ((mem_wide_q && row_q == MAT_DIM-1) ||
                            (!mem_wide_q && row_q == MAT_DIM-1 && col_q == MAT_DIM-1)) begin
                            state_q <= ST_IDLE;
                            done_q <= 1'b1;
                        end else begin
                            if (mem_wide_q || col_q == MAT_DIM-1) begin
                                row_q <= row_q + 1'b1;
                                col_q <= '0;
                            end else begin
                                col_q <= col_q + 1'b1;
                            end
                            state_q <= ST_MVOUT_REQ;
                        end
                    end
                end
                ST_MVOUT_WAIT: begin
                    // Unused state (kept for compatibility)
                    state_q <= ST_IDLE;
                end
                ST_MATMUL: begin
                    if (systolic_done) begin
                        // Systolic array计算完成，收集结果
                        for (int i = 0; i < MAT_DIM; i++) begin
                            for (int j = 0; j < MAT_DIM; j++) begin
                                automatic logic signed [31:0] result;
                                result = op_acc_q ? (acc_regs[i][j] + systolic_result[i][j]) : systolic_result[i][j];
                                acc_regs[i][j] <= result;
                                mat_regs[reg_dst_q][i][j] <= sat8(result);
                            end
                        end
                        state_q <= ST_IDLE;
                        done_q <= 1'b1;
                    end
                    // Systolic array正在计算，等待完成
                end
                ST_MATADD: begin
                    // 全并行矩阵加法 - 一个周期完成所有64个元素
                    for (int i = 0; i < MAT_DIM; i++) begin
                        for (int j = 0; j < MAT_DIM; j++) begin
                            automatic logic signed [31:0] add_result;
                            add_result = $signed(mat_regs[reg_a_q][i][j]) + 
                                        $signed(mat_regs[reg_b_q][i][j]);
                            mat_regs[reg_dst_q][i][j] <= sat8(add_result);
                        end
                    end
                    state_q <= ST_IDLE;
                    done_q <= 1'b1;
                end
                default: state_q <= ST_IDLE;
            endcase
        end
    end

endmodule
