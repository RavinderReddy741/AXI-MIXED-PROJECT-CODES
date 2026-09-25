`include "uvm_macros.svh"
import uvm_pkg::*;
import axi_seq_item_pkg::*;

// ============================================================
// sb_beat.sv
// Scoreboard support types. MUST be compiled BEFORE
// axi_scoreboard.sv (it declares the analysis imp classes).
//
// DUT topology:
//   S00 (AXI4-Lite) -+
//   S01 (AXI3)      -+- axi_interconnect_0 --- M00 (AXI4-Lite)
//   S02 (AXI4)      -+                      +- M01 (AXI3)
//                                           +- M02 (AXI4)
//                                           +- M03 (AXI4)
//                                           +- M04 (AXI4 -> BRAM, internal)
// ============================================================

// -- Analysis imp macros -- OUTSIDE the class ---------------
`uvm_analysis_imp_decl(_s00_lite)
`uvm_analysis_imp_decl(_s01_axi3)
`uvm_analysis_imp_decl(_s02_axi4)
`uvm_analysis_imp_decl(_m00_lite)
`uvm_analysis_imp_decl(_m01_axi3)
`uvm_analysis_imp_decl(_m02_axi4)
`uvm_analysis_imp_decl(_m03_axi4)

// -- Protocol enum ------------------------------------------
typedef enum int {
    SB_LITE = 0,
    SB_AXI3 = 1,
    SB_AXI4 = 2
} sb_proto_e;

// ============================================================
// SB_BEAT -- normalised scoreboard beat
//
// Every AXI transaction is broken into individual beats.
// All protocols use the same beat object.
//
// strb : writes -> WSTRB of the beat
//        reads  -> byte lanes that must be compared
// ============================================================
class sb_beat extends uvm_object;
    `uvm_object_utils(sb_beat)

    // -- Routing -------------------------------------------
    int          source_port;       // 0=S00, 1=S01, 2=S02
    int          dest_port;         // 0=M00 .. 3=M03, 4=M04(BRAM)
    sb_proto_e   source_proto;
    sb_proto_e   dest_proto;

    // -- Transaction ---------------------------------------
    bit          is_write;
    logic [31:0] addr;
    logic [31:0] data;
    logic [3:0]  strb;

    // -- Burst position ------------------------------------
    int unsigned beat_num;
    int unsigned total_beats;

    // -- Response ------------------------------------------
    logic [1:0]  resp;

    function new(string name = "sb_beat");
        super.new(name);
    endfunction

    function string convert2string();
        return $sformatf(
            "SRC=S%0d DST=M%0d PROTO=%s DIR=%s ADDR=0x%08h DATA=0x%08h STRB=0x%h BEAT=%0d/%0d RESP=%02b",
            source_port, dest_port,
            dest_proto.name(),
            is_write ? "WR" : "RD",
            addr, data, strb,
            beat_num, total_beats,
            resp);
    endfunction

endclass : sb_beat
