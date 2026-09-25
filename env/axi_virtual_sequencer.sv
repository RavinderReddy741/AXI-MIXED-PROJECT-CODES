`include "uvm_macros.svh"
import uvm_pkg::*;
import axi_seq_item_pkg::*;

// ============================================================
// axi_virtual_sequencer.sv
// Holds handles to all three master sequencers.
// Virtual sequences run on this sequencer and
// use the handles to start sub-sequences on
// individual master agents.
// ============================================================

class axi_virtual_sequencer extends uvm_sequencer;

    `uvm_component_utils(axi_virtual_sequencer)

    // -- Handles to real sequencers ------------------------
    // Set in env connect_phase
    uvm_sequencer #(axi4lite_seq_item) seqr_s00;
    uvm_sequencer #(axi3_seq_item)     seqr_s01;
    uvm_sequencer #(axi4_seq_item)     seqr_s02;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

endclass : axi_virtual_sequencer
