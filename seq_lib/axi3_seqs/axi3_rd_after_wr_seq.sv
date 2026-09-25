`include "uvm_macros.svh"
import uvm_pkg::*;
import axi_seq_item_pkg::*;

// ============================================================
// axi3_rd_after_wr_seq.sv
// Writes a burst then reads back the same address
// Address range: M01 region 0x44A1_0000 - 0x44A1_FFFC
// 4KB boundary enforced by the item constraint c_4kb_incr
// ============================================================

class axi3_rd_after_wr_seq extends axi3_base_seq;

    `uvm_object_utils(axi3_rd_after_wr_seq)

    function new(string name = "axi3_rd_after_wr_seq");
        super.new(name);
    endfunction

    task body();
        axi3_seq_item wr_item, rd_item;

        for (int i = 0; i < num_txns; i++) begin
            // -- Write -------------------------------------
            wr_item = axi3_seq_item::type_id::create($sformatf("axi3_wr_%0d", i));
            start_item(wr_item);
            if (!wr_item.randomize() with {
                direction == AXI_WRITE;
                addr inside {[32'h44A1_0000:32'h44A1_FFFC]};
                len   inside {[4'h0:4'h3]};   // 1-4 beats
                size  == 3'b010;               // 4 bytes/beat
                burst == AXI_INCR;
                lock  == 2'b00;
            }) `uvm_fatal("RAND", "axi3_rd_after_wr: write rand failed")
            finish_item(wr_item);

            `uvm_info("AXI3_SEQ",
                $sformatf("WR addr=0x%08h len=%0d bresp=%0b",
                    wr_item.addr, wr_item.len, wr_item.bresp), UVM_MEDIUM)

            // -- Read back ---------------------------------
            rd_item = axi3_seq_item::type_id::create($sformatf("axi3_rd_%0d", i));
            start_item(rd_item);
            if (!rd_item.randomize() with {
                direction == AXI_READ;
                addr  == wr_item.addr;
                len   == wr_item.len;
                size  == 3'b010;
                burst == AXI_INCR;
                lock  == 2'b00;
            }) `uvm_fatal("RAND", "axi3_rd_after_wr: read rand failed")
            finish_item(rd_item);

            `uvm_info("AXI3_SEQ",
                $sformatf("RD addr=0x%08h len=%0d rdata=%p",
                    rd_item.addr, rd_item.len, rd_item.rdata), UVM_MEDIUM)
        end
    endtask

endclass : axi3_rd_after_wr_seq
