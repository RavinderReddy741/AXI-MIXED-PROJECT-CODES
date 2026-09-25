// ============================================================================================
// axi_test_pkg.sv
// Master test package (aggregates the protocol test packages).
// ============================================================================================
package axi_test_pkg;
    import uvm_pkg::*;
    `include "uvm_macros.svh"
    import axi_seq_item_pkg::*;
    import axi_seq_lib_pkg::*;
    import axi4lite_test_pkg::*;
    import axi3_test_pkg::*;
    import axi4_test_pkg::*;
    import axi_cross_protocol_test_pkg::*;
endpackage : axi_test_pkg
