# Change guide: where to edit YOUR code

This guide walks your original files in order and gives the **old code → new code** for each change. It is a companion to the zip.

**Fastest path:** copy the files from `axi_tb_fixed_v2.zip` over your tree. Use this guide to understand each change, or to apply it by hand.

Each change is marked with a priority:

* 🔴 **Critical.** Breaks read data or responses. Do these first.
* 🟠 **Important.** Wrong checking, or the test passes falsely.
* 🟡 **Compile / cleanup.**

---

## 1. `interfaces/axi3_if.sv` 🔴 (responses routed to the wrong master)

M01 carries a 4-bit ID `{slot[1:0], id[1:0]}`. With 2-bit IDs the slot bits are lost, and the RID/BID returned by the M01 slave goes to S00 instead of the requester.

Change **all five** ID declarations:

```systemverilog
// OLD
logic [1:0]  awid;   // S01: 2-bit per DUT RTL
logic [1:0]  wid;    // S01: 2-bit per DUT RTL
logic [1:0]  bid;    // S01: 2-bit per DUT RTL
logic [1:0]  arid;   // S01: 2-bit per DUT RTL
logic [1:0]  rid;    // S01: 2-bit per DUT RTL

// NEW
logic [3:0]  awid;
logic [3:0]  wid;
logic [3:0]  bid;
logic [3:0]  arid;
logic [3:0]  rid;
```

The S01 port is still 2 bits wide, so `tb_top` has to adapt it. See section 16.

## 2. `interfaces/axi4_if.sv` 🟡 (compile error)

The whole AW block is declared **twice**. Delete the second copy, which starts right after `logic awready;` on the same line:

```systemverilog
    logic        awvalid;
    logic        awready;    // =====...          <-- delete from here
    // WRITE ADDRESS CHANNEL (AW)
    ...
    logic        awready;                           <-- ...to here (2nd copy)
```

---

## 3. All 7 drivers: the handshake rule 🔴

This is the most important change and it is the same in every driver.

**Rule:** after the handshake edge is detected, drop VALID/READY **immediately**. Never do `@(cb)` first.

```systemverilog
// OLD (every channel, every driver)
wait_handshake("AW", aw_timeout, timeout_hit);
...
@(vif.master_cb);                 // <-- signal stays high 1 extra cycle
vif.master_cb.awvalid <= 0;       //     -> 2nd (phantom) handshake

// NEW
wait_handshake("AW", aw_timeout, timeout_hit);
vif.master_cb.awvalid <= 1'b0;    // dropped in the handshake cycle
```

The slave drivers have the same bug:

```systemverilog
// OLD
do @(vif.slave_cb);
while (!vif.slave_cb.rready || !vif.aresetn);
@(vif.slave_cb);                  // <-- RVALID high 1 extra cycle
vif.slave_cb.rvalid <= 0;         //     -> DUT takes a DUPLICATE R beat

// NEW
do @(vif.slave_cb); while (vif.slave_cb.rready !== 1'b1);
vif.slave_cb.rvalid <= 1'b0;
```

The following sections show exactly where to apply this in each file.

---

## 4. `axi4lite_master_driver.sv`

### 4a. 🟡 Remove the duplicate declarations (compile error)

```systemverilog
// OLD: these 3 lines appear twice -- delete the second set
    int unsigned b_timeout  = 1000;
    int unsigned ar_timeout = 1000;
    int unsigned r_timeout  = 1000;
```

### 4b. 🔴 Add completion tracking, and call `item_done()` only after the response

Add these members after the timeouts:

```systemverilog
    bit          blocking_mode = 1;
    int unsigned issued_cnt;
    int unsigned completed_cnt;
    int unsigned rsp_timeout = 5000;
```

In `get_and_dispatch()`:

