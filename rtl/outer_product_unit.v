module outer_product_unit #(
    parameter ARRAY_SIZE = 8,
    parameter DATA_WIDTH = 8,
    parameter ACC_WIDTH  = 16,
    parameter ADDR_WIDTH = 3
)(
    input  wire                        clk,
    input  wire                        rst_n,
    input  wire [31:0]                 instruction,
    output wire [31:0]                 status,
    output reg                         busy,
    output reg                         done,

    output wire [ADDR_WIDTH-1:0]       a_addr,
    input  wire [ARRAY_SIZE*DATA_WIDTH-1:0] a_dout,
    output wire                        a_ren,

    output wire [ADDR_WIDTH-1:0]       b_addr,
    input  wire [ARRAY_SIZE*DATA_WIDTH-1:0] b_dout,
    output wire                        b_ren,

    output wire [ADDR_WIDTH-1:0]       c_addr,
    output wire [ARRAY_SIZE*ACC_WIDTH-1:0]  c_dout,
    output wire                        c_wen,
    output wire                        c_ren
);

    localparam ROW_DATA_W = ARRAY_SIZE * DATA_WIDTH;
    localparam ROW_ACC_W  = ARRAY_SIZE * ACC_WIDTH;

    localparam OP_MVIN   = 4'd0;
    localparam OP_MVOUT  = 4'd1;
    localparam OP_MATMUL = 4'd2;
    localparam OP_MATADD = 4'd3;
    localparam OP_NOP    = 4'hF;
    localparam [ADDR_WIDTH-1:0] LAST_INDEX = ADDR_WIDTH'(ARRAY_SIZE - 1);

    wire [3:0] opcode_in    = instruction[31:28];
    wire       mvin_target  = instruction[21];

    reg [3:0] opcode;
    reg       mvin_sel;

    localparam [2:0] IDLE    = 3'd0,
                     MVIN    = 3'd1,
                     MVOUT   = 3'd2,
                     COMPUTE = 3'd3,
                     S_DONE  = 3'd5;

    reg [2:0] state, next_state;
    reg [ADDR_WIDTH-1:0] addr_counter;
    reg [ADDR_WIDTH-1:0] k_counter;
    reg [1:0] read_phase;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            opcode <= OP_NOP;
            mvin_sel <= 0;
        end else if (state == IDLE && opcode_in != OP_NOP) begin
            opcode <= opcode_in;
            mvin_sel <= mvin_target;
        end else if (state == S_DONE && opcode_in == OP_NOP) begin
            opcode <= OP_NOP;
        end
    end

    always @(*) begin
        next_state = state;
        case (state)
            IDLE: begin
                if (opcode_in == OP_MVIN) next_state = MVIN;
                else if (opcode_in == OP_MVOUT) next_state = MVOUT;
                else if (opcode_in == OP_MATMUL || opcode_in == OP_MATADD) next_state = COMPUTE;
            end
            MVIN:    if (addr_counter >= LAST_INDEX) next_state = S_DONE;
            MVOUT:   if (addr_counter >= LAST_INDEX) next_state = S_DONE;
            COMPUTE: if (k_counter >= LAST_INDEX && read_phase >= 2'd3) next_state = S_DONE;
            S_DONE:  if (opcode_in == OP_NOP) next_state = IDLE;
            default: next_state = IDLE;
        endcase
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) state <= IDLE;
        else        state <= next_state;
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            addr_counter <= 0;
            k_counter    <= 0;
            read_phase   <= 0;
        end else begin
            case (state)
                IDLE: begin
                    addr_counter <= 0;
                    k_counter    <= 0;
                    read_phase   <= 0;
                end
                MVIN, MVOUT: begin
                    if (addr_counter < LAST_INDEX)
                        addr_counter <= addr_counter + 1;
                end
                COMPUTE: begin
                    if (read_phase < 2'd3) begin
                        read_phase <= read_phase + 1;
                    end else begin
                        read_phase <= 0;
                        if (k_counter < LAST_INDEX)
                            k_counter <= k_counter + 1;
                    end
                end
                default: ;
            endcase
        end
    end

    // ===================== SRAM (row-wide) =====================
    wire [ROW_DATA_W-1:0] weight_sram_dout, input_sram_dout;
    reg  [ADDR_WIDTH-1:0] weight_sram_addr, input_sram_addr;

    wire weight_sram_wen = (state == MVIN && !mvin_sel);
    wire weight_sram_ren = (state == COMPUTE && read_phase == 2'd0);
    wire input_sram_wen  = (state == MVIN && mvin_sel);
    wire input_sram_ren  = (state == COMPUTE && read_phase == 2'd1);

    always @(*) begin
        weight_sram_addr = 0;
        input_sram_addr  = 0;
        if (state == MVIN) begin
            if (!mvin_sel) weight_sram_addr = addr_counter;
            else           input_sram_addr  = addr_counter;
        end else if (state == COMPUTE) begin
            weight_sram_addr = k_counter;
            input_sram_addr  = k_counter;
        end
    end

    sram #(.DEPTH(ARRAY_SIZE), .ADDR_WIDTH(ADDR_WIDTH), .DATA_WIDTH(ROW_DATA_W))
    weight_sram_inst (
        .clk(clk), .wen(weight_sram_wen), .ren(weight_sram_ren),
        .addr(weight_sram_addr), .din(a_dout), .dout(weight_sram_dout)
    );

    sram #(.DEPTH(ARRAY_SIZE), .ADDR_WIDTH(ADDR_WIDTH), .DATA_WIDTH(ROW_DATA_W))
    input_sram_inst (
        .clk(clk), .wen(input_sram_wen), .ren(input_sram_ren),
        .addr(input_sram_addr), .din(b_dout), .dout(input_sram_dout)
    );

    // ===================== External ports =====================
    assign a_addr = addr_counter;
    assign b_addr = addr_counter;
    assign a_ren  = (state == MVIN && !mvin_sel);
    assign b_ren  = (state == MVIN && mvin_sel);

    assign c_addr = addr_counter;
    assign c_wen  = (state == MVOUT);
    assign c_ren  = 1'b0;

    // ===================== PE Array =====================
    wire compute_ready = (state == COMPUTE && read_phase == 2'd2);
    wire acc_clear     = (state == COMPUTE && read_phase == 2'd1 && k_counter == 0);
    wire op_mode       = (opcode == OP_MATADD);

    wire [DATA_WIDTH-1:0] row_broadcast [0:ARRAY_SIZE-1];
    wire [DATA_WIDTH-1:0] col_broadcast [0:ARRAY_SIZE-1];

    genvar gi;
    generate
        for (gi = 0; gi < ARRAY_SIZE; gi = gi + 1) begin : gen_broadcast
            assign row_broadcast[gi] = compute_ready ? weight_sram_dout[gi*DATA_WIDTH +: DATA_WIDTH] : {DATA_WIDTH{1'b0}};
            assign col_broadcast[gi] = compute_ready ? input_sram_dout[gi*DATA_WIDTH +: DATA_WIDTH]  : {DATA_WIDTH{1'b0}};
        end
    endgenerate

    wire [ACC_WIDTH-1:0] result_array   [0:ARRAY_SIZE-1][0:ARRAY_SIZE-1];
    wire [ACC_WIDTH-1:0] cascade_in     [0:ARRAY_SIZE-1][0:ARRAY_SIZE-1];
    wire [ACC_WIDTH-1:0] acc_data_array [0:ARRAY_SIZE-1][0:ARRAY_SIZE-1];

    genvar gj;
    generate
        for (gi = 0; gi < ARRAY_SIZE; gi = gi + 1) begin : gen_zero_i
            for (gj = 0; gj < ARRAY_SIZE; gj = gj + 1) begin : gen_zero_j
                assign cascade_in[gi][gj]     = {ACC_WIDTH{1'b0}};
                assign acc_data_array[gi][gj]  = {ACC_WIDTH{1'b0}};
            end
        end
    endgenerate

    outer_product_array #(
        .ARRAY_SIZE(ARRAY_SIZE), .DATA_WIDTH(DATA_WIDTH), .ACC_WIDTH(ACC_WIDTH)
    ) array_inst (
        .clk(clk), .rst_n(rst_n), .en(1'b1),
        .op_mode(op_mode),
        .row_broadcast(row_broadcast), .row_valid(compute_ready),
        .col_broadcast(col_broadcast), .col_valid(compute_ready),
        .cascade_in(cascade_in), .cascade_in_valid(1'b0),
        .cascade_out(), .cascade_out_valid(),
        .acc_clear(acc_clear), .acc_load(1'b0), .acc_load_data(acc_data_array),
        .result_out(result_array), .result_valid()
    );

    // ===================== MVOUT data packing =====================
    reg [ROW_ACC_W-1:0] c_dout_packed;
    integer ci;
    always @(*) begin
        c_dout_packed = 0;
        for (ci = 0; ci < ARRAY_SIZE; ci = ci + 1)
            c_dout_packed[ci*ACC_WIDTH +: ACC_WIDTH] = result_array[addr_counter][ci];
    end
    assign c_dout = c_dout_packed;

    // ===================== Status =====================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            busy <= 0;
            done <= 0;
        end else begin
            busy <= (state != IDLE && state != S_DONE);
            done <= (state == S_DONE);
        end
    end

    assign status = {27'b0, state, 2'b10};

endmodule
