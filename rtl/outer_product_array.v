
//==============================================================================
// 外积广播网络阵列 (Outer Product Broadcast Array)
//==============================================================================
// 架构特性:
//   - 规模: 8×8 PE 阵列（可参数化）
//   - 数据流: 广播模式 (Broadcast-based)
//     * 行广播: A[m][k] 广播到第m行的所有PE
//     * 列广播: B[k][n] 广播到第n列的所有PE
//   - 计算模式: 外积 C += A[:][k] × B[k][:]
//   - 累加器: 驻留在PE内部
//   - 延迟: K个周期完成M×N×K矩阵乘法
//
// 与脉动阵列对比:
//   - 脉动阵列: M+N+K-1周期，数据流动
//   - 外积阵列: K周期，数据广播
//
// 支持扩展:
//   - 可通过级联端口拼接多个阵列
//   - 支持流水线模式（中间打一拍）
//==============================================================================

module outer_product_array #(
    parameter ARRAY_SIZE = 8,           // 阵列尺寸 (8×8)
    parameter DATA_WIDTH = 8,            // 数据位宽
    parameter ACC_WIDTH  = 16            // 累加器位宽
)(
    // 全局信号
    input  wire                        clk,
    input  wire                        rst_n,
    input  wire                        en,

    //==========================================================================
    // 广播数据输入
    //==========================================================================
    // 行广播: A[M][K] 的第k列（M个值，每个广播到一行）
    input  wire [DATA_WIDTH-1:0]       row_broadcast [0:ARRAY_SIZE-1],
    input  wire                        row_valid,

    // 列广播: B[K][N] 的第k行（N个值，每个广播到一列）
    input  wire [DATA_WIDTH-1:0]       col_broadcast [0:ARRAY_SIZE-1],
    input  wire                        col_valid,

    //==========================================================================
    // 级联端口（用于多阵列拼接）
    //==========================================================================
    input  wire [ACC_WIDTH-1:0]        cascade_in [0:ARRAY_SIZE-1][0:ARRAY_SIZE-1],
    input  wire                        cascade_in_valid,
    output wire [ACC_WIDTH-1:0]        cascade_out [0:ARRAY_SIZE-1][0:ARRAY_SIZE-1],
    output wire                        cascade_out_valid,

    //==========================================================================
    // 操作模式控制
    //==========================================================================
    input  wire                        op_mode,        // 0: MATMUL, 1: MATADD

    //==========================================================================
    // 累加器控制
    //==========================================================================
    input  wire                        acc_clear,      // 清除所有累加器
    input  wire                        acc_load,       // 加载初始值
    input  wire [ACC_WIDTH-1:0]        acc_load_data [0:ARRAY_SIZE-1][0:ARRAY_SIZE-1],

    //==========================================================================
    // 结果输出
    //==========================================================================
    output wire [ACC_WIDTH-1:0]        result_out [0:ARRAY_SIZE-1][0:ARRAY_SIZE-1],
    output wire                        result_valid    // 结果输出有效
);

    //==========================================================================
    // 内部信号
    //==========================================================================
    wire [ACC_WIDTH-1:0] psum_out [0:ARRAY_SIZE-1][0:ARRAY_SIZE-1];
    wire [ACC_WIDTH-1:0] psum_cascade [0:ARRAY_SIZE-1][0:ARRAY_SIZE-1];
    wire        valid_out [0:ARRAY_SIZE-1][0:ARRAY_SIZE-1];

    // 计算有效信号：行和列广播都有效时才计算
    wire compute_valid_comb = row_valid && col_valid;

    //==========================================================================
    // 输入流水线寄存器 (Input Pipeline Registers)
    //==========================================================================
    // 目的: 切断关键路径，通过复制寄存器降低扇出 (Fanout reduction)
    
    // 数据广播流水线
    reg [DATA_WIDTH-1:0] row_broadcast_pipe [0:ARRAY_SIZE-1];
    reg [DATA_WIDTH-1:0] col_broadcast_pipe [0:ARRAY_SIZE-1];
    
    // 控制信号流水线 (按行复制以降低扇出)
    reg [ARRAY_SIZE-1:0] compute_valid_pipe;
    reg [ARRAY_SIZE-1:0] op_mode_pipe;
    reg [ARRAY_SIZE-1:0] acc_clear_pipe;
    reg [ARRAY_SIZE-1:0] acc_load_pipe;
    
    // 级联输入流水线 (可选，视时序情况而定，暂不流水化级联数据以节省资源，假设级联路径较短)
    // reg [ACC_WIDTH-1:0] cascade_in_pipe [0:ARRAY_SIZE-1][0:ARRAY_SIZE-1];

    integer i;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            compute_valid_pipe <= 0;
            op_mode_pipe <= 0;
            acc_clear_pipe <= 0;
            acc_load_pipe <= 0;
            for (i = 0; i < ARRAY_SIZE; i = i + 1) begin
                row_broadcast_pipe[i] <= 0;
                col_broadcast_pipe[i] <= 0;
            end
        end else if (en) begin
            // 复制控制信号到每一行的寄存器
            compute_valid_pipe <= {ARRAY_SIZE{compute_valid_comb}};
            op_mode_pipe       <= {ARRAY_SIZE{op_mode}};
            acc_clear_pipe     <= {ARRAY_SIZE{acc_clear}};
            acc_load_pipe      <= {ARRAY_SIZE{acc_load}};
            
            // 数据打拍
            for (i = 0; i < ARRAY_SIZE; i = i + 1) begin
                row_broadcast_pipe[i] <= row_broadcast[i];
                col_broadcast_pipe[i] <= col_broadcast[i];
            end
        end
    end

    //==========================================================================
    // PE阵列生成
    //==========================================================================
    genvar row, col;
    generate
        for (row = 0; row < ARRAY_SIZE; row = row + 1) begin : gen_row
            for (col = 0; col < ARRAY_SIZE; col = col + 1) begin : gen_col
                // 每个PE的连接：
                // - row_broadcast[row]: A[row][k] 广播到该行所有PE
                // - col_broadcast[col]: B[k][col] 广播到该列所有PE
                // - 计算外积: C[row][col] += A[row][k] × B[k][col]
                outer_product_pe #(
                    .DATA_WIDTH(DATA_WIDTH),
                    .ACC_WIDTH(ACC_WIDTH),
                    .ROW_IDX(row),
                    .COL_IDX(col)
                ) pe_inst (
                    .clk(clk),
                    .rst_n(rst_n),
                    .en(en),

                    // 操作模式
                    .op_mode(op_mode_pipe[row]),  // 使用流水线信号

                    // 广播输入
                    .weight_broadcast(row_broadcast_pipe[row]),  // 使用流水线数据
                    .input_broadcast(col_broadcast_pipe[col]),   // 使用流水线数据
                    .compute_valid(compute_valid_pipe[row]),     // 使用流水线信号

                    // 级联端口
                    .psum_cascade_in(cascade_in[row][col]),
                    .cascade_in_valid(cascade_in_valid),

                    // 控制
                    .acc_clear(acc_clear_pipe[row]), // 使用流水线信号
                    .acc_load(acc_load_pipe[row]),   // 使用流水线信号
                    .acc_load_data(acc_load_data[row][col]),

                    // 输出
                    .psum_out(psum_out[row][col]),
                    .psum_cascade_out(psum_cascade[row][col]),
                    .valid_out(valid_out[row][col])
                );

                // 将PE的输出连接到结果端口
                assign result_out[row][col] = psum_out[row][col];
                assign cascade_out[row][col] = psum_cascade[row][col];
            end
        end
    endgenerate

    //==========================================================================
    // 结果有效信号生成
    //==========================================================================
    // 当所有PE都有效时，输出结果有效
    reg [7:0] valid_count;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            valid_count <= 0;
        end else if (en) begin
            // 简化：任一PE有效即认为结果有效（实际应用可能需要所有PE）
            if (compute_valid_pipe[0]) begin
                valid_count <= valid_count + 1;
            end
        end
    end

    assign result_valid = valid_count > 0;

    //==========================================================================
    // 级联输出有效：延迟一拍
    //==========================================================================
    reg cascade_valid_reg;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cascade_valid_reg <= 1'b0;
        end else if (en) begin
            cascade_valid_reg <= compute_valid_pipe[0] || cascade_in_valid;
        end
    end
    assign cascade_out_valid = cascade_valid_reg;

    //==========================================================================
    // 调试信息
    //==========================================================================
    `ifdef DEBUG_ARRAY
        always @(posedge clk) begin
            if (en && compute_valid_pipe[0]) begin
                $display("[Array] Broadcast: Row[0]=%0d Col[0]=%0d",
                         $signed(row_broadcast_pipe[0]), $signed(col_broadcast_pipe[0]));
            end
        end
    `endif

endmodule
