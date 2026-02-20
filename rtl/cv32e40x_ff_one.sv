module cv32e40x_ff_one (
    input  logic [31:0] in_i,
    output logic [4:0]  first_one_o,
    output logic        no_ones_o
);

    always_comb begin
        first_one_o = '0;
        no_ones_o   = 1'b1;
        for (int i = 0; i < 32; i++) begin
            if (in_i[i]) begin
                first_one_o = 5'(i);
                no_ones_o   = 1'b0;
                break;
            end
        end
    end

endmodule
