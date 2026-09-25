// ============================================================
// tb_top.sv
// Top-level Testbench Module
// Tool      : VCS V-2023.12-SP2-5 + UVM-1.1d
// Project   : AXI Mixed-Protocol Interconnect Verification
// ============================================================
// DUT TOPOLOGY (Vivado Block Design):
//
//   S00_AXI_0 (AXI4-Lite) -+                 +- M00 (AXI4-Lite)
//   S01_AXI_0 (AXI3)      -+- interconnect --+- M01 (AXI3)
//   S02_AXI_0 (AXI4)      -+                 +- M02 (AXI4)
//                                            +- M03 (AXI4)
//                                            +- M04 (AXI4 -> BRAM, internal)
//
//   DUT SLAVE  ports S00/S01/S02  --> MASTER AGENTS drive
//   DUT MASTER ports M00-M03      --> SLAVE  AGENTS respond
//   M04/BRAM is inside the BD: no interface, no agent. It is
//   checked end-to-end by the scoreboard (S-side RDATA vs ref_mem).
//
// ADDRESS MAP:
//   M00 : 0x44A0_0000 - 0x44A0_FFFF  AXI4-Lite
//   M01 : 0x44A1_0000 - 0x44A1_FFFF  AXI3
//   M02 : 0x44A2_0000 - 0x44A2_FFFF  AXI4
//   M03 : 0x44A3_0000 - 0x44A3_FFFF  AXI4
//   M04 : 0xC000_0000 - 0xC000_1FFF  AXI4 -> BRAM (internal)
//
// Clock  : clk_100MHz  -- 100 MHz (10 ns period)
// Reset  : reset_rtl_0 -- active-low, 20 cycles
//
// FIXES:
//   - S01 ID width adapter (S01_ID_W). axi3_if is 4-bit wide so it
//     can carry the extended {slot,id} on M01; the 2-bit S01 port
//     is connected to the low bits. Previously axi3_if was 2-bit
//     and M01 lost the slot bits -> responses routed to the wrong
//     S-port. CHECK THE VCS ELAB LOG FOR "PCWM" (port connection
//     width mismatch) WARNINGS: every one of them is a real bug.
//   - Reset released on the FALLING clock edge (no race with the
//     DUT flops / agents sampling on the rising edge)
//   - FSDB dump with "+all" (interfaces, MDAs, structs) and an
//     optional VCD fallback (+define+DUMP_VCD)
//   - Duplicate config_db set() calls removed
// ============================================================

