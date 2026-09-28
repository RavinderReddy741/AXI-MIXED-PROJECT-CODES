// ============================================================
// axi4_if.sv
// AXI4 Full Interface
// Data width  : 32-bit
// Addr width  : 32-bit
// ID width    : 4-bit
// Used on     : S02_AXI, M02_AXI, M03_AXI
//
// AXI4 vs AXI3 differences:
//   ADDED   : awqos, awregion (4-bit each)
//   ADDED   : awlock is 1-bit (was 2-bit in AXI3)
//   ADDED   : awlen is 8-bit (was 4-bit in AXI3)
//   REMOVED : wid (no write data interleaving in AXI4)
//   REMOVED : locked transactions (awlock=2'b10 illegal)
//
// FIX: the AW channel signals were declared twice (compile error).
// ============================================================

interface axi4_if (
    input logic aclk,
    input logic aresetn
);

    // ========================================================
    // WRITE ADDRESS CHANNEL (AW)
    // ========================================================
    logic [3:0]  awid;
    logic [31:0] awaddr;
    logic [7:0]  awlen;      // AXI4: 8-bit, max 255 (INCR)
    logic [2:0]  awsize;
    logic [1:0]  awburst;
    logic        awlock;     // AXI4: 1-bit only
    logic [3:0]  awcache;
    logic [2:0]  awprot;
    logic [3:0]  awqos;      // AXI4 addition
    logic [3:0]  awregion;   // AXI4 addition
    logic        awvalid;
    logic        awready;

    // ========================================================
    // WRITE DATA CHANNEL (W)
    // NO wid in AXI4 -- write interleaving removed
    // ========================================================
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
    logic [7:0]  arlen;
    logic [2:0]  arsize;
    logic [1:0]  arburst;
    logic        arlock;
    logic [3:0]  arcache;
    logic [2:0]  arprot;
    logic [3:0]  arqos;
    logic [3:0]  arregion;
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
    // Used by: axi4_master_driver
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
        output awqos;
        output awregion;
        output awvalid;
        input  awready;

        // W -- no wid
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
        output arqos;
        output arregion;
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
    // Used by: axi4_slave_driver
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
        input  awqos;
        input  awregion;
        input  awvalid;
        output awready;

        // W
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
        input  arqos;
        input  arregion;
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
    // Used by: axi4_master_monitor, axi4_slave_monitor
    // ========================================================
    clocking monitor_cb @(posedge aclk);
        default input #1ns;

        input awid, awaddr, awlen, awsize, awburst;
        input awlock, awcache, awprot, awqos, awregion;
        input awvalid, awready;

        input wdata, wstrb, wlast, wvalid, wready;

        input bid, bresp, bvalid, bready;

        input arid, araddr, arlen, arsize, arburst;
        input arlock, arcache, arprot, arqos, arregion;
        input arvalid, arready;

        input rid, rdata, rresp, rlast, rvalid, rready;
    endclocking

    // ========================================================
    // MODPORTS
    // ========================================================
    modport master_mp (clocking master_cb,  input aclk, aresetn);
    modport slave_mp  (clocking slave_cb,   input aclk, aresetn);
    modport monitor_mp(clocking monitor_cb, input aclk, aresetn);

endinterface : axi4_if
