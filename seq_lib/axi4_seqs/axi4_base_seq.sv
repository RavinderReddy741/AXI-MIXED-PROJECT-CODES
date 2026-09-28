`include "uvm_macros.svh"
import uvm_pkg::*;
import axi_seq_item_pkg::*;

// ============================================================
// axi4_base_seq.sv
// Base class for all axi4 sequences
// ============================================================

class axi4_base_seq extends uvm_sequence #(axi4_seq_item);

    `uvm_object_utils(axi4_base_seq)

    int unsigned num_txns = 4;

    function new(string name = "axi4_base_seq");
        super.new(name);
    endfunction

    // Helper -- randomize and send one item
    task send_item(axi4_seq_item item);
        start_item(item);
        if (!item.randomize())
            `uvm_fatal("RAND", "axi4_base_seq: randomize failed")
        finish_item(item);
    endtask

    task body();
        // Overridden by child classes
    endtask

endclass : axi4_base_seq
