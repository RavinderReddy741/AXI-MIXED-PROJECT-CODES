# AXI Mixed-Protocol TB: bug analysis and fixes

Reported symptom: *"The basic test passes, but I can't see values in the waveforms and the output isn't what I expect."*

That symptom has three separate causes:

1. **The test could not fail.** The scoreboard printed `TEST PASSED` whenever its own mismatch counter was 0, even when it had compared nothing. Most monitor checks had been demoted to `uvm_info`/`uvm_warning`, and "expected beat never arrived" was only a warning.
2. **Several defects stopped real data from flowing or being captured.** These include handshake timing, ID width, sequence item lifetime and queue indexing.
3. **The waveform dump was incomplete** (FSDB options plus the Xilinx `glbl` top).

Every fix below is in this commit. The whole TB elaborates with zero errors in the slang SystemVerilog compiler against UVM sources, using a port-accurate stub in place of the DUT. It has **not** been simulated against the real Vivado IP, because the IP isn't available in this environment.

---

## A. Why the waveforms showed no values

| # | Cause | Fix |
|---|-------|-----|
| A1 | `$fsdbDumpvars(0, tb_top)` without `"+all"` dumps no interface contents, MDAs or structs. Without `-debug_access+all -kdb` at compile time, Verdi shows signal names but no values. | `tb_top.sv` uses `$fsdbDumpvars(0, tb_top, "+all")`. `sim/Makefile` passes `-debug_access+all -kdb -lca`. Add `+define+DUMP_VCD` if you have no Verdi license. |
| A2 | A Vivado BD wrapper needs `glbl.v` elaborated as a **second top**. Without it the Xilinx primitives stay in GSR and the DUT outputs stay X or 0. | The Makefile uses `-top tb_top -top glbl` and `$(XILINX_VIVADO)/data/verilog/src/glbl.v`. Generate the DUT file list with Vivado `export_simulation -simulator vcs`. |
| A3 | **M01 ID width.** `axi3_if` declared 2-bit IDs because S01 is 2 bits wide, but the same interface was also used on **M01**, which carries the 4-bit extended ID `{slot,id}`. The slot bits were truncated, the slave echoed `BID/RID` with slot `00`, and the DUT routed the response to **S00** instead of S01. | `axi3_if` IDs are now 4 bits. `tb_top` adapts the 2-bit S01 port through the `S01_ID_W` parameter and the `s01_bid`/`s01_rid` wires. **Check the VCS log for `PCWM` (port connection width mismatch) lint warnings: each one is a real bug.** |
| A4 | Master outputs were X until the first clock edge. `init_signals()` drove through the clocking block, which only takes effect at the next edge plus skew. | `init_signals()` now assigns the interface signals directly, so outputs are 0 from time 0. |

## B. Handshake bugs (duplicate or lost transfers)

**B1, in all 7 drivers:** VALID/READY stayed high for one cycle after the handshake. The drivers did this:

```systemverilog
wait_handshake(...);        // returns on the handshake edge E
@(vif.master_cb);           // <-- waits until E+1
vif.master_cb.awvalid <= 0; // takes effect at E+1+skew
```

So at edge E+1 the signal was **still high**. Whenever the other side also kept its READY or VALID high (the Xilinx interconnect usually does), a second handshake happened:

* master AWVALID or WVALID: a duplicate address or duplicate data beat went into the DUT
* master BREADY or RREADY: the driver silently accepted an extra response or beat it never recorded
* slave BVALID or RVALID: the DUT saw a phantom second B response, or a duplicate R beat that could carry RLAST
* slave AWREADY or ARREADY: the DUT handed over a request the slave then ignored, and the DUT hung

**Fix:** drop VALID/READY on the handshake edge itself. The next beat is driven in the same timestep for back-to-back transfers. Only one clocking drive happens per signal per timestep.

**B2:** `wait_handshake` in the Lite driver mixed direct drives (`vif.awvalid <= 1`) with clocking-block drives (`vif.master_cb.awaddr <= ...`), so VALID and payload changed at different times. Everything now goes through `master_cb`.

**B3:** Each channel task now re-aligns with `@(vif.master_cb)` before it drives. A clocking drive issued outside the clocking event lands one edge later, while `wait_handshake` was already counting that edge.

## C. Sequence-item lifetime (the "wrong output" in the log)

**C1:** The Lite and AXI4 drivers called `item_done()` **as soon as they received the item**, before driving it. As a result:

* `lite_item.rdata` printed in `axi_sanity_vseq` was always 0, because the read hadn't happened yet.
* A read could overtake the preceding write to the same address. The AW/W/AR tasks run independently, so the read returned stale data.
* The AXI3 driver waited on `b_q.size()==0`, but `b_q` is popped *before* the response arrives, so it had the same problem.

**Fix:** every master driver has `blocking_mode` (default 1), where `item_done()` is called only after the B response or the last R beat, with a watchdog. Set `blocking_mode=0` through `config_db` on the AXI4 driver for pipelined, multi-outstanding traffic.

## D. Monitor bugs