```systemverilog
// OLD
            if (item.direction == AXI_WRITE) begin
                aw_q.push_back(item); w_q.push_back(item); b_q.push_back(item);
            end else begin
                ar_q.push_back(item); r_q.push_back(item);
            end
            seq_item_port.item_done();      // <-- returns BEFORE the read happens
                                            //     -> lite_item.rdata printed 0

// NEW
            issued_cnt++;
            if (item.direction == AXI_WRITE) begin
                aw_q.push_back(item); w_q.push_back(item); b_q.push_back(item);
            end else begin
                ar_q.push_back(item); r_q.push_back(item);
            end
            if (blocking_mode) wait_for_response();
            seq_item_port.item_done();
```

Add this new task. The same task goes into the AXI3 and AXI4 drivers, with a different message ID:

```systemverilog
    task wait_for_response();
        fork begin
            fork
                wait (completed_cnt == issued_cnt);
                begin
                    repeat (rsp_timeout) @(vif.master_cb);
                    `uvm_error("LITE_MDRV", $sformatf(
                        "No response within %0d cycles", rsp_timeout))
                    completed_cnt = issued_cnt;
                end
            join_any
            disable fork;
        end join
    endtask
```

### 4c. 🔴 Channel tasks: use the clocking block only, and drop VALID/READY on the handshake

Your Lite driver used `vif.awvalid <= 1` (direct) together with `vif.master_cb.awaddr <= ...` (clocking block). Those two land at different times.

**`drive_aw`** (`drive_ar` is identical, with ar signals):

```systemverilog
// OLD
            item = aw_q.pop_front();
            repeat (item.aw_valid_delay) begin
                @(vif.master_cb);
                if (!vif.aresetn) break;
            end
            if (!vif.aresetn) continue;
            vif.master_cb.awaddr  <= item.addr;
            vif.master_cb.awprot  <= item.prot;
            vif.awvalid <= 1;
            ...
            wait_handshake("AW", aw_timeout, timeout_hit);
            if (timeout_hit || !vif.aresetn) begin
                vif.awvalid <= 0;
                continue;
            end
            @(vif.master_cb);
            vif.awvalid <= 0;

// NEW
            item = aw_q.pop_front();
            @(vif.master_cb);                          // align to the clock edge
            repeat (item.aw_valid_delay) @(vif.master_cb);
            if (!vif.aresetn) continue;
            vif.master_cb.awaddr  <= item.addr;
            vif.master_cb.awprot  <= item.prot;
            vif.master_cb.awvalid <= 1'b1;
            ...
            wait_handshake("AW", aw_timeout, timeout_hit);
            vif.master_cb.awvalid <= 1'b0;
```

**`drive_w`** works the same way: use `vif.master_cb.wvalid <= 1'b1`, and after the handshake `vif.master_cb.wvalid <= 1'b0`.

**`collect_b`**:

```systemverilog
// OLD
            vif.bready <= 1;
            wait_handshake("B", b_timeout, timeout_hit);
            if (timeout_hit || !vif.aresetn) begin
                vif.bready <= 0;
                continue;
            end
            item.resp = axi_resp_e'(vif.master_cb.bresp);
            ...
            @(vif.master_cb);
            vif.bready <= 0;

// NEW
            item = b_q.pop_front();
            @(vif.master_cb);
            repeat (item.b_ready_delay) @(vif.master_cb);
            vif.master_cb.bready <= 1'b1;
            wait_handshake("B", b_timeout, timeout_hit);
            vif.master_cb.bready <= 1'b0;
            if (!timeout_hit && vif.aresetn) begin
                item.resp = vif.master_cb.bresp;
                if (item.resp == AXI_EXOKAY)
                    `uvm_error("LITE_MDRV", "BRESP=EXOKAY -- illegal on AXI4-Lite")
            end
            completed_cnt++;                           // <-- releases item_done
```

**`collect_r`** follows the same shape as `collect_b`: `rready`, then `item.rdata = vif.master_cb.rdata; item.resp = vif.master_cb.rresp;`, then `completed_cnt++`.

### 4d. 🔴 `wait_handshake`: only check the OTHER side's signal

```systemverilog
// OLD
"AW": if (vif.awvalid && vif.master_cb.awready) return;
...
// NEW
"AW": if (vif.master_cb.awready === 1'b1) return;
"W" : if (vif.master_cb.wready  === 1'b1) return;
"B" : if (vif.master_cb.bvalid  === 1'b1) return;
"AR": if (vif.master_cb.arready === 1'b1) return;
"R" : if (vif.master_cb.rvalid  === 1'b1) return;
```

