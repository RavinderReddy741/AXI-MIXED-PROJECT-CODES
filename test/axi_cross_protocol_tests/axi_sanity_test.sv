`include "uvm_macros.svh"
import uvm_pkg::*;
import axi_seq_item_pkg::*;

// ============================================================
// axi_sanity_test.sv
// Runs axi_sanity_vseq (W+R on every master).
// ============================================================

class axi_sanity_test extends axi_base_test;
    `uvm_component_utils(axi_sanity_test)

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    task run_phase(uvm_phase phase);
        axi_sanity_vseq vseq;
        phase.raise_objection(this);
        vseq = axi_sanity_vseq::type_id::create("vseq");
        vseq.start(env.vseqr);
        drain();
        phase.drop_objection(this);
    endtask
endclass : axi_sanity_test
