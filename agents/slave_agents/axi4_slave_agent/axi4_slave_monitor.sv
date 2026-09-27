`include "uvm_macros.svh"
import uvm_pkg::*;
import axi_seq_item_pkg::*;

// ============================================================
// axi4_slave_monitor.sv
// Passive monitor on DUT M02_AXI and M03_AXI (AXI4 ports)
//
// CHECKS:
//   1.  Routing: address in configured region
//   2.  WLAST / RLAST on correct beat
//   3.  BID == AWID (full extended echo), RID == ARID per beat
//   4.  EXOKAY only on exclusive write
//   5.  No X on WDATA / RDATA
//
// INTEROPERABILITY CHECKS (source slot = AxID[3:2]):
//     2'b00 Lite source: AWLEN=0, WLAST=1, QoS=0, Region=0
//     2'b01 AXI3 source: AxQOS=0, AWREGION=0, AWLEN[7:4]=0
//     2'b10 AXI4 source: native, no extra checks
//
// FIX: every check had been demoted to `uvm_info(...,UVM_MEDIUM)`
//      so NOTHING on M02/M03 could ever fail a test. They are
//      `uvm_error again. Single sampling loop in fixed order.
//
// INSTANCE CONFIGURATION via config_db:
//   slave_m02: region_lo=0x44A2_0000 region_hi=0x44A2_FFFF
//   slave_m03: region_lo=0x44A3_0000 region_hi=0x44A3_FFFF
// ============================================================