### 4e. `monitor_reset`: after `r_q.delete();` add

```systemverilog
            completed_cnt = issued_cnt;
```

---

## 5. `axi3_master_driver.sv`

### 5a. 🔴 Completion tracking

Add the same members and `wait_for_response()` as in 4b. In `get_and_dispatch()`:

```systemverilog
// OLD
            seq_item_port.item_done();
            // Wait for response before next item
            if (item.direction == AXI_WRITE) wait(b_q.size() == 0);
            else wait(r_q.size() == 0);
            // (b_q/r_q are popped BEFORE the response -> this doesn't wait)

// NEW
            item.rdata.delete();
            item.rresp.delete();
            issued_cnt++;
            ... push to queues (unchanged) ...
            if (blocking_mode) wait_for_response();
            seq_item_port.item_done();
```

### 5b. 🔴 AW and AR

Apply the 4c pattern: add `@(vif.master_cb);` after `pop_front()`. After `wait_handshake`, drop VALID immediately, and delete the `@(vif.master_cb);` in front of `awvalid <= 0` / `arvalid <= 0`.

### 5c. 🔴 `drive_w` beat loop

Replace the loop body:

```systemverilog
            item = w_q.pop_front();
            @(vif.master_cb);
            for (int beat = 0; beat <= item.len; beat++) begin
                if (item.w_valid_delay > 0) begin
                    vif.master_cb.wvalid <= 1'b0;
                    repeat (item.w_valid_delay) @(vif.master_cb);
                end
                if (!vif.aresetn) break;
                vif.master_cb.wid    <= item.id;
                vif.master_cb.wdata  <= item.wdata[beat];
                vif.master_cb.wstrb  <= item.wstrb[beat];
                vif.master_cb.wlast  <= (beat == item.len);
                vif.master_cb.wvalid <= 1'b1;
                wait_handshake("W", w_timeout, timeout_hit);
                if (timeout_hit || !vif.aresetn) break;
                // NO "@(vif.master_cb); wvalid <= 0;" here any more
            end
            vif.master_cb.wvalid <= 1'b0;
            vif.master_cb.wlast  <= 1'b0;
```

### 5d. 🔴 `collect_b`

Drop BREADY right after `wait_handshake`, and add `completed_cnt++;` at the end of the loop body. The BID check on `[1:0]` stays.

### 5e. 🔴 `collect_r`: rdata was never stored

```systemverilog
// OLD
                item.rdata[beat] = vif.master_cb.rdata;       // out-of-bounds on an
                item.rresp[beat] = axi_resp_e'(...);          // EMPTY queue -> ignored!
                ...
                @(vif.master_cb);
                vif.master_cb.rready <= 0;

// NEW
                item.rdata.push_back(vif.master_cb.rdata);
                item.rresp.push_back(vif.master_cb.rresp);
                ...   (RID / RLAST checks unchanged)
            end                                   // end of beat loop
            vif.master_cb.rready <= 1'b0;
            completed_cnt++;
```

Inside the beat loop, keep RREADY high between beats. Only lower it when `r_ready_delay > 0`, the same way as the W loop.

### 5f. `wait_handshake` and `monitor_reset`

Make the same change as in 4d and 4e.

---

## 6. `axi4_master_driver.sv`

### 6a. 🟡 Compile error in `collect_b`

Delete the stray duplicated line after the `uvm_info`:

```systemverilog
                         $sformatf("%0b",item.bresp)), UVM_HIGH)    <-- delete this line
```

### 6b. 🔴 Completion tracking

Make the same change as in 4b. `item_done()` comes after `wait_for_response()`. Also clear `item.rdata` and `item.rresp` at dispatch.

### 6c. 🔴 Replace `collect_b` and `collect_r` entirely

The old versions held BREADY/RREADY for an extra cycle and silently acked unknown IDs.

