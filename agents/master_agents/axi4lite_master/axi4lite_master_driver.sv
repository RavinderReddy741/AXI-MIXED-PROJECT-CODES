`include "uvm_macros.svh"
import uvm_pkg::*;
import axi_seq_item_pkg::*;

// ============================================================
// axi4lite_master_driver.sv
// Drives AXI4-Lite transactions on DUT S00_AXI slave port
//
// Design decisions:
//   - Parallel channel tasks (AW, W, B, AR, R)
//   - Every output is driven through master_cb (no direct
//     vif.xxx <= drives mixed with clocking drives)
//   - VALID/READY is dropped in the SAME cycle the handshake
//     is seen, so each item produces exactly one handshake
//   - Timeout on every channel handshake
//   - item_done() is called AFTER the response is captured
//     (blocking_mode=1, default) so the sequence can read
//     item.resp / item.rdata right after finish_item(), and
//     a read can never overtake an earlier write
// ============================================================

class axi4lite_master_driver extends
    uvm_driver #(axi4lite_seq_item);

    `uvm_component_utils(axi4lite_master_driver)

    // -- Virtual interface --------------------------------
    virtual axi4lite_if vif;

    // -- Internal queues -- one per channel ----------------
    // Same item object pushed to all relevant queues
    axi4lite_seq_item aw_q[$];
    axi4lite_seq_item w_q[$];
    axi4lite_seq_item b_q[$];
    axi4lite_seq_item ar_q[$];
    axi4lite_seq_item r_q[$];

    // -- Completion tracking (blocking mode) ---------------
    bit          blocking_mode = 1;
    int unsigned issued_cnt;
    int unsigned completed_cnt;
    int unsigned rsp_timeout = 5000;

    // -- Timeout (cycles) per channel ---------------------
    int unsigned aw_timeout = 1000;
    int unsigned w_timeout  = 1000;
    int unsigned b_timeout  = 1000;
    int unsigned ar_timeout = 1000;
    int unsigned r_timeout  = 1000;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        if (!uvm_config_db #(virtual axi4lite_if)::get(
                this, "", "vif", vif))
            `uvm_fatal("NOVIF",
                "axi4lite_master_driver: cannot get vif")
        // Allow test to override timeouts
        void'(uvm_config_db #(int unsigned)::get(this, "", "aw_timeout",  aw_timeout));
        void'(uvm_config_db #(int unsigned)::get(this, "", "w_timeout",   w_timeout));
        void'(uvm_config_db #(int unsigned)::get(this, "", "b_timeout",   b_timeout));
        void'(uvm_config_db #(int unsigned)::get(this, "", "ar_timeout",  ar_timeout));
        void'(uvm_config_db #(int unsigned)::get(this, "", "r_timeout",   r_timeout));
        void'(uvm_config_db #(int unsigned)::get(this, "", "rsp_timeout", rsp_timeout));
        void'(uvm_config_db #(bit)::get(this, "", "blocking_mode", blocking_mode));
    endfunction

    task run_phase(uvm_phase phase);
        // Initialise all outputs to idle
        init_signals();
        // Wait for reset to deassert
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

    // -- Initialise all master outputs to safe idle --------
    // Direct (asynchronous) assignment so outputs are 0 from
    // time 0 and immediately on reset -- not X until 1st edge.
    function void init_signals();
        vif.awvalid <= 1'b0;
        vif.awaddr  <= '0;
        vif.awprot  <= '0;
        vif.wvalid  <= 1'b0;
        vif.wdata   <= '0;
        vif.wstrb   <= '0;
        vif.bready  <= 1'b0;
        vif.arvalid <= 1'b0;
        vif.araddr  <= '0;
        vif.arprot  <= '0;
        vif.rready  <= 1'b0;
    endfunction

    // -- Get items from sequencer and dispatch to queues ---
    task get_and_dispatch();
        axi4lite_seq_item item;
        forever begin
            // Wait for reset release before accepting items
            wait (vif.aresetn === 1'b1);
            seq_item_port.get_next_item(item);
            `uvm_info("LITE_MDRV",
                $sformatf("Got item: %s",
                    item.convert2string()), UVM_HIGH)

            issued_cnt++;
            if (item.direction == AXI_WRITE) begin
                aw_q.push_back(item);
                w_q.push_back(item);
                b_q.push_back(item);
            end else begin
                ar_q.push_back(item);
                r_q.push_back(item);
            end

            if (blocking_mode) wait_for_response();
            seq_item_port.item_done();
        end
    endtask

    // Block until every issued item has completed (or timed out)
    task wait_for_response();
        fork begin
            fork
                wait (completed_cnt == issued_cnt);
                begin
                    repeat (rsp_timeout) @(vif.master_cb);
                    `uvm_error("LITE_MDRV",
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
        axi4lite_seq_item item;
        bit timeout_hit;
        forever begin
            wait (aw_q.size() > 0 && vif.aresetn);
            item = aw_q.pop_front();
            // Re-align to the clock so the drive lands on THIS edge
            @(vif.master_cb);
            repeat (item.aw_valid_delay) @(vif.master_cb);
            if (!vif.aresetn) continue;

            vif.master_cb.awaddr  <= item.addr;
            vif.master_cb.awprot  <= item.prot;
            vif.master_cb.awvalid <= 1'b1;

            `uvm_info("LITE_MDRV",
                $sformatf("AW: addr=0x%08h prot=%0d",
                    item.addr, item.prot), UVM_HIGH)

            wait_handshake("AW", aw_timeout, timeout_hit);
            // Drop VALID in the handshake cycle (no extra cycle)
            vif.master_cb.awvalid <= 1'b0;
        end
    endtask

    // -- Drive W channel -----------------------------------
    task drive_w();
        axi4lite_seq_item item;
        bit timeout_hit;
        forever begin
            wait (w_q.size() > 0 && vif.aresetn);
            item = w_q.pop_front();
            @(vif.master_cb);
            repeat (item.w_valid_delay) @(vif.master_cb);
            if (!vif.aresetn) continue;

            vif.master_cb.wdata  <= item.data;
            vif.master_cb.wstrb  <= item.strb;
            vif.master_cb.wvalid <= 1'b1;

            `uvm_info("LITE_MDRV",
                $sformatf("W: data=0x%08h strb=0x%h",
                    item.data, item.strb), UVM_HIGH)

            wait_handshake("W", w_timeout, timeout_hit);
            vif.master_cb.wvalid <= 1'b0;
        end
    endtask

    // -- Collect B channel (write response) ----------------
    task collect_b();
        axi4lite_seq_item item;
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
                // Capture response (sampled in the handshake cycle)
                item.resp = vif.master_cb.bresp;

                // Negative check: EXOKAY illegal on Lite
                if (item.resp == AXI_EXOKAY)
                    `uvm_error("LITE_MDRV",
                        "BRESP=EXOKAY received -- illegal on AXI4-Lite")

                `uvm_info("LITE_MDRV",
                    $sformatf("B: resp=%0b", item.resp), UVM_HIGH)
            end
            completed_cnt++;
        end
    endtask

    // -- Drive AR channel ----------------------------------
    task drive_ar();
        axi4lite_seq_item item;
        bit timeout_hit;
        forever begin
            wait (ar_q.size() > 0 && vif.aresetn);
            item = ar_q.pop_front();
            @(vif.master_cb);
            repeat (item.ar_valid_delay) @(vif.master_cb);
            if (!vif.aresetn) continue;

            vif.master_cb.araddr  <= item.addr;
            vif.master_cb.arprot  <= item.prot;
            vif.master_cb.arvalid <= 1'b1;

            `uvm_info("LITE_MDRV",
                $sformatf("AR: addr=0x%08h prot=%0d",
                    item.addr, item.prot), UVM_HIGH)

            wait_handshake("AR", ar_timeout, timeout_hit);
            vif.master_cb.arvalid <= 1'b0;
        end
    endtask

    // -- Collect R channel (read data) ---------------------
    task collect_r();
        axi4lite_seq_item item;
        bit timeout_hit;
        forever begin
            wait (r_q.size() > 0 && vif.aresetn);
            item = r_q.pop_front();
            @(vif.master_cb);
            repeat (item.r_ready_delay) @(vif.master_cb);

            vif.master_cb.rready <= 1'b1;
            wait_handshake("R", r_timeout, timeout_hit);
            vif.master_cb.rready <= 1'b0;

            if (!timeout_hit && vif.aresetn) begin
                // Capture read data and response
                item.rdata = vif.master_cb.rdata;
                item.resp  = vif.master_cb.rresp;

                `uvm_info("LITE_MDRV",
                    $sformatf("R: data=0x%08h resp=%0b",
                        item.rdata, item.resp), UVM_HIGH)
            end
            completed_cnt++;
        end
    endtask

    // -- Monitor reset -- clear all queues on reset ---------
    task monitor_reset();
        forever begin
            @(negedge vif.aresetn);
            `uvm_info("LITE_MDRV",
                "Reset detected -- clearing queues", UVM_LOW)
            aw_q.delete();
            w_q.delete();
            b_q.delete();
            ar_q.delete();
            r_q.delete();
            completed_cnt = issued_cnt;
            init_signals();
        end
    endtask

    // -- Generic handshake wait with timeout ---------------
    // Call right after asserting our VALID/READY on a clock
    // edge. Returns on the edge where the other side's
    // READY/VALID is sampled high = the handshake edge.
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
                `uvm_error("LITE_MDRV",
                    $sformatf("%s channel TIMEOUT after %0d cycles",
                        channel, timeout_cycles))
                return;
            end
        end
    endtask

endclass : axi4lite_master_driver
