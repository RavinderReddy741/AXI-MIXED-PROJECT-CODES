`include "uvm_macros.svh"
import uvm_pkg::*;
import axi_seq_item_pkg::*;

// ============================================================
// axi4_master_monitor.sv
// Passive monitor on DUT S02_AXI (AXI4 slave port)
//
// AXI4 specific:
//   - No WID to check
//   - awlen is 8-bit, awlock is 1-bit
//   - awqos and awregion captured
//   - Out-of-order response handling (by ID)
//
// FIXES:
//   - RID/BID matched on (id & id_mask). The interconnect returns
//     its slot number in the upper ID bits (ARID=2 -> RID=0xA), so
//     the old full-ID compare never matched: every S02 read was
//     dropped with an INFO message and never reached the scoreboard.
//   - B matched to its AW by ID (was blind FIFO pop)
//   - Protocol problems are UVM_ERRORs again (were demoted to INFO)
//   - Single sampling loop in fixed channel order
// ============================================================

class axi4_master_monitor extends uvm_monitor;

    `uvm_component_utils(axi4_master_monitor)

    virtual axi4_if vif;

    // -- Analysis port -------------------------------------
    uvm_analysis_port #(axi4_seq_item) ap;

    // -- ID handling ---------------------------------------
    int unsigned id_mask = 'h3;

    // -- Internal queues -----------------------------------
    axi4_seq_item aw_q[$];          // AW waiting for B
    axi4_seq_item w_q[$];           // W bursts (AXI4: in AW order)
    axi4_seq_item ar_pending_q[$];  // AR waiting for first R beat
    axi4_seq_item r_pkt[int];       // R burst assembly, key = masked RID
    axi4_seq_item w_cur;

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
        if (!uvm_config_db #(virtual axi4_if)::get(
                this, "", "vif", vif))
            `uvm_fatal("NOVIF",
                "axi4_master_monitor: cannot get vif")
        void'(uvm_config_db #(int unsigned)::get(this, "", "id_mask", id_mask));
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
        aw_q.delete();
        w_q.delete();
        ar_pending_q.delete();
        r_pkt.delete();
        w_cur = null;
        aw_stall_cnt = 0; w_stall_cnt = 0; ar_stall_cnt = 0;
        b_stall_cnt  = 0; r_stall_cnt = 0;
    endfunction

    function int key_of(logic [3:0] id);
        return int'(id) & int'(id_mask);
    endfunction

    // -- AW channel ----------------------------------------
    function void sample_aw();
        axi4_seq_item item;
        if (vif.monitor_cb.awvalid && !vif.monitor_cb.awready)
            aw_stall_cnt++;

        if (vif.monitor_cb.awvalid && vif.monitor_cb.awready) begin
            item = axi4_seq_item::type_id::create("aw_item");
            item.direction       = AXI_WRITE;
            item.id              = vif.monitor_cb.awid;
            item.addr            = vif.monitor_cb.awaddr;
            item.len             = vif.monitor_cb.awlen;
            item.size            = vif.monitor_cb.awsize;
            item.burst           = axi_burst_e'(vif.monitor_cb.awburst);
            item.lock            = vif.monitor_cb.awlock;
            item.cache           = vif.monitor_cb.awcache;
            item.prot            = vif.monitor_cb.awprot;
            item.qos             = vif.monitor_cb.awqos;
            item.region          = vif.monitor_cb.awregion;
            item.aw_stall_cycles = aw_stall_cnt;
            aw_q.push_back(item);

            `uvm_info("AXI4_MMON",
                $sformatf("AW: id=%0h addr=0x%08h len=%0d burst=%s lock=%0b qos=%0d region=%0d",
                    item.id, item.addr, item.len,
                    item.burst.name(), item.lock,
                    item.qos, item.region), UVM_HIGH)
            aw_stall_cnt = 0;
        end
    endfunction

    // -- W channel -- no WID, collect beats until WLAST -----
    function void sample_w();
        int beat_idx;
        if (vif.monitor_cb.wvalid && !vif.monitor_cb.wready)
            w_stall_cnt++;

        if (vif.monitor_cb.wvalid && vif.monitor_cb.wready) begin
            if (w_cur == null) begin
                w_cur = axi4_seq_item::type_id::create("w_item");
                w_cur.wdata = new[0];
                w_cur.wstrb = new[0];
            end
            beat_idx = w_cur.wdata.size();
            w_cur.wdata = new[beat_idx + 1](w_cur.wdata);
            w_cur.wstrb = new[beat_idx + 1](w_cur.wstrb);
            w_cur.wdata[beat_idx] = vif.monitor_cb.wdata;
            w_cur.wstrb[beat_idx] = vif.monitor_cb.wstrb;
            w_cur.w_stall_cycles  = w_stall_cnt;

            `uvm_info("AXI4_MMON",
                $sformatf("W: beat=%0d data=0x%08h strb=0x%h wlast=%0b",
                    beat_idx, vif.monitor_cb.wdata,
                    vif.monitor_cb.wstrb, vif.monitor_cb.wlast), UVM_HIGH)

            if (vif.monitor_cb.wlast) begin
                w_q.push_back(w_cur);
                w_cur = null;
            end
            w_stall_cnt = 0;
        end
    endfunction

    // -- B channel -----------------------------------------
    function void sample_b();
        axi4_seq_item aw_item, w_item, complete;
        int idx = -1;
        int wr_pos;
        if (vif.monitor_cb.bvalid && !vif.monitor_cb.bready)
            b_stall_cnt++;

        if (vif.monitor_cb.bvalid && vif.monitor_cb.bready) begin
            // Oldest AW with the same (masked) ID
            foreach (aw_q[i])
                if (key_of(aw_q[i].id) == key_of(vif.monitor_cb.bid)) begin
                    idx = i;
                    break;
                end

            // W bursts are in AW order: AW position = W position
            if (idx < 0 || idx >= w_q.size()) begin
                `uvm_error("AXI4_MMON",
                    $sformatf("B (bid=0x%0h) with no matching AW/W", vif.monitor_cb.bid))
                b_stall_cnt = 0;
                return;
            end
            wr_pos  = idx;
            aw_item = aw_q[wr_pos];
            w_item  = w_q[wr_pos];
            aw_q.delete(wr_pos);
            w_q.delete(wr_pos);

            if (w_item.wdata.size() != aw_item.len + 1)
                `uvm_error("AXI4_MMON",
                    $sformatf("W beats=%0d != AWLEN+1=%0d",
                        w_item.wdata.size(), aw_item.len + 1))

            complete = axi4_seq_item::type_id::create("wr_complete");
            complete.direction       = AXI_WRITE;
            complete.id              = aw_item.id;
            complete.addr            = aw_item.addr;
            complete.len             = aw_item.len;
            complete.size            = aw_item.size;
            complete.burst           = aw_item.burst;
            complete.lock            = aw_item.lock;
            complete.cache           = aw_item.cache;
            complete.prot            = aw_item.prot;
            complete.qos             = aw_item.qos;
            complete.region          = aw_item.region;
            complete.wdata           = w_item.wdata;
            complete.wstrb           = w_item.wstrb;
            complete.bresp           = vif.monitor_cb.bresp;
            complete.aw_stall_cycles = aw_item.aw_stall_cycles;
            complete.w_stall_cycles  = w_item.w_stall_cycles;
            complete.b_stall_cycles  = b_stall_cnt;

            if (complete.bresp == AXI_EXOKAY && complete.lock == 1'b0)
                `uvm_error("AXI4_MMON",
                    $sformatf("EXOKAY on non-exclusive write addr=0x%08h",
                        complete.addr))

            `uvm_info("AXI4_MMON",
                $sformatf("WR complete: id=%0h addr=0x%08h len=%0d resp=%0b",
                    complete.id, complete.addr,
                    complete.len, complete.bresp), UVM_MEDIUM)

            ap.write(complete);
            b_stall_cnt = 0;
        end
    endfunction

    // -- AR channel ----------------------------------------
    function void sample_ar();
        axi4_seq_item item;
        if (vif.monitor_cb.arvalid && !vif.monitor_cb.arready)
            ar_stall_cnt++;

        if (vif.monitor_cb.arvalid && vif.monitor_cb.arready) begin
            item = axi4_seq_item::type_id::create("ar_item");
            item.direction       = AXI_READ;
            item.id              = vif.monitor_cb.arid;
            item.addr            = vif.monitor_cb.araddr;
            item.len             = vif.monitor_cb.arlen;
            item.size            = vif.monitor_cb.arsize;
            item.burst           = axi_burst_e'(vif.monitor_cb.arburst);
            item.lock            = vif.monitor_cb.arlock;
            item.cache           = vif.monitor_cb.arcache;
            item.prot            = vif.monitor_cb.arprot;
            item.qos             = vif.monitor_cb.arqos;
            item.region          = vif.monitor_cb.arregion;
            item.ar_stall_cycles = ar_stall_cnt;
            item.wdata           = new[0];
            item.wstrb           = new[0];
            ar_pending_q.push_back(item);

            `uvm_info("AXI4_MMON",
                $sformatf("AR: id=%0h addr=0x%08h len=%0d burst=%s",
                    item.id, item.addr, item.len, item.burst.name()),
                UVM_HIGH)
            ar_stall_cnt = 0;
        end
    endfunction

    // -- R channel -- out-of-order, tracked by (masked) RID --
    function void sample_r();
        int rid_int;
        axi4_seq_item complete;
        if (vif.monitor_cb.rvalid && !vif.monitor_cb.rready)
            r_stall_cnt++;

        if (vif.monitor_cb.rvalid && vif.monitor_cb.rready) begin
            rid_int = key_of(vif.monitor_cb.rid);

            // First beat for this RID -> oldest AR with same ID
            if (!r_pkt.exists(rid_int)) begin
                foreach (ar_pending_q[i]) begin
                    if (key_of(ar_pending_q[i].id) == rid_int) begin
                        r_pkt[rid_int] = ar_pending_q[i];
                        ar_pending_q.delete(i);
                        break;
                    end
                end
                if (!r_pkt.exists(rid_int)) begin
                    `uvm_error("AXI4_MMON",
                        $sformatf("R data RID=0x%0h with no matching AR",
                            vif.monitor_cb.rid))
                    r_stall_cnt = 0;
                    return;
                end
            end

            r_pkt[rid_int].rdata.push_back(vif.monitor_cb.rdata);
            r_pkt[rid_int].rresp.push_back(vif.monitor_cb.rresp);
            r_pkt[rid_int].r_stall_cycles = r_stall_cnt;

            `uvm_info("AXI4_MMON",
                $sformatf("R: id=%0h beat=%0d data=0x%08h rlast=%0b",
                    rid_int, r_pkt[rid_int].rdata.size()-1,
                    vif.monitor_cb.rdata, vif.monitor_cb.rlast), UVM_HIGH)

            if (vif.monitor_cb.rlast) begin
                complete = r_pkt[rid_int];
                r_pkt.delete(rid_int);
                if (complete.rdata.size() != complete.len + 1)
                    `uvm_error("AXI4_MMON",
                        $sformatf("R beats=%0d != ARLEN+1=%0d (addr=0x%08h)",
                            complete.rdata.size(), complete.len + 1, complete.addr))

                `uvm_info("AXI4_MMON",
                    $sformatf("RD complete: id=%0h addr=0x%08h len=%0d",
                        complete.id, complete.addr, complete.len), UVM_MEDIUM)
                ap.write(complete);
            end else if (r_pkt[rid_int].rdata.size() > r_pkt[rid_int].len) begin
                `uvm_error("AXI4_MMON",
                    $sformatf("RLAST missing on final beat (ARLEN=%0d)",
                        r_pkt[rid_int].len))
            end
            r_stall_cnt = 0;
        end
    endfunction

endclass : axi4_master_monitor
