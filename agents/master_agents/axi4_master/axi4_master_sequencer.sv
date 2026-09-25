`include "uvm_macros.svh"
import uvm_pkg::*;
import axi_seq_item_pkg::*;

// ============================================================
// axi4_master_sequencer.sv
// Standard UVM sequencer for axi4 master agent
// ============================================================

class axi4_master_sequencer extends uvm_sequencer #(axi4_seq_item);

    `uvm_component_utils(axi4_master_sequencer)

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

endclass : axi4_master_sequencer
