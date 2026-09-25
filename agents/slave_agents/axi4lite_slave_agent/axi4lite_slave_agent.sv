`include "uvm_macros.svh"
import uvm_pkg::*;
import axi_seq_item_pkg::*;

// ============================================================
// axi4lite_slave_agent.sv
// Responds on DUT M00_AXI (AXI4-Lite master port)
// No sequencer -- slave responds reactively
// ============================================================

class axi4lite_slave_agent extends uvm_agent;

    `uvm_component_utils(axi4lite_slave_agent)

    axi4lite_slave_driver  drv;
    axi4lite_slave_monitor mon;

    uvm_analysis_port #(axi4lite_seq_item) ap;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        drv = axi4lite_slave_driver::type_id::create("drv", this);
        mon = axi4lite_slave_monitor::type_id::create("mon", this);
        ap  = new("ap", this);
    endfunction

    function void connect_phase(uvm_phase phase);
        mon.ap.connect(ap);
    endfunction

endclass : axi4lite_slave_agent
