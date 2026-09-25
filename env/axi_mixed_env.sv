`include "uvm_macros.svh"
import uvm_pkg::*;
import axi_seq_item_pkg::*;

// ============================================================
// axi_mixed_env.sv
// Top-level UVM environment
//
// Master agents (drive DUT slave ports):
//   master_lite  -> S00_AXI (AXI4-Lite)
//   master_axi3  -> S01_AXI (AXI3)
//   master_axi4  -> S02_AXI (AXI4)
//
// Slave agents (respond on DUT master ports):
//   slave_m00    -> M00_AXI (AXI4-Lite)
//   slave_m01    -> M01_AXI (AXI3)
//   slave_m02    -> M02_AXI (AXI4)
//   slave_m03    -> M03_AXI (AXI4)
//   M04 -> BRAM is internal to the BD (checked end-to-end by
//   the scoreboard's S-side read-data compare)
//
// Scoreboard, per-protocol coverage, virtual sequencer
// ============================================================

class axi_mixed_env extends uvm_env;

    `uvm_component_utils(axi_mixed_env)

    // -- Master agents -------------------------------------
    axi4lite_master_agent master_lite;
    axi3_master_agent     master_axi3;
    axi4_master_agent     master_axi4;

    // -- Slave agents --------------------------------------
    axi4lite_slave_agent  slave_m00;
    axi3_slave_agent      slave_m01;
    axi4_slave_agent      slave_m02;
    axi4_slave_agent      slave_m03;

    // -- Scoreboard ----------------------------------------
    axi_scoreboard sb;

    // -- Coverage ------------------------------------------
    axi4lite_coverage cov_lite;
    axi3_coverage     cov_axi3;
    axi4_coverage     cov_axi4;

    // -- Virtual sequencer ---------------------------------
    axi_virtual_sequencer vseqr;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);

        // -- Master agents ---------------------------------
        master_lite = axi4lite_master_agent::type_id::create("master_lite", this);
        master_axi3 = axi3_master_agent::type_id::create("master_axi3", this);
        master_axi4 = axi4_master_agent::type_id::create("master_axi4", this);

        // -- Slave agents ----------------------------------
        slave_m00 = axi4lite_slave_agent::type_id::create("slave_m00", this);
        slave_m01 = axi3_slave_agent::type_id::create("slave_m01", this);
        slave_m02 = axi4_slave_agent::type_id::create("slave_m02", this);
        slave_m03 = axi4_slave_agent::type_id::create("slave_m03", this);

        // -- Slave agent regions ---------------------------
        uvm_config_db #(logic [31:0])::set(this, "slave_m00.*", "region_lo", 32'h44A0_0000);
        uvm_config_db #(logic [31:0])::set(this, "slave_m00.*", "region_hi", 32'h44A0_FFFF);
        uvm_config_db #(logic [31:0])::set(this, "slave_m01.*", "region_lo", 32'h44A1_0000);
        uvm_config_db #(logic [31:0])::set(this, "slave_m01.*", "region_hi", 32'h44A1_FFFF);
        uvm_config_db #(logic [31:0])::set(this, "slave_m02.*", "region_lo", 32'h44A2_0000);
        uvm_config_db #(logic [31:0])::set(this, "slave_m02.*", "region_hi", 32'h44A2_FFFF);
        uvm_config_db #(logic [31:0])::set(this, "slave_m03.*", "region_lo", 32'h44A3_0000);
        uvm_config_db #(logic [31:0])::set(this, "slave_m03.*", "region_hi", 32'h44A3_FFFF);

        // -- Scoreboard ------------------------------------
        sb = axi_scoreboard::type_id::create("sb", this);

        // -- Coverage --------------------------------------
        cov_lite = axi4lite_coverage::type_id::create("cov_lite", this);
        cov_axi3 = axi3_coverage::type_id::create("cov_axi3", this);
        cov_axi4 = axi4_coverage::type_id::create("cov_axi4", this);

        // -- Virtual sequencer -----------------------------
        vseqr = axi_virtual_sequencer::type_id::create("vseqr", this);
    endfunction

    function void connect_phase(uvm_phase phase);
        // -- Master monitors -> scoreboard S-side ports ----
        master_lite.ap.connect(sb.imp_s00);
        master_axi3.ap.connect(sb.imp_s01);
        master_axi4.ap.connect(sb.imp_s02);

        // -- Slave monitors -> scoreboard M-side ports -----
        slave_m00.ap.connect(sb.imp_m00);
        slave_m01.ap.connect(sb.imp_m01);
        slave_m02.ap.connect(sb.imp_m02);
        slave_m03.ap.connect(sb.imp_m03);

        // -- Master monitors -> coverage -------------------
        master_lite.ap.connect(cov_lite.analysis_export);
        master_axi3.ap.connect(cov_axi3.analysis_export);
        master_axi4.ap.connect(cov_axi4.analysis_export);

        // -- Virtual sequencer handles ---------------------
        vseqr.seqr_s00 = master_lite.seqr;
        vseqr.seqr_s01 = master_axi3.seqr;
        vseqr.seqr_s02 = master_axi4.seqr;
    endfunction

endclass : axi_mixed_env
