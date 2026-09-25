// ============================================================
// axi3_if.sv
// AXI3 Interface
// Data width  : 32-bit
// Addr width  : 32-bit
// ID width    : 4-bit (interface is always sized for the WIDEST
//               port it is used on)
// Used on     : S01_AXI (slave port) and M01_AXI (master port)
//
// ID WIDTH NOTE (FIX):
//   M01 carries the interconnect-extended ID {slot[1:0], id[1:0]}
//   = 4 bits. The same interface type is also used for S01, whose
//   RTL port is only 2 bits. The interface is therefore 4 bits wide
//   and tb_top adapts the S01 connection (see S01_ID_W in tb_top).
//   A 2-bit interface on M01 silently dropped the slot bits, so the
//   slave echoed BID/RID with slot=00 and the DUT routed the
//   response to the wrong S-port.
//
// AXI3 specific signals (NOT in AXI4):
//   - WID      : write data ID per beat
//   - AWLOCK   : 2-bit (00=normal, 01=exclusive, 10=locked)
//   - AWLEN    : 4-bit (max 15, so max 16 beats)
// ============================================================

interface axi3_if (
    input logic aclk,
    input logic aresetn
);

    // ========================================================
    // WRITE ADDRESS CHANNEL (AW)
    // ========================================================
    logic [3:0]  awid;
    logic [31:0] awaddr;
    logic [3:0]  awlen;      // AXI3: 4-bit, max value = 15
    logic [2:0]  awsize;
    logic [1:0]  awburst;
    logic [1:0]  awlock;     // AXI3: 2-bit
    logic [3:0]  awcache;
    logic [2:0]  awprot;
    logic        awvalid;
    logic        awready;

    // ========================================================
    // WRITE DATA CHANNEL (W)
    // ========================================================
    logic [3:0]  wid;        // AXI3 only -- per beat ID
    logic [31:0] wdata;
    logic [3:0]  wstrb;
    logic        wlast;
    logic        wvalid;
    logic        wready;

    // ========================================================
    // WRITE RESPONSE CHANNEL (B)
    // ========================================================
    logic [3:0]  bid;
    logic [1:0]  bresp;
    logic        bvalid;
    logic        bready;

    // ========================================================
    // READ ADDRESS CHANNEL (AR)
    // ========================================================
    logic [3:0]  arid;
    logic [31:0] araddr;
    logic [3:0]  arlen;      // AXI3: 4-bit
    logic [2:0]  arsize;
    logic [1:0]  arburst;
    logic [1:0]  arlock;
    logic [3:0]  arcache;
    logic [2:0]  arprot;
    logic        arvalid;
    logic        arready;

    // ========================================================
    // READ DATA CHANNEL (R)
    // ========================================================
    logic [3:0]  rid;
    logic [31:0] rdata;
    logic [1:0]  rresp;
    logic        rlast;
    logic        rvalid;
    logic        rready;

    // ========================================================
    // MASTER CLOCKING BLOCK
    // Used by: axi3_master_driver
    // ========================================================
    clocking master_cb @(posedge aclk);
        default input  #1ns
                output #1ns;

        // AW
        output awid;
        output awaddr;
        output awlen;
        output awsize;
        output awburst;
        output awlock;
        output awcache;
        output awprot;
        output awvalid;
        input  awready;

        // W
        output wid;
        output wdata;
        output wstrb;
        output wlast;
        output wvalid;
        input  wready;

        // B
        input  bid;
        input  bresp;
        input  bvalid;
        output bready;

        // AR
        output arid;
        output araddr;
        output arlen;
        output arsize;
        output arburst;
        output arlock;
        output arcache;
        output arprot;
        output arvalid;
        input  arready;

        // R
        input  rid;
        input  rdata;
        input  rresp;
        input  rlast;
        input  rvalid;
        output rready;
    endclocking

    // ========================================================
    // SLAVE CLOCKING BLOCK
    // Used by: axi3_slave_driver
    // ========================================================
    clocking slave_cb @(posedge aclk);
        default input  #1ns
                output #1ns;

        // AW
        input  awid;
        input  awaddr;
        input  awlen;
        input  awsize;
        input  awburst;
        input  awlock;
        input  awcache;
        input  awprot;
        input  awvalid;
        output awready;

        // W
        input  wid;
        input  wdata;
        input  wstrb;
        input  wlast;
        input  wvalid;
        output wready;

        // B
        output bid;
        output bresp;
        output bvalid;
        input  bready;

        // AR
        input  arid;
        input  araddr;
        input  arlen;
        input  arsize;
        input  arburst;
        input  arlock;
        input  arcache;
        input  arprot;
        input  arvalid;
        output arready;

        // R
        output rid;
        output rdata;
        output rresp;
        output rlast;
        output rvalid;
        input  rready;
    endclocking

    // ========================================================
    // MONITOR CLOCKING BLOCK
    // Used by: axi3_master_monitor, axi3_slave_monitor
    // Passive -- only samples
    // ========================================================
    clocking monitor_cb @(posedge aclk);
        default input #1ns;

        input awid, awaddr, awlen, awsize, awburst;
        input awlock, awcache, awprot, awvalid, awready;

        input wid, wdata, wstrb, wlast, wvalid, wready;

        input bid, bresp, bvalid, bready;

        input arid, araddr, arlen, arsize, arburst;
        input arlock, arcache, arprot, arvalid, arready;

        input rid, rdata, rresp, rlast, rvalid, rready;
    endclocking

    // ========================================================
    // MODPORTS
    // ========================================================
    modport master_mp (clocking master_cb,   input aclk, aresetn);
    modport slave_mp  (clocking slave_cb,    input aclk, aresetn);
    modport monitor_mp(clocking monitor_cb,  input aclk, aresetn);

endinterface : axi3_if
