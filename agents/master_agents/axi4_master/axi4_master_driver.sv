`include "uvm_macros.svh"
import uvm_pkg::*;
import axi_seq_item_pkg::*;

// ============================================================
// axi4_master_driver.sv
// Drives AXI4 transactions on DUT S02_AXI slave port
//
// AXI4 vs AXI3 differences in driver:
//   - NO WID (removed in AXI4)
//   - awlen is 8-bit (max 255)
//   - awlock is 1-bit (exclusive only)
//   - awqos and awregion driven
//   - Semaphore controls outstanding transactions
//   - ID-indexed response queues for out-of-order
//
// ID REMAPPING:
//   The interconnect returns BID/RID with its slot number in the
//   upper bits (ARID=2 -> RID=0xA). Responses are matched on
//   (id & id_mask), id_mask = S02 thread-ID bits (default 2'b11).
//
// FIXES:
//   - Stray duplicated $sformatf line in collect_b (compile error)
//   - B/R channels: READY held high (with optional random
//     back-pressure) and every sampled VALID&&READY is processed.
//     The old code held BREADY/RREADY one cycle too long and
//     lost the extra beat accepted in that cycle.
//   - A response whose ID matches nothing is now a UVM_ERROR
//     (was silently acked at UVM_DEBUG -> reads just disappeared).
//   - blocking_mode (default 1): item_done() only after the
//     response, so rdata is valid in the sequence and a read
//     cannot overtake a write. Set 0 for pipelined traffic.
// ============================================================

class axi4_master_driver extends
    uvm_driver #(axi4_seq_item);

    `uvm_component_utils(axi4_master_driver)

    virtual axi4_if vif;

    // -- Outstanding transaction control -------------------
    semaphore wr_slots;
    semaphore rd_slots;
    int unsigned max_wr_outstanding = 4;
    int unsigned max_rd_outstanding = 4;

    // -- Completion tracking -------------------------------
    bit          blocking_mode = 1;
    int unsigned issued_cnt;
    int unsigned completed_cnt;
    int unsigned rsp_timeout = 20000;

    // -- ID handling ---------------------------------------
    int unsigned id_mask = 'h3;

    // -- READY back-pressure (0 = always ready) ------------
    int unsigned bready_backpressure_pct = 0;
    int unsigned rready_backpressure_pct = 0;

    // -- Internal queues -----------------------------------
    axi4_seq_item aw_q[$];
    axi4_seq_item w_q[$];
    axi4_seq_item ar_q[$];

    // ID-indexed response queues (out-of-order support)
    axi4_seq_item wr_rsp_q[int][$];
    axi4_seq_item rd_rsp_q[int][$];

    // Active read transactions indexed by RID
    axi4_seq_item active_rd[int];

    // -- Timeout (cycles) ----------------------------------
    int unsigned aw_timeout = 1000;
    int unsigned w_timeout  = 1000;
    int unsigned ar_timeout = 1000;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        if (!uvm_config_db #(virtual axi4_if)::get(
                this, "", "vif", vif))
            `uvm_fatal("NOVIF",
                "axi4_master_driver: cannot get vif")
        void'(uvm_config_db #(int unsigned)::get(this, "", "max_wr_outstanding", max_wr_outstanding));
        void'(uvm_config_db #(int unsigned)::get(this, "", "max_rd_outstanding", max_rd_outstanding));
        void'(uvm_config_db #(int unsigned)::get(this, "", "aw_timeout",  aw_timeout));
        void'(uvm_config_db #(int unsigned)::get(this, "", "w_timeout",   w_timeout));
        void'(uvm_config_db #(int unsigned)::get(this, "", "ar_timeout",  ar_timeout));
        void'(uvm_config_db #(int unsigned)::get(this, "", "rsp_timeout", rsp_timeout));
        void'(uvm_config_db #(int unsigned)::get(this, "", "id_mask",     id_mask));
        void'(uvm_config_db #(int unsigned)::get(this, "", "bready_backpressure_pct", bready_backpressure_pct));
        void'(uvm_config_db #(int unsigned)::get(this, "", "rready_backpressure_pct", rready_backpressure_pct));
        void'(uvm_config_db #(bit)::get(this, "", "blocking_mode", blocking_mode));
        wr_slots = new(max_wr_outstanding);
        rd_slots = new(max_rd_outstanding);
    endfunction

    task run_phase(uvm_phase phase);
        init_signals();
        @(posedge vif.aresetn);
        @(vif.master_cb);
        fork
            get_and_dispatch();
            drive_aw();
            drive_w();
            collect_b();
            drive_ar();
            collect_r();
            monitor_reset();
        join_none
    endtask

    // -- Initialise outputs (asynchronous, so no X at t=0) --
    function void init_signals();
        vif.awvalid  <= 1'b0;
        vif.awid     <= '0;
        vif.awaddr   <= '0;
        vif.awlen    <= '0;
        vif.awsize   <= '0;
        vif.awburst  <= '0;
        vif.awlock   <= '0;
        vif.awcache  <= '0;
        vif.awprot   <= '0;
        vif.awqos    <= '0;
        vif.awregion <= '0;
        // NO wid in AXI4
        vif.wvalid   <= 1'b0;
        vif.wdata    <= '0;
        vif.wstrb    <= '0;
        vif.wlast    <= 1'b0;
        vif.bready   <= 1'b0;
        vif.arvalid  <= 1'b0;
        vif.arid     <= '0;
        vif.araddr   <= '0;
        vif.arlen    <= '0;
        vif.arsize   <= '0;
        vif.arburst  <= '0;
        vif.arlock   <= '0;
        vif.arcache  <= '0;
        vif.arprot   <= '0;
        vif.arqos    <= '0;
        vif.arregion <= '0;
        vif.rready   <= 1'b0;
    endfunction

    function int key_of(logic [3:0] id);
        return int'(id) & int'(id_mask);
    endfunction

    // -- Get items and dispatch ----------------------------
    task get_and_dispatch();
        axi4_seq_item item;
        forever begin
            wait (vif.aresetn === 1'b1);
            seq_item_port.get_next_item(item);
            `uvm_info("AXI4_MDRV",
                $sformatf("Got: %s",
                    item.convert2string()), UVM_HIGH)

            item.rdata.delete();
            item.rresp.delete();
            issued_cnt++;
            if (item.direction == AXI_WRITE) begin
                // Get write slot (blocks if max outstanding)
                wr_slots.get(1);
                aw_q.push_back(item);
                w_q.push_back(item);
                wr_rsp_q[key_of(item.id)].push_back(item);
            end else begin
                rd_slots.get(1);
                ar_q.push_back(item);
                rd_rsp_q[key_of(item.id)].push_back(item);
            end
            if (blocking_mode) wait_for_response();
            seq_item_port.item_done();
        end
    endtask

    task wait_for_response();
        fork begin
            fork
                wait (completed_cnt == issued_cnt);
                begin
                    repeat (rsp_timeout) @(vif.master_cb);
                    `uvm_error("AXI4_MDRV",
                        $sformatf("No response within %0d cycles (issued=%0d completed=%0d)",
                            rsp_timeout, issued_cnt, completed_cnt))
                    completed_cnt = issued_cnt;
                end
            join_any
            disable fork;
        end join
    endtask

    // -- Drive AW channel ----------------------------------
    task drive_aw();
        axi4_seq_item item;
        bit timeout_hit;
        forever begin
            wait (aw_q.size() > 0 && vif.aresetn);
            item = aw_q.pop_front();
            @(vif.master_cb);
            repeat (item.aw_valid_delay) @(vif.master_cb);
            if (!vif.aresetn) continue;

            // AXI4 AW -- includes QoS and Region, NO WID
            vif.master_cb.awid     <= item.id;
            vif.master_cb.awaddr   <= item.addr;
            vif.master_cb.awlen    <= item.len;    // 8-bit
            vif.master_cb.awsize   <= item.size;
            vif.master_cb.awburst  <= item.burst;
            vif.master_cb.awlock   <= item.lock;   // 1-bit
            vif.master_cb.awcache  <= item.cache;
            vif.master_cb.awprot   <= item.prot;
            vif.master_cb.awqos    <= item.qos;
            vif.master_cb.awregion <= item.region;
            vif.master_cb.awvalid  <= 1'b1;

            `uvm_info("AXI4_MDRV",
                $sformatf("AW: id=%0h addr=0x%08h len=%0d burst=%s lock=%0b qos=%0d region=%0d",
                    item.id, item.addr, item.len,
                    item.burst.name(), item.lock,
                    item.qos, item.region), UVM_HIGH)

            wait_handshake("AW", aw_timeout, timeout_hit);
            vif.master_cb.awvalid <= 1'b0;
        end
    endtask

    // -- Drive W channel -----------------------------------
    // AXI4: no WID -- data must arrive in AW order
    task drive_w();
        axi4_seq_item item;
        bit timeout_hit;
        forever begin
            wait (w_q.size() > 0 && vif.aresetn);
            item = w_q.pop_front();
            @(vif.master_cb);

            for (int beat = 0; beat <= item.len; beat++) begin
                if (item.w_valid_delay > 0) begin
                    vif.master_cb.wvalid <= 1'b0;
                    repeat (item.w_valid_delay) @(vif.master_cb);
                end
                if (!vif.aresetn) break;

                vif.master_cb.wdata  <= item.wdata[beat];
                vif.master_cb.wstrb  <= item.wstrb[beat];
                vif.master_cb.wlast  <= (beat == item.len);
                vif.master_cb.wvalid <= 1'b1;

                `uvm_info("AXI4_MDRV",
                    $sformatf("W: beat=%0d/%0d data=0x%08h strb=0x%h wlast=%0b",
                        beat, item.len,
                        item.wdata[beat],
                        item.wstrb[beat],
                        (beat == item.len)), UVM_HIGH)

                wait_handshake("W", w_timeout, timeout_hit);
                if (timeout_hit || !vif.aresetn) break;
            end
            vif.master_cb.wvalid <= 1'b0;
            vif.master_cb.wlast  <= 1'b0;
        end
    endtask

    // -- Collect B channel ---------------------------------
    // ID-indexed -- responses can arrive out of order.
    // Every edge: if BVALID && BREADY were both high, that
    // edge was a handshake -> consume one response.
    task collect_b();
        axi4_seq_item item;
        int bid_int;
        forever begin
            @(vif.master_cb);
            if (!vif.aresetn) continue;

            if (vif.master_cb.bvalid === 1'b1 && vif.bready === 1'b1) begin
                bid_int = key_of(vif.master_cb.bid);
                if (wr_rsp_q.exists(bid_int) &&
                    wr_rsp_q[bid_int].size() > 0) begin
                    item = wr_rsp_q[bid_int].pop_front();
                    if (wr_rsp_q[bid_int].size() == 0)
                        wr_rsp_q.delete(bid_int);
                    item.bresp = vif.master_cb.bresp;

                    // AXI4 EXOKAY only on exclusive write
                    if (item.bresp == AXI_EXOKAY && item.lock == 1'b0)
                        `uvm_error("AXI4_MDRV",
                            $sformatf("EXOKAY on non-exclusive write id=%0h",
                                item.id))

                    `uvm_info("AXI4_MDRV",
                        $sformatf("B: id=%0h (bid=0x%0h) resp=%0b",
                            item.id, vif.master_cb.bid, item.bresp), UVM_HIGH)

                    wr_slots.put(1);
                    completed_cnt++;
                end else begin
                    `uvm_error("AXI4_MDRV",
                        $sformatf("BID=0x%0h (key %0d) matches no outstanding write",
                            vif.master_cb.bid, bid_int))
                end
            end

            vif.master_cb.bready <= ready_value(bready_backpressure_pct);
        end
    endtask

    // -- Drive AR channel ----------------------------------
    task drive_ar();
        axi4_seq_item item;
        bit timeout_hit;
        forever begin
            wait (ar_q.size() > 0 && vif.aresetn);
            item = ar_q.pop_front();
            @(vif.master_cb);
            repeat (item.ar_valid_delay) @(vif.master_cb);
            if (!vif.aresetn) continue;

            vif.master_cb.arid     <= item.id;
            vif.master_cb.araddr   <= item.addr;
            vif.master_cb.arlen    <= item.len;
            vif.master_cb.arsize   <= item.size;
            vif.master_cb.arburst  <= item.burst;
            vif.master_cb.arlock   <= item.lock;
            vif.master_cb.arcache  <= item.cache;
            vif.master_cb.arprot   <= item.prot;
            vif.master_cb.arqos    <= item.qos;
            vif.master_cb.arregion <= item.region;
            vif.master_cb.arvalid  <= 1'b1;

            `uvm_info("AXI4_MDRV",
                $sformatf("AR: id=%0h addr=0x%08h len=%0d",
                    item.id, item.addr, item.len), UVM_HIGH)

            wait_handshake("AR", ar_timeout, timeout_hit);
            vif.master_cb.arvalid <= 1'b0;
        end
    endtask

    // -- Collect R channel ---------------------------------
    // Multi-beat, ID-indexed, out-of-order capable
    task collect_r();
        axi4_seq_item item;
        int rid_int;
        forever begin
            @(vif.master_cb);
            if (!vif.aresetn) continue;

            if (vif.master_cb.rvalid === 1'b1 && vif.rready === 1'b1) begin
                rid_int = key_of(vif.master_cb.rid);

                // First beat of a burst -> look up the request
                if (!active_rd.exists(rid_int) &&
                    rd_rsp_q.exists(rid_int) &&
                    rd_rsp_q[rid_int].size() > 0) begin
                    active_rd[rid_int] = rd_rsp_q[rid_int].pop_front();
                    if (rd_rsp_q[rid_int].size() == 0)
                        rd_rsp_q.delete(rid_int);
                end

                if (!active_rd.exists(rid_int)) begin
                    `uvm_error("AXI4_MDRV",
                        $sformatf("RID=0x%0h (key %0d) matches no outstanding read",
                            vif.master_cb.rid, rid_int))
                end else begin
                    item = active_rd[rid_int];
                    item.rdata.push_back(vif.master_cb.rdata);
                    item.rresp.push_back(vif.master_cb.rresp);

                    `uvm_info("AXI4_MDRV",
                        $sformatf("R: id=%0h (rid=0x%0h) beat=%0d data=0x%08h rlast=%0b",
                            item.id, vif.master_cb.rid,
                            item.rdata.size()-1,
                            vif.master_cb.rdata,
                            vif.master_cb.rlast), UVM_HIGH)

                    if (vif.master_cb.rlast) begin
                        if (item.rdata.size() != item.len + 1)
                            `uvm_error("AXI4_MDRV",
                                $sformatf("RLAST after %0d beats, ARLEN+1=%0d",
                                    item.rdata.size(), item.len + 1))
                        active_rd.delete(rid_int);
                        rd_slots.put(1);
                        completed_cnt++;
                    end else if (item.rdata.size() > item.len) begin
                        `uvm_error("AXI4_MDRV",
                            $sformatf("RLAST missing on beat %0d (ARLEN=%0d)",
                                item.rdata.size()-1, item.len))
                    end
                end
            end

            vif.master_cb.rready <= ready_value(rready_backpressure_pct);
        end
    endtask

    function bit ready_value(int unsigned backpressure_pct);
        if (backpressure_pct == 0) return 1'b1;
        return ($urandom_range(99) >= backpressure_pct);
    endfunction

    // -- Reset monitor -------------------------------------
    task monitor_reset();
        forever begin
            @(negedge vif.aresetn);
            `uvm_info("AXI4_MDRV",
                "Reset -- clearing all queues", UVM_LOW)
            // Release semaphore slots for all pending items
            foreach (wr_rsp_q[id])
                wr_slots.put(wr_rsp_q[id].size());
            foreach (rd_rsp_q[id])
                rd_slots.put(rd_rsp_q[id].size());
            foreach (active_rd[id])
                rd_slots.put(1);
            aw_q.delete();  w_q.delete();
            ar_q.delete();
            wr_rsp_q.delete();
            rd_rsp_q.delete();
            active_rd.delete();
            completed_cnt = issued_cnt;
            init_signals();
        end
    endtask

    // -- Handshake wait with timeout -----------------------
    // Returns on the edge where the handshake completes.
    task automatic wait_handshake(
        input  string       channel,
        input  int unsigned timeout_cycles,
        output bit          timeout_hit
    );
        int unsigned count = 0;
        timeout_hit = 0;
        forever begin
            @(vif.master_cb);
            if (!vif.aresetn) return;
            case (channel)
                "AW": if (vif.master_cb.awready === 1'b1) return;
                "W" : if (vif.master_cb.wready  === 1'b1) return;
                "AR": if (vif.master_cb.arready === 1'b1) return;
            endcase
            count++;
            if (count >= timeout_cycles) begin
                timeout_hit = 1;
                `uvm_error("AXI4_MDRV",
                    $sformatf("%s TIMEOUT after %0d cycles",
                        channel, timeout_cycles))
                return;
            end
        end
    endtask

endclass : axi4_master_driver