```systemverilog
    int unsigned id_mask = 'h3;       // S02 thread-ID bits (RID 0xA -> key 2)

    function int key_of(logic [3:0] id);
        return int'(id) & int'(id_mask);
    endfunction

    task collect_b();
        axi4_seq_item item; int k;
        forever begin
            @(vif.master_cb);
            if (!vif.aresetn) continue;
            if (vif.master_cb.bvalid === 1'b1 && vif.bready === 1'b1) begin
                k = key_of(vif.master_cb.bid);
                if (wr_rsp_q.exists(k) && wr_rsp_q[k].size() > 0) begin
                    item = wr_rsp_q[k].pop_front();
                    if (wr_rsp_q[k].size() == 0) wr_rsp_q.delete(k);
                    item.bresp = vif.master_cb.bresp;
                    wr_slots.put(1);
                    completed_cnt++;
                end else
                    `uvm_error("AXI4_MDRV", $sformatf(
                        "BID=0x%0h matches no outstanding write", vif.master_cb.bid))
            end
            vif.master_cb.bready <= 1'b1;        // always ready
        end
    endtask

    task collect_r();
        axi4_seq_item item; int k;
        forever begin
            @(vif.master_cb);
            if (!vif.aresetn) continue;
            if (vif.master_cb.rvalid === 1'b1 && vif.rready === 1'b1) begin
                k = key_of(vif.master_cb.rid);
                if (!active_rd.exists(k) && rd_rsp_q.exists(k) && rd_rsp_q[k].size() > 0) begin
                    active_rd[k] = rd_rsp_q[k].pop_front();
                    if (rd_rsp_q[k].size() == 0) rd_rsp_q.delete(k);
                end
                if (!active_rd.exists(k))
                    `uvm_error("AXI4_MDRV", $sformatf(
                        "RID=0x%0h matches no outstanding read", vif.master_cb.rid))
                else begin
                    item = active_rd[k];
                    item.rdata.push_back(vif.master_cb.rdata);
                    item.rresp.push_back(vif.master_cb.rresp);
                    if (vif.master_cb.rlast) begin
                        active_rd.delete(k);
                        rd_slots.put(1);
                        completed_cnt++;
                    end
                end
            end
            vif.master_cb.rready <= 1'b1;        // always ready
        end
    endtask
```

In `get_and_dispatch()`, index the queues with the same key:

```systemverilog
// OLD
wr_rsp_q[item.id].push_back(item);
rd_rsp_q[item.id].push_back(item);
// NEW
wr_rsp_q[key_of(item.id)].push_back(item);
rd_rsp_q[key_of(item.id)].push_back(item);
```

### 6d. 🔴 AW, W, AR

Apply the same fixes as in 5b and 5c (there is no WID in AXI4). In `wait_handshake`, keep only the AW, W and AR cases, checking the ready signal.

---

## 7. `axi4lite_slave_driver.sv` 🔴

Apply the section 3 rule at **5 places**: remove the `@(vif.slave_cb);` that sits in front of each of these lines:

```systemverilog
vif.slave_cb.awready <= 0;
vif.slave_cb.wready  <= 0;
vif.slave_cb.bvalid  <= 0;
vif.slave_cb.arready <= 0;
vif.slave_cb.rvalid  <= 0;
```

Also change the wait loops:

```systemverilog
// OLD
do @(vif.slave_cb); while (!vif.slave_cb.awvalid || !vif.aresetn);
// NEW
do @(vif.slave_cb); while (vif.slave_cb.awvalid !== 1'b1);
```

Finally, restart the handlers on reset:

```systemverilog
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
        end
    endtask
```

## 8. `axi3_slave_driver.sv`

### 8a. 🟡 Compile error in `handle_reads`

The `case` line is missing:

```systemverilog
                // Advance address
                case (ar_burst)                     // <-- ADD THIS LINE
                    2'b00: beat_addr  = ar_addr;
```

### 8b. 🔴 Remove the 1000-cycle read stall

Delete the whole `begin : wait_mem ... end` block. It stalls every read of an unwritten address for 1000 cycles, which is as long as the Lite master's read timeout.

### 8c. 🔴 Handshakes (AW, each W beat, B, AR, each R beat)

