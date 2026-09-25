`include "uvm_macros.svh"
import uvm_pkg::*;
import axi_seq_item_pkg::*;

// ============================================================
// axi4_slave_agent.sv
// Responds on DUT M02_AXI / M03_AXI (AXI4 master ports)
// No sequencer -- slave responds reactively
// ============================================================

class axi4_slave_agent extends uvm_agent;

    `uvm_component_utils(axi4_slave_agent)

    axi4_slave_driver  drv;
    axi4_slave_monitor mon;

    uvm_analysis_port #(axi4_seq_item) ap;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        drv = axi4_slave_driver::type_id::create("drv", this);
        mon = axi4_slave_monitor::type_id::create("mon", this);
        ap  = new("ap", this);
    endfunction

    function void connect_phase(uvm_phase phase);
        mon.ap.connect(ap);
    endfunction

endclass : axi4_slave_agent
