`include "uvm_macros.svh"
import uvm_pkg::*;
import axi_seq_item_pkg::*;

// ============================================================
// axi4lite_master_agent.sv
// Connects to DUT S00_AXI (AXI4-Lite slave port)
// ============================================================

class axi4lite_master_agent extends uvm_agent;

    `uvm_component_utils(axi4lite_master_agent)

    axi4lite_master_sequencer seqr;
    axi4lite_master_driver    drv;
    axi4lite_master_monitor   mon;

    uvm_analysis_port #(axi4lite_seq_item) ap;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        seqr = axi4lite_master_sequencer::type_id::create("seqr", this);
        drv  = axi4lite_master_driver::type_id::create("drv", this);
        mon  = axi4lite_master_monitor::type_id::create("mon", this);
        ap   = new("ap", this);
    endfunction

    function void connect_phase(uvm_phase phase);
        drv.seq_item_port.connect(seqr.seq_item_export);
        mon.ap.connect(ap);
    endfunction

endclass : axi4lite_master_agent
