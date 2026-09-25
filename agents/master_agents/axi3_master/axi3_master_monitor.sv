`include "uvm_macros.svh"
import uvm_pkg::*;
import axi_seq_item_pkg::*;

// ============================================================
// axi3_master_monitor.sv
// Passive monitor on DUT S01_AXI (AXI3 slave port)
//
// AXI3 specific checks:
//   - WID must match AWID on every W beat
//   - WLAST must be on correct beat
//   - RLAST must be on correct beat
//   - BID must match AWID
//   - RID must match ARID per beat
// Publishes complete burst transactions to scoreboard
//
// FIXES:
//   - Single sampling loop in fixed channel order (no race
//     between forked per-channel threads on the same edge)
//   - rdata/rresp collected with push_back. The old code did
//     item.rdata[beat_idx] = ... on an EMPTY queue, which is an
//     out-of-bounds write -> ignored -> reads published with no
//     data -> scoreboard compared X/garbage.
//   - WID checked against the oldest AW whose data is not yet
//     complete (w_aw_idx), not simply aw_pending_q[0]
//   - WLAST position checked against AWLEN
// ============================================================

class axi3_master_monitor extends uvm_monitor;

    `uvm_component_utils(axi3_master_monitor)

    virtual axi3_if vif;

    // -- Analysis port -------------------------------------
    uvm_analysis_port #(axi3_seq_item) ap;

    // -- Internal staging ----------------------------------
    axi3_seq_item aw_pending_q[$];   // AW waiting for B
    axi3_seq_item w_pending_q[$];    // completed W bursts waiting for B
    axi3_seq_item ar_pending_q[$];   // AR waiting for R
    axi3_seq_item w_cur;             // W burst being assembled
    int unsigned  w_aw_idx;          // index into aw_pending_q of w_cur's AW
    int           r_beat_idx;

    // -- Stall tracking ------------------------------------
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
        if (!uvm_config_db #(virtual axi3_if)::get(
                this, "", "vif", vif))
            `uvm_fatal("NOVIF",
                "axi3_master_monitor: cannot get vif")
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
        w_cur      = null;
        w_aw_idx   = 0;
        r_beat_idx = 0;
        aw_stall_cnt = 0; w_stall_cnt = 0; ar_stall_cnt = 0;
        b_stall_cnt  = 0; r_stall_cnt = 0;
    endfunction

    // -- AW channel ----------------------------------------
    function void sample_aw();
        axi3_seq_item item;
        if (vif.monitor_cb.awvalid && !vif.monitor_cb.awready)
            aw_stall_cnt++;

        if (vif.monitor_cb.awvalid && vif.monitor_cb.awready) begin
            item = axi3_seq_item::type_id::create("aw_item");
            item.direction       = AXI_WRITE;
            item.id              = vif.monitor_cb.awid;
            item.addr            = vif.monitor_cb.awaddr;
            item.len             = vif.monitor_cb.awlen;
            item.size            = vif.monitor_cb.awsize;
            item.burst           = axi_burst_e'(vif.monitor_cb.awburst);
            item.lock            = vif.monitor_cb.awlock;
            item.cache           = vif.monitor_cb.awcache;
            item.prot            = vif.monitor_cb.awprot;
            item.aw_stall_cycles = aw_stall_cnt;
            aw_pending_q.push_back(item);

            `uvm_info("AXI3_MMON",
                $sformatf("AW: id=%0h addr=0x%08h len=%0d burst=%s",
                    item.id, item.addr, item.len, item.burst.name()),
                UVM_HIGH)
            aw_stall_cnt = 0;
        end
    endfunction

    // -- W channel (burst beats) ---------------------------
    function void sample_w();
        int beat_idx;
        if (vif.monitor_cb.wvalid && !vif.monitor_cb.wready)
            w_stall_cnt++;

        if (vif.monitor_cb.wvalid && vif.monitor_cb.wready) begin
            // First beat -- create item
            if (w_cur == null) begin
                w_cur = axi3_seq_item::type_id::create("w_item");
                w_cur.wdata = new[0];
                w_cur.wstrb = new[0];
            end
            beat_idx = w_cur.wdata.size();

            // AXI3: WID must match the AWID of this burst
            if (w_aw_idx < aw_pending_q.size()) begin
                if (vif.monitor_cb.wid[1:0] !== aw_pending_q[w_aw_idx].id)
                    `uvm_error("AXI3_MMON",
                        $sformatf("WID=0x%0h != AWID=0x%0h at beat %0d",
                            vif.monitor_cb.wid,
                            aw_pending_q[w_aw_idx].id, beat_idx))
                if (vif.monitor_cb.wlast !== (beat_idx == aw_pending_q[w_aw_idx].len))
                    `uvm_error("AXI3_MMON",
                        $sformatf("WLAST=%0b at beat %0d but AWLEN=%0d",
                            vif.monitor_cb.wlast, beat_idx,
                            aw_pending_q[w_aw_idx].len))
            end

            w_cur.wdata = new[beat_idx + 1](w_cur.wdata);
            w_cur.wstrb = new[beat_idx + 1](w_cur.wstrb);
            w_cur.wdata[beat_idx] = vif.monitor_cb.wdata;
            w_cur.wstrb[beat_idx] = vif.monitor_cb.wstrb;
            w_cur.w_stall_cycles  = w_stall_cnt;

            `uvm_info("AXI3_MMON",
                $sformatf("W: beat=%0d data=0x%08h strb=0x%h wlast=%0b",
                    beat_idx, vif.monitor_cb.wdata,
                    vif.monitor_cb.wstrb, vif.monitor_cb.wlast),
                UVM_HIGH)

            // WLAST -- burst complete
            if (vif.monitor_cb.wlast) begin
                w_pending_q.push_back(w_cur);
                w_cur = null;
                w_aw_idx++;
            end
            w_stall_cnt = 0;
        end
    endfunction

    // -- B channel -- assemble complete write ---------------
    function void sample_b();
        axi3_seq_item aw_item, w_item, complete;
        if (vif.monitor_cb.bvalid && !vif.monitor_cb.bready)
            b_stall_cnt++;

        if (vif.monitor_cb.bvalid && vif.monitor_cb.bready) begin
            if (aw_pending_q.size() == 0 || w_pending_q.size() == 0) begin
                `uvm_error("AXI3_MMON", "B with no pending AW or W burst")
                b_stall_cnt = 0;
                return;
            end

            aw_item = aw_pending_q.pop_front();
            w_item  = w_pending_q.pop_front();
            if (w_aw_idx > 0) w_aw_idx--;

            // BID must match AWID
            if (vif.monitor_cb.bid[1:0] !== aw_item.id[1:0])
                `uvm_error("AXI3_MMON",
                    $sformatf("BID=0x%0h != AWID=0x%0h",
                        vif.monitor_cb.bid, aw_item.id))

            if (w_item.wdata.size() != aw_item.len + 1)
                `uvm_error("AXI3_MMON",
                    $sformatf("W beats=%0d != AWLEN+1=%0d",
                        w_item.wdata.size(), aw_item.len + 1))

            complete = axi3_seq_item::type_id::create("wr_complete");
            complete.direction       = AXI_WRITE;
            complete.id              = aw_item.id;
            complete.addr            = aw_item.addr;
            complete.len             = aw_item.len;
            complete.size            = aw_item.size;
            complete.burst           = aw_item.burst;
            complete.lock            = aw_item.lock;
            complete.cache           = aw_item.cache;
            complete.prot            = aw_item.prot;
            complete.wdata           = w_item.wdata;
            complete.wstrb           = w_item.wstrb;
            complete.bresp           = vif.monitor_cb.bresp;
            complete.aw_stall_cycles = aw_item.aw_stall_cycles;
            complete.w_stall_cycles  = w_item.w_stall_cycles;
            complete.b_stall_cycles  = b_stall_cnt;

            `uvm_info("AXI3_MMON",
                $sformatf("WR complete: id=%0h addr=0x%08h len=%0d resp=%0b",
                    complete.id, complete.addr,
                    complete.len, complete.bresp), UVM_MEDIUM)

            ap.write(complete);
            b_stall_cnt = 0;
        end
    endfunction

    // -- AR channel ----------------------------------------
    function void sample_ar();
        axi3_seq_item item;
        if (vif.monitor_cb.arvalid && !vif.monitor_cb.arready)
            ar_stall_cnt++;

        if (vif.monitor_cb.arvalid && vif.monitor_cb.arready) begin
            item = axi3_seq_item::type_id::create("ar_item");
            item.direction       = AXI_READ;
            item.id              = vif.monitor_cb.arid;
            item.addr            = vif.monitor_cb.araddr;
            item.len             = vif.monitor_cb.arlen;
            item.size            = vif.monitor_cb.arsize;
            item.burst           = axi_burst_e'(vif.monitor_cb.arburst);
            item.lock            = vif.monitor_cb.arlock;
            item.cache           = vif.monitor_cb.arcache;
            item.prot            = vif.monitor_cb.arprot;
            item.ar_stall_cycles = ar_stall_cnt;
            item.wdata           = new[0];
            item.wstrb           = new[0];
            ar_pending_q.push_back(item);

            `uvm_info("AXI3_MMON",
                $sformatf("AR: id=%0h addr=0x%08h len=%0d", item.id,
                    item.addr, item.len), UVM_HIGH)
            ar_stall_cnt = 0;
        end
    endfunction

    // -- R channel (burst beats) ---------------------------
    function void sample_r();
        axi3_seq_item ar_item;
        if (vif.monitor_cb.rvalid && !vif.monitor_cb.rready)
            r_stall_cnt++;

        if (vif.monitor_cb.rvalid && vif.monitor_cb.rready) begin
            if (ar_pending_q.size() == 0) begin
                `uvm_error("AXI3_MMON", "R data with no pending AR")
                r_stall_cnt = 0;
                return;
            end
            ar_item = ar_pending_q[0];

            // RID must match ARID per beat
            if (vif.monitor_cb.rid[1:0] !== ar_item.id[1:0])
                `uvm_error("AXI3_MMON",
                    $sformatf("RID=0x%0h != ARID=0x%0h at beat %0d",
                        vif.monitor_cb.rid, ar_item.id, r_beat_idx))

            ar_item.rdata.push_back(vif.monitor_cb.rdata);
            ar_item.rresp.push_back(vif.monitor_cb.rresp);
            ar_item.r_stall_cycles = r_stall_cnt;

            `uvm_info("AXI3_MMON",
                $sformatf("R: beat=%0d data=0x%08h rlast=%0b",
                    r_beat_idx, vif.monitor_cb.rdata,
                    vif.monitor_cb.rlast), UVM_HIGH)

            r_beat_idx++;

            if (vif.monitor_cb.rlast) begin
                // Verify beat count matches len
                if (r_beat_idx != ar_item.len + 1)
                    `uvm_error("AXI3_MMON",
                        $sformatf("R beats=%0d != ARLEN+1=%0d",
                            r_beat_idx, ar_item.len + 1))

                void'(ar_pending_q.pop_front());

                `uvm_info("AXI3_MMON",
                    $sformatf("RD complete: id=%0h addr=0x%08h len=%0d",
                        ar_item.id, ar_item.addr, ar_item.len), UVM_MEDIUM)

                ap.write(ar_item);
                r_beat_idx = 0;
            end else if (r_beat_idx == ar_item.len + 1) begin
                `uvm_error("AXI3_MMON",
                    $sformatf("RLAST missing on final beat %0d", r_beat_idx - 1))
            end
            r_stall_cnt = 0;
        end
    endfunction

endclass : axi3_master_monitor
