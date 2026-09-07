// Timing-characterisation harness for multiplier_tree. Not part of the design.
//
// Purpose: get genuine post-route numbers. OOC synthesis of multiplier_tree
// cannot be placed (a bare clock port gives [Place 30-188] UnBuffered IOs, see
// M0_FINDINGS.md), and the full SoC does not fit on the parts available. This
// wraps the DUT in registers and four real I/O so an ordinary non-OOC
// synth -> place -> route flow applies, leaving every DUT-internal path
// register-to-register and therefore analysable by STA.
//
// The LFSR feeds the operands so nothing is constant-propagated away, and it
// drives insn_i too so every opcode's datapath stays reachable.

module mt_char_wrapper (
    input  logic clk,
    input  logic rst_n,
    input  logic serial_in,
    output logic serial_out
);

    logic [31:0] lfsr;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) lfsr <= 32'h1;
        else        lfsr <= {lfsr[30:0],
                             lfsr[31] ^ lfsr[21] ^ lfsr[1] ^ lfsr[0] ^ serial_in};
    end

    logic [31:0] rs1_q, rs2_q, rs3_q;
    logic [ 6:0] insn_q;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rs1_q  <= '0;
            rs2_q  <= '0;
            rs3_q  <= '0;
            insn_q <= '0;
        end else begin
            rs1_q  <= lfsr;
            rs2_q  <= {lfsr[15:0], lfsr[31:16]};
            rs3_q  <= ~lfsr;
            insn_q <= lfsr[6:0];
        end
    end

    logic [31:0] res_lo, res_hi;
    multiplier_tree dut (
        .clk_i              (clk),
        .rst_ni             (rst_n),
        .multiplier_tree1_i (rs1_q),
        .multiplier_tree2_i (rs2_q),
        .multiplier_tree3_i (rs3_q),
        .insn_i             (horcrux_pkg::horcrux_insn'(insn_q)),
        .result_o           (res_lo),
        .result_hi_o        (res_hi)
    );

    logic [31:0] sig;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) sig <= '0;
        else        sig <= sig ^ res_lo ^ res_hi;
    end

    assign serial_out = ^sig;

endmodule
