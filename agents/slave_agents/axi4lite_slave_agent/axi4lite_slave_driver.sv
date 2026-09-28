`include "uvm_macros.svh"
import uvm_pkg::*;
import axi_seq_item_pkg::*;

// ============================================================
// axi4lite_slave_driver.sv
// Responds on DUT M00_AXI (AXI4-Lite master port)
//
// RESPONSE RULE:
//   BRESP -- slave drives, DUT routes back to correct S-port
//   RRESP -- slave drives
//   EXOKAY -- NEVER returned on Lite (no exclusive support)
//
// HANDSHAKE RULE (FIX):
//   READY/VALID is dropped on the SAME edge the handshake is
//   sampled. The old code waited one more edge before dropping
//   it, so while the DUT kept BREADY/RREADY high it saw a SECOND
//   B response / R beat that the slave never meant to send, and
//   AWREADY/ARREADY high one extra cycle accepted a request the
//   slave then ignored (-> DUT hang).
//
// RESET (FIX): handlers are killed and restarted on reset.
//
// ADDRESS REGION: M00 = 0x44A0_0000 - 0x44A0_FFFF
// ============================================================

class axi4lite_slave_driver extends uvm_driver #(axi4lite_seq_item);

    `uvm_component_utils(axi4lite_slave_driver)

    virtual axi4lite_if vif;

    // -- Memory model -- byte granular ---------------------
    logic [7:0] mem [logic [31:0]];

    // -- Address region ------------------------------------
    logic [31:0] region_lo = 32'h44A0_0000;
    logic [31:0] region_hi = 32'h44A0_FFFF;

    // -- Configurable delays -------------------------------
    int unsigned aw_ready_delay = 0;
    int unsigned w_ready_delay  = 0;
    int unsigned b_valid_delay  = 1;
    int unsigned ar_ready_delay = 0;
    int unsigned r_valid_delay  = 1;

    // -- Error injection -----------------------------------
    bit inject_slverr = 0;
    bit inject_decerr = 0;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        if (!uvm_config_db #(virtual axi4lite_if)::get(
                this, "", "vif", vif))
            `uvm_fatal("NOVIF",
                "axi4lite_slave_driver: cannot get vif")
        void'(uvm_config_db #(int unsigned)::get(this, "", "aw_ready_delay", aw_ready_delay));
        void'(uvm_config_db #(int unsigned)::get(this, "", "w_ready_delay",  w_ready_delay));
        void'(uvm_config_db #(int unsigned)::get(this, "", "b_valid_delay",  b_valid_delay));
        void'(uvm_config_db #(int unsigned)::get(this, "", "ar_ready_delay", ar_ready_delay));
        void'(uvm_config_db #(int unsigned)::get(this, "", "r_valid_delay",  r_valid_delay));
        void'(uvm_config_db #(bit)::get(this, "", "inject_slverr",  inject_slverr));
        void'(uvm_config_db #(bit)::get(this, "", "inject_decerr",  inject_decerr));
        void'(uvm_config_db #(logic [31:0])::get(this, "", "region_lo", region_lo));
        void'(uvm_config_db #(logic [31:0])::get(this, "", "region_hi", region_hi));
    endfunction

    task run_phase(uvm_phase phase);
        forever begin
            init_signals();
            wait (vif.aresetn === 1'b1);
            @(vif.slave_cb);
            fork
                handle_writes();
                handle_reads();
                @(negedge vif.aresetn);
            join_any
            disable fork;
            `uvm_info("LITE_SDRV", "[M00] Reset -- restarting", UVM_LOW)
        end
    endtask

    function void init_signals();
        vif.awready <= 1'b0;
        vif.wready  <= 1'b0;
        vif.bvalid  <= 1'b0;
        vif.bresp   <= 2'b00;
        vif.arready <= 1'b0;
        vif.rvalid  <= 1'b0;
        vif.rdata   <= '0;
        vif.rresp   <= 2'b00;
    endfunction

    function logic [1:0] get_resp();
        // EXOKAY NEVER returned on AXI4-Lite
        if      (inject_decerr) return 2'b11;
        else if (inject_slverr) return 2'b10;
        else                    return 2'b00;
    endfunction

    // -- Write handler -------------------------------------
    task handle_writes();
        logic [31:0] wr_addr;
        logic [31:0] wr_data;
        logic [3:0]  wr_strb;

        forever begin
            // AW phase
            repeat (aw_ready_delay) @(vif.slave_cb);
            vif.slave_cb.awready <= 1'b1;
            do @(vif.slave_cb); while (vif.slave_cb.awvalid !== 1'b1);
            vif.slave_cb.awready <= 1'b0;
            wr_addr = vif.slave_cb.awaddr;

            // Routing check
            if (!(wr_addr inside {[region_lo:region_hi]}))
                `uvm_error("LITE_SDRV",
                    $sformatf("[M00] ROUTING ERROR: wr addr=0x%08h not in [0x%08h..0x%08h]",
                        wr_addr, region_lo, region_hi))

            // W phase
            repeat (w_ready_delay) @(vif.slave_cb);
            vif.slave_cb.wready <= 1'b1;
            do @(vif.slave_cb); while (vif.slave_cb.wvalid !== 1'b1);
            vif.slave_cb.wready <= 1'b0;
            wr_data = vif.slave_cb.wdata;
            wr_strb = vif.slave_cb.wstrb;

            // Write to memory -- byte strobe aware
            for (int b = 0; b < 4; b++)
                if (wr_strb[b])
                    mem[{wr_addr[31:2], 2'b00} + b] = wr_data[b*8+:8];

            `uvm_info("LITE_SDRV",
                $sformatf("[M00] WR addr=0x%08h data=0x%08h strb=0x%h",
                    wr_addr, wr_data, wr_strb), UVM_MEDIUM)

            // B phase -- BVALID held until BREADY, dropped on the
            // handshake edge
            repeat (b_valid_delay) @(vif.slave_cb);
            vif.slave_cb.bresp  <= get_resp();
            vif.slave_cb.bvalid <= 1'b1;
            do @(vif.slave_cb); while (vif.slave_cb.bready !== 1'b1);
            vif.slave_cb.bvalid <= 1'b0;
        end
    endtask

    // -- Read handler --------------------------------------
    task handle_reads();
        logic [31:0] rd_addr;
        logic [31:0] rd_data;

        forever begin
            // AR phase
            repeat (ar_ready_delay) @(vif.slave_cb);
            vif.slave_cb.arready <= 1'b1;
            do @(vif.slave_cb); while (vif.slave_cb.arvalid !== 1'b1);
            vif.slave_cb.arready <= 1'b0;
            rd_addr = vif.slave_cb.araddr;

            // Routing check
            if (!(rd_addr inside {[region_lo:region_hi]}))
                `uvm_error("LITE_SDRV",
                    $sformatf("[M00] ROUTING ERROR: rd addr=0x%08h not in [0x%08h..0x%08h]",
                        rd_addr, region_lo, region_hi))

            rd_data = read_mem(rd_addr);

            // R phase -- RVALID held until RREADY
            repeat (r_valid_delay) @(vif.slave_cb);
            vif.slave_cb.rdata  <= rd_data;
            vif.slave_cb.rresp  <= get_resp();
            vif.slave_cb.rvalid <= 1'b1;
            do @(vif.slave_cb); while (vif.slave_cb.rready !== 1'b1);
            vif.slave_cb.rvalid <= 1'b0;

            `uvm_info("LITE_SDRV",
                $sformatf("[M00] RD addr=0x%08h rdata=0x%08h%s",
                    rd_addr, rd_data,
                    mem.exists({rd_addr[31:2],2'b00}) ? "" : "  <-- NEVER WRITTEN, returns 0"),
                UVM_MEDIUM)
        end
    endtask

    // -- Public helpers ------------------------------------
    function void preload(
        logic [31:0] addr,
        logic [31:0] data
    );
        for (int b = 0; b < 4; b++)
            mem[{addr[31:2],2'b00} + b] = data[b*8+:8];
    endfunction

    function logic [31:0] read_mem(logic [31:0] addr);
        logic [31:0] d = '0;
        for (int b = 0; b < 4; b++)
            if (mem.exists({addr[31:2],2'b00} + b))
                d[b*8+:8] = mem[{addr[31:2],2'b00} + b];
        return d;
    endfunction

endclass : axi4lite_slave_driver
