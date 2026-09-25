`include "uvm_macros.svh"
import uvm_pkg::*;
import axi_seq_item_pkg::*;

// ============================================================
// axi_scoreboard.sv
// AXI Mixed-Protocol Interconnect Scoreboard
//
// Strategy:
//   1. S-side master monitors publish completed transactions
//      -> split into beats (sb_beat)
//      -> writes update ref_mem (golden memory)
//      -> reads are checked END-TO-END: S-side RDATA vs ref_mem
//      -> an expected beat is queued for the destination M-port
//
//   2. M-side slave monitors publish completed transactions
//      -> split into beats, matched (addr + direction) against the
//         expected queue of THAT port, data/strobe compared.
//      M-side completes BEFORE S-side (the response travels back
//      through the DUT), so early M-side beats are parked in
//      unmatched_actual_q and matched when the expectation arrives.
//
//   3. Responses:
//      - unmapped address       -> DECERR expected
//      - mapped address         -> OKAY expected (EXOKAY ok on
//                                  exclusive), unless the test sets
//                                  "expect_err_resp" (error injection)
//
//   4. End of test (check_phase), all UVM_ERROR:
//      - expected beats that never reached their M-port (dropped
//        or misrouted by the DUT)
//      - M-side beats nobody expected (DUT invented / misrouted)
//      - zero comparisons (a test that checked nothing FAILS)
//
// FIXES vs previous version:
//   - duplicate imp_s01 declaration (compile error)
//   - mismatches were only counted, never reported -> now uvm_error
//     with expected/actual values
//   - check_pending was a uvm_warning -> "never arrived" could not
//     fail a test; leftovers in unmatched_actual_q were ignored
//   - "TEST PASSED" was printed when nothing was compared at all
//     and ignored UVM_ERRORs from drivers/monitors
//   - S-side read data was never compared (the actual end-to-end
//     check); BRAM (M04) reads were therefore unchecked too
//   - ref_mem wrote 0 into non-strobed bytes; narrow transfers used
//     wrong byte lanes
//   - matching no longer requires equal beat_num, so bursts split
//     by the interconnect (e.g. AXI4 32-beat -> 2x16 on AXI3 M01)
//     still match
// ============================================================
class axi_scoreboard extends uvm_scoreboard;

    `uvm_component_utils(axi_scoreboard)

    // ========================================================
    // ANALYSIS IMPLEMENTATION PORTS
    // ========================================================
    uvm_analysis_imp_s00_lite #(axi4lite_seq_item, axi_scoreboard) imp_s00;
    uvm_analysis_imp_s01_axi3 #(axi3_seq_item,     axi_scoreboard) imp_s01;
    uvm_analysis_imp_s02_axi4 #(axi4_seq_item,     axi_scoreboard) imp_s02;

    uvm_analysis_imp_m00_lite #(axi4lite_seq_item, axi_scoreboard) imp_m00;
    uvm_analysis_imp_m01_axi3 #(axi3_seq_item,     axi_scoreboard) imp_m01;
    uvm_analysis_imp_m02_axi4 #(axi4_seq_item,     axi_scoreboard) imp_m02;
    uvm_analysis_imp_m03_axi4 #(axi4_seq_item,     axi_scoreboard) imp_m03;

    // ========================================================
    // EXPECTED QUEUES (M00..M03) + early M-side beats
    // ========================================================
    sb_beat expected_m00_q[$];
    sb_beat expected_m01_q[$];
    sb_beat expected_m02_q[$];
    sb_beat expected_m03_q[$];
    sb_beat unmatched_actual_q[$];

    // ========================================================
    // REFERENCE MEMORY MODEL
    // ========================================================
    logic [7:0] ref_mem [logic [31:0]];

    // ========================================================
    // ADDRESS MAP
    // ========================================================
    localparam logic [31:0] M00_BASE = 32'h44A0_0000;
    localparam logic [31:0] M00_HIGH = 32'h44A0_FFFF;
    localparam logic [31:0] M01_BASE = 32'h44A1_0000;
    localparam logic [31:0] M01_HIGH = 32'h44A1_FFFF;
    localparam logic [31:0] M02_BASE = 32'h44A2_0000;
    localparam logic [31:0] M02_HIGH = 32'h44A2_FFFF;
    localparam logic [31:0] M03_BASE = 32'h44A3_0000;
    localparam logic [31:0] M03_HIGH = 32'h44A3_FFFF;
    localparam logic [31:0] M04_BASE = 32'hC000_0000;  // BRAM (internal)
    localparam logic [31:0] M04_HIGH = 32'hC000_1FFF;

    localparam int DEST_UNMAPPED = -1;
    localparam int DEST_BRAM     = 4;

    // -- Knobs ---------------------------------------------
    // Error-injection tests: SLVERR/DECERR on mapped addresses
    // is expected, not an error
    bit expect_err_resp = 0;

    // ========================================================
    // COUNTERS
    // ========================================================
    int unsigned total_expected;
    int unsigned total_actual;
    int unsigned total_matches;
    int unsigned total_errors;
    int unsigned total_writes;
    int unsigned total_reads;
    int unsigned total_e2e_checks;
    int unsigned total_neg;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        imp_s00 = new("imp_s00", this);
        imp_s01 = new("imp_s01", this);
        imp_s02 = new("imp_s02", this);
        imp_m00 = new("imp_m00", this);
        imp_m01 = new("imp_m01", this);
        imp_m02 = new("imp_m02", this);
        imp_m03 = new("imp_m03", this);
        void'(uvm_config_db #(bit)::get(this, "", "expect_err_resp", expect_err_resp));
    endfunction

    // ========================================================
    // HELPERS
    // ========================================================
    function int decode_dest(logic [31:0] addr);
        if (addr inside {[M00_BASE:M00_HIGH]}) return 0;
        if (addr inside {[M01_BASE:M01_HIGH]}) return 1;
        if (addr inside {[M02_BASE:M02_HIGH]}) return 2;
        if (addr inside {[M03_BASE:M03_HIGH]}) return 3;
        if (addr inside {[M04_BASE:M04_HIGH]}) return DEST_BRAM;
        return DEST_UNMAPPED;
    endfunction

    function sb_proto_e dest_proto_of(int dst);
        case (dst)
            0:       return SB_LITE;
            1:       return SB_AXI3;
            default: return SB_AXI4;
        endcase
    endfunction

    function string port_name(int dst);
        case (dst)
            0: return "M00_LITE";
            1: return "M01_AXI3";
            2: return "M02_AXI4";
            3: return "M03_AXI4";
            4: return "M04_BRAM";
            default: return "UNMAPPED";
        endcase
    endfunction

    function logic [31:0] word_addr(logic [31:0] addr);
        return {addr[31:2], 2'b00};
    endfunction

    // Write only the strobed byte lanes
    function void ref_mem_write(logic [31:0] addr, logic [31:0] data, logic [3:0] strb);
        for (int i = 0; i < 4; i++)
            if (strb[i]) ref_mem[word_addr(addr) + i] = data[i*8+:8];
    endfunction

    function logic [31:0] ref_mem_read(logic [31:0] addr);
        logic [31:0] data = '0;
        for (int i = 0; i < 4; i++)
            if (ref_mem.exists(word_addr(addr) + i))
                data[i*8+:8] = ref_mem[word_addr(addr) + i];
        return data;
    endfunction

    // Lanes for which the reference model actually knows a value
    function logic [3:0] ref_mem_known(logic [31:0] addr);
        logic [3:0] m = '0;
        for (int i = 0; i < 4; i++)
            m[i] = ref_mem.exists(word_addr(addr) + i);
        return m;
    endfunction

    function logic [31:0] lane_bits(logic [3:0] lanes);
        logic [31:0] m = '0;
        for (int i = 0; i < 4; i++)
            if (lanes[i]) m[i*8+:8] = 8'hFF;
        return m;
    endfunction

    function void sb_error(string id, string msg);
        total_errors++;
        `uvm_error(id, msg)
    endfunction

    // Response check for one S-side beat. Returns 1 if the data
    // phase is meaningful (OKAY/EXOKAY on a mapped address).
    function bit check_resp(string src, bit is_write, logic [31:0] addr,
                            int dst, logic [1:0] resp, bit exclusive);
        string dir = is_write ? "WR" : "RD";
        if (dst == DEST_UNMAPPED) begin
            total_neg++;
            if (resp !== AXI_DECERR)
                sb_error("SB_ROUTE",
                    $sformatf("[%s] %s to UNMAPPED addr=0x%08h returned resp=%02b, DECERR expected",
                        src, dir, addr, resp));
            return 0;
        end
        if (resp === AXI_OKAY) return 1;
        if (resp === AXI_EXOKAY && exclusive) return 1;
        if (!expect_err_resp)
            sb_error("SB_RESP",
                $sformatf("[%s] %s addr=0x%08h (%s) returned resp=%02b, OKAY expected",
                    src, dir, addr, port_name(dst), resp));
        return 0;
    endfunction

    // ========================================================
    // EXPECTED / ACTUAL MATCHING
    // ========================================================
    function bit same_key(sb_beat a, sb_beat b);
        return a.dest_port == b.dest_port &&
               a.addr      == b.addr      &&
               a.is_write  == b.is_write;
    endfunction

    function void push_exp(sb_beat exp);
        total_expected++;
        // The M-side beat may already have arrived
        foreach (unmatched_actual_q[i]) begin
            if (same_key(unmatched_actual_q[i], exp)) begin
                compare_beat(exp, unmatched_actual_q[i]);
                unmatched_actual_q.delete(i);
                return;
            end
        end
        case (exp.dest_port)
            0: expected_m00_q.push_back(exp);
            1: expected_m01_q.push_back(exp);
            2: expected_m02_q.push_back(exp);
            3: expected_m03_q.push_back(exp);
            default: sb_error("SB_PUSH", $sformatf("Invalid dest=%0d", exp.dest_port));
        endcase
    endfunction

    function void compare_beat(sb_beat exp, sb_beat actual);
        logic [31:0] mask = lane_bits(exp.strb);
        bit ok = 1;
        if (exp.is_write && exp.strb !== actual.strb) ok = 0;
        if ((exp.data & mask) !== (actual.data & mask)) ok = 0;
        if (ok) begin
            total_matches++;
            `uvm_info("SB_MATCH",
                $sformatf("[%s] %s addr=0x%08h data=0x%08h strb=0x%h OK (from S%0d)",
                    port_name(exp.dest_port), exp.is_write ? "WR" : "RD",
                    exp.addr, actual.data, exp.strb, exp.source_port), UVM_HIGH)
        end else begin
            sb_error("SB_MISMATCH",
                $sformatf("[%s] %s addr=0x%08h (from S%0d beat %0d/%0d)\n  expected data=0x%08h strb=0x%h\n  actual   data=0x%08h strb=0x%h",
                    port_name(exp.dest_port), exp.is_write ? "WR" : "RD",
                    exp.addr, exp.source_port, exp.beat_num, exp.total_beats,
                    exp.data & mask, exp.strb, actual.data & mask, actual.strb));
        end
    endfunction

    function void compare_from_queue(ref sb_beat q[$], input sb_beat actual);
        total_actual++;
        foreach (q[i]) begin
            if (same_key(q[i], actual)) begin
                compare_beat(q[i], actual);
                q.delete(i);
                return;
            end
        end
        // Not expected yet -- S-side has not completed. Park it.
        unmatched_actual_q.push_back(actual);
    endfunction

    // ========================================================
    // S-SIDE (expected) -- one generic beat handler
    // ========================================================
    function void process_s_beat(
        int          src,
        string       src_name,
        bit          is_write,
        logic [31:0] beat_addr,
        logic [31:0] data,        // wdata (write) / S-side rdata (read)
        logic [3:0]  lanes,       // wstrb (write) / active lanes (read)
        logic [1:0]  resp,
        bit          exclusive,
        int unsigned beat_num,
        int unsigned total_beats
    );
        int          dst = decode_dest(beat_addr);
        bit          data_ok;
        sb_beat      exp;
        logic [31:0] ref_data;
        logic [3:0]  cmp_lanes;

        data_ok = check_resp(src_name, is_write, beat_addr, dst, resp, exclusive);

        exp = sb_beat::type_id::create($sformatf("exp_s%0d", src));
        exp.source_port = src;
        exp.is_write    = is_write;
        exp.addr        = beat_addr;
        exp.beat_num    = beat_num;
        exp.total_beats = total_beats;
        exp.resp        = resp;
        exp.dest_port   = dst;
        exp.dest_proto  = dest_proto_of(dst);

        if (is_write) begin
            exp.data = data;
            exp.strb = lanes;
            if (data_ok) ref_mem_write(beat_addr, data, lanes);
        end else begin
            ref_data  = ref_mem_read(beat_addr);
            cmp_lanes = lanes & ref_mem_known(beat_addr);
            exp.data  = ref_data;
            exp.strb  = cmp_lanes;
            // END-TO-END CHECK: what the master really received
            if (data_ok && cmp_lanes != 0) begin
                total_e2e_checks++;
                if ((data & lane_bits(cmp_lanes)) !== (ref_data & lane_bits(cmp_lanes)))
                    sb_error("SB_RDATA",
                        $sformatf("[%s -> %s] RD addr=0x%08h beat %0d/%0d\n  expected rdata=0x%08h (lanes 0x%h)\n  actual   rdata=0x%08h",
                            src_name, port_name(dst), beat_addr, beat_num, total_beats,
                            ref_data & lane_bits(cmp_lanes), cmp_lanes,
                            data & lane_bits(cmp_lanes)));
                else
                    `uvm_info("SB_RDATA",
                        $sformatf("[%s -> %s] RD addr=0x%08h rdata=0x%08h OK",
                            src_name, port_name(dst), beat_addr, data), UVM_HIGH)
            end
        end

        // M00..M03 have a TB slave -> expect the beat there
        if (dst inside {[0:3]}) push_exp(exp);
    endfunction

    function void write_s00_lite(axi4lite_seq_item item);
        bit is_wr = (item.direction == AXI_WRITE);
        if (is_wr) total_writes++; else total_reads++;
        process_s_beat(0, "S00_LITE", is_wr, item.addr,
                       is_wr ? item.data : item.rdata,
                       is_wr ? item.strb : 4'hF,
                       item.resp, 1'b0, 0, 1);
    endfunction

    function void write_s01_axi3(axi3_seq_item item);
        bit          is_wr = (item.direction == AXI_WRITE);
        logic [31:0] beat_addr = item.addr;
        if (is_wr) total_writes++; else total_reads++;
        if (!is_wr && item.rdata.size() != item.len + 1) begin
            sb_error("SB_BEATS",
                $sformatf("[S01_AXI3] RD addr=0x%08h got %0d beats, expected %0d",
                    item.addr, item.rdata.size(), item.len + 1));
            return;
        end
        for (int b = 0; b <= item.len; b++) begin
            process_s_beat(1, "S01_AXI3", is_wr, beat_addr,
                           is_wr ? item.wdata[b] : item.rdata[b],
                           is_wr ? item.wstrb[b] : axi_lane_mask(beat_addr, item.size),
                           is_wr ? item.bresp : item.rresp[b],
                           item.lock == 2'b01, b, item.len + 1);
            beat_addr = axi_next_addr(item.addr, beat_addr, item.size,
                                      item.burst, 8'(item.len));
        end
    endfunction

    function void write_s02_axi4(axi4_seq_item item);
        bit          is_wr = (item.direction == AXI_WRITE);
        logic [31:0] beat_addr = item.addr;
        if (is_wr) total_writes++; else total_reads++;
        if (!is_wr && item.rdata.size() != item.len + 1) begin
            sb_error("SB_BEATS",
                $sformatf("[S02_AXI4] RD addr=0x%08h got %0d beats, expected %0d",
                    item.addr, item.rdata.size(), item.len + 1));
            return;
        end
        for (int b = 0; b <= item.len; b++) begin
            process_s_beat(2, "S02_AXI4", is_wr, beat_addr,
                           is_wr ? item.wdata[b] : item.rdata[b],
                           is_wr ? item.wstrb[b] : axi_lane_mask(beat_addr, item.size),
                           is_wr ? item.bresp : item.rresp[b],
                           item.lock, b, item.len + 1);
            beat_addr = axi_next_addr(item.addr, beat_addr, item.size,
                                      item.burst, item.len);
        end
    endfunction

    // ========================================================
    // M-SIDE (actual)
    // ========================================================
    function sb_beat make_actual(int dst, bit is_write, logic [31:0] addr,
                                 logic [31:0] data, logic [3:0] strb);
        sb_beat actual = sb_beat::type_id::create($sformatf("act_m%0d", dst));
        actual.dest_port = dst;
        actual.is_write  = is_write;
        actual.addr      = addr;
        actual.data      = data;
        actual.strb      = strb;
        return actual;
    endfunction

    function void write_m00_lite(axi4lite_seq_item item);
        bit is_wr = (item.direction == AXI_WRITE);
        compare_from_queue(expected_m00_q,
            make_actual(0, is_wr, item.addr,
                        is_wr ? item.data : item.rdata,
                        is_wr ? item.strb : 4'hF));
    endfunction

    function void write_m01_axi3(axi3_seq_item item);
        bit          is_wr = (item.direction == AXI_WRITE);
        logic [31:0] beat_addr = item.addr;
        int unsigned n_beats = is_wr ? item.wdata.size() : item.rdata.size();
        for (int b = 0; b < n_beats; b++) begin
            compare_from_queue(expected_m01_q,
                make_actual(1, is_wr, beat_addr,
                            is_wr ? item.wdata[b] : item.rdata[b],
                            is_wr ? item.wstrb[b] : axi_lane_mask(beat_addr, item.size)));
            beat_addr = axi_next_addr(item.addr, beat_addr, item.size,
                                      item.burst, 8'(item.len));
        end
    endfunction

    function void write_m02_axi4(axi4_seq_item item);
        process_m_axi4(item, 2, expected_m02_q);
    endfunction

    function void write_m03_axi4(axi4_seq_item item);
        process_m_axi4(item, 3, expected_m03_q);
    endfunction

    function void process_m_axi4(axi4_seq_item item, int dst, ref sb_beat q[$]);
        bit          is_wr = (item.direction == AXI_WRITE);
        logic [31:0] beat_addr = item.addr;
        int unsigned n_beats = is_wr ? item.wdata.size() : item.rdata.size();
        for (int b = 0; b < n_beats; b++) begin
            compare_from_queue(q,
                make_actual(dst, is_wr, beat_addr,
                            is_wr ? item.wdata[b] : item.rdata[b],
                            is_wr ? item.wstrb[b] : axi_lane_mask(beat_addr, item.size)));
            beat_addr = axi_next_addr(item.addr, beat_addr, item.size,
                                      item.burst, item.len);
        end
    endfunction

    // ========================================================
    // END OF TEST
    // ========================================================
    function void check_pending(ref sb_beat q[$], input string pname);
        if (q.size() == 0) return;
        sb_error("SB_PENDING",
            $sformatf("[%s] %0d EXPECTED BEAT(S) NEVER ARRIVED (dropped or misrouted by DUT). First: %s",
                pname, q.size(), q[0].convert2string()));
    endfunction

    function void check_phase(uvm_phase phase);
        super.check_phase(phase);
        check_pending(expected_m00_q, "M00_LITE");
        check_pending(expected_m01_q, "M01_AXI3");
        check_pending(expected_m02_q, "M02_AXI4");
        check_pending(expected_m03_q, "M03_AXI4");

        if (unmatched_actual_q.size() > 0)
            sb_error("SB_UNEXPECTED",
                $sformatf("%0d M-side beat(s) seen that no S-side transaction explains. First: DST=%s DIR=%s ADDR=0x%08h DATA=0x%08h",
                    unmatched_actual_q.size(),
                    port_name(unmatched_actual_q[0].dest_port),
                    unmatched_actual_q[0].is_write ? "WR" : "RD",
                    unmatched_actual_q[0].addr, unmatched_actual_q[0].data));

        if (total_writes + total_reads == 0)
            sb_error("SB_EMPTY",
                "Scoreboard saw NO S-side transactions -- the test verified nothing");
        else if (total_matches + total_e2e_checks == 0)
            sb_error("SB_EMPTY",
                "Scoreboard made ZERO data comparisons -- the test verified nothing");
    endfunction

    function void report_phase(uvm_phase phase);
        uvm_report_server rs = uvm_report_server::get_server();
        int unsigned n_err = rs.get_severity_count(UVM_ERROR) +
                             rs.get_severity_count(UVM_FATAL);
        super.report_phase(phase);

        `uvm_info("AXI_SB", $sformatf({"\n",
            "==================== SCOREBOARD SUMMARY ====================\n",
            "  S-side writes / reads      : %0d / %0d\n",
            "  M-side beats expected      : %0d\n",
            "  M-side beats observed      : %0d\n",
            "  M-side beats matched       : %0d\n",
            "  End-to-end read-data checks: %0d\n",
            "  Unmapped (DECERR) accesses : %0d\n",
            "  Scoreboard errors          : %0d\n",
            "  UVM_ERROR+UVM_FATAL (all)  : %0d\n",
            "============================================================"},
            total_writes, total_reads, total_expected, total_actual,
            total_matches, total_e2e_checks, total_neg, total_errors, n_err),
            UVM_NONE)

        if (n_err == 0)
            `uvm_info("AXI_SB", "*** TEST PASSED ***", UVM_NONE)
        else
            `uvm_info("AXI_SB",
                $sformatf("*** TEST FAILED -- %0d UVM_ERROR/UVM_FATAL ***", n_err),
                UVM_NONE)
    endfunction

endclass : axi_scoreboard
