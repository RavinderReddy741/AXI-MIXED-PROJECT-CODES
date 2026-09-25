`include "uvm_macros.svh"
import uvm_pkg::*;
import axi_seq_item_pkg::*;

// ============================================================
// axi3_slave_agent.sv
// Responds on DUT M01_AXI (AXI3 master port)
// No sequencer -- slave responds reactively
// ============================================================

class axi3_slave_agent extends uvm_agent;

    `uvm_component_utils(axi3_slave_agent)

    axi3_slave_driver  drv;
    axi3_slave_monitor mon;

    uvm_analysis_port #(axi3_seq_item) ap;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        drv = axi3_slave_driver::type_id::create("drv", this);
        mon = axi3_slave_monitor::type_id::create("mon", this);
        ap  = new("ap", this);
    endfunction

    function void connect_phase(uvm_phase phase);
        mon.ap.connect(ap);
    endfunction

endclass : axi3_slave_agent
