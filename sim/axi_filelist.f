// ============================================================
// axi_filelist.f -- TB compile order (paths relative to sim/)
// ORDER MATTERS: packages -> sb_beat (imp decls) -> scoreboard
//   -> agents -> env -> sequences -> tests -> tb_top
// The DUT (Vivado export_simulation output) is passed separately
// via DUT_FILELIST in the Makefile.
// ============================================================
+incdir+../seq_lib/sequence_items

// -- Interfaces --------------------------------------------
../interfaces/axi4lite_if.sv
../interfaces/axi3_if.sv
../interfaces/axi4_if.sv

// -- Packages ----------------------------------------------
../seq_lib/sequence_items/axi_seq_item_pkg.sv
../seq_lib/axi4_lite_seqs/axi4lite_seq_pkg.sv
../seq_lib/axi3_seqs/axi3_seq_pkg.sv
../seq_lib/axi4_seqs/axi4_seq_pkg.sv
../seq_lib/axi_cross_protocol_seqs/axi_cross_protocol_seq_pkg.sv
../seq_lib/axi_seq_lib_pkg.sv
../test/axi4lite_tests/axi4lite_test_pkg.sv
../test/axi3_tests/axi3_test_pkg.sv
../test/axi4_tests/axi4_test_pkg.sv
../test/axi_cross_protocol_tests/axi_cross_protocol_test_pkg.sv
../test/axi_test_pkg.sv

// -- Scoreboard (sb_beat.sv FIRST: analysis imp decls) ------
../scoreboard/sb_beat.sv
../scoreboard/axi_scoreboard.sv

// -- Coverage ----------------------------------------------
../coverage/axi_coverage.sv

// -- Master agents -----------------------------------------
../agents/master_agents/axi4lite_master/axi4lite_master_sequencer.sv
../agents/master_agents/axi4lite_master/axi4lite_master_driver.sv
../agents/master_agents/axi4lite_master/axi4lite_master_monitor.sv
../agents/master_agents/axi4lite_master/axi4lite_master_agent.sv
../agents/master_agents/axi3_master/axi3_master_sequencer.sv
../agents/master_agents/axi3_master/axi3_master_driver.sv
../agents/master_agents/axi3_master/axi3_master_monitor.sv
../agents/master_agents/axi3_master/axi3_master_agent.sv
../agents/master_agents/axi4_master/axi4_master_sequencer.sv
../agents/master_agents/axi4_master/axi4_master_driver.sv
../agents/master_agents/axi4_master/axi4_master_monitor.sv
../agents/master_agents/axi4_master/axi4_master_agent.sv

// -- Slave agents ------------------------------------------
../agents/slave_agents/axi4lite_slave_agent/axi4lite_slave_driver.sv
../agents/slave_agents/axi4lite_slave_agent/axi4lite_slave_monitor.sv
../agents/slave_agents/axi4lite_slave_agent/axi4lite_slave_agent.sv
../agents/slave_agents/axi3_slave_agent/axi3_slave_driver.sv
../agents/slave_agents/axi3_slave_agent/axi3_slave_monitor.sv
../agents/slave_agents/axi3_slave_agent/axi3_slave_agent.sv
../agents/slave_agents/axi4_slave_agent/axi4_slave_driver.sv
../agents/slave_agents/axi4_slave_agent/axi4_slave_monitor.sv
../agents/slave_agents/axi4_slave_agent/axi4_slave_agent.sv

// -- Env ---------------------------------------------------
../env/axi_virtual_sequencer.sv
../env/axi_mixed_env.sv

// -- Sequences ---------------------------------------------
../seq_lib/axi4_lite_seqs/axi4lite_base_seq.sv
../seq_lib/axi4_lite_seqs/axi4lite_wr_rd_seq.sv
../seq_lib/axi3_seqs/axi3_base_seq.sv
../seq_lib/axi3_seqs/axi3_rd_after_wr_seq.sv
../seq_lib/axi4_seqs/axi4_base_seq.sv
../seq_lib/axi4_seqs/axi4_rd_after_wr_seq.sv
../seq_lib/axi_virtual_base_seq.sv
../seq_lib/axi_cross_protocol_seqs/axi_sanity_vseq.sv

// -- Tests -------------------------------------------------
../test/axi_base_test.sv
../test/axi_cross_protocol_tests/axi_sanity_test.sv
../test/axi4lite_tests/axi4lite_wr_rd_test.sv
../test/axi3_tests/axi3_rd_after_wr_test.sv
../test/axi4_tests/axi4_rd_after_wr_test.sv

// -- Top ---------------------------------------------------
../top/tb_top.sv
