`include "uvm_macros.svh"
import uvm_pkg::*;
import axi_seq_item_pkg::*;

// ============================================================
// axi_sanity_vseq.sv
// Sanity virtual sequence -- sequential, all 3 masters.
//
// Flow:
//   1. Lite  WR  0x44A0_0100  data=0xDEAD_BEEF
//   2. AXI3  WR  0x44A1_0100  1-beat INCR
//   3. AXI4  WR  0x44A2_0100  1-beat INCR
//   4. Lite  RD  0x44A0_0100  -> must return 0xDEAD_BEEF
//   5. AXI3  RD  0x44A1_0100
//   6. AXI4  RD  0x44A2_0100
//
// The master drivers now call item_done() only after the
// response, so rdata printed here is the REAL read data
// (previously it was always 0 because item_done() came back
// before the read even started).
//
// NOTE: keep ONE copy of this file. The old tree had a second
//       copy in seq_lib/ -> "class already defined" if both are
//       compiled.
// ============================================================

class axi_sanity_vseq extends axi_virtual_base_seq;

    `uvm_object_utils(axi_sanity_vseq)

    function new(string name = "axi_sanity_vseq");
        super.new(name);
    endfunction

    task body();
        axi4lite_seq_item lite_item;
        axi3_seq_item     axi3_item;
        axi4_seq_item     axi4_item;
        logic [31:0]      axi3_wdata, axi4_wdata;

        // -- 1. Lite write to M00 -------------------------
        `uvm_do_on_with(lite_item, p_sequencer.seqr_s00, {
            direction == AXI_WRITE;
            addr      == 32'h44A0_0100;
            data      == 32'hDEAD_BEEF;
            strb      == 4'hF;
        })
        `uvm_info("SANITY_VSEQ",
            $sformatf("Lite WR done bresp=%0b", lite_item.resp), UVM_NONE)

        // -- 2. AXI3 write to M01 -------------------------
        `uvm_do_on_with(axi3_item, p_sequencer.seqr_s01, {
            direction == AXI_WRITE;
            addr      == 32'h44A1_0100;
            len       == 4'h0;
            size      == 3'b010;
            burst     == AXI_INCR;
            lock      == 2'b00;
            id        == 2'h1;
        })
        axi3_wdata = axi3_item.wdata[0];
        `uvm_info("SANITY_VSEQ",
            $sformatf("AXI3 WR done wdata=0x%08h bresp=%0b",
                axi3_wdata, axi3_item.bresp), UVM_NONE)

        // -- 3. AXI4 write to M02 -------------------------
        `uvm_do_on_with(axi4_item, p_sequencer.seqr_s02, {
            direction == AXI_WRITE;
            addr      == 32'h44A2_0100;
            len       == 8'h0;
            size      == 3'b010;
            burst     == AXI_INCR;
            lock      == 1'b0;
            id        == 4'h2;
        })
        axi4_wdata = axi4_item.wdata[0];
        `uvm_info("SANITY_VSEQ",
            $sformatf("AXI4 WR done wdata=0x%08h bresp=%0b",
                axi4_wdata, axi4_item.bresp), UVM_NONE)

        // -- 4. Lite read from M00 ------------------------
        `uvm_do_on_with(lite_item, p_sequencer.seqr_s00, {
            direction == AXI_READ;
            addr      == 32'h44A0_0100;
        })
        `uvm_info("SANITY_VSEQ",
            $sformatf("Lite RD done rdata=0x%08h (expect 0xdeadbeef)",
                lite_item.rdata), UVM_NONE)

        // -- 5. AXI3 read from M01 ------------------------
        `uvm_do_on_with(axi3_item, p_sequencer.seqr_s01, {
            direction == AXI_READ;
            addr      == 32'h44A1_0100;
            len       == 4'h0;
            size      == 3'b010;
            burst     == AXI_INCR;
            lock      == 2'b00;
            id        == 2'h1;
        })
        `uvm_info("SANITY_VSEQ",
            $sformatf("AXI3 RD done rdata=%p (expect 0x%08h)",
                axi3_item.rdata, axi3_wdata), UVM_NONE)

        // -- 6. AXI4 read from M02 ------------------------
        `uvm_do_on_with(axi4_item, p_sequencer.seqr_s02, {
            direction == AXI_READ;
            addr      == 32'h44A2_0100;
            len       == 8'h0;
            size      == 3'b010;
            burst     == AXI_INCR;
            lock      == 1'b0;
            id        == 4'h2;
        })
        `uvm_info("SANITY_VSEQ",
            $sformatf("AXI4 RD done rdata=%p (expect 0x%08h)",
                axi4_item.rdata, axi4_wdata), UVM_NONE)

        `uvm_info("SANITY_VSEQ",
            "Sanity sequence complete -- all 3 masters W+R done",
            UVM_NONE)
    endtask

endclass : axi_sanity_vseq
