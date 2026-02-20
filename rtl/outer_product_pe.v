//==============================================================================
// 外积计算单元 (Outer Product Processing Element)
//==============================================================================
// 功能特性:
//   - 计算核心: INT8 × INT8 + ACC16 → ACC16 (乘累加)
//   - 数据流: 广播模式 (Broadcast-based Outer Product)
//     * 权重 (Weight): 广播输入（非流动）
//     * 激活 (Input):  广播输入（非流动）
//     * 累加器 (Acc):   驻留PE内部，保持部分和
//   - 支持级联: 可将部分和传递给下一级阵列
//
// 外积计算公式:
//   C[m][n] += A[m][k] × B[k][n]
//   其中: m=行索引, n=列索引, k=当前迭代
//
// 与脉动阵列PE的区别:
//   - 脉动阵列: 数据流动，逐步传播
//   - 外积阵列: 数据广播，所有PE同时计算
//==============================================================================

module outer_product_pe #(
    parameter DATA_WIDTH = 8,            // 运算数据位宽
    parameter ACC_WIDTH  = 16,           // 累加器位宽
    parameter ROW_IDX    = 0,            // PE在阵列中的行索引
    parameter COL_IDX    = 0             // PE在阵列中的列索引
)(
    // 全局信号
    input  wire                    clk,
    input  wire                    rst_n,
    input  wire                    en,             // 模块使能

    // 操作模式
    input  wire                    op_mode,        // 0: MATMUL(乘累加), 1: MATADD(加法)

    // 广播数据输入（所有PE同时接收相同的weight或input）
    input  wire [DATA_WIDTH-1:0]   weight_broadcast, // MATMUL: A[m][k], MATADD: A[m][n]
    input  wire [DATA_WIDTH-1:0]   input_broadcast,  // MATMUL: B[k][n], MATADD: B[m][n]
    input  wire                    compute_valid,   // 计算有效信号

    // 累加器级联（用于多阵列拼接时的部分和传递）
    input  wire [ACC_WIDTH-1:0]    psum_cascade_in, // 上一级阵列的部分和
    input  wire                    cascade_in_valid,// 级联输入有效

    // 控制信号
    input  wire                    acc_clear,      // 清除累加器
    input  wire                    acc_load,       // 加载初始值到累加器
    input  wire [ACC_WIDTH-1:0]    acc_load_data,  // 加载数据

    // 输出
    output wire [ACC_WIDTH-1:0]    psum_out,       // 当前PE的部分和输出
    output wire [ACC_WIDTH-1:0]    psum_cascade_out,// 传递给下一级阵列
    output reg                     valid_out       // 输出有效信号
);

    //==========================================================================
    // 内部寄存器与信号
    //==========================================================================
    reg [ACC_WIDTH-1:0]         acc_reg;        // 累加器寄存器
    reg [ACC_WIDTH-1:0]         acc_reg_next;   // 下一周期累加器值

    // 符号扩展逻辑 - 保证有符号运算正确性
    wire signed [DATA_WIDTH:0]  weight_signed;
    wire signed [DATA_WIDTH:0]  input_signed;
    wire signed [ACC_WIDTH+1:0] product_ext;    // 扩展一位防止溢出

    //==========================================================================
    // 组合逻辑 - 乘法器
    //==========================================================================
    assign weight_signed = {{1{weight_broadcast[DATA_WIDTH-1]}}, weight_broadcast};
    assign input_signed  = {{1{input_broadcast[DATA_WIDTH-1]}}, input_broadcast};
    assign product_ext   = weight_signed * input_signed;  // 有符号乘法

    //==========================================================================
    // 累加器下一状态逻辑
    //==========================================================================
    // 符号扩展的加法操作数
    wire signed [ACC_WIDTH-1:0] weight_ext;
    wire signed [ACC_WIDTH-1:0] input_ext;

    assign weight_ext = {{8{weight_broadcast[DATA_WIDTH-1]}}, weight_broadcast};
    assign input_ext  = {{8{input_broadcast[DATA_WIDTH-1]}}, input_broadcast};

    always @(*) begin
        if (acc_clear) begin
            acc_reg_next = {ACC_WIDTH{1'b0}};
        end else if (acc_load) begin
            acc_reg_next = acc_load_data;
        end else if (cascade_in_valid) begin
            // 级联模式：累加上一级阵列的结果
            acc_reg_next = acc_reg + psum_cascade_in;
        end else if (compute_valid) begin
            // 根据操作模式选择计算方式
            if (op_mode == 1'b0) begin
                // MATMUL模式：累加乘积结果
                acc_reg_next = acc_reg + product_ext[ACC_WIDTH-1:0];
            end else begin
                // MATADD模式：累加两个输入的和
                // C[m][n] += A[m][n] + B[m][n]
                acc_reg_next = acc_reg + weight_ext[ACC_WIDTH-1:0] + input_ext[ACC_WIDTH-1:0];
            end
        end else begin
            acc_reg_next = acc_reg;  // 保持
        end
    end

    //==========================================================================
    // 时序逻辑 - 状态更新
    //==========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            acc_reg   <= {ACC_WIDTH{1'b0}};
            valid_out <= 1'b0;
        end else if (en) begin
            acc_reg   <= acc_reg_next;
            valid_out <= compute_valid || cascade_in_valid;
        end
    end

    //==========================================================================
    // 输出赋值
    //==========================================================================
    assign psum_out        = acc_reg;
    assign psum_cascade_out = acc_reg;  // 级联输出等于当前累加值

    //==========================================================================
    // 调试信息（编译时可选择）
    //==============================================================================
    `ifdef DEBUG_PE
        always @(posedge clk) begin
            if (en && compute_valid) begin
                $display("[PE %0d,%0d] W:%0d I:%0d Prod:%0d Acc:%0d",
                         ROW_IDX, COL_IDX,
                         $signed(weight_broadcast), $signed(input_broadcast),
                         $signed(product_ext[ACC_WIDTH-1:0]), $signed(acc_reg));
            end
        end
    `endif

endmodule
