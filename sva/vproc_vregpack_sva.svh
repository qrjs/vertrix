// Copyright TU Wien
// Licensed under the Solderpad Hardware License v2.1, see LICENSE.txt for details
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

    // INSTR_KILLED entries must never produce a register write.
    assert property (
        @(posedge clk_i)
        (stage_valid_q && instr_state_i[stage_state_q.instr_id] == INSTR_KILLED)
        |-> (!vreg_wr_valid_o)
    ) else begin
        $error("INSTR_KILLED entry at pack stage produced a register write");
    end
