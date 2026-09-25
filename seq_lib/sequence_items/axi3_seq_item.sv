// ============================================================
// axi3_seq_item.sv
// AXI3 Transaction Object
// (included inside axi_seq_item_pkg -- no imports here)
//
// AXI3 specifics :
//   - AWLEN[3:0]  : 4-bit, max 16 beats (len 0..15)
//   - AWLOCK[1:0] : 2-bit (00=normal,01=excl,10=locked)
//   - WID present : per-beat write ID (must match AWID)
//   - S01 port ID width is [1:0] (2-bit per DUT RTL)
//   - M01 port ID width is [3:0] (interconnect adds 2 slot bits)
//
// FIX: write strobes are now computed in post_randomize() from the
//      real beat address. The old constraint produced wrong lanes for
//      FIXED and WRAP narrow bursts.
// ============================================================

class axi3_seq_item extends uvm_sequence_item;

    // Configuration knobs
    int MAX_BURST_LEN  = 15;   // AXI3 max len
    int MAX_BURST_SIZE = 2;    // max size=2 (4 bytes)

    // -- Transaction fields --------------------------------
    rand axi_dir_e    direction;  // AXI_WRITE / AXI_READ
    rand logic [1:0]  id;         // [1:0] -- S01 is 2-bit per DUT RTL
    rand logic [31:0] addr;
    rand logic [3:0]  len;        // AXI3: 4-bit, 0..15
    rand logic [2:0]  size;       // log2(bytes/beat): 0=1B,1=2B,2=4B
    rand axi_burst_e  burst;      // AXI_INCR/WRAP/FIXED
    rand logic [1:0]  lock;       // AXI3: 2-bit
    rand logic [3:0]  cache;
    rand logic [2:0]  prot;
    rand logic [3:0]  qos;

    // -- Write data (dynamic array, one entry per beat) ---
    rand logic [31:0] wdata[];
    rand logic [3:0]  wstrb[];

    // -- Response (filled by driver after DUT responds) ---
    logic [31:0]      rdata[$];
    logic [1:0]       bresp;
    logic [1:0]       rresp[$];

    // -- M-side extended ID {slot,id} (filled by M01 monitor only)
    logic [3:0]       full_id;

    // -- Manual strobe override ---------------------------
    bit manual_strb = 0;

    // -- Driver delay knobs --------------------------------
    rand int unsigned aw_valid_delay;
    rand int unsigned w_valid_delay;
    rand int unsigned b_ready_delay;
    rand int unsigned ar_valid_delay;
    rand int unsigned r_ready_delay;

    // -- Stall cycle tracking (used by monitor) -----------
    int unsigned     aw_stall_cycles;
    int unsigned     w_stall_cycles;
    int unsigned     b_stall_cycles;
    int unsigned     ar_stall_cycles;
    int unsigned     r_stall_cycles;

    `uvm_object_utils_begin(axi3_seq_item)
        `uvm_field_enum    (axi_dir_e,   direction, UVM_DEFAULT)
        `uvm_field_int     (id,                     UVM_DEFAULT)
        `uvm_field_int     (addr,                   UVM_DEFAULT)
        `uvm_field_int     (len,                    UVM_DEFAULT)
        `uvm_field_int     (size,                   UVM_DEFAULT)
        `uvm_field_enum    (axi_burst_e, burst,     UVM_DEFAULT)
        `uvm_field_int     (lock,                   UVM_DEFAULT)
        `uvm_field_int     (cache,                  UVM_DEFAULT)
        `uvm_field_int     (prot,                   UVM_DEFAULT)
        `uvm_field_int     (qos,                    UVM_DEFAULT)
        `uvm_field_array_int(wdata,                 UVM_DEFAULT)
        `uvm_field_array_int(wstrb,                 UVM_DEFAULT)
    `uvm_object_utils_end

    // ========================================================
    // CONSTRAINTS
    // ========================================================

    // Lock: default normal (soft so tests can override)
    constraint c_lock {
        soft lock == 2'b00;
    }

    // Cache: default non-cacheable
    constraint c_cache {
        cache == 4'h0;
    }

    // Len: 0..15 (AXI3 max 16 beats)
    constraint c_len {
        len inside {[0:MAX_BURST_LEN]};
    }

    // Size: 0..2 (1B/2B/4B -- 32-bit data bus)
    constraint c_size {
        size inside {[0:MAX_BURST_SIZE]};
    }

    // Burst: all three types allowed
    constraint c_burst {
        burst inside {AXI_INCR, AXI_WRAP, AXI_FIXED};
    }

    // Data/strb arrays must match burst length
    constraint c_data_size {
        wdata.size() == (len + 1);
        wstrb.size() == (len + 1);
    }

    // Start address aligned to the transfer size (all bursts).
    // WRAP additionally needs len in {1,3,7,15}.
    constraint c_addr_align {
        addr % (1 << size) == 0;
        if (burst == AXI_WRAP)
            len inside {4'h1, 4'h3, 4'h7, 4'hF};
    }

    // INCR burst: must not cross 4KB boundary
    constraint c_4kb_incr {
        if (burst == AXI_INCR) {
            (33'(addr) + ((len + 1) << size) - 1) >> 12
                == 33'(addr) >> 12;
        }
    }

    // Delays: small random values
    constraint c_delays {
        aw_valid_delay inside {[0:3]};
        w_valid_delay  inside {[0:3]};
        b_ready_delay  inside {[0:2]};
        ar_valid_delay inside {[0:3]};
        r_ready_delay  inside {[0:2]};
    }

    function new(string name = "axi3_seq_item");
        super.new(name);
    endfunction

    // Strobes follow the real beat address (FIXED/INCR/WRAP)
    function void post_randomize();
        logic [31:0] beat_addr = addr;
        if (manual_strb) return;
        foreach (wstrb[i]) begin
            wstrb[i]  = axi_lane_mask(beat_addr, size);
            beat_addr = next_addr(beat_addr);
        end
    endfunction

    // ========================================================
    // ADDRESS CALCULATION UTILITIES
    // ========================================================

    // Wrap boundary -- lowest address of the WRAP window
    function logic [31:0] wrap_boundary();
        logic [31:0] total_bytes = (32'(len) + 1) * (32'd1 << size);
        return (addr / total_bytes) * total_bytes;
    endfunction : wrap_boundary

    // Beat address calculation for FIXED/INCR/WRAP
    function logic [31:0] next_addr(logic [31:0] curr_addr);
        return axi_next_addr(addr, curr_addr, size, burst, 8'(len));
    endfunction : next_addr

    // Auto size from address alignment
    function logic [2:0] size_of_addr(logic [31:0] a);
        if (a[0])      return 3'd0;
        else if (a[1]) return 3'd1;
        else           return 3'd2;
    endfunction : size_of_addr

    function string convert2string();
        return $sformatf(
            "AXI3: %s id=%0h addr=0x%08h len=%0d size=%0d burst=%s lock=%0b bresp=%0b",
            direction.name(), id, addr, len, size,
            burst.name(), lock, bresp);
    endfunction

endclass : axi3_seq_item
