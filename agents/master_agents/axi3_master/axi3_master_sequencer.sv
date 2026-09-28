`include "uvm_macros.svh"
import uvm_pkg::*;
import axi_seq_item_pkg::*;

// ============================================================
// axi3_master_sequencer.sv
// Standard UVM sequencer for axi3 master agent
// ============================================================

class axi3_master_sequencer extends uvm_sequencer #(axi3_seq_item);

    `uvm_component_utils(axi3_master_sequencer)

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

endclass : axi3_master_sequencer
