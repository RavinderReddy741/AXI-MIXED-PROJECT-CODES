`include "uvm_macros.svh"
import uvm_pkg::*;
import axi_seq_item_pkg::*;

// ============================================================
// axi3_master_driver.sv
// Drives AXI3 transactions on DUT S01_AXI slave port
//
// AXI3 specific handling:
//   - WID driven per beat (matches AWID)
//   - AWLEN is 4-bit (max 15)
//   - AWLOCK is 2-bit (supports locked)
//   - W beats sent as burst (loop per beat)
//   - WLAST driven on final beat
//   - BID checked against AWID (low S01_ID_W bits)
//   - RID checked per beat against ARID
//
// FIXES:
//   - VALID/READY dropped in the handshake cycle. Previously
//     they were held one extra cycle, which produced a second
//     (phantom) handshake whenever the DUT kept READY/VALID high:
//     duplicate AW/W beats and silently swallowed R beats.
//   - item_done() only after B / last R beat is really seen
//     (was: after b_q/r_q was popped, i.e. before the response).
//   - rdata/rresp collected with push_back (indexed writes to an
//     empty queue are out-of-bounds and silently dropped).
//   - w_timeout is now configurable too.
// ============================================================

class axi3_master_driver extends
    uvm_driver #(axi3_seq_item);

    `uvm_component_utils(axi3_master_driver)

    virtual axi3_if vif;

    // -- Internal queues -----------------------------------
    axi3_seq_item aw_q[$];
    axi3_seq_item w_q[$];
    axi3_seq_item b_q[$];
    axi3_seq_item ar_q[$];
    axi3_seq_item r_q[$];

    // -- Completion tracking -------------------------------
    bit          blocking_mode = 1;
    int unsigned issued_cnt;
    int unsigned completed_cnt;
    int unsigned rsp_timeout = 60000;

    // -- Timeout (cycles) ----------------------------------
    int unsigned aw_timeout = 50000;
    int unsigned w_timeout  = 50000;
    int unsigned b_timeout  = 50000;
    int unsigned ar_timeout = 50000;
    int unsigned r_timeout  = 50000;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        if (!uvm_config_db #(virtual axi3_if)::get(
                this, "", "vif", vif))
            `uvm_fatal("NOVIF",
                "axi3_master_driver: cannot get vif")
        void'(uvm_config_db #(int unsigned)::get(this, "", "aw_timeout",  aw_timeout));
        void'(uvm_config_db #(int unsigned)::get(this, "", "w_timeout",   w_timeout));
        void'(uvm_config_db #(int unsigned)::get(this, "", "b_timeout",   b_timeout));
        void'(uvm_config_db #(int unsigned)::get(this, "", "ar_timeout",  ar_timeout));
        void'(uvm_config_db #(int unsigned)::get(this, "", "r_timeout",   r_timeout));
        void'(uvm_config_db #(int unsigned)::get(this, "", "rsp_timeout", rsp_timeout));
        void'(uvm_config_db #(bit)::get(this, "", "blocking_mode", blocking_mode));
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
        vif.awvalid <= 1'b0;
        vif.awid    <= '0;
        vif.awaddr  <= '0;
        vif.awlen   <= '0;
        vif.awsize  <= '0;
        vif.awburst <= '0;
        vif.awlock  <= '0;
        vif.awcache <= '0;
        vif.awprot  <= '0;
        vif.wid     <= '0;
        vif.wvalid  <= 1'b0;
        vif.wdata   <= '0;
        vif.wstrb   <= '0;
        vif.wlast   <= 1'b0;
        vif.bready  <= 1'b0;
        vif.arvalid <= 1'b0;
        vif.arid    <= '0;
        vif.araddr  <= '0;
        vif.arlen   <= '0;
        vif.arsize  <= '0;
        vif.arburst <= '0;
        vif.arlock  <= '0;
        vif.arcache <= '0;
        vif.arprot  <= '0;
        vif.rready  <= 1'b0;
    endfunction

    // -- Get and dispatch ----------------------------------
    task get_and_dispatch();
        axi3_seq_item item;
        forever begin
            wait (vif.aresetn === 1'b1);
            seq_item_port.get_next_item(item);
            `uvm_info("AXI3_MDRV",
                $sformatf("Got: %s", item.convert2string()),
                UVM_HIGH)
            item.rdata.delete();
            item.rresp.delete();
            issued_cnt++;
            if (item.direction == AXI_WRITE) begin
                aw_q.push_back(item);
                w_q.push_back(item);
                b_q.push_back(item);
            end else begin
                ar_q.push_back(item);
                r_q.push_back(item);
            end
            // Wait for the response before handing the item back
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
                    `uvm_error("AXI3_MDRV",
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
        axi3_seq_item item;
        bit timeout_hit;
        forever begin
            wait (aw_q.size() > 0 && vif.aresetn);
            item = aw_q.pop_front();
            @(vif.master_cb);
            repeat (item.aw_valid_delay) @(vif.master_cb);
            if (!vif.aresetn) continue;

            vif.master_cb.awid    <= item.id;
            vif.master_cb.awaddr  <= item.addr;
            vif.master_cb.awlen   <= item.len;   // 4-bit
            vif.master_cb.awsize  <= item.size;
            vif.master_cb.awburst <= item.burst;
            vif.master_cb.awlock  <= item.lock;  // 2-bit
            vif.master_cb.awcache <= item.cache;
            vif.master_cb.awprot  <= item.prot;
            vif.master_cb.awvalid <= 1'b1;

            `uvm_info("AXI3_MDRV",
                $sformatf("AW: id=%0h addr=0x%08h len=%0d burst=%s lock=%0b",
                    item.id, item.addr, item.len,
                    item.burst.name(), item.lock),
                UVM_HIGH)

            wait_handshake("AW", aw_timeout, timeout_hit);
            vif.master_cb.awvalid <= 1'b0;
        end
    endtask

    // -- Drive W channel (burst -- beat by beat) ------------
    // AXI3: WID driven per beat matching AWID
    task drive_w();
        axi3_seq_item item;
        bit timeout_hit;
        forever begin
            wait (w_q.size() > 0 && vif.aresetn);
            item = w_q.pop_front();
            @(vif.master_cb);

            for (int beat = 0; beat <= item.len; beat++) begin
                // Optional bubble between beats
                if (item.w_valid_delay > 0) begin
                    vif.master_cb.wvalid <= 1'b0;
                    repeat (item.w_valid_delay) @(vif.master_cb);
                end
                if (!vif.aresetn) break;

                vif.master_cb.wid    <= item.id;
                vif.master_cb.wdata  <= item.wdata[beat];
                vif.master_cb.wstrb  <= item.wstrb[beat];
                vif.master_cb.wlast  <= (beat == item.len);
                vif.master_cb.wvalid <= 1'b1;

                `uvm_info("AXI3_MDRV",
                    $sformatf("W: beat=%0d/%0d data=0x%08h strb=0x%h wlast=%0b",
                        beat, item.len,
                        item.wdata[beat], item.wstrb[beat],
                        (beat == item.len)),
                    UVM_HIGH)

                wait_handshake("W", w_timeout, timeout_hit);
                if (timeout_hit || !vif.aresetn) break;
            end
            vif.master_cb.wvalid <= 1'b0;
            vif.master_cb.wlast  <= 1'b0;
        end
    endtask

    // -- Collect B channel ---------------------------------
    task collect_b();
        axi3_seq_item item;
        bit timeout_hit;
        forever begin
            wait (b_q.size() > 0 && vif.aresetn);
            item = b_q.pop_front();
            @(vif.master_cb);
            repeat (item.b_ready_delay) @(vif.master_cb);

            vif.master_cb.bready <= 1'b1;
            wait_handshake("B", b_timeout, timeout_hit);
            vif.master_cb.bready <= 1'b0;

            if (!timeout_hit && vif.aresetn) begin
                item.bresp = vif.master_cb.bresp;

                // Check BID matches AWID (S01 thread-ID bits)
                if (vif.master_cb.bid[1:0] !== item.id[1:0])
                    `uvm_error("AXI3_MDRV",
                        $sformatf("BID=0x%0h != AWID=0x%0h",
                            vif.master_cb.bid, item.id))

                `uvm_info("AXI3_MDRV",
                    $sformatf("B: id=%0h resp=%0b",
                        item.id, item.bresp), UVM_HIGH)
            end
            completed_cnt++;
        end
    endtask

    // -- Drive AR channel ----------------------------------
    task drive_ar();
        axi3_seq_item item;
        bit timeout_hit;
        forever begin
            wait (ar_q.size() > 0 && vif.aresetn);
            item = ar_q.pop_front();
            @(vif.master_cb);
            repeat (item.ar_valid_delay) @(vif.master_cb);
            if (!vif.aresetn) continue;

            vif.master_cb.arid    <= item.id;
            vif.master_cb.araddr  <= item.addr;
            vif.master_cb.arlen   <= item.len;
            vif.master_cb.arsize  <= item.size;
            vif.master_cb.arburst <= item.burst;
            vif.master_cb.arlock  <= item.lock;
            vif.master_cb.arcache <= item.cache;
            vif.master_cb.arprot  <= item.prot;
            vif.master_cb.arvalid <= 1'b1;

            `uvm_info("AXI3_MDRV",
                $sformatf("AR: id=%0h addr=0x%08h len=%0d",
                    item.id, item.addr, item.len), UVM_HIGH)

            wait_handshake("AR", ar_timeout, timeout_hit);
            vif.master_cb.arvalid <= 1'b0;
        end
    endtask

    // -- Collect R channel (burst beats) -------------------
    task collect_r();
        axi3_seq_item item;
        bit timeout_hit;
        forever begin
            wait (r_q.size() > 0 && vif.aresetn);
            item = r_q.pop_front();
            @(vif.master_cb);

            for (int beat = 0; beat <= item.len; beat++) begin
                if (item.r_ready_delay > 0) begin
                    vif.master_cb.rready <= 1'b0;
                    repeat (item.r_ready_delay) @(vif.master_cb);
                end
                vif.master_cb.rready <= 1'b1;

                wait_handshake("R", r_timeout, timeout_hit);
                if (timeout_hit || !vif.aresetn) break;

                item.rdata.push_back(vif.master_cb.rdata);
                item.rresp.push_back(vif.master_cb.rresp);

                // Check RID matches ARID per beat
                if (vif.master_cb.rid[1:0] !== item.id[1:0])
                    `uvm_error("AXI3_MDRV",
                        $sformatf("RID=0x%0h != ARID=0x%0h at beat %0d",
                            vif.master_cb.rid, item.id, beat))

                // Check RLAST on final beat
                if (beat == item.len && !vif.master_cb.rlast)
                    `uvm_error("AXI3_MDRV",
                        "RLAST missing on final R beat")

                if (beat < item.len && vif.master_cb.rlast)
                    `uvm_error("AXI3_MDRV",
                        $sformatf("Early RLAST at beat %0d of %0d", beat, item.len))

                `uvm_info("AXI3_MDRV",
                    $sformatf("R: beat=%0d data=0x%08h resp=%0b rlast=%0b",
                        beat, vif.master_cb.rdata,
                        vif.master_cb.rresp, vif.master_cb.rlast), UVM_HIGH)
            end
            vif.master_cb.rready <= 1'b0;
            completed_cnt++;
        end
    endtask

    // -- Reset monitor -------------------------------------
    task monitor_reset();
        forever begin
            @(negedge vif.aresetn);
            `uvm_info("AXI3_MDRV",
                "Reset -- clearing queues", UVM_LOW)
            aw_q.delete(); w_q.delete();
            b_q.delete();  ar_q.delete();
            r_q.delete();
            completed_cnt = issued_cnt;
            init_signals();
        end
    endtask

    // -- Generic handshake wait with timeout ---------------
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
                "B" : if (vif.master_cb.bvalid  === 1'b1) return;
                "AR": if (vif.master_cb.arready === 1'b1) return;
                "R" : if (vif.master_cb.rvalid  === 1'b1) return;
            endcase
            count++;
            if (count >= timeout_cycles) begin
                timeout_hit = 1;
                `uvm_error("AXI3_MDRV",
                    $sformatf("%s channel TIMEOUT after %0d cycles",
                        channel, timeout_cycles))
                return;
            end
        end
    endtask

endclass : axi3_master_driver