`timescale 1ns/1ps

module tb_top;

    // ========================================================
    // PACKAGE IMPORTS
    // ========================================================
    import uvm_pkg::*;
    `include "uvm_macros.svh"
    import axi_seq_item_pkg::*;
    import axi_seq_lib_pkg::*;
    import axi_test_pkg::*;

    // ========================================================
    // PARAMETERS -- match these to the DUT wrapper ports
    // ========================================================
    // Width of S01_AXI_0_{aw,w,b,ar,r}id on the DUT wrapper
    localparam int S01_ID_W = 2;

    // ========================================================
    // CLOCK AND RESET
    // ========================================================
    logic clk_100MHz;
    logic reset_rtl_0;   // active-low

    initial clk_100MHz = 1'b0;
    always  #5 clk_100MHz = ~clk_100MHz;

    initial begin
        reset_rtl_0 = 1'b0;
        repeat (20) @(posedge clk_100MHz);
        @(negedge clk_100MHz);
        reset_rtl_0 = 1'b1;
        `uvm_info("TB_TOP", "Reset released", UVM_NONE)
    end

    // ========================================================
    // INTERFACE INSTANTIATIONS
    // ========================================================
    // -- DUT SLAVE PORTS (driven by TB master agents) ------
    axi4lite_if axi4lite_s00_if (.aclk(clk_100MHz), .aresetn(reset_rtl_0)); // S00_AXI_0
    axi3_if     axi3_s01_if     (.aclk(clk_100MHz), .aresetn(reset_rtl_0)); // S01_AXI_0
    axi4_if     axi4_s02_if     (.aclk(clk_100MHz), .aresetn(reset_rtl_0)); // S02_AXI_0

    // -- DUT MASTER PORTS (answered by TB slave agents) ----
    axi4lite_if axi4lite_m00_if (.aclk(clk_100MHz), .aresetn(reset_rtl_0)); // M00_AXI_0
    axi3_if     axi3_m01_if     (.aclk(clk_100MHz), .aresetn(reset_rtl_0)); // M01_AXI_0
    axi4_if     axi4_m02_if     (.aclk(clk_100MHz), .aresetn(reset_rtl_0)); // M02_AXI_0
    axi4_if     axi4_m03_if     (.aclk(clk_100MHz), .aresetn(reset_rtl_0)); // M03_AXI_0

    // -- S01 ID adapter (DUT outputs BID/RID of S01_ID_W bits)
    wire [S01_ID_W-1:0] s01_bid;
    wire [S01_ID_W-1:0] s01_rid;
    assign axi3_s01_if.bid = 4'(s01_bid);
    assign axi3_s01_if.rid = 4'(s01_rid);

    // ========================================================
    // DUT INSTANTIATION
    // ========================================================
    axi_interconnect_ip DUT (
        .clk_100MHz  (clk_100MHz),
        .reset_rtl_0 (reset_rtl_0),

        // ---- S00 : AXI4-Lite slave port (driven by master_lite) ----
        .S00_AXI_0_awaddr   (axi4lite_s00_if.awaddr),
        .S00_AXI_0_awprot   (axi4lite_s00_if.awprot),
        .S00_AXI_0_awvalid  (axi4lite_s00_if.awvalid),
        .S00_AXI_0_awready  (axi4lite_s00_if.awready),
        .S00_AXI_0_wdata    (axi4lite_s00_if.wdata),
        .S00_AXI_0_wstrb    (axi4lite_s00_if.wstrb),
        .S00_AXI_0_wvalid   (axi4lite_s00_if.wvalid),
        .S00_AXI_0_wready   (axi4lite_s00_if.wready),
        .S00_AXI_0_bresp    (axi4lite_s00_if.bresp),
        .S00_AXI_0_bvalid   (axi4lite_s00_if.bvalid),
        .S00_AXI_0_bready   (axi4lite_s00_if.bready),
        .S00_AXI_0_araddr   (axi4lite_s00_if.araddr),
        .S00_AXI_0_arprot   (axi4lite_s00_if.arprot),
        .S00_AXI_0_arvalid  (axi4lite_s00_if.arvalid),
        .S00_AXI_0_arready  (axi4lite_s00_if.arready),
        .S00_AXI_0_rdata    (axi4lite_s00_if.rdata),
        .S00_AXI_0_rresp    (axi4lite_s00_if.rresp),
        .S00_AXI_0_rvalid   (axi4lite_s00_if.rvalid),
        .S00_AXI_0_rready   (axi4lite_s00_if.rready),

        // ---- S01 : AXI3 slave port (driven by master_axi3) ----
        // IDs are S01_ID_W bits on the DUT, 4 bits in axi3_if
        .S01_AXI_0_awid     (axi3_s01_if.awid[S01_ID_W-1:0]),
        .S01_AXI_0_awaddr   (axi3_s01_if.awaddr),
        .S01_AXI_0_awlen    (axi3_s01_if.awlen),
        .S01_AXI_0_awsize   (axi3_s01_if.awsize),
        .S01_AXI_0_awburst  (axi3_s01_if.awburst),
        .S01_AXI_0_awlock   (axi3_s01_if.awlock),
        .S01_AXI_0_awcache  (axi3_s01_if.awcache),
        .S01_AXI_0_awprot   (axi3_s01_if.awprot),
        .S01_AXI_0_awvalid  (axi3_s01_if.awvalid),
        .S01_AXI_0_awready  (axi3_s01_if.awready),
        .S01_AXI_0_wid      (axi3_s01_if.wid[S01_ID_W-1:0]),
        .S01_AXI_0_wdata    (axi3_s01_if.wdata),
        .S01_AXI_0_wstrb    (axi3_s01_if.wstrb),
        .S01_AXI_0_wlast    (axi3_s01_if.wlast),
        .S01_AXI_0_wvalid   (axi3_s01_if.wvalid),
        .S01_AXI_0_wready   (axi3_s01_if.wready),
        .S01_AXI_0_bid      (s01_bid),
        .S01_AXI_0_bresp    (axi3_s01_if.bresp),
        .S01_AXI_0_bvalid   (axi3_s01_if.bvalid),
        .S01_AXI_0_bready   (axi3_s01_if.bready),
        .S01_AXI_0_arid     (axi3_s01_if.arid[S01_ID_W-1:0]),
        .S01_AXI_0_araddr   (axi3_s01_if.araddr),
        .S01_AXI_0_arlen    (axi3_s01_if.arlen),
        .S01_AXI_0_arsize   (axi3_s01_if.arsize),
        .S01_AXI_0_arburst  (axi3_s01_if.arburst),
        .S01_AXI_0_arlock   (axi3_s01_if.arlock),
        .S01_AXI_0_arcache  (axi3_s01_if.arcache),
        .S01_AXI_0_arprot   (axi3_s01_if.arprot),
        .S01_AXI_0_arvalid  (axi3_s01_if.arvalid),
        .S01_AXI_0_arready  (axi3_s01_if.arready),
        .S01_AXI_0_rid      (s01_rid),
        .S01_AXI_0_rdata    (axi3_s01_if.rdata),
        .S01_AXI_0_rresp    (axi3_s01_if.rresp),
        .S01_AXI_0_rlast    (axi3_s01_if.rlast),
        .S01_AXI_0_rvalid   (axi3_s01_if.rvalid),
        .S01_AXI_0_rready   (axi3_s01_if.rready),

        // ---- S02 : AXI4 slave port (driven by master_axi4) ----
        .S02_AXI_0_awid     (axi4_s02_if.awid),
        .S02_AXI_0_awaddr   (axi4_s02_if.awaddr),
        .S02_AXI_0_awlen    (axi4_s02_if.awlen),
        .S02_AXI_0_awsize   (axi4_s02_if.awsize),
        .S02_AXI_0_awburst  (axi4_s02_if.awburst),
        .S02_AXI_0_awlock   (axi4_s02_if.awlock),
        .S02_AXI_0_awcache  (axi4_s02_if.awcache),
        .S02_AXI_0_awprot   (axi4_s02_if.awprot),
        .S02_AXI_0_awqos    (axi4_s02_if.awqos),
        .S02_AXI_0_awvalid  (axi4_s02_if.awvalid),
        .S02_AXI_0_awready  (axi4_s02_if.awready),
        .S02_AXI_0_wdata    (axi4_s02_if.wdata),
        .S02_AXI_0_wstrb    (axi4_s02_if.wstrb),
        .S02_AXI_0_wlast    (axi4_s02_if.wlast),
        .S02_AXI_0_wvalid   (axi4_s02_if.wvalid),
        .S02_AXI_0_wready   (axi4_s02_if.wready),
        .S02_AXI_0_bid      (axi4_s02_if.bid),
        .S02_AXI_0_bresp    (axi4_s02_if.bresp),
        .S02_AXI_0_bvalid   (axi4_s02_if.bvalid),
        .S02_AXI_0_bready   (axi4_s02_if.bready),
        .S02_AXI_0_arid     (axi4_s02_if.arid),
        .S02_AXI_0_araddr   (axi4_s02_if.araddr),
        .S02_AXI_0_arlen    (axi4_s02_if.arlen),
        .S02_AXI_0_arsize   (axi4_s02_if.arsize),
        .S02_AXI_0_arburst  (axi4_s02_if.arburst),
        .S02_AXI_0_arlock   (axi4_s02_if.arlock),
        .S02_AXI_0_arcache  (axi4_s02_if.arcache),
        .S02_AXI_0_arprot   (axi4_s02_if.arprot),
        .S02_AXI_0_arqos    (axi4_s02_if.arqos),
        .S02_AXI_0_arvalid  (axi4_s02_if.arvalid),
        .S02_AXI_0_arready  (axi4_s02_if.arready),
        .S02_AXI_0_rid      (axi4_s02_if.rid),
        .S02_AXI_0_rdata    (axi4_s02_if.rdata),
        .S02_AXI_0_rresp    (axi4_s02_if.rresp),
        .S02_AXI_0_rlast    (axi4_s02_if.rlast),
        .S02_AXI_0_rvalid   (axi4_s02_if.rvalid),
        .S02_AXI_0_rready   (axi4_s02_if.rready),

        // ---- M00 : AXI4-Lite master port (answered by slave_m00) ----
        .M00_AXI_0_awaddr   (axi4lite_m00_if.awaddr),
        .M00_AXI_0_awprot   (axi4lite_m00_if.awprot),
        .M00_AXI_0_awvalid  (axi4lite_m00_if.awvalid),
        .M00_AXI_0_awready  (axi4lite_m00_if.awready),
        .M00_AXI_0_wdata    (axi4lite_m00_if.wdata),
        .M00_AXI_0_wstrb    (axi4lite_m00_if.wstrb),
        .M00_AXI_0_wvalid   (axi4lite_m00_if.wvalid),
        .M00_AXI_0_wready   (axi4lite_m00_if.wready),
        .M00_AXI_0_bresp    (axi4lite_m00_if.bresp),
        .M00_AXI_0_bvalid   (axi4lite_m00_if.bvalid),
        .M00_AXI_0_bready   (axi4lite_m00_if.bready),
        .M00_AXI_0_araddr   (axi4lite_m00_if.araddr),
        .M00_AXI_0_arprot   (axi4lite_m00_if.arprot),
        .M00_AXI_0_arvalid  (axi4lite_m00_if.arvalid),
        .M00_AXI_0_arready  (axi4lite_m00_if.arready),
        .M00_AXI_0_rdata    (axi4lite_m00_if.rdata),
        .M00_AXI_0_rresp    (axi4lite_m00_if.rresp),
        .M00_AXI_0_rvalid   (axi4lite_m00_if.rvalid),
        .M00_AXI_0_rready   (axi4lite_m00_if.rready),

        // ---- M01 : AXI3 master port (answered by slave_m01) ----
        // 4-bit extended IDs {slot,id}
        .M01_AXI_0_awid     (axi3_m01_if.awid),
        .M01_AXI_0_awaddr   (axi3_m01_if.awaddr),
        .M01_AXI_0_awlen    (axi3_m01_if.awlen),
        .M01_AXI_0_awsize   (axi3_m01_if.awsize),
        .M01_AXI_0_awburst  (axi3_m01_if.awburst),
        .M01_AXI_0_awlock   (axi3_m01_if.awlock),
        .M01_AXI_0_awcache  (axi3_m01_if.awcache),
        .M01_AXI_0_awprot   (axi3_m01_if.awprot),
        .M01_AXI_0_awvalid  (axi3_m01_if.awvalid),
        .M01_AXI_0_awready  (axi3_m01_if.awready),
        .M01_AXI_0_wid      (axi3_m01_if.wid),
        .M01_AXI_0_wdata    (axi3_m01_if.wdata),
        .M01_AXI_0_wstrb    (axi3_m01_if.wstrb),
        .M01_AXI_0_wlast    (axi3_m01_if.wlast),
        .M01_AXI_0_wvalid   (axi3_m01_if.wvalid),
        .M01_AXI_0_wready   (axi3_m01_if.wready),
        .M01_AXI_0_bid      (axi3_m01_if.bid),
        .M01_AXI_0_bresp    (axi3_m01_if.bresp),
        .M01_AXI_0_bvalid   (axi3_m01_if.bvalid),
        .M01_AXI_0_bready   (axi3_m01_if.bready),
        .M01_AXI_0_arid     (axi3_m01_if.arid),
        .M01_AXI_0_araddr   (axi3_m01_if.araddr),
        .M01_AXI_0_arlen    (axi3_m01_if.arlen),
        .M01_AXI_0_arsize   (axi3_m01_if.arsize),
        .M01_AXI_0_arburst  (axi3_m01_if.arburst),
        .M01_AXI_0_arlock   (axi3_m01_if.arlock),
        .M01_AXI_0_arcache  (axi3_m01_if.arcache),
        .M01_AXI_0_arprot   (axi3_m01_if.arprot),
        .M01_AXI_0_arvalid  (axi3_m01_if.arvalid),
        .M01_AXI_0_arready  (axi3_m01_if.arready),
        .M01_AXI_0_rid      (axi3_m01_if.rid),
        .M01_AXI_0_rdata    (axi3_m01_if.rdata),
        .M01_AXI_0_rresp    (axi3_m01_if.rresp),
        .M01_AXI_0_rlast    (axi3_m01_if.rlast),
        .M01_AXI_0_rvalid   (axi3_m01_if.rvalid),
        .M01_AXI_0_rready   (axi3_m01_if.rready),

        // ---- M02 : AXI4 master port (answered by slave_m02) ----
        .M02_AXI_0_awid     (axi4_m02_if.awid),
        .M02_AXI_0_awaddr   (axi4_m02_if.awaddr),
        .M02_AXI_0_awlen    (axi4_m02_if.awlen),
        .M02_AXI_0_awsize   (axi4_m02_if.awsize),
        .M02_AXI_0_awburst  (axi4_m02_if.awburst),
        .M02_AXI_0_awlock   (axi4_m02_if.awlock),
        .M02_AXI_0_awcache  (axi4_m02_if.awcache),
        .M02_AXI_0_awprot   (axi4_m02_if.awprot),
        .M02_AXI_0_awqos    (axi4_m02_if.awqos),
        .M02_AXI_0_awregion (axi4_m02_if.awregion),
        .M02_AXI_0_awvalid  (axi4_m02_if.awvalid),
        .M02_AXI_0_awready  (axi4_m02_if.awready),
        .M02_AXI_0_wdata    (axi4_m02_if.wdata),
        .M02_AXI_0_wstrb    (axi4_m02_if.wstrb),
        .M02_AXI_0_wlast    (axi4_m02_if.wlast),
        .M02_AXI_0_wvalid   (axi4_m02_if.wvalid),
        .M02_AXI_0_wready   (axi4_m02_if.wready),
        .M02_AXI_0_bid      (axi4_m02_if.bid),
        .M02_AXI_0_bresp    (axi4_m02_if.bresp),
        .M02_AXI_0_bvalid   (axi4_m02_if.bvalid),
        .M02_AXI_0_bready   (axi4_m02_if.bready),
        .M02_AXI_0_arid     (axi4_m02_if.arid),
        .M02_AXI_0_araddr   (axi4_m02_if.araddr),
        .M02_AXI_0_arlen    (axi4_m02_if.arlen),
        .M02_AXI_0_arsize   (axi4_m02_if.arsize),
        .M02_AXI_0_arburst  (axi4_m02_if.arburst),
        .M02_AXI_0_arlock   (axi4_m02_if.arlock),
        .M02_AXI_0_arcache  (axi4_m02_if.arcache),
        .M02_AXI_0_arprot   (axi4_m02_if.arprot),
        .M02_AXI_0_arregion (axi4_m02_if.arregion),
        .M02_AXI_0_arqos    (axi4_m02_if.arqos),
        .M02_AXI_0_arvalid  (axi4_m02_if.arvalid),
        .M02_AXI_0_arready  (axi4_m02_if.arready),
        .M02_AXI_0_rid      (axi4_m02_if.rid),
        .M02_AXI_0_rdata    (axi4_m02_if.rdata),
        .M02_AXI_0_rresp    (axi4_m02_if.rresp),
        .M02_AXI_0_rlast    (axi4_m02_if.rlast),
        .M02_AXI_0_rvalid   (axi4_m02_if.rvalid),
        .M02_AXI_0_rready   (axi4_m02_if.rready),

        // ---- M03 : AXI4 master port (answered by slave_m03) ----
        .M03_AXI_0_awid     (axi4_m03_if.awid),
        .M03_AXI_0_awaddr   (axi4_m03_if.awaddr),
        .M03_AXI_0_awlen    (axi4_m03_if.awlen),
        .M03_AXI_0_awsize   (axi4_m03_if.awsize),
        .M03_AXI_0_awburst  (axi4_m03_if.awburst),
        .M03_AXI_0_awlock   (axi4_m03_if.awlock),
        .M03_AXI_0_awcache  (axi4_m03_if.awcache),
        .M03_AXI_0_awprot   (axi4_m03_if.awprot),
        .M03_AXI_0_awqos    (axi4_m03_if.awqos),
        .M03_AXI_0_awregion (axi4_m03_if.awregion),
        .M03_AXI_0_awvalid  (axi4_m03_if.awvalid),
        .M03_AXI_0_awready  (axi4_m03_if.awready),
        .M03_AXI_0_wdata    (axi4_m03_if.wdata),
        .M03_AXI_0_wstrb    (axi4_m03_if.wstrb),
        .M03_AXI_0_wlast    (axi4_m03_if.wlast),
        .M03_AXI_0_wvalid   (axi4_m03_if.wvalid),
        .M03_AXI_0_wready   (axi4_m03_if.wready),
        .M03_AXI_0_bid      (axi4_m03_if.bid),
        .M03_AXI_0_bresp    (axi4_m03_if.bresp),
        .M03_AXI_0_bvalid   (axi4_m03_if.bvalid),
        .M03_AXI_0_bready   (axi4_m03_if.bready),
        .M03_AXI_0_arid     (axi4_m03_if.arid),
        .M03_AXI_0_araddr   (axi4_m03_if.araddr),
        .M03_AXI_0_arlen    (axi4_m03_if.arlen),
        .M03_AXI_0_arsize   (axi4_m03_if.arsize),
        .M03_AXI_0_arburst  (axi4_m03_if.arburst),
        .M03_AXI_0_arlock   (axi4_m03_if.arlock),
        .M03_AXI_0_arcache  (axi4_m03_if.arcache),
        .M03_AXI_0_arprot   (axi4_m03_if.arprot),
        .M03_AXI_0_arregion (axi4_m03_if.arregion),
        .M03_AXI_0_arqos    (axi4_m03_if.arqos),
        .M03_AXI_0_arvalid  (axi4_m03_if.arvalid),
        .M03_AXI_0_arready  (axi4_m03_if.arready),
        .M03_AXI_0_rid      (axi4_m03_if.rid),
        .M03_AXI_0_rdata    (axi4_m03_if.rdata),
        .M03_AXI_0_rresp    (axi4_m03_if.rresp),
        .M03_AXI_0_rlast    (axi4_m03_if.rlast),
        .M03_AXI_0_rvalid   (axi4_m03_if.rvalid),
        .M03_AXI_0_rready   (axi4_m03_if.rready)
    );

    // ========================================================
    // UVM CONFIG_DB -- VIRTUAL INTERFACE REGISTRATION
    // ========================================================
    initial begin
        // -- Master agents (DUT slave ports) ---------------
        uvm_config_db #(virtual axi4lite_if)::set(null,
            "uvm_test_top.env.master_lite.*", "vif", axi4lite_s00_if);
        uvm_config_db #(virtual axi3_if)::set(null,
            "uvm_test_top.env.master_axi3.*", "vif", axi3_s01_if);
        uvm_config_db #(virtual axi4_if)::set(null,
            "uvm_test_top.env.master_axi4.*", "vif", axi4_s02_if);

        // -- Slave agents (DUT master ports) ---------------
        uvm_config_db #(virtual axi4lite_if)::set(null,
            "uvm_test_top.env.slave_m00.*", "vif", axi4lite_m00_if);
        uvm_config_db #(virtual axi3_if)::set(null,
            "uvm_test_top.env.slave_m01.*", "vif", axi3_m01_if);
        uvm_config_db #(virtual axi4_if)::set(null,
            "uvm_test_top.env.slave_m02.*", "vif", axi4_m02_if);
        uvm_config_db #(virtual axi4_if)::set(null,
            "uvm_test_top.env.slave_m03.*", "vif", axi4_m03_if);

        run_test();
    end

    // ========================================================
    // SIMULATION TIMEOUT (10 ms) -- catches deadlocks
    // ========================================================
    initial begin
        #10ms;
        `uvm_fatal("TB_TIMEOUT",
            "Simulation exceeded 10ms -- possible deadlock. Check AWREADY/WREADY/BVALID/ARREADY/RVALID in the waveform.")
    end

    // ========================================================
    // WAVEFORM DUMP
    // ========================================================
    // FSDB needs: vcs ... -debug_access+all -kdb -lca
    //   "+all" is required to dump interface contents, MDAs and
    //   structs; without it the interface signals show no values.
    // No Verdi license? compile with +define+DUMP_VCD
    // Disable dumping entirely with +define+NO_DUMP
    // ========================================================
`ifndef NO_DUMP
  `ifdef DUMP_VCD
    initial begin
        $dumpfile("waves.vcd");
        $dumpvars(0, tb_top);
    end
  `else
    initial begin
        $fsdbDumpfile("waves.fsdb");
        $fsdbDumpvars(0, tb_top, "+all");
        $fsdbDumpSVA;
    end
  `endif
`endif

endmodule : tb_top
