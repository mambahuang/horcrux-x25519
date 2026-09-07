// Equivalence check: rewritten unified_mul_32x32 vs the original (unified_mul_ref).
// Both modes, directed corner cases + randomised vectors.

module tb_equiv;

    logic [31:0] a, b;
    logic        cl;
    logic [63:0] p_new, p_ref;

    int errors = 0;
    int checks = 0;

    unified_mul_32x32 u_new (.a_i(a), .b_i(b), .carryless_mode_i(cl), .prod_o(p_new));
    unified_mul_ref   u_ref (.a_i(a), .b_i(b), .carryless_mode_i(cl), .prod_o(p_ref));

    task automatic check(input logic [31:0] va, input logic [31:0] vb, input logic vcl);
        a = va; b = vb; cl = vcl;
        #1;
        checks++;
        if (p_new !== p_ref) begin
            errors++;
            if (errors <= 20)
                $display("MISMATCH cl=%b a=%08h b=%08h : new=%016h ref=%016h",
                         vcl, va, vb, p_new, p_ref);
        end
    endtask

    // Independent golden model for the integer path, to catch the case where
    // both implementations agree but are both wrong about signedness.
    task automatic check_signed_golden(input logic [31:0] va, input logic [31:0] vb);
        logic signed [63:0] golden;
        a = va; b = vb; cl = 1'b0;
        #1;
        checks++;
        golden = $signed(va) * $signed(vb);
        if (p_ref !== golden) begin
            errors++;
            if (errors <= 20)
                $display("REF-vs-GOLDEN MISMATCH a=%08h b=%08h : ref=%016h golden=%016h",
                         va, vb, p_ref, golden);
        end
    endtask

    logic [31:0] corners [] = '{
        32'h00000000, 32'h00000001, 32'h00000002, 32'h7FFFFFFF,
        32'h80000000, 32'h80000001, 32'hFFFFFFFF, 32'hFFFFFFFE,
        32'h0000FFFF, 32'hFFFF0000, 32'hAAAAAAAA, 32'h55555555,
        32'h00010001, 32'h0D01FFFF, 32'h00000D01, 32'h7FFFFFFE
    };

    initial begin
        // Directed: full cross product of corner cases, both modes.
        foreach (corners[i])
            foreach (corners[j]) begin
                check(corners[i], corners[j], 1'b0);
                check(corners[i], corners[j], 1'b1);
                check_signed_golden(corners[i], corners[j]);
            end

        // Single-bit operands: exercises each partial-product rank in isolation.
        for (int i = 0; i < 32; i++)
            for (int j = 0; j < 32; j++) begin
                check(32'h1 << i, 32'h1 << j, 1'b0);
                check(32'h1 << i, 32'h1 << j, 1'b1);
            end

        // Randomised.
        for (int i = 0; i < 50000; i++) begin
            logic [31:0] ra, rb;
            ra = $urandom;
            rb = $urandom;
            check(ra, rb, 1'b0);
            check(ra, rb, 1'b1);
            check_signed_golden(ra, rb);
        end

        $display("--------------------------------------------------");
        if (errors == 0)
            $display("EQUIVALENCE PASS  (%0d checks, 0 mismatches)", checks);
        else
            $display("EQUIVALENCE FAIL  (%0d checks, %0d mismatches)", checks, errors);
        $display("--------------------------------------------------");
        $finish;
    end

endmodule
