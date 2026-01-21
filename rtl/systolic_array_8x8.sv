// Copyright TU Wien
// Licensed under the Solderpad Hardware License v2.1, see LICENSE.txt for details
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

// 并行矩阵乘法单元 - 每周期计算一行的8个元素
// 采用行级并行架构，8行需要8个周期
module systolic_array_8x8 (
    input  logic        clk_i,
    input  logic        rst_ni,
    input  logic        start_i,     // 开始计算
    output logic        done_o,      // 计算完成
    input  logic signed [7:0] mat_a [8][8],  // 矩阵A
    input  logic signed [7:0] mat_b [8][8],  // 矩阵B
    output logic signed [31:0] mat_c [8][8]  // 输出矩阵C（32位累加结果）
);

    // 控制状态
    typedef enum logic [1:0] {
        IDLE,
        COMPUTE,
        DONE
    } state_e;
    
    state_e state_q, state_d;
    logic [2:0] row_q, row_d;   // 当前计算的行号
    logic [2:0] k_q, k_d;       // 当前的k索引（用于点积）
    logic signed [31:0] accum [8];  // 当前行的8个累加器

    // 状态转换逻辑
    always_comb begin
        state_d = state_q;
        row_d = row_q;
        k_d = k_q;
        done_o = 1'b0;

        case (state_q)
            IDLE: begin
                if (start_i) begin
                    state_d = COMPUTE;
                    row_d = '0;
                    k_d = '0;
                end
            end
            COMPUTE: begin
                if (k_q == 7) begin
                    // 当前行的点积计算完成
                    k_d = '0;
                    if (row_q == 7) begin
                        // 所有行计算完成
                        state_d = DONE;
                    end else begin
                        row_d = row_q + 1;
                    end
                end else begin
                    k_d = k_q + 1;
                end
            end
            DONE: begin
                done_o = 1'b1;
                state_d = IDLE;
            end
            default: state_d = IDLE;
        endcase
    end

    // 状态寄存器
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (~rst_ni) begin
            state_q <= IDLE;
            row_q <= '0;
            k_q <= '0;
        end else begin
            state_q <= state_d;
            row_q <= row_d;
            k_q <= k_d;
        end
    end

    // 并行乘法和累加逻辑 - 每周期计算一行的8个部分积
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (~rst_ni) begin
            for (int i = 0; i < 8; i++) begin
                for (int j = 0; j < 8; j++) begin
                    mat_c[i][j] <= '0;
                end
                accum[i] <= '0;
            end
        end else begin
            if (state_q == COMPUTE) begin
                // 并行计算当前行的8个元素的部分积
                for (int col = 0; col < 8; col++) begin
                    automatic logic signed [15:0] mul;
                    mul = $signed(mat_a[row_q][k_q]) * $signed(mat_b[k_q][col]);
                    
                    if (k_q == 0) begin
                        // 第一个k，初始化累加器
                        accum[col] <= mul;
                    end else begin
                        // 累加部分积
                        accum[col] <= accum[col] + mul;
                    end
                    
                    // 当k=7时，保存最终结果
                    if (k_q == 7) begin
                        mat_c[row_q][col] <= accum[col] + mul;
                    end
                end
            end
        end
    end

endmodule
