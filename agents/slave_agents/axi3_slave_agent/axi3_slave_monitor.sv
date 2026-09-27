`include "uvm_macros.svh"
import uvm_pkg::*;
import axi_seq_item_pkg::*;

// ============================================================
// axi3_slave_monitor.sv
// Passive monitor on DUT M01_AXI (AXI3 master port)
//
// INTERCONNECT ID EXTENSION:
//   AWID[3:0] on M01 = {slot[1:0], orig_id[1:0]}
//   slot: 2'b00 Lite, 2'b01 AXI3, 2'b10 AXI4
//
// CHECKS:
//   1. Routing: address must be in M01 region
//   2. WID == AWID per beat (AXI3 spec)
//   3. WLAST / RLAST on correct beat
//   4. BID == AWID, RID == ARID per beat
//   5. Source-aware interop: Lite source -> AWLEN=0, WLAST=1
//
// FIXES:
//   - rdata/rresp collected with push_back (indexed write into an
//     empty queue was silently dropped -> reads had no data)
//   - Single sampling loop in fixed channel order
// ============================================================

class axi3_slave_monitor extends uvm_monitor;

    `uvm_component_utils(axi3_slave_monitor)

    virtual axi3_if vif;

    uvm_analysis_port #(axi3_seq_item) ap;

    // -- Address region ------------------------------------
    logic [31:0] region_lo = 32'h44A1_0000;
    logic [31:0] region_hi = 32'h44A1_FFFF;

    // -- Enable interoperability checks --------------------
    bit check_incompat = 1;

    // -- Internal queues -----------------------------------
    axi3_seq_item aw_q[$];
    axi3_seq_item w_q[$];
    axi3_seq_item ar_q[$];
    axi3_seq_item w_cur;
    int unsigned  w_aw_idx;
    int           r_beat_idx;

    // -- Stall tracking ------------------------------------
    int unsigned aw_stall;
    int unsigned w_stall;
    int unsigned ar_stall;
    int unsigned b_stall;
    int unsigned r_stall;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        ap = new("ap", this);
        if (!uvm_config_db #(virtual axi3_if)::get(
                this, "", "vif", vif))
            `uvm_fatal("NOVIF",
                "axi3_slave_monitor: cannot get vif")
        void'(uvm_config_db #(logic [31:0])::get(this, "", "region_lo", region_lo));
        void'(uvm_config_db #(logic [31:0])::get(this, "", "region_hi", region_hi));
        void'(uvm_config_db #(bit)::get(this, "", "check_incompat", check_incompat));
    endfunction

    task run_phase(uvm_phase phase);
        forever begin
            @(vif.monitor_cb);
            if (vif.aresetn !== 1'b1) begin
                aw_q.delete(); w_q.delete(); ar_q.delete();
                w_cur = null; w_aw_idx = 0; r_beat_idx = 0;
                aw_stall = 0; w_stall = 0; ar_stall = 0;
                b_stall  = 0; r_stall = 0;
                continue;
            end
            sample_aw();
            sample_w();
            sample_b();
            sample_ar();
            sample_r();
        end
    endtask

    // Source-slot interop check, shared by AW and AR. M01 has no
    // QoS/Region signals of its own (AXI3 never had them), so the
    // only thing to check here is the Lite-source single-beat rule --
    // but it must hold on BOTH channels, not just writes.
    function void check_source_incompat(string chan, logic [3:0] id, logic [3:0] len);
        if (check_incompat && id[3:2] == 2'b00 && len != 4'h0)
            `uvm_error("AXI3_SMON",
                $sformatf("[M01] INCOMPAT: %sLEN=%0d from Lite source -- must be 0",
                    chan, len))
    endfunction

    // -- AW ------------------------------------------------
    function void sample_aw();
        axi3_seq_item item;
        if (vif.monitor_cb.awvalid && !vif.monitor_cb.awready) aw_stall++;
        if (vif.monitor_cb.awvalid && vif.monitor_cb.awready) begin

            // CHECK 1: Routing
            if (!(vif.monitor_cb.awaddr inside {[region_lo:region_hi]}))
                `uvm_error("AXI3_SMON",
                    $sformatf("[M01] ROUTING FAIL: wr addr=0x%08h id=0x%0h not in M01 region",
                        vif.monitor_cb.awaddr, vif.monitor_cb.awid))

            check_source_incompat("AW", vif.monitor_cb.awid, vif.monitor_cb.awlen);

            item = axi3_seq_item::type_id::create("aw");
            item.direction       = AXI_WRITE;
            item.id              = vif.monitor_cb.awid;
            item.addr            = vif.monitor_cb.awaddr;
            item.len             = vif.monitor_cb.awlen;
            item.size            = vif.monitor_cb.awsize;
            item.burst           = axi_burst_e'(vif.monitor_cb.awburst);
            item.lock            = vif.monitor_cb.awlock;
            item.cache           = vif.monitor_cb.awcache;
            item.prot            = vif.monitor_cb.awprot;
            item.full_id         = vif.monitor_cb.awid;
            item.aw_stall_cycles = aw_stall;
            aw_q.push_back(item);

            `uvm_info("AXI3_SMON",
                $sformatf("[M01] AW: id=0x%0h addr=0x%08h len=%0d burst=%s lock=%0b",
                    vif.monitor_cb.awid, item.addr, item.len,
                    item.burst.name(), item.lock), UVM_HIGH)
            aw_stall = 0;
        end
    endfunction

    // -- W -------------------------------------------------
    function void sample_w();
        int beat_idx;
        if (vif.monitor_cb.wvalid && !vif.monitor_cb.wready) w_stall++;
        if (vif.monitor_cb.wvalid && vif.monitor_cb.wready) begin
            if (w_cur == null) begin
                w_cur = axi3_seq_item::type_id::create("w");
                w_cur.wdata = new[0];
                w_cur.wstrb = new[0];
            end
            beat_idx = w_cur.wdata.size();

            if (w_aw_idx < aw_q.size()) begin
                // CHECK 2: WID == AWID per beat
                if (vif.monitor_cb.wid !== aw_q[w_aw_idx].full_id)
                    `uvm_error("AXI3_SMON",
                        $sformatf("[M01] WID=0x%0h != AWID=0x%0h at beat %0d",
                            vif.monitor_cb.wid, aw_q[w_aw_idx].full_id, beat_idx))
                // CHECK 3: WLAST on correct beat
                if (vif.monitor_cb.wlast !== (beat_idx == aw_q[w_aw_idx].len))
                    `uvm_error("AXI3_SMON",
                        $sformatf("[M01] WLAST=%0b at beat %0d but AWLEN=%0d",
                            vif.monitor_cb.wlast, beat_idx, aw_q[w_aw_idx].len))
            end

            w_cur.wdata = new[beat_idx+1](w_cur.wdata);
            w_cur.wstrb = new[beat_idx+1](w_cur.wstrb);
            w_cur.wdata[beat_idx] = vif.monitor_cb.wdata;
            w_cur.wstrb[beat_idx] = vif.monitor_cb.wstrb;
            w_cur.w_stall_cycles  = w_stall;

            if (vif.monitor_cb.wlast) begin
                w_q.push_back(w_cur);
                w_cur = null;
                w_aw_idx++;
            end
            w_stall = 0;
        end
    endfunction

    // -- B -------------------------------------------------
    function void sample_b();
        axi3_seq_item aw_it, w_it, complete;
        if (vif.monitor_cb.bvalid && !vif.monitor_cb.bready) b_stall++;
        if (vif.monitor_cb.bvalid && vif.monitor_cb.bready) begin
            if (aw_q.size() == 0 || w_q.size() == 0) begin
                `uvm_error("AXI3_SMON", "[M01] B with no pending AW or W")
                b_stall = 0;
                return;
            end
            aw_it = aw_q.pop_front();
            w_it  = w_q.pop_front();
            if (w_aw_idx > 0) w_aw_idx--;

            // CHECK 4: BID == AWID (full extended ID)
            if (vif.monitor_cb.bid !== aw_it.full_id)
                `uvm_error("AXI3_SMON",
                    $sformatf("[M01] BID=0x%0h != AWID=0x%0h",
                        vif.monitor_cb.bid, aw_it.full_id))

            complete = axi3_seq_item::type_id::create("wr_complete");
            complete.direction       = AXI_WRITE;
            complete.id              = aw_it.id;
            complete.addr            = aw_it.addr;
            complete.len             = aw_it.len;
            complete.size            = aw_it.size;
            complete.burst           = aw_it.burst;
            complete.lock            = aw_it.lock;
            complete.cache           = aw_it.cache;
            complete.prot            = aw_it.prot;
            complete.wdata           = w_it.wdata;
            complete.wstrb           = w_it.wstrb;
            complete.bresp           = vif.monitor_cb.bresp;
            complete.aw_stall_cycles = aw_it.aw_stall_cycles;
            complete.w_stall_cycles  = w_it.w_stall_cycles;
            complete.b_stall_cycles  = b_stall;

            `uvm_info("AXI3_SMON",
                $sformatf("[M01] WR complete: id=0x%0h addr=0x%08h len=%0d resp=%0b",
                    aw_it.full_id, complete.addr, complete.len, complete.bresp), UVM_MEDIUM)
            ap.write(complete);
            b_stall = 0;
        end
    endfunction

    // -- AR ------------------------------------------------
    function void sample_ar();
        axi3_seq_item item;
        if (vif.monitor_cb.arvalid && !vif.monitor_cb.arready) ar_stall++;
        if (vif.monitor_cb.arvalid && vif.monitor_cb.arready) begin
            if (!(vif.monitor_cb.araddr inside {[region_lo:region_hi]}))
                `uvm_error("AXI3_SMON",
                    $sformatf("[M01] ROUTING FAIL: rd addr=0x%08h id=0x%0h",
                        vif.monitor_cb.araddr, vif.monitor_cb.arid))

            check_source_incompat("AR", vif.monitor_cb.arid, vif.monitor_cb.arlen);

            item = axi3_seq_item::type_id::create("ar");
            item.direction       = AXI_READ;
            item.id              = vif.monitor_cb.arid;
            item.full_id         = vif.monitor_cb.arid;
            item.addr            = vif.monitor_cb.araddr;
            item.len             = vif.monitor_cb.arlen;
            item.size            = vif.monitor_cb.arsize;
            item.burst           = axi_burst_e'(vif.monitor_cb.arburst);
            item.lock            = vif.monitor_cb.arlock;
            item.cache           = vif.monitor_cb.arcache;
            item.prot            = vif.monitor_cb.arprot;
            item.ar_stall_cycles = ar_stall;
            item.wdata           = new[0];
            item.wstrb           = new[0];
            ar_q.push_back(item);
            ar_stall = 0;
        end
    endfunction

    // -- R -------------------------------------------------
    function void sample_r();
        axi3_seq_item ar_it;
        if (vif.monitor_cb.rvalid && !vif.monitor_cb.rready) r_stall++;
        if (vif.monitor_cb.rvalid && vif.monitor_cb.rready) begin
            if (ar_q.size() == 0) begin
                `uvm_error("AXI3_SMON", "[M01] R with no pending AR")
                r_stall = 0;
                return;
            end
            ar_it = ar_q[0];

            // CHECK 4: RID == ARID per beat
            if (vif.monitor_cb.rid !== ar_it.full_id)
                `uvm_error("AXI3_SMON",
                    $sformatf("[M01] RID=0x%0h != ARID=0x%0h at beat %0d",
                        vif.monitor_cb.rid, ar_it.full_id, r_beat_idx))

            ar_it.rdata.push_back(vif.monitor_cb.rdata);
            ar_it.rresp.push_back(vif.monitor_cb.rresp);
            ar_it.r_stall_cycles = r_stall;
            r_beat_idx++;

            // CHECK 3: RLAST on correct beat
            if (vif.monitor_cb.rlast) begin
                if (r_beat_idx != ar_it.len + 1)
                    `uvm_error("AXI3_SMON",
                        $sformatf("[M01] RLAST at beat %0d but ARLEN+1=%0d",
                            r_beat_idx, ar_it.len + 1))
                void'(ar_q.pop_front());
                `uvm_info("AXI3_SMON",
                    $sformatf("[M01] RD complete: id=0x%0h addr=0x%08h len=%0d",
                        ar_it.full_id, ar_it.addr, ar_it.len), UVM_MEDIUM)
                ap.write(ar_it);
                r_beat_idx = 0;
            end else if (r_beat_idx == ar_it.len + 1) begin
                `uvm_error("AXI3_SMON",
                    $sformatf("[M01] RLAST missing on final beat %0d", r_beat_idx - 1))
            end
            r_stall = 0;
        end
    endfunction

endclass : axi3_slave_monitor
