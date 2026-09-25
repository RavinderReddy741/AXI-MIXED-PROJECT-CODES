`include "uvm_macros.svh"
import uvm_pkg::*;
import axi_seq_item_pkg::*;

// ============================================================
// axi4_slave_driver.sv
// Responds on DUT M02_AXI and M03_AXI (AXI4 master ports)
//
// INTERCONNECT ID EXTENSION MECHANISM:
//   M02/M03 ID = 4 bits = {slot[1:0], orig_id[1:0]}
//     S00 (Lite) -> slot 2'b00
//     S01 (AXI3) -> slot 2'b01
//     S02 (AXI4) -> slot 2'b10
//
// SLAVE RESPONSE RULE (KEY):
//   BID = AWID received (echo back unchanged)
//   RID = ARID received per beat
//
// AXI4 SPECIFIC:
//   - NO WID (AXI4 removed write interleaving)
//   - AWLEN 8-bit (max 255 INCR, max 15 WRAP/FIXED)
//   - AWLOCK 1-bit (0=normal, 1=exclusive)
//   - Exclusive access monitor per ID
//
// FIXES:
//   - READY/VALID dropped on the handshake edge (was 1 cycle late
//     -> duplicate B / R beats seen by the DUT)
//   - Narrow transfers use the correct byte lanes
//   - inject_decerr also applies to reads
//   - Kill/restart handlers on reset
//
// CONFIGURE PER INSTANCE in env:
//   slave_m02: region_lo=0x44A2_0000 region_hi=0x44A2_FFFF
//   slave_m03: region_lo=0x44A3_0000 region_hi=0x44A3_FFFF
// ============================================================

class axi4_slave_driver extends uvm_driver #(axi4_seq_item);

    `uvm_component_utils(axi4_slave_driver)

    virtual axi4_if vif;

    logic [7:0] mem [logic [31:0]];

    // Set per instance via config_db
    logic [31:0] region_lo = 32'h44A2_0000;
    logic [31:0] region_hi = 32'h44A2_FFFF;

    int unsigned aw_ready_delay = 0;
    int unsigned w_ready_delay  = 0;
    int unsigned b_valid_delay  = 1;
    int unsigned ar_ready_delay = 0;
    int unsigned r_valid_delay  = 1;

    bit inject_slverr = 0;
    bit inject_decerr = 0;

    // Exclusive access monitor
    // Key = ARID (extended), Value = locked address
    logic [31:0] excl_monitor [logic [3:0]];

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        if (!uvm_config_db #(virtual axi4_if)::get(
                this, "", "vif", vif))
            `uvm_fatal("NOVIF",
                "axi4_slave_driver: cannot get vif")
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
            excl_monitor.delete();
            wait (vif.aresetn === 1'b1);
            @(vif.slave_cb);
            fork
                handle_writes();
                handle_reads();
                @(negedge vif.aresetn);
            join_any
            disable fork;
            `uvm_info("AXI4_SDRV",
                $sformatf("[%s] Reset -- restarting", get_parent().get_name()), UVM_LOW)
        end
    endtask

    function void init_signals();
        vif.awready <= 1'b0;
        vif.wready  <= 1'b0;
        vif.bvalid  <= 1'b0;
        vif.bid     <= '0;
        vif.bresp   <= 2'b00;
        vif.arready <= 1'b0;
        vif.rvalid  <= 1'b0;
        vif.rid     <= '0;
        vif.rdata   <= '0;
        vif.rresp   <= 2'b00;
        vif.rlast   <= 1'b0;
    endfunction

    // -- Write handler -------------------------------------
    task handle_writes();
        logic [3:0]  aw_id;
        logic [31:0] aw_addr;
        logic [7:0]  aw_len;     // AXI4: 8-bit
        logic [2:0]  aw_size;
        logic [1:0]  aw_burst;
        logic        aw_lock;    // AXI4: 1-bit
        logic [31:0] beat_addr;
        logic [31:0] wr_data;
        logic [3:0]  wr_strb;
        logic [1:0]  resp;
        bit          excl_success;

        forever begin
            // AW phase
            repeat (aw_ready_delay) @(vif.slave_cb);
            vif.slave_cb.awready <= 1'b1;
            do @(vif.slave_cb); while (vif.slave_cb.awvalid !== 1'b1);
            vif.slave_cb.awready <= 1'b0;

            aw_id     = vif.slave_cb.awid;
            aw_addr   = vif.slave_cb.awaddr;
            aw_len    = vif.slave_cb.awlen;
            aw_size   = vif.slave_cb.awsize;
            aw_burst  = vif.slave_cb.awburst;
            aw_lock   = vif.slave_cb.awlock;

            // Routing check
            if (!(aw_addr inside {[region_lo:region_hi]}))
                `uvm_error("AXI4_SDRV",
                    $sformatf("[%s] ROUTING ERROR: wr addr=0x%08h id=0x%0h",
                        get_parent().get_name(), aw_addr, aw_id))

            // Exclusive write check
            excl_success = 0;
            if (aw_lock == 1'b1) begin
                if (excl_monitor.exists(aw_id) &&
                    excl_monitor[aw_id] == aw_addr) begin
                    excl_success = 1;
                    excl_monitor.delete(aw_id);
                end
            end else begin
                // Normal write to a monitored address breaks
                // other IDs' exclusivity
                foreach (excl_monitor[id])
                    if (excl_monitor[id] == aw_addr)
                        excl_monitor.delete(id);
            end

            // W beats -- AXI4 has NO WID
            beat_addr = aw_addr;
            for (int beat = 0; beat <= aw_len; beat++) begin
                if (w_ready_delay > 0) begin
                    vif.slave_cb.wready <= 1'b0;
                    repeat (w_ready_delay) @(vif.slave_cb);
                end
                vif.slave_cb.wready <= 1'b1;
                do @(vif.slave_cb); while (vif.slave_cb.wvalid !== 1'b1);

                wr_data = vif.slave_cb.wdata;
                wr_strb = vif.slave_cb.wstrb;

                // WLAST checks
                if (beat == aw_len && !vif.slave_cb.wlast)
                    `uvm_error("AXI4_SDRV",
                        $sformatf("[%s] WLAST missing beat=%0d len=%0d",
                            get_parent().get_name(), beat, aw_len))
                if (beat < aw_len && vif.slave_cb.wlast)
                    `uvm_error("AXI4_SDRV",
                        $sformatf("[%s] Early WLAST beat=%0d of %0d",
                            get_parent().get_name(), beat, aw_len))

                // Write to memory (lane = byte address)
                for (int b = 0; b < 4; b++)
                    if (wr_strb[b])
                        mem[{beat_addr[31:2], 2'b00} + b] = wr_data[b*8+:8];

                beat_addr = axi_next_addr(aw_addr, beat_addr, aw_size,
                                          aw_burst, aw_len);
            end
            vif.slave_cb.wready <= 1'b0;

            // Determine response
            if (inject_decerr)
                resp = 2'b11;    // DECERR
            else if (inject_slverr)
                resp = 2'b10;    // SLVERR
            else if (aw_lock && excl_success)
                resp = 2'b01;    // EXOKAY -- exclusive success
            else
                resp = 2'b00;    // OKAY

            // B phase -- BID = received AWID
            repeat (b_valid_delay) @(vif.slave_cb);
            vif.slave_cb.bid    <= aw_id;
            vif.slave_cb.bresp  <= resp;
            vif.slave_cb.bvalid <= 1'b1;
            do @(vif.slave_cb); while (vif.slave_cb.bready !== 1'b1);
            vif.slave_cb.bvalid <= 1'b0;

            `uvm_info("AXI4_SDRV",
                $sformatf("[%s] WR id=0x%0h addr=0x%08h len=%0d resp=%02b",
                    get_parent().get_name(), aw_id, aw_addr, aw_len, resp), UVM_HIGH)
        end
    endtask

    // -- Read handler --------------------------------------
    task handle_reads();
        logic [3:0]  ar_id;
        logic [31:0] ar_addr;
        logic [7:0]  ar_len;
        logic [2:0]  ar_size;
        logic [1:0]  ar_burst;
        logic        ar_lock;
        logic [31:0] beat_addr;
        logic [1:0]  resp;

        forever begin
            // AR phase
            repeat (ar_ready_delay) @(vif.slave_cb);
            vif.slave_cb.arready <= 1'b1;
            do @(vif.slave_cb); while (vif.slave_cb.arvalid !== 1'b1);
            vif.slave_cb.arready <= 1'b0;

            ar_id    = vif.slave_cb.arid;
            ar_addr  = vif.slave_cb.araddr;
            ar_len   = vif.slave_cb.arlen;
            ar_size  = vif.slave_cb.arsize;
            ar_burst = vif.slave_cb.arburst;
            ar_lock  = vif.slave_cb.arlock;

            // Load exclusive monitor on exclusive read
            if (ar_lock == 1'b1)
                excl_monitor[ar_id] = ar_addr;

            // Routing check
            if (!(ar_addr inside {[region_lo:region_hi]}))
                `uvm_error("AXI4_SDRV",
                    $sformatf("[%s] ROUTING ERROR: rd addr=0x%08h id=0x%0h",
                        get_parent().get_name(), ar_addr, ar_id))

            if      (inject_decerr) resp = 2'b11;
            else if (inject_slverr) resp = 2'b10;
            else if (ar_lock)       resp = 2'b01;  // EXOKAY: monitor armed
            else                    resp = 2'b00;

            // R beats -- RID = received ARID per beat
            beat_addr = ar_addr;
            for (int beat = 0; beat <= ar_len; beat++) begin
                if (r_valid_delay > 0) begin
                    vif.slave_cb.rvalid <= 1'b0;
                    repeat (r_valid_delay) @(vif.slave_cb);
                end
                vif.slave_cb.rid    <= ar_id;
                vif.slave_cb.rdata  <= read_mem(beat_addr);
                vif.slave_cb.rresp  <= resp;
                vif.slave_cb.rlast  <= (beat == ar_len);
                vif.slave_cb.rvalid <= 1'b1;
                do @(vif.slave_cb); while (vif.slave_cb.rready !== 1'b1);

                beat_addr = axi_next_addr(ar_addr, beat_addr, ar_size,
                                          ar_burst, ar_len);
            end
            vif.slave_cb.rvalid <= 1'b0;
            vif.slave_cb.rlast  <= 1'b0;
        end
    endtask

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

endclass : axi4_slave_driver
