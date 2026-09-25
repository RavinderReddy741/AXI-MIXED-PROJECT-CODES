`include "uvm_macros.svh"
import uvm_pkg::*;
import axi_seq_item_pkg::*;

// ============================================================
// axi_virtual_base_seq.sv
// Base class for all virtual sequences.
// p_sequencer is typed as axi_virtual_sequencer, so child
// sequences use p_sequencer.seqr_s00/s01/s02 directly.
// ============================================================

class axi_virtual_base_seq extends uvm_sequence;
    `uvm_object_utils(axi_virtual_base_seq)
    `uvm_declare_p_sequencer(axi_virtual_sequencer)

    function new(string name = "axi_virtual_base_seq");
        super.new(name);
    endfunction

    task pre_body();
        if (p_sequencer.seqr_s00 == null)
            `uvm_fatal("VSEQ", "seqr_s00 null")
        if (p_sequencer.seqr_s01 == null)
            `uvm_fatal("VSEQ", "seqr_s01 null")
        if (p_sequencer.seqr_s02 == null)
            `uvm_fatal("VSEQ", "seqr_s02 null")
    endtask
endclass : axi_virtual_base_seq