| # | Where | Bug | Effect |
|---|-------|-----|--------|
| D1 | AXI3 master driver and monitor, AXI3 slave monitor | `item.rdata[beat] = ...` on an **empty queue** | An out-of-bounds write is ignored, so reads were published with no data. Fixed with `push_back`. |
| D2 | AXI4 master monitor | RID matched against ARID with **all** bits, but the interconnect returns `RID=0xA` for `ARID=2` | No S02 read was ever published. The message was `uvm_info` at `UVM_MEDIUM`, so it stayed silent. Now matched on `id & id_mask`, which defaults to 2'b11. |
| D3 | AXI4 master driver | Unknown RID was acked silently at `UVM_DEBUG` | Now a `uvm_error`. |
| D4 | AXI4 slave monitor | **Every** check (routing, BID/RID, DECERR, X on data, interop) had been changed to `uvm_info(...,UVM_MEDIUM)` | M02/M03 could never fail a test. Restored to `uvm_error`. |
| D5 | Lite slave monitor | Checks were `uvm_warning`. "R with no pending AR" was hidden at `UVM_HIGH`. | Now `uvm_error`. |
| D6 | All monitors | One forked thread per channel woke on the same edge in an undefined order, for example the WID check running before the AW of the same edge was queued | Replaced with one sampling loop in a fixed order: AW, W, B, AR, R. |
| D7 | AXI3 monitors | WID checked against `aw_q[0]`, which was the wrong burst when several AWs were pending | Now tracks which AW the current W burst belongs to. WLAST position is also checked. |
| D8 | AXI4 master monitor | B response matched in plain FIFO order | Now matched to the oldest AW with the same ID. |

## E. Scoreboard: why it always passed

| # | Bug | Fix |
|---|-----|-----|
| E1 | `compare_beat` only incremented a counter and never printed anything | `uvm_error` with the expected and actual data and strobe |
| E2 | `check_pending` ("expected beat never arrived") was a **warning** | `uvm_error` |
| E3 | Leftover M-side beats in `unmatched_actual_q` (traffic the DUT invented or misrouted) were ignored | `uvm_error` in `check_phase` |
| E4 | `TEST PASSED` when **0** comparisons were made | `SB_EMPTY` error when nothing was checked |
| E5 | PASS/FAIL ignored UVM_ERRORs from drivers and monitors | Uses `uvm_report_server` error and fatal counts, and prints a summary table |
| E6 | **The read data the master receives was never checked.** Only the TB slave's own memory output on the M side was compared. BRAM (M04) reads were therefore not checked at all. | Every S-side read beat is compared against `ref_mem` end to end. This covers BRAM too. |
| E7 | Responses were ignored | DECERR is expected on unmapped addresses. OKAY is expected elsewhere, or EXOKAY for exclusive accesses. Set `expect_err_resp=1` for error-injection tests. |
| E8 | `ref_mem_write` wrote 0 into non-strobed bytes, and narrow transfers used the wrong byte lanes | Only strobed lanes are written. Lanes come from the byte address. |
| E9 | Matching required an equal `beat_num` | A burst split by the interconnect, such as a 32-beat AXI4 burst sent to AXI3 M01 as 2x16, never matched. Matching now uses port, address and direction in FIFO order. |
| E10 | `imp_s01` was declared twice | This was a compile error. |

## F. Slave-model bugs

* **F1 (AXI3 slave):** `handle_reads` was missing `case (ar_burst)`, which was a compile error.
* **F2 (all slaves):** narrow transfers wrote and read byte lanes starting at 0 instead of at the byte address.
* **F3 (AXI3 slave):** every read of an unwritten address waited up to 1000 cycles for the memory to be filled. That exceeds the Lite master's 1000-cycle R timeout. The hack is removed, since ordering is now guaranteed by the blocking masters (C1).
* **F4 (all slaves):** handlers are killed and restarted on reset.

## G. Other compile or elaboration problems in the code as pasted

* `axi4lite_master_driver`: `b_timeout`, `ar_timeout` and `r_timeout` were each declared twice.
* `axi4_if`: the whole AW channel was declared twice.
* `axi4_master_driver::collect_b`: a stray duplicated `$sformatf(...)` line.
* `axi4lite_slave_monitor`: a duplicated `complete.strb,` argument, which gave a format argument count mismatch.
* `axi_sanity_vseq` existed in two directories, so the class was defined twice.
* The seq-item files did `import axi_seq_item_pkg::*` while being `` `include``d **inside** that package, so the package imported itself.
* `axi_coverage.sv` used `bins edge`. `edge` is a SystemVerilog keyword, which is likely why coverage was commented out. The bin is renamed `at_edge` and coverage is enabled again.

## H. Sequence items

* Write strobes are computed in `post_randomize()` from the real beat address. The old constraint gave wrong lanes for narrow FIXED and WRAP bursts.
* Start addresses are aligned to the transfer size for every burst type.
* `axi4_seq_item.id` is soft-constrained to `[0:3]`, the S02 thread-ID width. See D2.

---

## What to check first on your server

1. Compile with `make compile DUT_FILELIST=<export_simulation .f>`. **Search `compile.log` for `PCWM`.** If any S or M port width differs from the interface, fix `S01_ID_W` or the interface widths.
2. Run `make run TEST=axi_sanity_test VERB=UVM_MEDIUM`. You should see:
   * `Lite RD done rdata=0xdeadbeef`
   * a scoreboard summary with non-zero *matched* and *end-to-end read-data checks* counts
3. `make verdi`. Values should now be visible on all 7 interfaces.
4. If something now **fails** that used to "pass", the checker is working. Read the first `UVM_ERROR`.

## Not reproduced here

The interface SVA blocks were commented out in the original code and are not carried over. Several of them need rework before they are enabled:

* `A_EXOKAY_ONLY_IF_EXCLUSIVE` tests `last_awid != 0`.
* `A_BID_MATCH` and the WLAST counters assume one outstanding transaction.
* They call `` `uvm_error`` inside an interface without importing `uvm_pkg`.

Re-enable the VALID-stable and payload-stable rules first, since those are safe.