Apply the section 3 rule. For the beat loops, use this pattern:

```systemverilog
            for (int beat = 0; beat <= aw_len; beat++) begin
                if (w_ready_delay > 0) begin
                    vif.slave_cb.wready <= 1'b0;
                    repeat (w_ready_delay) @(vif.slave_cb);
                end
                vif.slave_cb.wready <= 1'b1;
                do @(vif.slave_cb); while (vif.slave_cb.wvalid !== 1'b1);
                ... capture + checks + memory write ...
            end
            vif.slave_cb.wready <= 1'b0;
```

The R loop works the same way: drive `rid`, `rdata`, `rresp`, `rlast` and `rvalid <= 1`, then `do @(cb) while (rready !== 1)`. After the loop, set `rvalid <= 0` and `rlast <= 0`.

### 8d. 🟠 Byte lanes for narrow transfers (writes and reads)

```systemverilog
// OLD
for (int b = 0; b < (1 << aw_size); b++)
    if (wr_strb[b]) mem[beat_addr + b] = wr_data[b*8+:8];
// NEW
for (int b = 0; b < 4; b++)
    if (wr_strb[b]) mem[{beat_addr[31:2], 2'b00} + b] = wr_data[b*8+:8];
```

For reads, drive `rdata <= read_mem(beat_addr)`. `read_mem` already returns the full 32-bit word.

## 9. `axi4_slave_driver.sv` 🔴

Make the same changes as 8c and 8d. Also restart the handlers on reset, as in section 7.

---

## 10. `axi4lite_master_monitor.sv` 🟠

This file has no read-data bug. The rewrite samples all channels in one loop, in a fixed order, so the channel threads can't race each other on the same clock edge:

```systemverilog
    task run_phase(uvm_phase phase);
        forever begin
            @(vif.monitor_cb);
            if (vif.aresetn !== 1'b1) begin reset_state(); continue; end
            sample_aw(); sample_w(); sample_b(); sample_ar(); sample_r();
        end
    endtask
```

Each old `monitor_xx()` task becomes a `function void sample_xx()`. The body is the same, with the `forever` and `@` removed.

## 11. `axi3_master_monitor.sv` 🔴

`ar_item.rdata[beat_idx] = ...` writes into an empty queue, so nothing is stored. Replace it with:

```systemverilog
ar_item.rdata.push_back(vif.monitor_cb.rdata);
ar_item.rresp.push_back(vif.monitor_cb.rresp);
```

Also apply the single-loop structure from section 10.

## 12. `axi4_master_monitor.sv` 🔴 (no S02 read ever reached the scoreboard)

```systemverilog
// OLD
rid_int = int'(vif.monitor_cb.rid) & 4'hF;
...
if (ar_pending_q[i].id == rid_int)         // 2 != 0xA -> never matches

// NEW
rid_int = int'(vif.monitor_cb.rid) & 'h3;  // id_mask
...
if ((int'(ar_pending_q[i].id) & 'h3) == rid_int)
```

Change the `"No AR matching RID"` message from `uvm_info` to `uvm_error`.

## 13. `axi3_slave_monitor.sv` 🔴

Change `ar_it.rdata[beat_idx] = ...` to `push_back` (same as section 11). BID, RID and WID are now compared on the full 4 bits.

## 14. `axi4_slave_monitor.sv` and `axi4lite_slave_monitor.sv` 🟠

* Every `uvm_info(..., UVM_MEDIUM)` that reports a **check** goes back to `uvm_error`: ROUTING FAIL, BID/RID mismatch, EXOKAY, X on data, INCOMPAT, "no matching AR/AW".
* In the Lite slave monitor, change `uvm_warning` to `uvm_error`.
* In the Lite slave monitor, delete the duplicated `complete.strb,` argument (compile error).

---

## 15. `scoreboard/axi_scoreboard.sv` 🟠: **replace the whole file**

It changed too much for a snippet. What changed:

