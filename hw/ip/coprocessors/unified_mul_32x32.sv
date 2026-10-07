//////////////////////////////////////////////////////////////////////////////////////////
// Copyright 2025 PoliTO - EDGE Group, @VLSI Lab                                        //
// Solderpad Hardware License, Version 2.1, see LICENSE.md for details.                 //
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1                                     //
//                                                                                      //
// Authors:      Alessandra Dolmeta - alessandra.dolmeta@polito.it                      //
//               Valeria Piscopo    - valeria.piscopo@polito.it                         //
// Design Name:  Unified 32x32 Multiplier                                               //
// Language:     SystemVerilog                                                          //
// Date:         April 2026                                                             //
//                                                                                      //
// Description:  Dual-mode 32x32 multiplier, core of the Shared Multiplication Logic.   //
//               Switches between carry-propagating integer multiplication (lattice     //
//               schemes) and carry-free GF(2) accumulation (HQC) via carryless_mode_i. //
//////////////////////////////////////////////////////////////////////////////////////////

module unified_mul_32x32 (
    input  logic [31:0] a_i,
    input  logic [31:0] b_i,
    input  logic        carryless_mode_i, 
    output logic [63:0] prod_o
);
    // The two modes are kept as independent expressions. Muxing them inside a
    // single shared accumulate loop prevents the synthesiser from recognising
    // the integer branch as a multiply, which forces the whole 32x32 into a
    // LUT/CARRY4 ripple chain instead of DSP48E1s.
    logic signed [63:0] int_prod;
    assign int_prod = $signed(a_i) * $signed(b_i);

    logic [63:0] cl_prod;
    always_comb begin
        cl_prod = '0;
        for (int i = 0; i < 32; i++) begin
            if (a_i[i]) cl_prod ^= ({32'b0, b_i} << i);
        end
    end

    assign prod_o = carryless_mode_i ? cl_prod : int_prod;
endmodule
