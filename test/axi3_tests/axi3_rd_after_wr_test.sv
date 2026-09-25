`include "uvm_macros.svh"
import uvm_pkg::*;
import axi_seq_item_pkg::*;

// ============================================================
// axi3_rd_after_wr_test.sv -- S01 -> M01 burst write/read-back
// ============================================================

class axi3_rd_after_wr_test extends axi_base_test;
    `uvm_component_utils(axi3_rd_after_wr_test)

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    task run_phase(uvm_phase phase);
        axi3_rd_after_wr_seq seq;
        phase.raise_objection(this);
        seq = axi3_rd_after_wr_seq::type_id::create("seq");
        seq.num_txns = 16;
        seq.start(env.master_axi3.seqr);
        drain();
        phase.drop_objection(this);
    endtask
endclass : axi3_rd_after_wr_test
