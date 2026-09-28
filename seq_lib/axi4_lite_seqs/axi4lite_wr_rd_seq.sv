`include "uvm_macros.svh"
import uvm_pkg::*;
import axi_seq_item_pkg::*;

// ============================================================
// axi4lite_wr_rd_seq.sv
// Writes num_txns items then reads them all back
// Address range: M00 region 0x44A0_0000 - 0x44A0_FFFC
// Addresses are 4-byte aligned (AXI4-Lite requirement)
//
// NOTE: the "#100" between the phases is gone -- the driver now
//       returns item_done() only after the B response, so all
//       writes are complete before the first read is issued.
// ============================================================

class axi4lite_wr_rd_seq extends axi4lite_base_seq;

    `uvm_object_utils(axi4lite_wr_rd_seq)

    function new(string name = "axi4lite_wr_rd_seq");
        super.new(name);
    endfunction

    task body();
        axi4lite_seq_item item;
        logic [31:0] addrs[];

        addrs = new[num_txns];

        // -- Write phase -----------------------------------
        for (int i = 0; i < num_txns; i++) begin
            item = axi4lite_seq_item::type_id::create($sformatf("lite_wr_%0d", i));
            start_item(item);
            if (!item.randomize() with {
                direction  == AXI_WRITE;
                addr inside {[32'h44A0_0000:32'h44A0_FFFC]};
                strb       == 4'hF;
            }) `uvm_fatal("RAND", "axi4lite_wr_rd_seq: write rand failed")
            addrs[i] = item.addr;
            finish_item(item);

            `uvm_info("LITE_SEQ",
                $sformatf("WR[%0d] addr=0x%08h data=0x%08h resp=%0b",
                    i, item.addr, item.data, item.resp), UVM_MEDIUM)
        end

        // -- Read phase ------------------------------------
        for (int i = 0; i < num_txns; i++) begin
            item = axi4lite_seq_item::type_id::create($sformatf("lite_rd_%0d", i));
            start_item(item);
            if (!item.randomize() with {
                direction == AXI_READ;
                addr      == addrs[i];
            }) `uvm_fatal("RAND", "axi4lite_wr_rd_seq: read rand failed")
            finish_item(item);

            `uvm_info("LITE_SEQ",
                $sformatf("RD[%0d] addr=0x%08h rdata=0x%08h resp=%0b",
                    i, item.addr, item.rdata, item.resp), UVM_MEDIUM)
        end
    endtask

endclass : axi4lite_wr_rd_seq
