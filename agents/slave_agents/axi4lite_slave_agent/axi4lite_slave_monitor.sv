`include "uvm_macros.svh"
import uvm_pkg::*;
import axi_seq_item_pkg::*;

// ============================================================
// axi4lite_slave_monitor.sv
// Passive monitor on DUT M00_AXI (AXI4-Lite master port)
//
// WHAT THIS MONITOR CHECKS:
//   - Address falls within M00 region 0x44A0_xxxx
//   - AWADDR / ARADDR 4-byte aligned
//   - WSTRB non-zero
//   - BRESP / RRESP never EXOKAY (illegal on Lite)
//   - Stall cycle tracking per channel
//
// FIXES:
//   - Duplicate "complete.strb," argument in WR-complete message
//   - Checks were uvm_warning (never fail a test) -> uvm_error
//   - "R with no pending AR" was hidden at UVM_HIGH -> uvm_error
//   - Single sampling loop in fixed channel order
//
// Publishes complete write and read transactions to scoreboard
// ============================================================

class axi4lite_slave_monitor extends uvm_monitor;

    `uvm_component_utils(axi4lite_slave_monitor)

    virtual axi4lite_if vif;

    uvm_analysis_port #(axi4lite_seq_item) ap;

    // -- Address region ------------------------------------
    logic [31:0] region_lo = 32'h44A0_0000;
    logic [31:0] region_hi = 32'h44A0_FFFF;

    // -- Internal staging ----------------------------------
    axi4lite_seq_item aw_q[$];
    axi4lite_seq_item w_q[$];
    axi4lite_seq_item ar_q[$];

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
        if (!uvm_config_db #(virtual axi4lite_if)::get(
                this, "", "vif", vif))
            `uvm_fatal("NOVIF",
                "axi4lite_slave_monitor: cannot get vif")
        void'(uvm_config_db #(logic [31:0])::get(this, "", "region_lo", region_lo));
        void'(uvm_config_db #(logic [31:0])::get(this, "", "region_hi", region_hi));
    endfunction

    task run_phase(uvm_phase phase);
        forever begin
            @(vif.monitor_cb);
            if (vif.aresetn !== 1'b1) begin
                aw_q.delete(); w_q.delete(); ar_q.delete();
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

    function void sample_aw();
        axi4lite_seq_item item;
        if (vif.monitor_cb.awvalid && !vif.monitor_cb.awready) aw_stall++;
        if (vif.monitor_cb.awvalid && vif.monitor_cb.awready) begin
            if (!(vif.monitor_cb.awaddr inside {[region_lo:region_hi]}))
                `uvm_error("LITE_SMON",
                    $sformatf("[M00] ROUTING FAIL: wr addr=0x%08h not in M00",
                        vif.monitor_cb.awaddr))
            if (vif.monitor_cb.awaddr[1:0] != 2'b00)
                `uvm_error("LITE_SMON",
                    $sformatf("[M00] UNALIGNED WRITE: addr=0x%08h",
                        vif.monitor_cb.awaddr))
            item = axi4lite_seq_item::type_id::create("aw_item");
            item.direction       = AXI_WRITE;
            item.addr            = vif.monitor_cb.awaddr;
            item.prot            = vif.monitor_cb.awprot;
            item.aw_stall_cycles = aw_stall;
            aw_q.push_back(item);
            `uvm_info("LITE_SMON",
                $sformatf("[M00] AW: addr=0x%08h stall=%0d",
                    item.addr, aw_stall), UVM_HIGH)
            aw_stall = 0;
        end
    endfunction

    function void sample_w();
        axi4lite_seq_item item;
        if (vif.monitor_cb.wvalid && !vif.monitor_cb.wready) w_stall++;
        if (vif.monitor_cb.wvalid && vif.monitor_cb.wready) begin
            if (vif.monitor_cb.wstrb == 4'h0)
                `uvm_error("LITE_SMON", "[M00] WSTRB all-zero -- illegal")
            item = axi4lite_seq_item::type_id::create("w_item");
            item.data           = vif.monitor_cb.wdata;
            item.strb           = vif.monitor_cb.wstrb;
            item.w_stall_cycles = w_stall;
            w_q.push_back(item);
            `uvm_info("LITE_SMON",
                $sformatf("[M00] W: data=0x%08h strb=0x%h stall=%0d",
                    item.data, item.strb, w_stall), UVM_HIGH)
            w_stall = 0;
        end
    endfunction

    function void sample_b();
        axi4lite_seq_item aw_it, w_it, complete;
        if (vif.monitor_cb.bvalid && !vif.monitor_cb.bready) b_stall++;
        if (vif.monitor_cb.bvalid && vif.monitor_cb.bready) begin
            if (aw_q.size() == 0 || w_q.size() == 0) begin
                `uvm_error("LITE_SMON", "[M00] B with no pending AW or W")
                b_stall = 0;
                return;
            end
            aw_it = aw_q.pop_front();
            w_it  = w_q.pop_front();
            complete = axi4lite_seq_item::type_id::create("wr_complete");
            complete.direction       = AXI_WRITE;
            complete.addr            = aw_it.addr;
            complete.prot            = aw_it.prot;
            complete.data            = w_it.data;
            complete.strb            = w_it.strb;
            complete.resp            = vif.monitor_cb.bresp;
            complete.aw_stall_cycles = aw_it.aw_stall_cycles;
            complete.w_stall_cycles  = w_it.w_stall_cycles;
            complete.b_stall_cycles  = b_stall;

            if (complete.resp == AXI_EXOKAY)
                `uvm_error("LITE_SMON",
                    $sformatf("[M00] EXOKAY on Lite write addr=0x%08h -- ILLEGAL",
                        complete.addr))

            `uvm_info("LITE_SMON",
                $sformatf("[M00] WR complete: addr=0x%08h data=0x%08h strb=0x%h resp=%0b",
                    complete.addr, complete.data,
                    complete.strb, complete.resp), UVM_MEDIUM)
            ap.write(complete);
            b_stall = 0;
        end
    endfunction

    function void sample_ar();
        axi4lite_seq_item item;
        if (vif.monitor_cb.arvalid && !vif.monitor_cb.arready) ar_stall++;
        if (vif.monitor_cb.arvalid && vif.monitor_cb.arready) begin
            if (!(vif.monitor_cb.araddr inside {[region_lo:region_hi]}))
                `uvm_error("LITE_SMON",
                    $sformatf("[M00] ROUTING FAIL: rd addr=0x%08h",
                        vif.monitor_cb.araddr))
            if (vif.monitor_cb.araddr[1:0] != 2'b00)
                `uvm_error("LITE_SMON",
                    $sformatf("[M00] UNALIGNED READ: addr=0x%08h",
                        vif.monitor_cb.araddr))
            item = axi4lite_seq_item::type_id::create("ar_item");
            item.direction       = AXI_READ;
            item.addr            = vif.monitor_cb.araddr;
            item.prot            = vif.monitor_cb.arprot;
            item.ar_stall_cycles = ar_stall;
            ar_q.push_back(item);
            ar_stall = 0;
        end
    endfunction

    function void sample_r();
        axi4lite_seq_item ar_it, complete;
        if (vif.monitor_cb.rvalid && !vif.monitor_cb.rready) r_stall++;
        if (vif.monitor_cb.rvalid && vif.monitor_cb.rready) begin
            if (ar_q.size() == 0) begin
                `uvm_error("LITE_SMON", "[M00] R with no pending AR")
                r_stall = 0;
                return;
            end
            ar_it = ar_q.pop_front();
            complete = axi4lite_seq_item::type_id::create("rd_complete");
            complete.direction       = AXI_READ;
            complete.addr            = ar_it.addr;
            complete.prot            = ar_it.prot;
            complete.rdata           = vif.monitor_cb.rdata;
            complete.resp            = vif.monitor_cb.rresp;
            complete.ar_stall_cycles = ar_it.ar_stall_cycles;
            complete.r_stall_cycles  = r_stall;

            if (complete.resp == AXI_EXOKAY)
                `uvm_error("LITE_SMON",
                    $sformatf("[M00] EXOKAY read addr=0x%08h -- ILLEGAL",
                        complete.addr))

            `uvm_info("LITE_SMON",
                $sformatf("[M00] RD complete: addr=0x%08h rdata=0x%08h resp=%0b",
                    complete.addr, complete.rdata, complete.resp), UVM_MEDIUM)
            ap.write(complete);
            r_stall = 0;
        end
    endfunction

endclass : axi4lite_slave_monitor
