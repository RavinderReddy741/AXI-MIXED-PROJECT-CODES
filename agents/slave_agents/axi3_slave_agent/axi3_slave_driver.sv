`include "uvm_macros.svh"
import uvm_pkg::*;
import axi_seq_item_pkg::*;

// ============================================================
// axi3_slave_driver.sv
// Responds on DUT M01_AXI (AXI3 master port)
//
// INTERCONNECT ID EXTENSION MECHANISM:
//   M01 ID = 4 bits = {slot[1:0], orig_id[1:0]}
//     S00 (Lite)  -> slot 2'b00
//     S01 (AXI3)  -> slot 2'b01
//     S02 (AXI4)  -> slot 2'b10
//
// SLAVE RESPONSE RULE:
//   BID = received AWID (full 4-bit echo)
//   RID = received ARID (full 4-bit echo per beat)
//   Interconnect strips the slot bits and routes to the S-port
//
// AXI3 SPECIFIC:
//   - WID per beat must match AWID
//   - AWLEN 4-bit (max 15 = 16 beats)
//   - AWLOCK 2-bit; LOCKED/EXCL both answered OKAY
//   - WLAST / RLAST on final beat
//
// FIXES:
//   - handle_reads was missing "case (ar_burst)" (compile error)
//   - READY/VALID dropped on the handshake edge (was 1 cycle late
//     -> duplicate B / duplicate R beats seen by the DUT)
//   - Narrow transfers: memory uses the byte LANE of the beat
//     address (was always lanes starting at 0)
//   - Removed the "wait up to 1000 cycles for mem to exist" read
//     hack: it stalled every read of an unwritten address by
//     1000 cycles (> the Lite master's 1000-cycle R timeout).
//     Read-after-write ordering is now guaranteed by the
//     blocking master drivers.
//   - Kill/restart handlers on reset
//
// ADDRESS REGION: M01 = 0x44A1_0000 - 0x44A1_FFFF
// ============================================================

class axi3_slave_driver extends uvm_driver #(axi3_seq_item);

    `uvm_component_utils(axi3_slave_driver)

    virtual axi3_if vif;

    // -- Memory model --------------------------------------
    logic [7:0] mem [logic [31:0]];

    // -- Address region ------------------------------------
    logic [31:0] region_lo = 32'h44A1_0000;
    logic [31:0] region_hi = 32'h44A1_FFFF;

    // -- Delays --------------------------------------------
    int unsigned aw_ready_delay = 0;
    int unsigned w_ready_delay  = 0;
    int unsigned b_valid_delay  = 1;
    int unsigned ar_ready_delay = 0;
    int unsigned r_valid_delay  = 1;

    // -- Error injection -----------------------------------
    bit inject_slverr = 0;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        if (!uvm_config_db #(virtual axi3_if)::get(
                this, "", "vif", vif))
            `uvm_fatal("NOVIF",
                "axi3_slave_driver: cannot get vif")
        void'(uvm_config_db #(int unsigned)::get(this, "", "aw_ready_delay", aw_ready_delay));
        void'(uvm_config_db #(int unsigned)::get(this, "", "w_ready_delay",  w_ready_delay));
        void'(uvm_config_db #(int unsigned)::get(this, "", "b_valid_delay",  b_valid_delay));
        void'(uvm_config_db #(int unsigned)::get(this, "", "ar_ready_delay", ar_ready_delay));
        void'(uvm_config_db #(int unsigned)::get(this, "", "r_valid_delay",  r_valid_delay));
        void'(uvm_config_db #(bit)::get(this, "", "inject_slverr",  inject_slverr));
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
            `uvm_info("AXI3_SDRV", "[M01] Reset -- restarting", UVM_LOW)
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
        logic [3:0]  aw_id;      // extended ID from M01
        logic [31:0] aw_addr;
        logic [3:0]  aw_len;     // AXI3: 4-bit
        logic [2:0]  aw_size;
        logic [1:0]  aw_burst;
        logic [1:0]  aw_lock;    // AXI3: 2-bit
        logic [31:0] beat_addr;
        logic [31:0] wr_data;
        logic [3:0]  wr_strb;
        logic [1:0]  resp;

        forever begin
            // AW phase
            repeat (aw_ready_delay) @(vif.slave_cb);
            vif.slave_cb.awready <= 1'b1;
            do @(vif.slave_cb); while (vif.slave_cb.awvalid !== 1'b1);
            vif.slave_cb.awready <= 1'b0;

            // Capture extended ID -- echo this back as BID
            aw_id    = vif.slave_cb.awid;
            aw_addr  = vif.slave_cb.awaddr;
            aw_len   = vif.slave_cb.awlen;
            aw_size  = vif.slave_cb.awsize;
            aw_burst = vif.slave_cb.awburst;
            aw_lock  = vif.slave_cb.awlock;

            // Routing check
            if (!(aw_addr inside {[region_lo:region_hi]}))
                `uvm_error("AXI3_SDRV",
                    $sformatf("[M01] ROUTING ERROR: wr addr=0x%08h id=0x%0h",
                        aw_addr, aw_id))

            // W beats
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

                // AXI3: WID must match AWID per beat
                if (vif.slave_cb.wid !== aw_id)
                    `uvm_error("AXI3_SDRV",
                        $sformatf("[M01] WID=0x%0h != AWID=0x%0h at beat %0d",
                            vif.slave_cb.wid, aw_id, beat))

                // WLAST check
                if (beat == aw_len && !vif.slave_cb.wlast)
                    `uvm_error("AXI3_SDRV",
                        $sformatf("[M01] WLAST missing on final beat %0d", beat))
                if (beat < aw_len && vif.slave_cb.wlast)
                    `uvm_error("AXI3_SDRV",
                        $sformatf("[M01] Early WLAST at beat %0d of %0d",
                            beat, aw_len))

                // Write to memory with strobe (lane = byte address)
                for (int b = 0; b < 4; b++)
                    if (wr_strb[b])
                        mem[{beat_addr[31:2], 2'b00} + b] = wr_data[b*8+:8];

                `uvm_info("AXI3_SDRV",
                    $sformatf("%s WR beat %0d addr=0x%08h data=0x%08h strb=0x%h id=0x%0h",
                        "[M01]", beat, beat_addr, wr_data, wr_strb, aw_id), UVM_MEDIUM)

                beat_addr = axi_next_addr(aw_addr, beat_addr, aw_size,
                                          aw_burst, 8'(aw_len));
            end
            vif.slave_cb.wready <= 1'b0;

            // LOCKED (2'b10) / EXCLUSIVE (2'b01): OKAY
            // (interconnect converts lock semantics)
            resp = inject_slverr ? 2'b10 : 2'b00;

            // B phase -- BID = received AWID (full extended ID)
            repeat (b_valid_delay) @(vif.slave_cb);
            vif.slave_cb.bid    <= aw_id;
            vif.slave_cb.bresp  <= resp;
            vif.slave_cb.bvalid <= 1'b1;
            do @(vif.slave_cb); while (vif.slave_cb.bready !== 1'b1);
            vif.slave_cb.bvalid <= 1'b0;

            `uvm_info("AXI3_SDRV",
                $sformatf("[M01] WR id=0x%0h addr=0x%08h len=%0d lock=%0b resp=%02b",
                    aw_id, aw_addr, aw_len, aw_lock, resp), UVM_HIGH)
        end
    endtask

    // -- Read handler --------------------------------------
    task handle_reads();
        logic [3:0]  ar_id;      // extended ID from M01
        logic [31:0] ar_addr;
        logic [3:0]  ar_len;
        logic [2:0]  ar_size;
        logic [1:0]  ar_burst;
        logic [31:0] beat_addr;

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

            // Routing check
            if (!(ar_addr inside {[region_lo:region_hi]}))
                `uvm_error("AXI3_SDRV",
                    $sformatf("[M01] ROUTING ERROR: rd addr=0x%08h id=0x%0h",
                        ar_addr, ar_id))

            // R beats -- RID = received ARID per beat
            beat_addr = ar_addr;
            for (int beat = 0; beat <= ar_len; beat++) begin
                if (r_valid_delay > 0) begin
                    vif.slave_cb.rvalid <= 1'b0;
                    repeat (r_valid_delay) @(vif.slave_cb);
                end
                vif.slave_cb.rid    <= ar_id;
                vif.slave_cb.rdata  <= read_mem(beat_addr);
                vif.slave_cb.rresp  <= inject_slverr ? 2'b10 : 2'b00;
                vif.slave_cb.rlast  <= (beat == ar_len);
                vif.slave_cb.rvalid <= 1'b1;
                trace_read(ar_id, beat_addr, beat, ar_len);
                do @(vif.slave_cb); while (vif.slave_cb.rready !== 1'b1);

                beat_addr = axi_next_addr(ar_addr, beat_addr, ar_size,
                                          ar_burst, 8'(ar_len));
            end
            vif.slave_cb.rvalid <= 1'b0;
            vif.slave_cb.rlast  <= 1'b0;
        end
    endtask

    // Read-path debug: what this slave actually puts on RDATA.
    // Run with +UVM_VERBOSITY=UVM_MEDIUM. If a read shows
    // "NEVER WRITTEN" the write went elsewhere (address/lane/routing)
    // or the read overtook the write.
    function void trace_read(logic [3:0] id, logic [31:0] addr, int beat, int len);
        bit written = 0;
        for (int b = 0; b < 4; b++)
            written |= mem.exists({addr[31:2],2'b00} + b);
        `uvm_info("AXI3_SDRV",
            $sformatf("%s RD beat %0d/%0d addr=0x%08h rdata=0x%08h rid=0x%0h%s",
                "[M01]", beat, len, addr, read_mem(addr), id,
                written ? "" : "  <-- NEVER WRITTEN, returns 0"), UVM_MEDIUM)
    endfunction

    function void preload(
        logic [31:0] addr,
        logic [31:0] data
    );
        for (int b = 0; b < 4; b++)
            mem[{addr[31:2],2'b00} + b] = data[b*8+:8];
    endfunction

    // Full 32-bit word containing addr (all 4 lanes)
    function logic [31:0] read_mem(logic [31:0] addr);
        logic [31:0] d = '0;
        for (int b = 0; b < 4; b++)
            if (mem.exists({addr[31:2],2'b00} + b))
                d[b*8+:8] = mem[{addr[31:2],2'b00} + b];
        return d;
    endfunction

endclass : axi3_slave_driver
