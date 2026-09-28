// ============================================================
// axi4lite_seq_item.sv
// AXI4-Lite Transaction Object
// (included inside axi_seq_item_pkg -- no imports here)
//
// AXI4-Lite specifics:
//   - NO burst, NO id, NO len, NO size, NO lock, NO QoS
//   - Always single beat (1 word = 32-bit)
//   - Address must be 4-byte aligned
//   - WSTRB must not be 4'h0
//   - BRESP/RRESP: OKAY or SLVERR only (no EXOKAY)
//   - PROT: privilege/security/access type
// ============================================================

class axi4lite_seq_item extends uvm_sequence_item;

    // -- Transaction fields --------------------------------
    rand axi_dir_e   direction;   // AXI_WRITE / AXI_READ
    rand bit [31:0]  addr;        // byte address (must be aligned)
    rand bit [31:0]  data;        // write data
    rand bit [3:0]   strb;        // write byte strobe
    rand bit [2:0]   prot;        // AxPROT[2:0]

    // -- Response (driven by slave/DUT, not randomized) ---
    bit [1:0]        resp;        // BRESP / RRESP
    bit [31:0]       rdata;       // read data from DUT

    // -- Stall cycle tracking (used by monitor) -----------
    int unsigned     aw_stall_cycles;
    int unsigned     w_stall_cycles;
    int unsigned     b_stall_cycles;
    int unsigned     ar_stall_cycles;
    int unsigned     r_stall_cycles;

    // -- Driver delay knobs --------------------------------
    rand int unsigned aw_valid_delay;
    rand int unsigned w_valid_delay;
    rand int unsigned b_ready_delay;
    rand int unsigned ar_valid_delay;
    rand int unsigned r_ready_delay;

    `uvm_object_utils_begin(axi4lite_seq_item)
        `uvm_field_enum(axi_dir_e,  direction, UVM_DEFAULT)
        `uvm_field_int (addr,                  UVM_DEFAULT)
        `uvm_field_int (data,                  UVM_DEFAULT)
        `uvm_field_int (strb,                  UVM_DEFAULT)
        `uvm_field_int (prot,                  UVM_DEFAULT)
        `uvm_field_int (resp,                  UVM_DEFAULT)
        `uvm_field_int (rdata,                 UVM_DEFAULT)
    `uvm_object_utils_end

    // ========================================================
    // CONSTRAINTS
    // ========================================================

    // Address must be 4-byte aligned (AXI4-Lite spec)
    constraint c_addr_align {
        addr[1:0] == 2'b00;
    }

    // WSTRB must not be zero (no point writing nothing)
    constraint c_strb_nonzero {
        if (direction == AXI_WRITE)
            strb != 4'h0;
        else
            strb == 4'h0;  // strobe not used for reads
    }

    // Default delays -- small random values
    constraint c_delays {
        aw_valid_delay inside {[0:3]};
        w_valid_delay  inside {[0:3]};
        b_ready_delay  inside {[0:2]};
        ar_valid_delay inside {[0:3]};
        r_ready_delay  inside {[0:2]};
    }

    // PROT: any value
    constraint c_prot {
        prot inside {[3'b000:3'b111]};
    }

    function new(string name = "axi4lite_seq_item");
        super.new(name);
    endfunction

    function string convert2string();
        return $sformatf(
            "LITE: %s addr=0x%08h data=0x%08h strb=0x%h prot=%0b resp=%0b rdata=0x%08h",
            direction.name(), addr, data, strb, prot, resp, rdata);
    endfunction

endclass : axi4lite_seq_item
