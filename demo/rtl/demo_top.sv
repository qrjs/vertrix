// Copyright TU Wien
// Licensed under the Solderpad Hardware License v2.1, see LICENSE.txt for details
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1


module demo_top #(
        parameter              RAM_FPATH      = "",
        parameter int unsigned RAM_SIZE       = 262144,
        parameter bit          DIFF_CLK       = 1'b0,
        parameter real         SYSCLK_PER     = 0.0,
        parameter int unsigned PLL_MUL        = 10,
        parameter int unsigned PLL_DIV        = 20,
        parameter int unsigned UART_BAUD_RATE = 115200
    )
    (
        input  logic sys_clk_pi,
        input  logic sys_clk_ni,
        input  logic sys_rst_ni,

        input  logic uart_rx_i,
        output logic uart_tx_o
    );


    localparam logic [31:0] MEM_START = 32'h00000000;
    localparam logic [31:0] MEM_MASK  = RAM_SIZE-1;


    logic sys_clk;
    generate
        if (DIFF_CLK) begin
            IBUFDS sysclkbuf (
                .I  ( sys_clk_pi ),
                .IB ( sys_clk_ni ),
                .O  ( sys_clk    )
            );
        end else begin
            assign sys_clk = sys_clk_pi;
        end
    endgenerate

    localparam int unsigned CLK_FREQ = (1_000_000_000.0 / SYSCLK_PER) * PLL_MUL / PLL_DIV;

    logic clk_raw, pll_lock, pll_fb;
    PLLE2_BASE #(
        .CLKIN1_PERIOD  ( SYSCLK_PER  ),
        .CLKFBOUT_MULT  ( PLL_MUL     ),
        .CLKOUT0_DIVIDE ( PLL_DIV     )
    ) pll_inst (
        .CLKIN1         ( sys_clk     ),
        .CLKOUT0        ( clk_raw     ),
        .CLKOUT1        (             ),
        .CLKOUT2        (             ),
        .CLKOUT3        (             ),
        .CLKOUT4        (             ),
        .CLKOUT5        (             ),
        .LOCKED         ( pll_lock    ),
        .PWRDWN         ( 1'b0        ),
        .RST            ( ~sys_rst_ni ),
        .CLKFBOUT       ( pll_fb      ),
        .CLKFBIN        ( pll_fb      )
    );
    logic clk;
    BUFG clkbuf (
        .I ( clk_raw ),
        .O ( clk     )
    );
    logic rst_n;
    assign rst_n = sys_rst_ni & pll_lock;

    // 指令内存接口
    logic        imem_req;
    logic [31:0] imem_addr;
    logic        imem_rvalid;
    logic        imem_err;
    logic [31:0] imem_rdata;

    // 数据内存接口
    logic        dmem_req;
    logic [31:0] dmem_addr;
    logic        dmem_we;
    logic  [3:0] dmem_be;
    logic [31:0] dmem_wdata;
    logic        dmem_rvalid;
    logic        dmem_err;
    logic [31:0] dmem_rdata;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            imem_rvalid <= 1'b0;
            dmem_rvalid <= 1'b0;
        end else begin
            imem_rvalid <= imem_req;
            dmem_rvalid <= dmem_req;
        end
    end

    vproc_top #(
        .MEM_W        ( 32                          ),
        .VMEM_W       ( 32                          ),
        .VREG_TYPE    ( vproc_pkg::VREG_XLNX_RAM32M ),
        .MUL_TYPE     ( vproc_pkg::MUL_XLNX_DSP48E1 )
    ) vproc (
        .clk_i              ( clk              ),
        .rst_ni             ( rst_n            ),
        // 指令内存端口
        .imem_req_o         ( imem_req         ),
        .imem_addr_o        ( imem_addr        ),
        .imem_rvalid_i      ( imem_rvalid      ),
        .imem_err_i         ( imem_err         ),
        .imem_rdata_i       ( imem_rdata       ),
        // 数据内存端口
        .dmem_req_o         ( dmem_req         ),
        .dmem_addr_o        ( dmem_addr        ),
        .dmem_we_o          ( dmem_we          ),
        .dmem_be_o          ( dmem_be          ),
        .dmem_wdata_o       ( dmem_wdata       ),
        .dmem_rvalid_i      ( dmem_rvalid      ),
        .dmem_err_i         ( dmem_err         ),
        .dmem_rdata_i       ( dmem_rdata       ),
        .pend_vreg_wr_map_o (                  )
    );

    logic        isram_rvalid;
    logic [31:0] isram_rdata;
    logic        dsram_rvalid;
    logic [31:0] dsram_rdata;
    logic        hwreg_rvalid;
    logic [31:0] hwreg_rdata;

    assign imem_err   = imem_rvalid & ~isram_rvalid;
    assign imem_rdata = isram_rdata;
    assign dmem_err   = dmem_rvalid & (~(dsram_rvalid | hwreg_rvalid));
    assign dmem_rdata = hwreg_rvalid ? hwreg_rdata : dsram_rdata;

    // 指令内存
    ram32 #(
        .SIZE      ( RAM_SIZE / 4                                     ),
        .INIT_FILE ( RAM_FPATH                                        )
    ) imem_ram (
        .clk_i     ( clk                                              ),
        .rst_ni    ( rst_n                                            ),
        .req_i     ( imem_req & ((imem_addr & ~MEM_MASK) == MEM_START)),
        .we_i      ( 1'b0                                             ),
        .be_i      ( 4'b1111                                          ),
        .addr_i    ( imem_addr                                        ),
        .wdata_i   ( 32'b0                                            ),
        .rvalid_o  ( isram_rvalid                                     ),
        .rdata_o   ( isram_rdata                                      )
    );

    // 数据内存
    ram32 #(
        .SIZE      ( RAM_SIZE / 4                                     ),
        .INIT_FILE ( RAM_FPATH                                        )
    ) dmem_ram (
        .clk_i     ( clk                                              ),
        .rst_ni    ( rst_n                                            ),
        .req_i     ( dmem_req & ((dmem_addr & ~MEM_MASK) == MEM_START)),
        .we_i      ( dmem_req & dmem_we                               ),
        .be_i      ( dmem_be                                          ),
        .addr_i    ( dmem_addr                                        ),
        .wdata_i   ( dmem_wdata                                       ),
        .rvalid_o  ( dsram_rvalid                                     ),
        .rdata_o   ( dsram_rdata                                      )
    );

    hwreg_iface #(
        .CLK_FREQ       ( CLK_FREQ                                 ),
        .UART_BAUD_RATE ( UART_BAUD_RATE                           )
    ) hwregs (
        .clk_i          ( clk                                      ),
        .rst_ni         ( rst_n                                    ),
        .req_i          ( dmem_req & (dmem_addr[31:16] == 16'hFF00)),
        .we_i           ( dmem_we                                  ),
        .addr_i         ( dmem_addr[15:0]                          ),
        .wdata_i        ( dmem_wdata                               ),
        .rvalid_o       ( hwreg_rvalid                             ),
        .rdata_o        ( hwreg_rdata                              ),
        .rx_i           ( uart_rx_i                                ),
        .tx_o           ( uart_tx_o                                )
    );

endmodule


module hwreg_iface #(
        parameter int unsigned CLK_FREQ       = 100_000_000,
        parameter int unsigned UART_BAUD_RATE = 115200
    )
    (
        input  logic          clk_i,
        input  logic          rst_ni,
        input  logic          req_i,
        input  logic          we_i,
        input  logic [15:0]   addr_i,
        input  logic [31:0]   wdata_i,
        output logic          rvalid_o,
        output logic [31:0]   rdata_o,

        input  logic          rx_i,
        output logic          tx_o
    );

    localparam logic [13:0] ADDR_UART_DATA   = 16'h0000 >> 2;
    localparam logic [13:0] ADDR_UART_STATUS = 16'h0004 >> 2;

    logic       uart_req;
    logic       uart_wbusy;
    logic       uart_rvalid;
    logic [7:0] uart_rdata;

    assign uart_req = req_i && addr_i[15:2] == ADDR_UART_DATA;

    uart_iface #(
        .CLK_FREQ       ( CLK_FREQ          ),
        .BAUD_RATE      ( UART_BAUD_RATE    )
    ) uart (
        .clk_i          ( clk_i             ),
        .rst_ni         ( rst_ni            ),
        .we_i           ( uart_req && we_i  ),
        .wdata_i        ( wdata_i[7:0]      ),
        .wbusy_o        ( uart_wbusy        ),
        .read_i         ( uart_req && !we_i ),
        .rvalid_o       ( uart_rvalid       ),
        .rdata_o        ( uart_rdata        ),

        .rx_i           ( rx_i              ),
        .tx_o           ( tx_o              )
    );

    logic [31:0] rdata;
    logic        rvalid;

    always_ff @(posedge clk_i) begin
        unique case (addr_i[15:2])
            ADDR_UART_DATA:   rdata <= uart_rvalid ? uart_rdata : 32'hFFFFFFFF;
            ADDR_UART_STATUS: rdata <= { 30'h0, uart_rvalid, uart_wbusy };

            default:          rdata <= 0;
        endcase
        rvalid <= req_i;
    end

    assign rdata_o  = rdata;
    assign rvalid_o = rvalid;
endmodule


module uart_iface #(
        parameter int unsigned CLK_FREQ  = 100_000_000,
        parameter int unsigned BAUD_RATE = 115200
    )
    (
        input  logic          clk_i,
        input  logic          rst_ni,

        input  logic          we_i,
        input  logic [7:0]    wdata_i,
        output logic          wbusy_o,
        input  logic          read_i,
        output logic          rvalid_o,
        output logic [7:0]    rdata_o,

        input  logic          rx_i,
        output logic          tx_o
    );

    localparam UART_RX_QUEUE_LEN = 8;

    logic tx_ready;
    uart_tx #(
        .DATA_WIDTH ( 8         ),
        .BAUD_RATE  ( BAUD_RATE ),
        .CLK_FREQ   ( CLK_FREQ  )
    ) tx_inst (
        .clk_i      ( clk_i     ),
        .rst_ni     ( rst_ni    ),
        .valid_i    ( we_i      ),
        .data_i     ( wdata_i   ),
        .ready_o    ( tx_ready  ),
        .tx_o       ( tx_o      )
    );
    assign wbusy_o = ~tx_ready;

    logic       rx_valid;
    logic [7:0] rx_data;
    uart_rx #(
        .DATA_WIDTH ( 8         ),
        .BAUD_RATE  ( BAUD_RATE ),
        .CLK_FREQ   ( CLK_FREQ  )
    ) rx_inst (
        .clk_i      ( clk_i     ),
        .rst_ni     ( rst_ni    ),
        .rx_i       ( rx_i      ),
        .ready_i    ( 1'b1      ),
        .valid_o    ( rx_valid  ),
        .data_o     ( rx_data   )
    );

    logic       rvalid [UART_RX_QUEUE_LEN-1:0] = '{default: 0};
    logic [7:0] rdata  [UART_RX_QUEUE_LEN-1:0] = '{default: 0};

    always_ff @(posedge clk_i) begin
        if (rvalid[0] == 0) begin
            for (int i = 0; i < UART_RX_QUEUE_LEN-1; i++) begin
                rvalid[i] <= rvalid[i+1];
                rdata [i] <= rdata [i+1];
            end
            rvalid[UART_RX_QUEUE_LEN-1] <= 0;
        end

        if (rx_valid) begin
            rvalid[UART_RX_QUEUE_LEN-1] <= 1;
            rdata [UART_RX_QUEUE_LEN-1] <= rx_data;
        end
        if (rvalid[0] && read_i)
            rvalid[0] <= 0;
    end

    assign rvalid_o = rvalid[0];
    assign rdata_o = rdata[0];
endmodule
