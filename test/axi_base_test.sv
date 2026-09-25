`include "uvm_macros.svh"
import uvm_pkg::*;
import axi_seq_item_pkg::*;

// ============================================================
// axi_base_test.sv
// Base test class -- builds env. Clock/reset live in tb_top.
// All protocol tests extend this.
// ============================================================

class axi_base_test extends uvm_test;

    `uvm_component_utils(axi_base_test)

    axi_mixed_env env;

    // Cycles to keep running after the stimulus completes so
    // in-flight monitor/scoreboard traffic drains (10 ns clock)
    int unsigned drain_cycles = 100;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        env = axi_mixed_env::type_id::create("env", this);
    endfunction

    function void end_of_elaboration_phase(uvm_phase phase);
        super.end_of_elaboration_phase(phase);
        uvm_top.print_topology();
    endfunction

    task drain();
        #(drain_cycles * 10ns);
    endtask

endclass : axi_base_test
