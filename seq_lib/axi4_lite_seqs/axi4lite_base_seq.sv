`include "uvm_macros.svh"
import uvm_pkg::*;
import axi_seq_item_pkg::*;

// ============================================================
// axi4lite_base_seq.sv
// Base class for all axi4lite sequences
// ============================================================

class axi4lite_base_seq extends uvm_sequence #(axi4lite_seq_item);

    `uvm_object_utils(axi4lite_base_seq)

    int unsigned num_txns = 4;

    function new(string name = "axi4lite_base_seq");
        super.new(name);
    endfunction

    // Helper -- randomize and send one item
    task send_item(axi4lite_seq_item item);
        start_item(item);
        if (!item.randomize())
            `uvm_fatal("RAND", "axi4lite_base_seq: randomize failed")
        finish_item(item);
    endtask

    task body();
        // Overridden by child classes
    endtask

endclass : axi4lite_base_seq
