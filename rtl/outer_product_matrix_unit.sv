// Outer Product Matrix Unit - 外积引擎适配层
// 将外积引擎包装成与 matrix_unit 相同的接口
// 策略：在适配层维护本地缓存，批量从 dcache 加载/存储

module outer_product_matrix_unit #(
    parameter int unsigned MEM_WIDTH = 64
)(
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
    output logic [MEM_WIDTH/8-1:0] mem_be_o,
    output logic [MEM_WIDTH-1:0]   mem_wdata_o,
    input  logic        mem_gnt_i,
    input  logic        mem_rvalid_i,
    input  logic        mem_err_i,
    input  logic [MEM_WIDTH-1:0]   mem_rdata_i
);

    localparam int unsigned MAT_DIM  = 8;
    localparam int unsigned BYTES_PER_ACCESS = MEM_WIDTH / 8;

    localparam logic [6:0] OPCODE_CUSTOM0 = 7'b0001011;
    localparam logic [2:0] FUNCT3_MVIN    = 3'b000;
    localparam logic [2:0] FUNCT3_MVOUT   = 3'b001;
    localparam logic [2:0] FUNCT3_MATMUL  = 3'b010;
    localparam logic [2:0] FUNCT3_MATADD  = 3'b100;

    typedef enum logic [3:0] {
        ST_IDLE,
        ST_LOAD_REQ,
        ST_LOAD_WAIT,
        ST_OP_MVIN,
        ST_OP_MVIN_WAIT,
        ST_OP_COMPUTE,
        ST_OP_COMPUTE_WAIT,
        ST_OP_MVOUT,
        ST_OP_MVOUT_WAIT,
        ST_STORE_REQ,
        ST_STORE_WAIT,
        ST_DONE,
        ST_MATADD
    } state_e;

    state_e state_q, state_d;

    logic [2:0]  row_cnt_q, row_cnt_d;
    logic [1:0]  mat_sel_q, mat_sel_d;
    logic [31:0] base_addr_q, base_addr_d;
    logic [2:0]  funct3_q, funct3_d;
    logic        done_q, done_d;
    logic        op_started_q, op_started_d;
    logic [5:0]  matadd_cnt_q, matadd_cnt_d;

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
    assign need_mat_ids  = (funct3 == FUNCT3_MATMUL) || (funct3 == FUNCT3_MATADD);
    assign legal_instr = (opcode == OPCODE_CUSTOM0) &&
                         (funct7 == 7'b0000000) &&
                         ((funct3 == FUNCT3_MVIN)  ||
                          (funct3 == FUNCT3_MVOUT) ||
                          (funct3 == FUNCT3_MATMUL)||
                          (funct3 == FUNCT3_MATADD))  &&
                         legal_regs &&
                         (need_mat_ids ? legal_mat_ids : 1'b1);

    logic can_accept;
    logic accepting_new_instr;
    assign can_accept      = (state_q == ST_IDLE) && ~done_q;
    assign accepting_new_instr = instr_valid_i && (can_accept || done_q) && legal_instr;
    assign instr_gnt_o     = instr_valid_i && (done_q || can_accept);
    assign instr_illegal_o = instr_valid_i && can_accept && ~legal_instr;
    assign wait_o          = ((state_q != ST_IDLE) && (state_q != ST_DONE)) || accepting_new_instr;
    assign res_valid_o     = (state_q == ST_DONE);
    assign res_o           = 32'b0;

    logic [7:0]  a_mem [64];
    logic [7:0]  b_mem [64];
    logic [15:0] c_mem [64];

    function automatic logic signed [7:0] sat8(input logic signed [15:0] val);
        if (val > 16'sd127) begin
            sat8 = 8'sd127;
        end else if (val < -16'sd128) begin
            sat8 = -8'sd128;
        end else begin
            sat8 = val[7:0];
        end
    endfunction

    logic [31:0] op_instruction;
    logic        op_busy;
    logic        op_done;
    logic [31:0] op_status;

    logic [2:0]  op_a_addr;
    logic [MAT_DIM*8-1:0]  op_a_dout;
    logic        op_a_ren;

    logic [2:0]  op_b_addr;
    logic [MAT_DIM*8-1:0]  op_b_dout;
    logic        op_b_ren;

    logic [2:0]  op_c_addr;
    logic [MAT_DIM*16-1:0] op_c_dout;
    logic        op_c_wen;
    logic        op_c_ren;

    always_comb begin
        for (int i = 0; i < MAT_DIM; i++)
            op_a_dout[i*8 +: 8] = a_mem[{3'(i), op_a_addr}];
    end

    always_comb begin
        for (int j = 0; j < MAT_DIM; j++)
            op_b_dout[j*8 +: 8] = b_mem[{op_b_addr, 3'(j)}];
    end

    outer_product_unit #(
        .ARRAY_SIZE(MAT_DIM),
        .DATA_WIDTH(8),
        .ACC_WIDTH(16),
        .ADDR_WIDTH(3)
    ) op_unit (
        .clk        (clk_i),
        .rst_n      (rst_ni),
        .instruction(op_instruction),
        .status     (op_status),
        .busy       (op_busy),
        .done       (op_done),
        .a_addr     (op_a_addr),
        .a_dout     (op_a_dout),
        .a_ren      (op_a_ren),
        .b_addr     (op_b_addr),
        .b_dout     (op_b_dout),
        .b_ren      (op_b_ren),
        .c_addr     (op_c_addr),
        .c_dout     (op_c_dout),
        .c_wen      (op_c_wen),
        .c_ren      (op_c_ren)
    );

    localparam int unsigned ELEMS_PER_STORE = MEM_WIDTH / 8;

    always_comb begin
        state_d = state_q;
        row_cnt_d = row_cnt_q;
        mat_sel_d = mat_sel_q;
        base_addr_d = base_addr_q;
        funct3_d = funct3_q;
        done_d = done_q;
        op_started_d = op_started_q;
        matadd_cnt_d = matadd_cnt_q;

        mem_req_o = 1'b0;
        mem_addr_o = 32'b0;
        mem_we_o = 1'b0;
        mem_be_o = '0;
        mem_wdata_o = '0;

        op_instruction = {4'hF, 28'b0};

        case (state_q)
            ST_IDLE: begin
                op_started_d = 1'b0;
                if (instr_valid_i && (can_accept || done_q) && legal_instr) begin
                    done_d = 1'b0;
                    base_addr_d = rs1_i;
                    mat_sel_d = rd_idx[1:0];
                    funct3_d = funct3;
                    row_cnt_d = 3'b0;

                    case (funct3)
                        FUNCT3_MVIN: begin
                            state_d = ST_LOAD_REQ;
                        end
                        FUNCT3_MVOUT: begin
                            row_cnt_d = 3'b0;
                            state_d = ST_STORE_REQ;
                        end
                        FUNCT3_MATMUL: begin
                            state_d = ST_OP_COMPUTE;
                        end
                        FUNCT3_MATADD: begin
                            matadd_cnt_d = 6'd0;
                            state_d = ST_MATADD;
                        end
                        default: ;
                    endcase
                end
            end

            ST_LOAD_REQ: begin
                mem_req_o = 1'b1;
                mem_addr_o = base_addr_q + {26'b0, row_cnt_q, 3'b0};
                mem_we_o = 1'b0;
                mem_be_o = '1;
                if (mem_gnt_i) begin
                    state_d = ST_LOAD_WAIT;
                end
            end

            ST_LOAD_WAIT: begin
                if (mem_rvalid_i) begin
                    if (row_cnt_q == MAT_DIM - 1) begin
                        row_cnt_d = 3'b0;
                        state_d = ST_OP_MVIN;
                    end else begin
                        row_cnt_d = row_cnt_q + 1;
                        state_d = ST_LOAD_REQ;
                    end
                end
            end

            ST_OP_MVIN: begin
                op_instruction = {4'd0, 4'h0, 2'b0, mat_sel_q[0] ? 6'd0 : 6'd32, 2'b0, 6'd0, 4'd8, 4'd8};
                op_started_d = 1'b1;
                if (op_busy || op_started_q) begin
                    state_d = ST_OP_MVIN_WAIT;
                end
            end

            ST_OP_MVIN_WAIT: begin
                op_instruction = {4'hF, 28'b0};
                if (op_done) begin
                    state_d = ST_DONE;
                end
            end

            ST_OP_COMPUTE: begin
                logic [3:0] op_code;
                if (funct3_q == FUNCT3_MATADD) begin
                    op_code = 4'd3;
                end else begin
                    op_code = 4'd2;
                end
                op_instruction = {op_code, 4'h0, 2'b0, 6'd0, 2'b0, 6'd0, 4'd8, 4'd8};
                op_started_d = 1'b1;
                if (op_busy || op_started_q) begin
                    state_d = ST_OP_COMPUTE_WAIT;
                end
            end

            ST_OP_COMPUTE_WAIT: begin
                op_instruction = {4'hF, 28'b0};
                if (op_done) begin
                    op_started_d = 1'b0;
                    state_d = ST_OP_MVOUT;
                end
            end

            ST_OP_MVOUT: begin
                op_instruction = {4'd1, 4'h0, 2'b0, 6'd0, 2'b0, 6'd0, 4'd8, 4'd8};
                op_started_d = 1'b1;
                if (op_busy || op_started_q) begin
                    state_d = ST_OP_MVOUT_WAIT;
                end
            end

            ST_OP_MVOUT_WAIT: begin
                op_instruction = {4'hF, 28'b0};
                if (op_done) begin
                    state_d = ST_DONE;
                end
            end

            ST_STORE_REQ: begin
                mem_req_o = 1'b1;
                mem_addr_o = base_addr_q + {26'b0, row_cnt_q, 3'b0};
                mem_we_o = 1'b1;
                mem_be_o = '1;
                for (int i = 0; i < ELEMS_PER_STORE && i < MAT_DIM; i++) begin
                    mem_wdata_o[i*8 +: 8] = sat8($signed(c_mem[{row_cnt_q, 3'(i)}]));
                end
                if (mem_gnt_i) begin
                    if (row_cnt_q == MAT_DIM - 1) begin
                        state_d = ST_DONE;
                    end else begin
                        row_cnt_d = row_cnt_q + 1;
                    end
                end
            end

            ST_STORE_WAIT: begin
                state_d = ST_STORE_REQ;
            end

            ST_MATADD: begin
                matadd_cnt_d = matadd_cnt_q + 1;
                if (matadd_cnt_q == 6'd63) begin
                    state_d = ST_DONE;
                end
            end

            ST_DONE: begin
                op_instruction = {4'hF, 28'b0};
                done_d = 1'b1;
                state_d = ST_IDLE;
            end

            default: state_d = ST_IDLE;
        endcase
    end

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (~rst_ni) begin
            state_q <= ST_IDLE;
            row_cnt_q <= '0;
            mat_sel_q <= '0;
            base_addr_q <= '0;
            funct3_q <= '0;
            done_q <= 1'b0;
            op_started_q <= 1'b0;
            matadd_cnt_q <= '0;
        end else begin
            state_q <= state_d;
            row_cnt_q <= row_cnt_d;
            mat_sel_q <= mat_sel_d;
            base_addr_q <= base_addr_d;
            funct3_q <= funct3_d;
            done_q <= done_d;
            op_started_q <= op_started_d;
            matadd_cnt_q <= matadd_cnt_d;

            if (state_q == ST_LOAD_WAIT && mem_rvalid_i) begin
                for (int i = 0; i < BYTES_PER_ACCESS && i < MAT_DIM; i++) begin
                    if (mat_sel_q[0]) begin
                        a_mem[{row_cnt_q, 3'(i)}] <= mem_rdata_i[i*8 +: 8];
                    end else begin
                        b_mem[{row_cnt_q, 3'(i)}] <= mem_rdata_i[i*8 +: 8];
                    end
                end
            end

            if (state_q == ST_MATADD) begin
                c_mem[matadd_cnt_q] <= $signed({{8{a_mem[matadd_cnt_q][7]}}, a_mem[matadd_cnt_q]}) +
                                       $signed({{8{b_mem[matadd_cnt_q][7]}}, b_mem[matadd_cnt_q]});
            end else if (op_c_wen) begin
                for (int j = 0; j < MAT_DIM; j++)
                    c_mem[{op_c_addr, 3'(j)}] <= op_c_dout[j*16 +: 16];
            end
        end
    end

    `ifdef DEBUG_OPMAT
    always_ff @(posedge clk_i) begin
        if (instr_valid_i && instr_gnt_o) begin
            $display("[OPMAT] t=%0t Accept funct3=%b rd=%d rs1=%h rs2=%h", $time, funct3, rd_idx, rs1_i, rs2_i);
        end
        if (state_q != state_d) begin
            $display("[OPMAT] t=%0t state: %s -> %s", $time, state_q.name(), state_d.name());
        end
    end
    `endif

endmodule
