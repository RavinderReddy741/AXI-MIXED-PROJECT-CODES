// =========================================================================================================
// axi_cross_protocol_seq_pkg.sv
// Placeholder package for cross-protocol sequences that do NOT depend on $unit classes.
//
// NOTE: virtual sequences (axi_sanity_vseq, ...) extend axi_virtual_base_seq, which uses
//       axi_virtual_sequencer -- a $unit-scope class. A package cannot see $unit, so virtual
//       sequences are compiled as $unit files from sim/axi_filelist.f, NOT included here.
// =========================================================================================================
package axi_cross_protocol_seq_pkg;

    import uvm_pkg::*;
    `include "uvm_macros.svh"
    import axi_seq_item_pkg::*;

endpackage : axi_cross_protocol_seq_pkg
