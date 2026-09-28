// ============================================================================================
// axi_seq_item_pkg.sv
// Base sequence item package (seq_lib/sequence_items/axi_seq_item_pkg.sv)
//
// CAUTION: This package aggregates all protocol transaction item classes.
// Ensure all item files exist in the corresponding directory before including.
// NOTE: the item files are `included INTO this package -- they must NOT
//       contain their own `import axi_seq_item_pkg::*` (a package cannot
//       import itself).
// ============================================================================================
package axi_seq_item_pkg;

    import uvm_pkg::*;
    `include "uvm_macros.svh"

    // -- Enums shared across all protocols -----------------
    typedef enum logic [1:0] {
        AXI_OKAY   = 2'b00,
        AXI_EXOKAY = 2'b01,
        AXI_SLVERR = 2'b10,
        AXI_DECERR = 2'b11
    } axi_resp_e;

    typedef enum logic [1:0] {
        AXI_FIXED = 2'b00,
        AXI_INCR  = 2'b01,
        AXI_WRAP  = 2'b10
    } axi_burst_e;

    typedef enum bit {
        AXI_WRITE = 1'b1,
        AXI_READ  = 1'b0
    } axi_dir_e;

    // -- Shared helpers ------------------------------------
    // Byte-lane mask of one beat on a 32-bit bus
    function automatic logic [3:0] axi_lane_mask(
        logic [31:0] beat_addr,
        logic [2:0]  size
    );
        case (size)
            3'd0:    return 4'b0001 << beat_addr[1:0];
            3'd1:    return 4'b0011 << {beat_addr[1], 1'b0};
            default: return 4'b1111;
        endcase
    endfunction

    // Address of the beat following cur_addr (AXI spec A3.4.1)
    function automatic logic [31:0] axi_next_addr(
        logic [31:0] start_addr,
        logic [31:0] cur_addr,
        logic [2:0]  size,
        logic [1:0]  burst,
        logic [7:0]  len
    );
        logic [31:0] step      = 32'd1 << size;
        logic [31:0] wrap_sz   = step * (32'(len) + 1);
        logic [31:0] wrap_base = (start_addr / wrap_sz) * wrap_sz;
        logic [31:0] nxt;
        case (burst)
            2'b00:   return cur_addr;                          // FIXED
            2'b10: begin                                        // WRAP
                nxt = (cur_addr & ~(step - 1)) + step;
                return (nxt >= wrap_base + wrap_sz) ? wrap_base : nxt;
            end
            default: return (cur_addr & ~(step - 1)) + step;   // INCR
        endcase
    endfunction

    // -- Seq item classes ----------------------------------
    `include "axi4lite_seq_item.sv"
    `include "axi3_seq_item.sv"
    `include "axi4_seq_item.sv"

endpackage : axi_seq_item_pkg
