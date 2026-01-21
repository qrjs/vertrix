// Copyright TU Wien
// Licensed under the Solderpad Hardware License v2.1, see LICENSE.txt for details
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

    // Assert that only the main core does not attempt to offload a speculative instruction
    assert property (
        @(posedge clk_i)
        issue_valid_i |-> instr_state_q[issue_id_i] != INSTR_SPECULATIVE
    ) else begin
        $error("attempt to offload instruction ID %d, which is still speculative",
               issue_id_i);
    end

    // Assert that the main core does not commit a valid instruction that is not speculative
    assert property (
        @(posedge clk_i)
        commit_valid_i |-> (
            (instr_state_q[commit_id_i] != INSTR_COMMITTED) &
            (instr_state_q[commit_id_i] != INSTR_KILLED)
        )
    ) else begin
        $error("attempt to commit instruction ID %d, which already had a commit transaction",
               commit_id_i);
    end
