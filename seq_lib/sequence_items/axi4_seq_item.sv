// ============================================================
// axi4_seq_item.sv
// AXI4 Transaction Object
// (included inside axi_seq_item_pkg -- no imports here)
//
// AXI4 :
//   - AWLEN[7:0]   : 8-bit, 256 beats for INCR (0..255)
//   - AWLOCK[0]    : 1-bit only (no locked mode)
//   - NO WID       : write interleaving removed
//   - AWQOS[3:0]   : QoS hint (new in AXI4)
//   - AWREGION[3:0]: region identifier (new in AXI4)
//   - WRAP/FIXED   : still max 16 beats (len 0..15)
//
// FIX: id is soft-constrained to the S02 thread-ID width (2 bits).
//      The interconnect returns BID/RID with its slot bits in [3:2]
//      (ARID=2 comes back as RID=0xA), so the driver/monitor match
//      responses on id[1:0]. IDs >= 4 would alias.
// FIX: strobes computed in post_randomize() from the real beat address.
// ============================================================

class axi4_seq_item extends uvm_sequence_item;

    // Configuration knobs
    int MAX_BURST_LEN  = 255;  // AXI4 INCR max
    int MAX_BURST_SIZE = 2;    // max size=2 (4 bytes/beat)

    // -- Transaction fields --------------------------------
    rand axi_dir_e    direction;  // AXI_WRITE / AXI_READ
    rand logic [3:0]  id;         // AWID/ARID [3:0]
    rand logic [31:0] addr;
    rand logic [7:0]  len;        // AXI4: 8-bit, 0..255 (INCR)
    rand logic [2:0]  size;       // log2(bytes/beat): 0=1B,1=2B,2=4B
    rand axi_burst_e  burst;      // AXI_INCR/WRAP/FIXED
    rand logic        lock;       // AXI4: 1-bit (0=normal,1=excl)
    rand logic [3:0]  cache;
    rand logic [2:0]  prot;
    rand logic [3:0]  qos;        // QoS hint (new in AXI4)
    rand logic [3:0]  region;     // region identifier (new in AXI4)

    // -- Write data (dynamic array, one entry per beat) ---
    rand logic [31:0] wdata[];
    rand logic [3:0]  wstrb[];

    // -- Response (filled by driver after DUT responds) ---
    logic [31:0]      rdata[$];
    logic [1:0]       bresp;
    logic [1:0]       rresp[$];

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

    `uvm_object_utils_begin(axi4_seq_item)
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
        `uvm_field_int     (region,                 UVM_DEFAULT)
        `uvm_field_array_int(wdata,                 UVM_DEFAULT)
        `uvm_field_array_int(wstrb,                 UVM_DEFAULT)
    `uvm_object_utils_end

    // ========================================================
    // CONSTRAINTS
    // ========================================================

    // ID: S02 thread-ID width is 2 bits (see header)
    constraint c_id {
        soft id inside {[0:3]};
    }

    // Lock: default normal
    constraint c_lock {
        soft lock == 1'b0;
    }

    // Cache: default non-cacheable
    constraint c_cache {
        cache == 4'h0;
    }

    // QoS: default 0
    constraint c_qos {
        soft qos == 4'h0;
    }

    // Region: default 0
    constraint c_region {
        soft region == 4'h0;
    }

    // Len constraints per burst type:
    //   INCR  : 0..255 (256 beats)
    //   WRAP  : 1,3,7,15 only (2,4,8,16 beats)
    //   FIXED : 0..15 (16 beats max)
    constraint c_len {
        if (burst == AXI_INCR)
            len inside {[0:MAX_BURST_LEN]};
        else
            len inside {[0:8'hF]};
    }

    // Size: 0..2 (32-bit data bus)
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
            len inside {8'h1, 8'h3, 8'h7, 8'hF};
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

    function new(string name = "axi4_seq_item");
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

    function logic [31:0] wrap_boundary();
        logic [31:0] total_bytes = (32'(len) + 1) * (32'd1 << size);
        return (addr / total_bytes) * total_bytes;
    endfunction : wrap_boundary

    function logic [31:0] next_addr(logic [31:0] curr_addr);
        return axi_next_addr(addr, curr_addr, size, burst, len);
    endfunction : next_addr

    function logic [2:0] size_of_addr(logic [31:0] a);
        if (a[0])      return 3'd0;
        else if (a[1]) return 3'd1;
        else           return 3'd2;
    endfunction : size_of_addr

    function string convert2string();
        return $sformatf(
            "AXI4: %s id=%0h addr=0x%08h len=%0d size=%0d burst=%s lock=%0b qos=%0h bresp=%0b",
            direction.name(), id, addr, len, size,
            burst.name(), lock, qos, bresp);
    endfunction

endclass : axi4_seq_item
