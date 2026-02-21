// Copyright TU Wien
// Licensed under the Solderpad Hardware License v2.1, see LICENSE.txt for details
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1


module vproc_result #(
        parameter int unsigned      XIF_ID_W       = 3,    // width in bits of instruction IDs
        parameter bit               DONT_CARE_ZERO = 1'b0  // initialize don't care values to zero
    )(
        input  logic                clk_i,
        input  logic                async_rst_ni,
        input  logic                sync_rst_ni,

        input  logic                result_empty_valid_i,
        input  logic [XIF_ID_W-1:0] result_empty_id_i,

        input  logic                instr_issue_valid_i,
        input  logic [XIF_ID_W-1:0] instr_issue_id_i,

        input  logic                result_lsu_valid_i,
        output logic                result_lsu_ready_o,
        input  logic [XIF_ID_W-1:0] result_lsu_id_i,
        input  logic                result_lsu_exc_i,
        input  logic [5:0]          result_lsu_exccode_i,

        input  logic                result_xreg_valid_i,
        output logic                result_xreg_ready_o,
        input  logic [XIF_ID_W-1:0] result_xreg_id_i,
        input  logic [4:0]          result_xreg_addr_i,
        input  logic [31:0]         result_xreg_data_i,

        `ifdef RISCV_ZVE32F
        input  logic                result_freg_i,
        output logic                result_freg_o,

        input logic                 fpu_res_acc,
        input logic [XIF_ID_W-1:0]  fpu_res_id,

        `endif

        input  logic                result_csr_valid_i,
        output logic                result_csr_ready_o,
        input  logic [XIF_ID_W-1:0] result_csr_id_i,
        input  logic [4:0]          result_csr_addr_i,
        input  logic                result_csr_delayed_i,
        input  logic [31:0]         result_csr_data_i,
        input  logic [31:0]         result_csr_data_delayed_i,

        input  logic                     commit_valid_i,
        input  logic [XIF_ID_W-1:0]     commit_id_i,
        input  logic                     commit_kill_i,
        output logic                     result_valid_o,
        input  logic                     result_ready_i,
        output logic [XIF_ID_W-1:0]     result_id_o,
        output logic [31:0]             result_data_o,
        output logic [4:0]              result_rd_o,
        output logic                     result_we_o,
        output logic                     result_exc_o,
        output logic [5:0]              result_exccode_o,
        output logic                     result_err_o,
        output logic                     result_dbg_o
    );

    // Total count of instruction IDs used by the extension interface
    localparam int unsigned XIF_ID_CNT = 1 << XIF_ID_W;

    // buffer IDs for which an empty result shall be generated
    logic [XIF_ID_CNT-1:0] instr_result_empty_q, instr_result_empty_d;

    // CSR result buffer
    logic                result_csr_valid_q,   result_csr_valid_d;
    logic [XIF_ID_W-1:0] result_csr_id_q,      result_csr_id_d;
    logic [4:0]          result_csr_addr_q,    result_csr_addr_d;
    logic                result_csr_delayed_q, result_csr_delayed_d;
    logic [31:0]         result_csr_data_q,    result_csr_data_d;

    // Per-ID LSU result buffer: always drain the FIFO queue into this buffer so
    // that LSU results can be served in next_id order without blocking the queue
    logic [XIF_ID_CNT-1:0] lsu_buf_valid_q, lsu_buf_valid_d;
    logic [XIF_ID_CNT-1:0] lsu_buf_exc_q,   lsu_buf_exc_d;
    logic [XIF_ID_CNT-1:0][5:0] lsu_buf_exccode_q, lsu_buf_exccode_d;

    always_ff @(posedge clk_i or negedge async_rst_ni) begin : vproc_result_buffer
        if (~async_rst_ni) begin
            instr_result_empty_q <= '0;
            result_csr_valid_q   <= 1'b0;
            lsu_buf_valid_q      <= '0;
        end
        else if (~sync_rst_ni) begin
            instr_result_empty_q <= '0;
            result_csr_valid_q   <= 1'b0;
            lsu_buf_valid_q      <= '0;
        end
        else begin
            instr_result_empty_q <= instr_result_empty_d;
            result_csr_valid_q   <= result_csr_valid_d;
            lsu_buf_valid_q      <= lsu_buf_valid_d;
        end
    end
    always_ff @(posedge clk_i) begin : vproc_result
        result_csr_id_q      <= result_csr_id_d;
        result_csr_addr_q    <= result_csr_addr_d;
        result_csr_delayed_q <= result_csr_delayed_d;
        result_csr_data_q    <= result_csr_data_d;
        lsu_buf_exc_q        <= lsu_buf_exc_d;
        lsu_buf_exccode_q    <= lsu_buf_exccode_d;
    end

    logic [XIF_ID_W-1:0] next_id_q, next_id_d;
    always_ff @(posedge clk_i or negedge async_rst_ni) begin : vproc_next_result_id
        if (~async_rst_ni) begin
            next_id_q <= '0;
        end
        else if (~sync_rst_ni) begin
            next_id_q <= '0;
        end
        else begin
            next_id_q <= next_id_d;
        end
    end



    typedef enum logic [2:0] {
        RESULT_SOURCE_EMPTY,
        RESULT_SOURCE_EMPTY_BUF,
        RESULT_SOURCE_LSU,
        RESULT_SOURCE_XREG,
        RESULT_SOURCE_CSR_BUF,
        RESULT_SOURCE_NONE
    } result_source_e;
    logic                result_source_hold_q, result_source_hold_d;
    result_source_e      result_source_q,      result_source_d;
    logic [XIF_ID_W-1:0] result_empty_id_q,    result_empty_id_d;
    always_ff @(posedge clk_i or negedge async_rst_ni) begin
        if (~async_rst_ni) begin
            result_source_hold_q <= 1'b0;
        end
        else if (~sync_rst_ni) begin
            result_source_hold_q <= 1'b0;
        end else begin
            result_source_hold_q <= result_source_hold_d;
        end
    end
    always_ff @(posedge clk_i) begin
        result_source_q   <= result_source_d;
        result_empty_id_q <= result_empty_id_d;
    end

    // whether an LSU result is available for next_id (buffered or arriving this cycle)
    logic lsu_result_avail;
    assign lsu_result_avail = lsu_buf_valid_q[next_id_q] |
                              (result_lsu_valid_i & (result_lsu_id_i == next_id_q));

    result_source_e      result_source;
    logic [XIF_ID_W-1:0] result_empty_id;
    always_comb begin
        result_source   = RESULT_SOURCE_NONE;
        result_empty_id = DONT_CARE_ZERO ? '0 : 'x;

        // LSU takes precedence when a result for next_id is available (buffered or direct)
        if (lsu_result_avail) begin
            result_source = RESULT_SOURCE_LSU;
        end
        // XREG goes second, only when ID matches
        else if (result_xreg_valid_i & (result_xreg_id_i == next_id_q)) begin
            result_source = RESULT_SOURCE_XREG;
        end
        // CSR goes third
        else if (result_csr_valid_q & (result_csr_id_q == next_id_q)) begin
            result_source = RESULT_SOURCE_CSR_BUF;
        end
        // buffered empty results follow
        else if (instr_result_empty_q != '0) begin
            result_source = RESULT_SOURCE_EMPTY_BUF;
        end
        // incoming empty result goes last (since it is always the most recent instruction)
        else if (result_empty_valid_i) begin
            result_source = RESULT_SOURCE_EMPTY;
        end

        // select the empty result ID: prefer next_id_q so we can advance in-order;
        // fall back to lowest set bit for buffering/holding purposes
        if (instr_result_empty_q[next_id_q]) begin
            result_empty_id = next_id_q;
        end else begin
            for (int i = 0; i < XIF_ID_CNT; i++) begin
                if (instr_result_empty_q[i]) begin
                    result_empty_id = XIF_ID_W'(i);
                    break;
                end
            end
        end

        // always keep the current result source during an ongoing result transaction; since the
        // ID for empty results is taken from a set, it must also be buffered to remain stable
        if (result_source_hold_q) begin
            result_source   = result_source_q;
            result_empty_id = result_empty_id_q;
        end
    end
    assign result_source_hold_d = result_valid_o & ~result_ready_i;
    always_comb begin
        result_source_d   = result_source;
        result_empty_id_d = result_empty_id;
        if (result_source == RESULT_SOURCE_EMPTY) begin
            result_source_d   = RESULT_SOURCE_EMPTY_BUF;
            result_empty_id_d = result_empty_id_i;
        end
    end

    always_comb begin
        instr_result_empty_d = instr_result_empty_q;
        result_csr_valid_d   = result_csr_valid_q;
        result_csr_id_d      = result_csr_id_q;
        result_csr_addr_d    = result_csr_addr_q;
        result_csr_delayed_d = result_csr_delayed_q;
        result_csr_data_d    = result_csr_data_q;
        lsu_buf_valid_d      = lsu_buf_valid_q;
        lsu_buf_exc_d        = lsu_buf_exc_q;
        lsu_buf_exccode_d    = lsu_buf_exccode_q;

        // for a delayed result the data is always available in the cycle after the result was
        // received, but if the interface is not ready to return that result yet, the data has to
        // be buffered as well
        if (result_csr_delayed_q) begin
            result_csr_delayed_d = 1'b0;
            result_csr_data_d    = result_csr_data_delayed_i;
        end

        if (result_source == RESULT_SOURCE_EMPTY_BUF) begin
            // clear the selected ID if the XIF interface is ready and instruction is next to be retired
            instr_result_empty_d[result_empty_id] = ~(result_ready_i &^ (result_empty_id == next_id_q));
        end
        if (result_source == RESULT_SOURCE_CSR_BUF) begin
            result_csr_valid_d = ~result_ready_i || !(result_csr_id_q == next_id_q);
        end

        // Always buffer incoming LSU results from the queue into the per-ID buffer
        if (result_lsu_valid_i) begin
            lsu_buf_valid_d[result_lsu_id_i]   = 1'b1;
            lsu_buf_exc_d[result_lsu_id_i]     = result_lsu_exc_i;
            lsu_buf_exccode_d[result_lsu_id_i] = result_lsu_exccode_i;
        end

        // Clear LSU buffer entry when result is served
        if (result_source == RESULT_SOURCE_LSU && result_ready_i) begin
            lsu_buf_valid_d[next_id_q] = 1'b0;
        end

        // instr ID is added to buffer if another result takes precedence or XIF iface is not ready or current instruction is not the next one to be retired
        if (result_empty_valid_i & ((result_source != RESULT_SOURCE_EMPTY) | ~result_ready_i | result_empty_id_i != next_id_q)) begin
            instr_result_empty_d[result_empty_id_i] = 1'b1;
        end
        // CSR result is always buffered
        if (result_csr_valid_i & result_csr_ready_o) begin
            result_csr_valid_d   = 1'b1;
            result_csr_id_d      = result_csr_id_i;
            result_csr_addr_d    = result_csr_addr_i;
            result_csr_delayed_d = result_csr_delayed_i;
            result_csr_data_d    = result_csr_data_i;
        end

        // clear stale buffer entries when instruction ID is recycled;
        // this MUST be the last assignment to instr_result_empty_d and lsu_buf_valid_d
        // so the clear overrides any buffering set for the same (recycled) ID in the same cycle
        if (instr_issue_valid_i) begin
            instr_result_empty_d[instr_issue_id_i] = 1'b0;
            lsu_buf_valid_d[instr_issue_id_i]      = 1'b0;
        end
    end

    // Always drain the LSU queue; results are buffered per-ID above
    assign result_lsu_ready_o  = 1'b1;
    assign result_xreg_ready_o =  (result_source == RESULT_SOURCE_XREG   ) & result_ready_i;
    assign result_csr_ready_o  = ((result_source == RESULT_SOURCE_CSR_BUF) & result_ready_i) | ~result_csr_valid_q;

    logic fpu_res_accepted;

    `ifdef RISCV_ZVE32F
    assign result_freg_o = result_xreg_ready_o & result_freg_i;
    assign fpu_res_accepted = fpu_res_acc;
    `else
    assign fpu_res_accepted = 1'b0;
    `endif


    always_comb begin
        next_id_d = next_id_q; //Possible for a ready result and killed commit at the same time?
        if ((result_valid_o && result_ready_i) || fpu_res_accepted || commit_kill_i && commit_valid_i) begin
            next_id_d = next_id_q + 1;
        end
    end


    always_comb begin
        result_valid_o   = '0;
        result_id_o      = DONT_CARE_ZERO ? '0 : 'x; // always set if result_valid = 1

        // note: the signals below are all '0 if not used to ensure that they remain stable during
        // a transaction
        result_data_o    = '0;
        result_rd_o      = '0;
        result_we_o      = '0;
        result_exc_o     = '0;
        result_exccode_o = '0;
        result_err_o     = '0;
        result_dbg_o     = '0;

        unique case (result_source)
            RESULT_SOURCE_EMPTY: begin
                result_valid_o = result_empty_id_i == next_id_q;
                result_id_o    = result_empty_id_i;
            end
            RESULT_SOURCE_EMPTY_BUF: begin
                result_valid_o = result_empty_id == next_id_q;
                result_id_o    = result_empty_id;
            end
            RESULT_SOURCE_LSU: begin
                result_valid_o   = 1'b1; // lsu_result_avail already ensures ID match
                result_id_o      = next_id_q;
                // serve from buffer if available, otherwise bypass from queue input
                if (lsu_buf_valid_q[next_id_q]) begin
                    result_exc_o     = lsu_buf_exc_q[next_id_q];
                    result_exccode_o = lsu_buf_exccode_q[next_id_q];
                end else begin
                    result_exc_o     = result_lsu_exc_i;
                    result_exccode_o = result_lsu_exccode_i;
                end
            end
            RESULT_SOURCE_XREG: begin
                result_valid_o = result_xreg_id_i == next_id_q;
                result_id_o    = result_xreg_id_i;
                result_data_o  = result_xreg_data_i;
                result_rd_o    = result_xreg_addr_i;
                result_we_o    = 1'b1;
            end
            RESULT_SOURCE_CSR_BUF: begin
                result_valid_o = result_csr_id_q == next_id_q;
                result_id_o    = result_csr_id_q;
                result_data_o  = result_csr_delayed_q ? result_csr_data_delayed_i : result_csr_data_q;
                result_rd_o    = result_csr_addr_q;
                result_we_o    = 1'b1;
            end
            default: ;
        endcase
    end


// synthesis translate_off
    always @(posedge clk_i) begin
        if (result_valid_o || result_lsu_valid_i || result_xreg_valid_i || result_empty_valid_i) begin
            $display("RESULT_DBG cyc=%0t next_id=%0d src=%0d valid=%b ready=%b we=%b id=%0d lsu_v=%b lsu_id=%0d lsu_buf=%08b empty_buf=%08b xreg_v=%b xreg_id=%0d",
                $time, next_id_q, result_source, result_valid_o, result_ready_i, result_we_o, result_id_o,
                result_lsu_valid_i, result_lsu_id_i, lsu_buf_valid_q, instr_result_empty_q,
                result_xreg_valid_i, result_xreg_id_i);
        end
    end
// synthesis translate_on

`ifdef VPROC_SVA
`include "vproc_result_sva.svh"
`endif

endmodule
