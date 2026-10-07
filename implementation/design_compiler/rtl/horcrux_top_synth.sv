//////////////////////////////////////////////////////////////////////////////////////////
// Design Name:  HORCRUX coprocessor ASIC synthesis wrapper
// Language:     SystemVerilog
//
// Description:  Flat-port wrapper around `horcrux_top`.
//
//               `horcrux_top` exposes the CORE-V XIF as SystemVerilog interface
//               modports (`if_xif.coproc_*`). Design Compiler elaborates interfaces
//               that are *internal* to the design, but it cannot accept an interface
//               on the top-level boundary. This wrapper instantiates the `if_xif`
//               interface locally and re-exposes every signal as an ordinary packed
//               port, so `horcrux_top_synth` can be used as the synthesis top.
//
//               The port structs come from `cv32e40px_core_v_xif_pkg`, which declares
//               types bit-identical to those inside `if_xif` when the interface is
//               parameterised with X_NUM_RS = 3 (the value used by crheepto_top,
//               see hw/ip/crheepto_top.sv.tpl).
//
//               This file adds no logic: it is a pure boundary adapter, so the area
//               and timing reported for `horcrux_top_synth` are those of
//               `horcrux_top` itself.
//////////////////////////////////////////////////////////////////////////////////////////

module horcrux_top_synth
  import cv32e40px_core_v_xif_pkg::*;
(
  input  logic               clk_i,
  input  logic               rst_ni,

  // Compressed interface (tied off inside horcrux_top, kept for boundary fidelity)
  input  logic               compressed_valid_i,
  output logic               compressed_ready_o,
  input  x_compressed_req_t  compressed_req_i,
  output x_compressed_resp_t compressed_resp_o,

  // Issue interface
  input  logic               issue_valid_i,
  output logic               issue_ready_o,
  input  x_issue_req_t       issue_req_i,
  output x_issue_resp_t      issue_resp_o,

  // Commit interface
  input  logic               commit_valid_i,
  input  x_commit_t          commit_i,

  // Memory interface (tied off inside horcrux_top)
  output logic               mem_valid_o,
  input  logic               mem_ready_i,
  output x_mem_req_t         mem_req_o,
  input  x_mem_resp_t        mem_resp_i,

  // Memory result interface
  input  logic               mem_result_valid_i,
  input  x_mem_result_t      mem_result_i,

  // Result interface
  output logic               result_valid_o,
  input  logic               result_ready_i,
  output x_result_t          result_o
);

  if_xif #(.X_NUM_RS(3)) xif ();

  // ---- Core -> coprocessor -------------------------------------------------
  assign xif.compressed_valid = compressed_valid_i;
  assign xif.compressed_req   = compressed_req_i;
  assign xif.issue_valid      = issue_valid_i;
  assign xif.issue_req        = issue_req_i;
  assign xif.commit_valid     = commit_valid_i;
  assign xif.commit           = commit_i;
  assign xif.mem_ready        = mem_ready_i;
  assign xif.mem_resp         = mem_resp_i;
  assign xif.mem_result_valid = mem_result_valid_i;
  assign xif.mem_result       = mem_result_i;
  assign xif.result_ready     = result_ready_i;

  // ---- Coprocessor -> core -------------------------------------------------
  assign compressed_ready_o = xif.compressed_ready;
  assign compressed_resp_o  = xif.compressed_resp;
  assign issue_ready_o      = xif.issue_ready;
  assign issue_resp_o       = xif.issue_resp;
  assign mem_valid_o        = xif.mem_valid;
  assign mem_req_o          = xif.mem_req;
  assign result_valid_o     = xif.result_valid;
  assign result_o           = xif.result;

  horcrux_top i_horcrux_top (
    .clk_i             (clk_i),
    .rst_ni            (rst_ni),
    .xif_compressed_if (xif),
    .xif_issue_if      (xif),
    .xif_commit_if     (xif),
    .xif_mem_if        (xif),
    .xif_mem_result_if (xif),
    .xif_result_if     (xif)
  );

endmodule
