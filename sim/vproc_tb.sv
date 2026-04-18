// Copyright TU Wien
// Licensed under the Solderpad Hardware License v2.1, see LICENSE.txt for details
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1


module vproc_tb #(
        parameter              PROG_PATHS_LIST = "",
        parameter int unsigned MEM_W           = 32,
        parameter int unsigned MEM_SZ          = 262144,
        parameter int unsigned MEM_LATENCY     = 1,
        parameter int unsigned VMEM_W          = 32,
        parameter bit          WRITEBACK_STAGE = 1'b0,
        parameter int unsigned ICACHE_SZ       = 0,   // instruction cache size in bytes
        parameter int unsigned ICACHE_LINE_W   = 128, // instruction cache line width in bits
        parameter int unsigned DCACHE_SZ       = 0,   // data cache size in bytes
        parameter int unsigned DCACHE_LINE_W   = 512  // data cache line width in bits
    );

    logic clk, rst;
    always begin
        clk = 1'b0;
        #5;
        clk = 1'b1;
        #5;
    end

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
    logic [3:0]  dmem_be;
    logic [31:0] dmem_wdata;
    logic        dmem_rvalid;
    logic        dmem_err;
    logic [31:0] dmem_rdata;

    vproc_top #(
        .MEM_W         ( MEM_W                       ),
        .VMEM_W        ( VMEM_W                      ),
        .VREG_TYPE     ( vproc_pkg::VREG_XLNX_RAM32M ),
        .MUL_TYPE      ( vproc_pkg::MUL_XLNX_DSP48E1 ),
        .WritebackStage( WRITEBACK_STAGE             ),
        .ICACHE_SZ     ( ICACHE_SZ                   ),
        .ICACHE_LINE_W ( ICACHE_LINE_W               ),
        .DCACHE_SZ     ( DCACHE_SZ                   ),
        .DCACHE_LINE_W ( DCACHE_LINE_W               )
    ) top (
        .clk_i              ( clk                         ),
        .rst_ni             ( ~rst                        ),
        // 指令内存端口
        .imem_req_o         ( imem_req                    ),
        .imem_addr_o        ( imem_addr                   ),
        .imem_rvalid_i      ( imem_rvalid                 ),
        .imem_err_i         ( imem_err                    ),
        .imem_rdata_i       ( imem_rdata                  ),
        // 数据内存端口
        .dmem_req_o         ( dmem_req                    ),
        .dmem_addr_o        ( dmem_addr                   ),
        .dmem_we_o          ( dmem_we                     ),
        .dmem_be_o          ( dmem_be                     ),
        .dmem_wdata_o       ( dmem_wdata                  ),
        .dmem_rvalid_i      ( dmem_rvalid                 ),
        .dmem_err_i         ( dmem_err                    ),
        .dmem_rdata_i       ( dmem_rdata                  ),
        .pend_vreg_wr_map_o (                             )
    );

    // 共享物理内存（但有独立的指令和数据端口）
    logic [MEM_W-1:0]                    mem[MEM_SZ/(MEM_W/8)];
    
    // 指令内存访问
    logic [$clog2(MEM_SZ/(MEM_W/8))-1:0] imem_idx;
    assign imem_idx = imem_addr[$clog2(MEM_SZ)-1 : $clog2(MEM_W/8)];
    logic        imem_rvalid_queue[MEM_LATENCY];
    logic [31:0] imem_rdata_queue [MEM_LATENCY];
    logic        imem_err_queue   [MEM_LATENCY];
    
    // 数据内存访问
    logic [$clog2(MEM_SZ/(MEM_W/8))-1:0] dmem_idx;
    assign dmem_idx = dmem_addr[$clog2(MEM_SZ)-1 : $clog2(MEM_W/8)];
    logic        dmem_rvalid_queue[MEM_LATENCY];
    logic [31:0] dmem_rdata_queue [MEM_LATENCY];
    logic        dmem_err_queue   [MEM_LATENCY];
    
    always_ff @(posedge clk) begin
        // 数据写入
        if (dmem_req & dmem_we) begin
            for (int i = 0; i < MEM_W/8; i++) begin
                if (dmem_be[i]) begin
                    mem[dmem_idx][i*8 +: 8] <= dmem_wdata[i*8 +: 8];
                end
            end
        end
        
        // 指令内存延迟流水线
        for (int i = 1; i < MEM_LATENCY; i++) begin
            if (i == 1) begin
                imem_rvalid_queue[i] <= imem_req;
                imem_rdata_queue [i] <= mem[imem_idx];
                imem_err_queue   [i] <= imem_addr[31:$clog2(MEM_SZ)] != '0;
            end else begin
                imem_rvalid_queue[i] <= imem_rvalid_queue[i-1];
                imem_rdata_queue [i] <= imem_rdata_queue [i-1];
                imem_err_queue   [i] <= imem_err_queue   [i-1];
            end
        end
        
        // 数据内存延迟流水线
        for (int i = 1; i < MEM_LATENCY; i++) begin
            if (i == 1) begin
                dmem_rvalid_queue[i] <= dmem_req;
                dmem_rdata_queue [i] <= mem[dmem_idx];
                dmem_err_queue   [i] <= dmem_addr[31:$clog2(MEM_SZ)] != '0;
            end else begin
                dmem_rvalid_queue[i] <= dmem_rvalid_queue[i-1];
                dmem_rdata_queue [i] <= dmem_rdata_queue [i-1];
                dmem_err_queue   [i] <= dmem_err_queue   [i-1];
            end
        end
        
        // 指令内存输出
        if ((MEM_LATENCY) == 1) begin
            imem_rvalid <= imem_req;
            imem_rdata  <= mem[imem_idx];
            imem_err    <= imem_addr[31:$clog2(MEM_SZ)] != '0;
        end else begin
            imem_rvalid <= imem_rvalid_queue[MEM_LATENCY-1];
            imem_rdata  <= imem_rdata_queue [MEM_LATENCY-1];
            imem_err    <= imem_err_queue   [MEM_LATENCY-1];
        end
        
        // 数据内存输出
        if ((MEM_LATENCY) == 1) begin
            dmem_rvalid <= dmem_req;
            dmem_rdata  <= mem[dmem_idx];
            dmem_err    <= dmem_addr[31:$clog2(MEM_SZ)] != '0;
        end else begin
            dmem_rvalid <= dmem_rvalid_queue[MEM_LATENCY-1];
            dmem_rdata  <= dmem_rdata_queue [MEM_LATENCY-1];
            dmem_err    <= dmem_err_queue   [MEM_LATENCY-1];
        end
        
        // 初始化内存
        for (int i = 0; i < MEM_SZ; i++) begin
            // set the don't care values in the memory to 0 during the first rising edge
            if ($isunknown(mem[i]) & ($time < 10)) begin
                mem[i] <= '0;
            end
        end
    end

    logic prog_end, done;
    assign prog_end = mem_req & (mem_addr == '0);

    integer fd1, fd2, cnt, ref_start, ref_end, dump_start, dump_end;
    string  line, prog_path, ref_path, dump_path;
    initial begin
        done = 1'b0;

        fd1 = $fopen(PROG_PATHS_LIST, "r");
        for (int i = 0; !$feof(fd1); i++) begin
            rst = 1'b1;

            $fgets(line, fd1);

            ref_path   = "/dev/null";
            ref_start  = 0;
            ref_end    = 0;
            dump_path  = "/dev/null";
            dump_start = 0;
            dump_end   = 0;
            cnt = $sscanf(line, "%s %s %x %x %s %x %x", prog_path, ref_path, ref_start, ref_end, dump_path, dump_start, dump_end);

            // continue with next line in case of an empty line (cnt == 0) or an EOF (cnt == -1)
            if (cnt < 1) begin
                continue;
            end

            $readmemh(prog_path, mem);

            fd2 = $fopen(ref_path, "w");
            for (int j = ref_start / (MEM_W/8); j < ref_end / (MEM_W/8); j++) begin
                for (int k = 0; k < MEM_W/32; k++) begin
                    $fwrite(fd2, "%x\n", mem[j][k*32 +: 32]);
                end
            end
            $fclose(fd2);

            // reset for 10 cycles
            #100
            rst = 1'b0;

            // wait for completion (i.e. request of instr mem addr 0x00000000)
            //@(posedge prog_end);
            while (1) begin
                @(posedge clk);
                if (prog_end) begin
                    break;
                end
            end

            fd2 = $fopen(dump_path, "w");
            for (int j = dump_start / (MEM_W/8); j < dump_end / (MEM_W/8); j++) begin
                for (int k = 0; k < MEM_W/32; k++) begin
                    $fwrite(fd2, "%x\n", mem[j][k*32 +: 32]);
                end
            end
            $fclose(fd2);
        end
        $fclose(fd1);
        done = 1'b1;
    end

endmodule
