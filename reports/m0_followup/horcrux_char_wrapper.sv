// Timing/area characterisation harness for the whole HORCRUX coprocessor.
// Not part of the design.
//
// Why a wrapper is needed at all:
//   1. horcrux_top's ports are SystemVerilog interfaces (if_xif.coproc_*).
//      Vivado cannot elaborate a top-level module with interface ports, so the
//      if_xif instance has to live inside a wrapper.
//   2. The XIF is far too wide for the Z020's ~125 usable I/O (issue_req alone
//      is 3x32 rs + 32 instr + ...), so a flat-port top cannot be placed.
//
// Same trick as mt_char_wrapper: an LFSR drives every coprocessor input and a
// signature register collects every coprocessor output, leaving four real pins.
// Everything inside the DUT is then register-to-register and analysable by STA,
// and nothing is constant-propagated away (an LFSR output is not a constant to
// the tool, so the full Keccak / SPHINCS / multiplier datapath survives).

module horcrux_char_wrapper (
    input  logic clk,
    input  logic rst_n,
    input  logic serial_in,
    output logic serial_out
);

    // X_NUM_RS(3) matches crheepto_top.sv.tpl:116 -- the SoC's own instance.
    if_xif #(.X_NUM_RS(3), .X_ID_WIDTH(4)) xif ();

    logic [31:0] lfsr;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) lfsr <= 32'h1;
        else        lfsr <= {lfsr[30:0],
                             lfsr[31] ^ lfsr[21] ^ lfsr[1] ^ lfsr[0] ^ serial_in};
    end

    // CPU side of the XIF, registered so every DUT input path starts at a FF.
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            xif.compressed_valid    <= 1'b0;
            xif.compressed_req      <= '0;
            xif.issue_valid         <= 1'b0;
            xif.issue_req           <= '0;
            xif.commit_valid        <= 1'b0;
            xif.commit              <= '0;
            xif.mem_ready           <= 1'b0;
            xif.mem_resp            <= '0;
            xif.mem_result_valid    <= 1'b0;
            xif.mem_result          <= '0;
            xif.result_ready        <= 1'b0;
        end else begin
            xif.compressed_valid    <= lfsr[3];
            xif.compressed_req.instr<= lfsr[15:0];
            xif.compressed_req.mode <= lfsr[17:16];
            xif.compressed_req.id   <= lfsr[21:18];

            xif.issue_valid         <= lfsr[0];
            xif.issue_req.instr     <= lfsr;
            xif.issue_req.mode      <= lfsr[1:0];
            xif.issue_req.id        <= lfsr[7:4];
            xif.issue_req.rs[0]     <= lfsr;
            xif.issue_req.rs[1]     <= {lfsr[15:0], lfsr[31:16]};
            xif.issue_req.rs[2]     <= ~lfsr;
            xif.issue_req.rs_valid  <= 3'b111;
            xif.issue_req.ecs       <= lfsr[5:0];
            xif.issue_req.ecs_valid <= 1'b1;

            xif.commit_valid        <= lfsr[1];
            xif.commit.id           <= lfsr[11:8];
            xif.commit.commit_kill  <= lfsr[2];

            xif.mem_ready           <= lfsr[6];
            xif.mem_resp.exc        <= lfsr[7];
            xif.mem_resp.exccode    <= lfsr[13:8];
            xif.mem_resp.dbg        <= lfsr[14];

            xif.mem_result_valid    <= lfsr[9];
            xif.mem_result.id       <= lfsr[19:16];
            xif.mem_result.rdata    <= ~{lfsr[7:0], lfsr[31:8]};
            xif.mem_result.err      <= lfsr[20];
            xif.mem_result.dbg      <= lfsr[21];

            xif.result_ready        <= lfsr[10];
        end
    end

    horcrux_top dut (
        .clk_i             (clk),
        .rst_ni            (rst_n),
        .xif_compressed_if (xif),
        .xif_issue_if      (xif),
        .xif_commit_if     (xif),
        .xif_mem_if        (xif),
        .xif_mem_result_if (xif),
        .xif_result_if     (xif)
    );

    // Observe every non-constant coprocessor output so none of it is pruned.
    logic [31:0] obs;
    always_comb begin
        obs = xif.result.data
            ^ {27'd0, xif.result.rd}
            ^ {28'd0, xif.result.id}
            ^ {23'd0, xif.issue_resp}
            ^ {26'd0, xif.result.ecsdata}
            ^ {29'd0, xif.result.ecswe}
            ^ {26'd0, xif.result.exccode}
            ^ {27'd0, xif.result_valid, xif.issue_ready, xif.result.we,
                      xif.result.exc,   xif.result.err};
    end

    logic [31:0] sig;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) sig <= '0;
        else        sig <= sig ^ obs;
    end

    assign serial_out = ^sig;

endmodule
