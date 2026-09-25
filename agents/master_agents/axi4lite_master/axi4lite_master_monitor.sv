`include "uvm_macros.svh"
import uvm_pkg::*;
import axi_seq_item_pkg::*;

// ============================================================
// axi4lite_master_monitor.sv
// Passive monitor on DUT S00_AXI (AXI4-Lite slave port)
// Watches what master sends and what DUT responds
//
// Publishes COMPLETE transactions to scoreboard:
//   - Write: addr + data + strb + resp (after B)
//   - Read : addr + rdata + resp (after R)
//
// Also tracks handshake stall cycles per channel
//
// FIX: all channels are sampled from ONE loop in a fixed order
//      (AW, W, B, AR, R). With one forked thread per channel the
//      order in which threads woke on the same edge was undefined.
// ============================================================

class axi4lite_master_monitor extends uvm_monitor;

    `uvm_component_utils(axi4lite_master_monitor)

    // -- Virtual interface --------------------------------
    virtual axi4lite_if vif;

    // -- Analysis port  sends completed items -------------
    uvm_analysis_port #(axi4lite_seq_item) ap;

    // -- Internal staging queues ---------------------------
    axi4lite_seq_item aw_pending_q[$];
    axi4lite_seq_item w_pending_q[$];
    axi4lite_seq_item ar_pending_q[$];

    // -- Handshake stall tracking --------------------------
    int unsigned aw_stall_cnt;
    int unsigned w_stall_cnt;
    int unsigned ar_stall_cnt;
    int unsigned b_stall_cnt;
    int unsigned r_stall_cnt;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        ap = new("ap", this);
        if (!uvm_config_db #(virtual axi4lite_if)::get(
                this, "", "vif", vif))
            `uvm_fatal("NOVIF",
                "axi4lite_master_monitor: cannot get vif")
    endfunction

    task run_phase(uvm_phase phase);
        forever begin
            @(vif.monitor_cb);
            if (vif.aresetn !== 1'b1) begin
                reset_state();
                continue;
            end
            sample_aw();
            sample_w();
            sample_b();
            sample_ar();
            sample_r();
        end
    endtask

    function void reset_state();
        aw_pending_q.delete();
        w_pending_q.delete();
        ar_pending_q.delete();
        aw_stall_cnt = 0;
        w_stall_cnt  = 0;
        ar_stall_cnt = 0;
        b_stall_cnt  = 0;
        r_stall_cnt  = 0;
    endfunction

    // -- AW channel ----------------------------------------
    function void sample_aw();
        axi4lite_seq_item item;
        if (vif.monitor_cb.awvalid && !vif.monitor_cb.awready)
            aw_stall_cnt++;

        if (vif.monitor_cb.awvalid && vif.monitor_cb.awready) begin
            item = axi4lite_seq_item::type_id::create("aw_item");
            item.direction       = AXI_WRITE;
            item.addr            = vif.monitor_cb.awaddr;
            item.prot            = vif.monitor_cb.awprot;
            item.aw_stall_cycles = aw_stall_cnt;
            aw_pending_q.push_back(item);

            `uvm_info("LITE_MMON",
                $sformatf("AW captured: addr=0x%08h stall=%0d",
                    item.addr, item.aw_stall_cycles), UVM_HIGH)
            aw_stall_cnt = 0;
        end
    endfunction

    // -- W channel -----------------------------------------
    function void sample_w();
        axi4lite_seq_item item;
        if (vif.monitor_cb.wvalid && !vif.monitor_cb.wready)
            w_stall_cnt++;

        if (vif.monitor_cb.wvalid && vif.monitor_cb.wready) begin
            item = axi4lite_seq_item::type_id::create("w_item");
            item.data           = vif.monitor_cb.wdata;
            item.strb           = vif.monitor_cb.wstrb;
            item.w_stall_cycles = w_stall_cnt;
            w_pending_q.push_back(item);

            `uvm_info("LITE_MMON",
                $sformatf("W captured: data=0x%08h strb=0x%h",
                    item.data, item.strb), UVM_HIGH)
            w_stall_cnt = 0;
        end
    endfunction

    // -- B channel -- assemble complete write item ---------
    function void sample_b();
        axi4lite_seq_item aw_item, w_item, complete;
        if (vif.monitor_cb.bvalid && !vif.monitor_cb.bready)
            b_stall_cnt++;

        if (vif.monitor_cb.bvalid && vif.monitor_cb.bready) begin
            if (aw_pending_q.size() == 0 || w_pending_q.size() == 0) begin
                `uvm_error("LITE_MMON",
                    "B response with no pending AW or W")
                b_stall_cnt = 0;
                return;
            end

            aw_item = aw_pending_q.pop_front();
            w_item  = w_pending_q.pop_front();

            complete = axi4lite_seq_item::type_id::create("wr_complete");
            complete.direction       = AXI_WRITE;
            complete.addr            = aw_item.addr;
            complete.prot            = aw_item.prot;
            complete.data            = w_item.data;
            complete.strb            = w_item.strb;
            complete.resp            = vif.monitor_cb.bresp;
            complete.aw_stall_cycles = aw_item.aw_stall_cycles;
            complete.w_stall_cycles  = w_item.w_stall_cycles;
            complete.b_stall_cycles  = b_stall_cnt;

            // Negative check: EXOKAY illegal on Lite
            if (complete.resp == AXI_EXOKAY)
                `uvm_error("LITE_MMON",
                    $sformatf("EXOKAY on Lite write addr=0x%08h -- ILLEGAL",
                        complete.addr))

            `uvm_info("LITE_MMON",
                $sformatf("WR complete: addr=0x%08h data=0x%08h resp=%0b",
                    complete.addr, complete.data, complete.resp), UVM_MEDIUM)

            // Publish to scoreboard (scoreboard judges DECERR/SLVERR)
            ap.write(complete);
            b_stall_cnt = 0;
        end
    endfunction

    // -- AR channel ----------------------------------------
    function void sample_ar();
        axi4lite_seq_item item;
        if (vif.monitor_cb.arvalid && !vif.monitor_cb.arready)
            ar_stall_cnt++;

        if (vif.monitor_cb.arvalid && vif.monitor_cb.arready) begin
            item = axi4lite_seq_item::type_id::create("ar_item");
            item.direction       = AXI_READ;
            item.addr            = vif.monitor_cb.araddr;
            item.prot            = vif.monitor_cb.arprot;
            item.ar_stall_cycles = ar_stall_cnt;
            ar_pending_q.push_back(item);

            `uvm_info("LITE_MMON",
                $sformatf("AR captured: addr=0x%08h", item.addr), UVM_HIGH)
            ar_stall_cnt = 0;
        end
    endfunction

    // -- R channel -- assemble complete read item -----------
    function void sample_r();
        axi4lite_seq_item ar_item, complete;
        if (vif.monitor_cb.rvalid && !vif.monitor_cb.rready)
            r_stall_cnt++;

        if (vif.monitor_cb.rvalid && vif.monitor_cb.rready) begin
            if (ar_pending_q.size() == 0) begin
                `uvm_error("LITE_MMON", "R data with no pending AR")
                r_stall_cnt = 0;
                return;
            end

            ar_item = ar_pending_q.pop_front();

            complete = axi4lite_seq_item::type_id::create("rd_complete");
            complete.direction       = AXI_READ;
            complete.addr            = ar_item.addr;
            complete.prot            = ar_item.prot;
            complete.rdata           = vif.monitor_cb.rdata;
            complete.resp            = vif.monitor_cb.rresp;
            complete.ar_stall_cycles = ar_item.ar_stall_cycles;
            complete.r_stall_cycles  = r_stall_cnt;

            if (complete.resp == AXI_EXOKAY)
                `uvm_error("LITE_MMON",
                    $sformatf("EXOKAY on Lite read addr=0x%08h -- ILLEGAL",
                        complete.addr))

            `uvm_info("LITE_MMON",
                $sformatf("RD complete: addr=0x%08h rdata=0x%08h resp=%0b",
                    complete.addr, complete.rdata, complete.resp), UVM_MEDIUM)

            ap.write(complete);
            r_stall_cnt = 0;
        end
    endfunction

endclass : axi4lite_master_monitor