* 🟡 Removed the duplicate `imp_s01` line (compile error).
* `compare_beat` mismatch is now reported with `uvm_error`, showing expected vs actual.
* **New end-to-end check:** the S-side read data (what your master really got) is compared with `ref_mem`. This also covers BRAM.
* BRESP/RRESP are checked: DECERR is expected for unmapped addresses, OKAY for mapped ones.
* Beats that never arrived, and unexpected M-side beats, are `uvm_error`.
* The test fails if nothing was compared.
* PASS/FAIL uses the total UVM_ERROR count.

`sb_beat.sv`: delete the unused `_m04_axi4` imp declaration. It is harmless, but misleading.

## 16. `top/tb_top.sv` 🔴

Add the S01 ID adapter after the interfaces:

```systemverilog
    localparam int S01_ID_W = 2;   // width of S01_AXI_0_*id on the DUT
    wire [S01_ID_W-1:0] s01_bid, s01_rid;
    assign axi3_s01_if.bid = 4'(s01_bid);
    assign axi3_s01_if.rid = 4'(s01_rid);
```

Change the 5 S01 ID connections:

```systemverilog
        .S01_AXI_0_awid (axi3_s01_if.awid[S01_ID_W-1:0]),
        .S01_AXI_0_wid  (axi3_s01_if.wid[S01_ID_W-1:0]),
        .S01_AXI_0_bid  (s01_bid),
        .S01_AXI_0_arid (axi3_s01_if.arid[S01_ID_W-1:0]),
        .S01_AXI_0_rid  (s01_rid),
```

Waveforms:

```systemverilog
// OLD
$fsdbDumpvars(0, tb_top);
// NEW
$fsdbDumpvars(0, tb_top, "+all");
```

Release reset on the falling clock edge:

```systemverilog
        repeat (20) @(posedge clk_100MHz);
        @(negedge clk_100MHz);
        reset_rtl_0 = 1'b1;
```

Delete the duplicated `uvm_config_db::set` calls. Each one appears twice.

## 17. Compile command 🔴 (no values in Verdi)

```
vcs -full64 -sverilog -ntb_opts uvm-1.1 -timescale=1ns/1ps \
    -debug_access+all -kdb -lca +lint=PCWM \
    -top tb_top -top glbl \
    -f <vivado export_simulation .f> $XILINX_VIVADO/data/verilog/src/glbl.v \
    -f axi_filelist.f
```

**After compiling, run `grep PCWM compile.log`.** Every port-width mismatch it lists is a real bug.

## 18. Small items 🟡

| File | Change |
|------|--------|
| `axi3_seq_item.sv`, `axi4_seq_item.sv`, `axi4lite_seq_item.sv` | Delete `import axi_seq_item_pkg::*;` at the top. These files are included **inside** that package, so it imports itself. |
| `axi4_seq_item.sv` | Add `constraint c_id { soft id inside {[0:3]}; }`, because S02 has 2 thread-ID bits. |
| `axi3_seq_item.sv` / `axi4_seq_item.sv` | Replace `c_strb` with strobes computed in `post_randomize()` from each beat address. The old constraint gave wrong lanes for FIXED and WRAP bursts. |
| `seq_lib/axi_sanity_vseq.sv` | Delete it. It duplicates `seq_lib/axi_cross_protocol_seqs/axi_sanity_vseq.sv`. |
| `coverage/axi_coverage.sv` | Rename `bins edge` to `bins at_edge` (`edge` is a keyword), then uncomment the file and enable it in the env. |
| `axi4lite_wr_rd_seq.sv` | Delete `#100;`. It isn't needed once `item_done()` waits for the response. |
| All `config_db::get` of timeouts and delays | Use `#(int unsigned)`, matching the field types. |

---

## After applying: what you should see

Run `axi_sanity_test` with `+UVM_VERBOSITY=UVM_MEDIUM`:

```
[M00] WR addr=0x44a00100 data=0xdeadbeef strb=0xf
[M00] RD addr=0x44a00100 rdata=0xdeadbeef
SANITY_VSEQ  Lite RD done rdata=0xdeadbeef (expect 0xdeadbeef)
... SCOREBOARD SUMMARY: matched > 0, end-to-end read-data checks > 0
*** TEST PASSED ***
```
