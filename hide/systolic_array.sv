// Copyright TU Wien
// Licensed under the Solderpad Hardware License v2.1, see LICENSE.txt for details
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

// Systolic Array Processing Element
module systolic_pe (
    input  logic        clk_i,
    input  logic        rst_ni,
    input  logic        en_i,
    input  logic signed [7:0]  a_i,      // 输入A（从上到下）
    input  logic signed [7:0]  b_i,      // 输入B（从左到右）
    input  logic signed [31:0] acc_i,    // 累加器输入（从左到右）
    output logic signed [7:0]  a_o,      // 输出A（向下传递）
    output logic signed [7:0]  b_o,      // 输出B（向右传递）
    output logic signed [31:0] acc_o     // 累加器输出（向右传递）
);

    logic signed [7:0]  a_q;
    logic signed [7:0]  b_q;
    logic signed [31:0] acc_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (~rst_ni) begin
            a_q   <= '0;
            b_q   <= '0;
            acc_q <= '0;
        end else if (en_i) begin
            a_q   <= a_i;
            b_q   <= b_i;
            acc_q <= acc_i + ($signed(a_i) * $signed(b_i));
        end
    end

    assign a_o   = a_q;
    assign b_o   = b_q;
    assign acc_o = acc_q;

endmodule

// 8x8 Systolic Array
module systolic_array_8x8 (
    input  logic        clk_i,
    input  logic        rst_ni,
    input  logic        start_i,     // 开始计算
    output logic        done_o,      // 计算完成
    input  logic signed [7:0] mat_a [8][8],  // 矩阵A
    input  logic signed [7:0] mat_b [8][8],  // 矩阵B
    output logic signed [31:0] mat_c [8][8]  // 输出矩阵C（32位累加结果）
);

    // PE之间的连接信号
    logic signed [7:0]  a_wire [8][9];   // [行][列]，9列因为需要连接PE输入输出
    logic signed [7:0]  b_wire [9][8];   // [行][列]，9行因为需要连接PE输入输出
    logic signed [31:0] acc_wire [8][9]; // [行][列]

    // 控制信号
    logic [4:0] cycle_cnt;
    logic       computing;
    logic       pe_en;

    // 8x8 PE阵列
    generate
        for (genvar i = 0; i < 8; i++) begin : gen_row
            for (genvar j = 0; j < 8; j++) begin : gen_col
                systolic_pe pe_inst (
                    .clk_i   (clk_i),
                    .rst_ni  (rst_ni),
                    .en_i    (pe_en),
                    .a_i     (a_wire[i][j]),
                    .b_i     (b_wire[i][j]),
                    .acc_i   (acc_wire[i][j]),
                    .a_o     (a_wire[i][j+1]),
                    .b_o     (b_wire[i+1][j]),
                    .acc_o   (acc_wire[i][j+1])
                );
            end
        end
    endgenerate

    // 输入数据调度逻辑（skewed输入）
    always_comb begin
        // 初始化所有输入为0
        for (int i = 0; i < 8; i++) begin
            a_wire[i][0] = '0;
            b_wire[0][i] = '0;
            acc_wire[i][0] = '0;
        end

        if (computing) begin
            // A矩阵输入（从上到下，每列错开输入）
            for (int i = 0; i < 8; i++) begin
                if (cycle_cnt >= i && cycle_cnt < (i + 8)) begin
                    a_wire[i][0] = mat_a[i][cycle_cnt - i];
                end
            end

            // B矩阵输入（从左到右，每行错开输入）
            for (int j = 0; j < 8; j++) begin
                if (cycle_cnt >= j && cycle_cnt < (j + 8)) begin
                    b_wire[0][j] = mat_b[cycle_cnt - j][j];
                end
            end
        end
    end

    // 控制逻辑
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (~rst_ni) begin
            cycle_cnt <= '0;
            computing <= 1'b0;
            pe_en     <= 1'b0;
            done_o    <= 1'b0;
        end else begin
            done_o <= 1'b0;
            
            if (start_i && !computing) begin
                computing <= 1'b1;
                cycle_cnt <= '0;
                pe_en     <= 1'b1;
            end else if (computing) begin
                if (cycle_cnt < 22) begin  // 总共需要23个周期（0-22）
                    cycle_cnt <= cycle_cnt + 1;
                end else begin
                    computing <= 1'b0;
                    pe_en     <= 1'b0;
                    done_o    <= 1'b1;
                end
            end
        end
    end

    // 输出收集逻辑
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (~rst_ni) begin
            for (int i = 0; i < 8; i++) begin
                for (int j = 0; j < 8; j++) begin
                    mat_c[i][j] <= '0;
                end
            end
        end else if (computing && pe_en) begin
            // 结果在周期15-22时开始从右侧输出
            for (int i = 0; i < 8; i++) begin
                if (cycle_cnt >= (15 + i) && cycle_cnt <= (22)) begin
                    int col_idx = cycle_cnt - 15 - i;
                    if (col_idx >= 0 && col_idx < 8) begin
                        mat_c[i][7-col_idx] <= acc_wire[i][8];
                    end
                end
            end
        end
    end

endmodule
