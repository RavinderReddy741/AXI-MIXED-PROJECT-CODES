`include "uvm_macros.svh"
import uvm_pkg::*;
import axi_seq_item_pkg::*;

// ============================================================
// axi4lite_wr_rd_test.sv -- S00 -> M00 random write/read-back
// ============================================================

class axi4lite_wr_rd_test extends axi_base_test;
    `uvm_component_utils(axi4lite_wr_rd_test)

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    task run_phase(uvm_phase phase);
        axi4lite_wr_rd_seq seq;
        phase.raise_objection(this);
        seq = axi4lite_wr_rd_seq::type_id::create("seq");
        seq.num_txns = 16;
        seq.start(env.master_lite.seqr);
        drain();
        phase.drop_objection(this);
    endtask
endclass : axi4lite_wr_rd_test
