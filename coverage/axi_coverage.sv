`include "uvm_macros.svh"
import uvm_pkg::*;
import axi_seq_item_pkg::*;

// ============================================================
// axi_coverage.sv
// Functional coverage for all three protocols
//
// Instantiated in env, subscribes to all master monitors
// One covergroup per protocol
// Cross coverage for burst x size x direction
//
// FIX: "bins edge" -- `edge` is a SystemVerilog keyword, which
//      made the whole file uncompilable (renamed to at_edge).
//      Coverage is now enabled in the env.
// ============================================================

class axi4lite_coverage extends uvm_subscriber #(axi4lite_seq_item);
    `uvm_component_utils(axi4lite_coverage)

    axi4lite_seq_item item;

    covergroup lite_cg;
        cp_dir: coverpoint item.direction {
            bins wr = {AXI_WRITE};
            bins rd = {AXI_READ};
        }
        cp_strb: coverpoint item.strb iff (item.direction == AXI_WRITE) {
            bins full        = {4'hF};
            bins byte0       = {4'h1};
            bins byte1       = {4'h2};
            bins byte2       = {4'h4};
            bins byte3       = {4'h8};
            bins two_bytes   = {4'h3, 4'h5, 4'h6, 4'h9, 4'hA, 4'hC};
            bins three_bytes = {4'h7, 4'hB, 4'hD, 4'hE};
        }
        cp_prot: coverpoint item.prot;
        cp_resp: coverpoint item.resp {
            bins okay   = {AXI_OKAY};
            bins slverr = {AXI_SLVERR};
            bins decerr = {AXI_DECERR};
        }
        // Address region coverage
        cp_region: coverpoint item.addr[31:16] {
            bins m00  = {16'h44A0};
            bins m01  = {16'h44A1};
            bins m02  = {16'h44A2};
            bins m03  = {16'h44A3};
            bins bram = {16'hC000};
            bins other = default;
        }
        cx_dir_resp:   cross cp_dir, cp_resp;
        cx_dir_region: cross cp_dir, cp_region;
    endgroup

    function new(string name, uvm_component parent);
        super.new(name, parent);
        lite_cg = new();
    endfunction

    function void write(axi4lite_seq_item t);
        item = t;
        lite_cg.sample();
    endfunction

endclass : axi4lite_coverage


class axi3_coverage extends uvm_subscriber #(axi3_seq_item);
    `uvm_component_utils(axi3_coverage)

    axi3_seq_item item;

    covergroup axi3_cg;
        cp_dir: coverpoint item.direction {
            bins wr = {AXI_WRITE};
            bins rd = {AXI_READ};
        }
        cp_burst: coverpoint item.burst {
            bins fixed = {AXI_FIXED};
            bins incr  = {AXI_INCR};
            bins wrap  = {AXI_WRAP};
        }
        cp_size: coverpoint item.size {
            bins byte_x = {3'b000};
            bins half_w = {3'b001};
            bins word   = {3'b010};
        }
        cp_len: coverpoint item.len {
            bins len1    = {4'h0};
            bins len2_4  = {[4'h1:4'h3]};
            bins len5_8  = {[4'h4:4'h7]};
            bins len9_16 = {[4'h8:4'hF]};
        }
        cp_lock: coverpoint item.lock {
            bins normal    = {2'b00};
            bins exclusive = {2'b01};
            bins locked    = {2'b10};
        }
        cp_resp: coverpoint item.bresp iff (item.direction == AXI_WRITE) {
            bins okay   = {AXI_OKAY};
            bins slverr = {AXI_SLVERR};
            bins decerr = {AXI_DECERR};
        }
        cp_region: coverpoint item.addr[31:16] {
            bins m00  = {16'h44A0};
            bins m01  = {16'h44A1};
            bins m02  = {16'h44A2};
            bins m03  = {16'h44A3};
            bins bram = {16'hC000};
            bins other = default;
        }
        // 4KB boundary proximity
        cp_4kb: coverpoint item.addr[11:0] {
            bins far     = {[12'h000:12'hEFF]};
            bins near    = {[12'hF00:12'hFEF]};
            bins at_edge = {[12'hFF0:12'hFFF]};
        }
        cx_burst_size: cross cp_burst, cp_size;
        cx_dir_burst:  cross cp_dir,   cp_burst;
        cx_dir_len:    cross cp_dir,   cp_len;
        cx_dir_region: cross cp_dir,   cp_region;
        cx_burst_4kb:  cross cp_burst, cp_4kb;
    endgroup

    function new(string name, uvm_component parent);
        super.new(name, parent);
        axi3_cg = new();
    endfunction

    function void write(axi3_seq_item t);
        item = t;
        axi3_cg.sample();
    endfunction

endclass : axi3_coverage


class axi4_coverage extends uvm_subscriber #(axi4_seq_item);
    `uvm_component_utils(axi4_coverage)

    axi4_seq_item item;

    covergroup axi4_cg;
        cp_dir: coverpoint item.direction {
            bins wr = {AXI_WRITE};
            bins rd = {AXI_READ};
        }
        cp_burst: coverpoint item.burst {
            bins fixed = {AXI_FIXED};
            bins incr  = {AXI_INCR};
            bins wrap  = {AXI_WRAP};
        }
        cp_size: coverpoint item.size {
            bins byte_x = {3'b000};
            bins half_w = {3'b001};
            bins word   = {3'b010};
        }
        cp_len: coverpoint item.len {
            bins len1      = {8'h0};
            bins len2_4    = {[8'h1:8'h3]};
            bins len5_16   = {[8'h4:8'hF]};
            bins len17_64  = {[8'h10:8'h3F]};
            bins len65_256 = {[8'h40:8'hFF]};
        }
        cp_lock: coverpoint item.lock {
            bins normal    = {1'b0};
            bins exclusive = {1'b1};
        }
        cp_resp: coverpoint item.bresp iff (item.direction == AXI_WRITE) {
            bins okay   = {AXI_OKAY};
            bins exokay = {AXI_EXOKAY};
            bins slverr = {AXI_SLVERR};
            bins decerr = {AXI_DECERR};
        }
        cp_qos: coverpoint item.qos {
            bins zero    = {4'h0};
            bins nonzero = {[4'h1:4'hF]};
        }
        cp_4kb: coverpoint item.addr[11:0] {
            bins far     = {[12'h000:12'hEFF]};
            bins near    = {[12'hF00:12'hFEF]};
            bins at_edge = {[12'hFF0:12'hFFF]};
        }
        cp_region: coverpoint item.addr[31:16] {
            bins m00  = {16'h44A0};
            bins m01  = {16'h44A1};
            bins m02  = {16'h44A2};
            bins m03  = {16'h44A3};
            bins bram = {16'hC000};
            bins other = default;
        }
        cx_burst_size: cross cp_burst, cp_size;
        cx_dir_burst:  cross cp_dir,   cp_burst;
        cx_dir_len:    cross cp_dir,   cp_len;
        cx_burst_4kb:  cross cp_burst, cp_4kb;
        cx_lock_resp:  cross cp_lock,  cp_resp;
        cx_dir_region: cross cp_dir,   cp_region;
    endgroup

    function new(string name, uvm_component parent);
        super.new(name, parent);
        axi4_cg = new();
    endfunction

    function void write(axi4_seq_item t);
        item = t;
        axi4_cg.sample();
    endfunction

endclass : axi4_coverage
