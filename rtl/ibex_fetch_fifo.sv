// Copyright lowRISC contributors.
// Copyright 2018 ETH Zurich and University of Bologna, see also CREDITS.md.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

/**
 * Fetch Fifo for 32 bit memory interface
 *
 * input port: send address and data to the FIFO
 * clear_i clears the FIFO for the following cycle, including any new request
 */

`include "prim_assert.sv"

module ibex_fetch_fifo #(
  parameter int unsigned NUM_REQS = 2
) (
    input  logic                clk_i,
    input  logic                rst_ni,

    // control signals
    input  logic                clear_i,   // clears the contents of the FIFO
    output logic [NUM_REQS-1:0] busy_o,

    // input port
    input  logic                in_valid_i,
    input  logic [31:0]         in_addr_i,
    input  logic [31:0]         in_rdata_i,
    input  logic                in_err_i,

    // output port
    output logic                out_valid_o,
    input  logic                out_ready_i,
    output logic [31:0]         out_addr_o,
    output logic [31:0]         out_addr_next_o,
    output logic [31:0]         out_rdata_o,
    output logic                out_err_o,
    output logic                out_err_plus2_o
);

  localparam int unsigned DEPTH = NUM_REQS+1;

  // index 0 is used for output
  logic [DEPTH-1:0] [31:0]  rdata_d,   rdata_q;
  logic [DEPTH-1:0]         err_d,     err_q;
  logic [DEPTH-1:0]         valid_d,   valid_q;
  logic [DEPTH-1:0]         lowest_free_entry;
  logic [DEPTH-1:0]         valid_pushed, valid_popped;
  logic [DEPTH-1:0]         entry_en;

  logic                     pop_fifo;
  logic             [31:0]  rdata;
  logic                     err;
  logic                     valid;
  logic [31:1]              instr_addr_next;
  logic [31:1]              instr_addr_d, instr_addr_q;
  logic                     instr_addr_en;
  logic                     unused_addr_in;

  /////////////////
  // Output port //
  /////////////////

  assign rdata = valid_q[0] ? rdata_q[0] : in_rdata_i;
  assign err   = valid_q[0] ? err_q[0]   : in_err_i;
  assign valid = valid_q[0] | in_valid_i;

  // All instructions are 32-bit aligned (no compressed instruction support)
  // Output is always word-aligned data
  assign out_rdata_o     = rdata;
  assign out_err_o       = err;
  assign out_err_plus2_o = 1'b0;
  assign out_valid_o     = valid;

  /////////////////////////
  // Instruction address //
  /////////////////////////

  // Update the address on branches and every time an instruction is driven
  assign instr_addr_en = clear_i | (out_ready_i & out_valid_o);

  // All instructions are 32-bit, always increment by 4
  assign instr_addr_next = instr_addr_q[31:1] + 31'd2;

  assign instr_addr_d = clear_i ? in_addr_i[31:1] :
                                  instr_addr_next;

  always_ff @(posedge clk_i) begin
    if (instr_addr_en) begin
      instr_addr_q <= instr_addr_d;
    end
  end

  // Output both PC of current instruction and instruction following. PC of instruction following is
  // required for the branch predictor. It's used to fetch the instruction following a branch that
  // was not-taken but (mis)predicted taken.
  assign out_addr_next_o = {instr_addr_next, 1'b0};
  assign out_addr_o      = {instr_addr_q, 1'b0};

  // The LSB of the address is unused, since all addresses are halfword aligned
  assign unused_addr_in = in_addr_i[0];

  /////////////////
  // FIFO status //
  /////////////////

  // Indicate the fill level of fifo-entries. This is used to determine when a new request can be
  // made on the bus. The prefetch buffer only needs to know about the upper entries which overlap
  // with NUM_REQS.
  assign busy_o = valid_q[DEPTH-1:DEPTH-NUM_REQS];

  /////////////////////
  // FIFO management //
  /////////////////////

  // All instructions are 32-bit, always pop on ready
  assign pop_fifo = out_ready_i & out_valid_o;

  for (genvar i = 0; i < (DEPTH - 1); i++) begin : g_fifo_next
    // Calculate lowest free entry (write pointer)
    if (i == 0) begin : g_ent0
      assign lowest_free_entry[i] = ~valid_q[i];
    end else begin : g_ent_others
      assign lowest_free_entry[i] = ~valid_q[i] & valid_q[i-1];
    end

    // An entry is set when an incoming request chooses the lowest available entry
    assign valid_pushed[i] = (in_valid_i & lowest_free_entry[i]) |
                             valid_q[i];
    // Popping the FIFO shifts all entries down
    assign valid_popped[i] = pop_fifo ? valid_pushed[i+1] : valid_pushed[i];
    // All entries are wiped out on a clear
    assign valid_d[i] = valid_popped[i] & ~clear_i;

    // data flops are enabled if there is new data to shift into it, or
    assign entry_en[i] = (valid_pushed[i+1] & pop_fifo) |
                         // a new request is incoming and this is the lowest free entry
                         (in_valid_i & lowest_free_entry[i] & ~pop_fifo);

    // take the next entry or the incoming data
    assign rdata_d[i]  = valid_q[i+1] ? rdata_q[i+1] : in_rdata_i;
    assign err_d  [i]  = valid_q[i+1] ? err_q  [i+1] : in_err_i;
  end
  // The top entry is similar but with simpler muxing
  assign lowest_free_entry[DEPTH-1] = ~valid_q[DEPTH-1] & valid_q[DEPTH-2];
  assign valid_pushed     [DEPTH-1] = valid_q[DEPTH-1] | (in_valid_i & lowest_free_entry[DEPTH-1]);
  assign valid_popped     [DEPTH-1] = pop_fifo ? 1'b0 : valid_pushed[DEPTH-1];
  assign valid_d [DEPTH-1]          = valid_popped[DEPTH-1] & ~clear_i;
  assign entry_en[DEPTH-1]          = in_valid_i & lowest_free_entry[DEPTH-1];
  assign rdata_d [DEPTH-1]          = in_rdata_i;
  assign err_d   [DEPTH-1]          = in_err_i;

  ////////////////////
  // FIFO registers //
  ////////////////////

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      valid_q <= '0;
    end else begin
      valid_q <= valid_d;
    end
  end

  for (genvar i = 0; i < DEPTH; i++) begin : g_fifo_regs
    always_ff @(posedge clk_i) begin
      if (entry_en[i]) begin
        rdata_q[i]   <= rdata_d[i];
        err_q[i]     <= err_d[i];
      end
    end
  end

  ////////////////
  // Assertions //
  ////////////////

  // Must not push and pop simultaneously when FIFO full.
  `ASSERT(IbexFetchFifoPushPopFull,
      (in_valid_i && pop_fifo) |-> (!valid_q[DEPTH-1] || clear_i))

  // Must not push to FIFO when full.
  `ASSERT(IbexFetchFifoPushFull,
      (in_valid_i) |-> (!valid_q[DEPTH-1] || clear_i))

endmodule