class axi4_slave_monitor extends uvm_monitor;

    `uvm_component_utils(axi4_slave_monitor)

    virtual axi4_if vif;

    uvm_analysis_port #(axi4_seq_item) ap;

    // -- Region -- set per instance -------------------------
    logic [31:0] region_lo = 32'h44A2_0000;
    logic [31:0] region_hi = 32'h44A2_FFFF;

    // -- Enable interoperability checks --------------------
    bit check_incompat = 1;

    // -- Internal queues -----------------------------------
    axi4_seq_item aw_q[$];
    axi4_seq_item w_q[$];
    axi4_seq_item ar_q[$];
    axi4_seq_item r_pkt[int];  // indexed by RID
    axi4_seq_item w_cur;
    int unsigned  w_aw_idx;

    // -- Stall tracking ------------------------------------
    int unsigned aw_stall;
    int unsigned w_stall;
    int unsigned ar_stall;
    int unsigned b_stall;
    int unsigned r_stall;

    string tag;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        ap  = new("ap", this);
        tag = get_parent().get_name();
        if (!uvm_config_db #(virtual axi4_if)::get(
                this, "", "vif", vif))
            `uvm_fatal("NOVIF",
                "axi4_slave_monitor: cannot get vif")
        void'(uvm_config_db #(logic [31:0])::get(this, "", "region_lo", region_lo));
        void'(uvm_config_db #(logic [31:0])::get(this, "", "region_hi", region_hi));
        void'(uvm_config_db #(bit)::get(this, "", "check_incompat", check_incompat));
    endfunction

    task run_phase(uvm_phase phase);
        forever begin
            @(vif.monitor_cb);
            if (vif.aresetn !== 1'b1) begin
                aw_q.delete(); w_q.delete();
                ar_q.delete(); r_pkt.delete();
                w_cur = null; w_aw_idx = 0;
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

    // Source-slot interop check, shared by AW and AR so the read
    // path is checked exactly as thoroughly as the write path.
    // (Previously AR only checked AXI3-source QoS; the Lite-source
    // ARLEN=0 check and the AXI4-source-native/unknown-slot cases
    // were missing on reads, which is why a bad read burst length
    // from a Lite-sourced read could pass through unflagged.)
    function void check_source_incompat(
        string chan, logic [3:0] id, logic [7:0] len,
        logic [3:0] qos, logic [3:0] region
    );
        if (!check_incompat) return;
        case (id[3:2])
            2'b00: begin   // Lite source: single beat, no QoS/Region
                if (len != 8'h0)
                    `uvm_error("AXI4_SMON",
                        $sformatf("[%s] INCOMPAT: %sLEN=0x%02h from Lite source -- must be 0",
                            tag, chan, len))
                if (qos != 4'h0)
                    `uvm_error("AXI4_SMON",
                        $sformatf("[%s] INCOMPAT: %sQOS=0x%0h from Lite source -- must be 0",
                            tag, chan, qos))
                if (region != 4'h0)
                    `uvm_error("AXI4_SMON",
                        $sformatf("[%s] INCOMPAT: %sREGION=0x%0h from Lite source -- must be 0",
                            tag, chan, region))
            end
            2'b01: begin   // AXI3 source: no QoS/Region, LEN zero-extended from 4 bits
                if (qos != 4'h0)
                    `uvm_error("AXI4_SMON",
                        $sformatf("[%s] INCOMPAT: %sQOS=0x%0h from AXI3 source -- must be 0",
                            tag, chan, qos))
                if (region != 4'h0)
                    `uvm_error("AXI4_SMON",
                        $sformatf("[%s] INCOMPAT: %sREGION=0x%0h from AXI3 source -- must be 0",
                            tag, chan, region))
                if (len[7:4] != 4'h0)
                    `uvm_error("AXI4_SMON",
                        $sformatf("[%s] INCOMPAT: %sLEN=0x%02h from AXI3 source -- upper nibble must be 0",
                            tag, chan, len))
            end
            2'b10: ;       // AXI4 source -- native, no extra checks
            default:
                `uvm_error("AXI4_SMON",
                    $sformatf("[%s] UNKNOWN source slot 2'b%02b in %sID=0x%0h",
                        tag, id[3:2], chan, id))
        endcase
    endfunction

    // -- AW ------------------------------------------------
    function void sample_aw();
        axi4_seq_item item;
        if (vif.monitor_cb.awvalid && !vif.monitor_cb.awready) aw_stall++;
        if (vif.monitor_cb.awvalid && vif.monitor_cb.awready) begin

            // CHECK 1: Routing
            if (!(vif.monitor_cb.awaddr inside {[region_lo:region_hi]}))
                `uvm_error("AXI4_SMON",
                    $sformatf("[%s] ROUTING FAIL: wr addr=0x%08h id=0x%0h",
                        tag, vif.monitor_cb.awaddr, vif.monitor_cb.awid))

            check_source_incompat("AW", vif.monitor_cb.awid, vif.monitor_cb.awlen,
                                  vif.monitor_cb.awqos, vif.monitor_cb.awregion);

            item = axi4_seq_item::type_id::create("aw");
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
            item.aw_stall_cycles = aw_stall;
            aw_q.push_back(item);

            `uvm_info("AXI4_SMON",
                $sformatf("[%s] AW: id=0x%0h addr=0x%08h len=%0d burst=%s lock=%0b qos=%0d region=%0d",
                    tag, item.id, item.addr, item.len,
                    item.burst.name(), item.lock,
                    item.qos, item.region), UVM_HIGH)
            aw_stall = 0;
        end
    endfunction

    // -- W -------------------------------------------------
    function void sample_w();
        int beat_idx;
        if (vif.monitor_cb.wvalid && !vif.monitor_cb.wready) w_stall++;
        if (vif.monitor_cb.wvalid && vif.monitor_cb.wready) begin
            if (w_cur == null) begin
                w_cur = axi4_seq_item::type_id::create("w");
                w_cur.wdata = new[0];
                w_cur.wstrb = new[0];
            end
            beat_idx = w_cur.wdata.size();

            // CHECK 2: WLAST on correct beat (AXI4: W in AW order)
            if (w_aw_idx < aw_q.size() &&
                vif.monitor_cb.wlast !== (beat_idx == aw_q[w_aw_idx].len))
                `uvm_error("AXI4_SMON",
                    $sformatf("[%s] WLAST=%0b at beat %0d but AWLEN=%0d",
                        tag, vif.monitor_cb.wlast, beat_idx, aw_q[w_aw_idx].len))

            // CHECK 5: No X on WDATA
            if ($isunknown(vif.monitor_cb.wdata))
                `uvm_error("AXI4_SMON",
                    $sformatf("[%s] X/Z on WDATA beat=%0d", tag, beat_idx))

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
        axi4_seq_item aw_it, w_it, complete;
        if (vif.monitor_cb.bvalid && !vif.monitor_cb.bready) b_stall++;
        if (vif.monitor_cb.bvalid && vif.monitor_cb.bready) begin
            if (aw_q.size() == 0 || w_q.size() == 0) begin
                `uvm_error("AXI4_SMON",
                    $sformatf("[%s] B with no pending AW/W", tag))
                b_stall = 0;
                return;
            end
            aw_it = aw_q.pop_front();
            w_it  = w_q.pop_front();
            if (w_aw_idx > 0) w_aw_idx--;

            // CHECK 3: BID == AWID
            if (vif.monitor_cb.bid !== aw_it.id)
                `uvm_error("AXI4_SMON",
                    $sformatf("[%s] BID=0x%0h != AWID=0x%0h",
                        tag, vif.monitor_cb.bid, aw_it.id))

            // CHECK 4: EXOKAY only on exclusive
            if (vif.monitor_cb.bresp == 2'b01 && aw_it.lock == 1'b0)
                `uvm_error("AXI4_SMON",
                    $sformatf("[%s] EXOKAY on non-exclusive write addr=0x%08h id=0x%0h",
                        tag, aw_it.addr, aw_it.id))

            complete = axi4_seq_item::type_id::create("wr_complete");
            complete.direction       = AXI_WRITE;
            complete.id              = aw_it.id;
            complete.addr            = aw_it.addr;
            complete.len             = aw_it.len;
            complete.size            = aw_it.size;
            complete.burst           = aw_it.burst;
            complete.lock            = aw_it.lock;
            complete.cache           = aw_it.cache;
            complete.prot            = aw_it.prot;
            complete.qos             = aw_it.qos;
            complete.region          = aw_it.region;
            complete.wdata           = w_it.wdata;
            complete.wstrb           = w_it.wstrb;
            complete.bresp           = vif.monitor_cb.bresp;
            complete.aw_stall_cycles = aw_it.aw_stall_cycles;
            complete.w_stall_cycles  = w_it.w_stall_cycles;
            complete.b_stall_cycles  = b_stall;

            `uvm_info("AXI4_SMON",
                $sformatf("[%s] WR complete: id=0x%0h addr=0x%08h len=%0d resp=%0b",
                    tag, complete.id, complete.addr,
                    complete.len, complete.bresp), UVM_MEDIUM)
            ap.write(complete);
            b_stall = 0;
        end
    endfunction

    // -- AR ------------------------------------------------
    function void sample_ar();
        axi4_seq_item item;
        if (vif.monitor_cb.arvalid && !vif.monitor_cb.arready) ar_stall++;
        if (vif.monitor_cb.arvalid && vif.monitor_cb.arready) begin
            if (!(vif.monitor_cb.araddr inside {[region_lo:region_hi]}))
                `uvm_error("AXI4_SMON",
                    $sformatf("[%s] ROUTING FAIL: rd addr=0x%08h id=0x%0h",
                        tag, vif.monitor_cb.araddr, vif.monitor_cb.arid))

            check_source_incompat("AR", vif.monitor_cb.arid, vif.monitor_cb.arlen,
                                  vif.monitor_cb.arqos, vif.monitor_cb.arregion);

            item = axi4_seq_item::type_id::create("ar");
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
            item.ar_stall_cycles = ar_stall;
            item.wdata           = new[0];
            item.wstrb           = new[0];
            ar_q.push_back(item);
            ar_stall = 0;
        end
    endfunction

    // -- R -------------------------------------------------
    function void sample_r();
        int rid_int;
        axi4_seq_item complete;
        if (vif.monitor_cb.rvalid && !vif.monitor_cb.rready) r_stall++;
        if (vif.monitor_cb.rvalid && vif.monitor_cb.rready) begin
            rid_int = int'(vif.monitor_cb.rid);

            // First beat -- find oldest AR with this ID
            if (!r_pkt.exists(rid_int)) begin
                foreach (ar_q[i]) begin
                    if (int'(ar_q[i].id) == rid_int) begin
                        r_pkt[rid_int] = ar_q[i];
                        ar_q.delete(i);
                        break;
                    end
                end
                if (!r_pkt.exists(rid_int)) begin
                    `uvm_error("AXI4_SMON",
                        $sformatf("[%s] R RID=0x%0h has no matching AR (slave must echo ARID)",
                            tag, rid_int))
                    r_stall = 0;
                    return;
                end
            end

            // CHECK 5: No X on RDATA
            if ($isunknown(vif.monitor_cb.rdata))
                `uvm_error("AXI4_SMON",
                    $sformatf("[%s] X/Z on RDATA rid=0x%0h", tag, rid_int))

            r_pkt[rid_int].rdata.push_back(vif.monitor_cb.rdata);
            r_pkt[rid_int].rresp.push_back(vif.monitor_cb.rresp);
            r_pkt[rid_int].r_stall_cycles = r_stall;

            // CHECK 2: RLAST on correct beat
            if (vif.monitor_cb.rlast) begin
                complete = r_pkt[rid_int];
                r_pkt.delete(rid_int);
                if (complete.rdata.size() != complete.len + 1)
                    `uvm_error("AXI4_SMON",
                        $sformatf("[%s] RLAST after %0d beats, ARLEN+1=%0d",
                            tag, complete.rdata.size(), complete.len + 1))
                `uvm_info("AXI4_SMON",
                    $sformatf("[%s] RD complete: id=0x%0h addr=0x%08h len=%0d",
                        tag, complete.id, complete.addr, complete.len), UVM_MEDIUM)
                ap.write(complete);
            end else if (r_pkt[rid_int].rdata.size() > r_pkt[rid_int].len) begin
                `uvm_error("AXI4_SMON",
                    $sformatf("[%s] RLAST missing on final beat (ARLEN=%0d)",
                        tag, r_pkt[rid_int].len))
            end
            r_stall = 0;
        end
    endfunction

endclass : axi4_slave_monitor
