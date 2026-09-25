// ============================================================
// axi4lite_if.sv
// AXI4-Lite Interface
// Data width  : 32-bit
// Addr width  : 32-bit
// Used on     : S00_AXI (slave port) and M00_AXI (master port)
//
// AXI4-Lite has NO:
//   - AxID, AxLEN, AxBURST, AxSIZE, AxLOCK
//   - WLAST, RLAST
//   - Exclusive access
// ============================================================

interface axi4lite_if (
    input logic aclk,
    input logic aresetn    // active-low reset
);

    // ========================================================
    // WRITE ADDRESS CHANNEL (AW)
    // ========================================================
    logic [31:0] awaddr;
    logic [2:0]  awprot;
    logic        awvalid;
    logic        awready;

    // ========================================================
    // WRITE DATA CHANNEL (W)
    // ========================================================
    logic [31:0] wdata;
    logic [3:0]  wstrb;
    logic        wvalid;
    logic        wready;

    // ========================================================
    // WRITE RESPONSE CHANNEL (B)
    // ========================================================
    logic [1:0]  bresp;
    logic        bvalid;
    logic        bready;

    // ========================================================
    // READ ADDRESS CHANNEL (AR)
    // ========================================================
    logic [31:0] araddr;
    logic [2:0]  arprot;
    logic        arvalid;
    logic        arready;

    // ========================================================
    // READ DATA CHANNEL (R)
    // ========================================================
    logic [31:0] rdata;
    logic [1:0]  rresp;
    logic        rvalid;
    logic        rready;

    // ========================================================
    // MASTER CLOCKING BLOCK
    // Used by: axi4lite_master_driver
    // Master drives: AW, W, AR channels
    // Master samples: B, R channels
    // ========================================================
    clocking master_cb @(posedge aclk);
        default input  #1ns
                output #1ns;

        // AW -- master drives
        output awaddr;
        output awprot;
        output awvalid;
        input  awready;

        // W -- master drives
        output wdata;
        output wstrb;
        output wvalid;
        input  wready;

        // B -- master samples
        input  bresp;
        input  bvalid;
        output bready;

        // AR -- master drives
        output araddr;
        output arprot;
        output arvalid;
        input  arready;

        // R -- master samples
        input  rdata;
        input  rresp;
        input  rvalid;
        output rready;
    endclocking

    // ========================================================
    // SLAVE CLOCKING BLOCK
    // Used by: axi4lite_slave_driver
    // Slave samples: AW, W, AR channels
    // Slave drives:  B, R channels
    // ========================================================
    clocking slave_cb @(posedge aclk);
        default input  #1ns
                output #1ns;

        // AW -- slave samples
        input  awaddr;
        input  awprot;
        input  awvalid;
        output awready;

        // W -- slave samples
        input  wdata;
        input  wstrb;
        input  wvalid;
        output wready;

        // B -- slave drives
        output bresp;
        output bvalid;
        input  bready;

        // AR -- slave samples
        input  araddr;
        input  arprot;
        input  arvalid;
        output arready;

        // R -- slave drives
        output rdata;
        output rresp;
        output rvalid;
        input  rready;
    endclocking

    // ========================================================
    // MONITOR CLOCKING BLOCK
    // Used by: axi4lite_master_monitor, axi4lite_slave_monitor
    // Passive -- only samples, never drives
    // ========================================================
    clocking monitor_cb @(posedge aclk);
        default input #1ns;

        input awaddr;
        input awprot;
        input awvalid;
        input awready;

        input wdata;
        input wstrb;
        input wvalid;
        input wready;

        input bresp;
        input bvalid;
        input bready;

        input araddr;
        input arprot;
        input arvalid;
        input arready;

        input rdata;
        input rresp;
        input rvalid;
        input rready;
    endclocking

    // ========================================================
    // MODPORTS
    // ========================================================
    modport master_mp (clocking master_cb,  input aclk, aresetn);
    modport slave_mp  (clocking slave_cb,   input aclk, aresetn);
    modport monitor_mp(clocking monitor_cb, input aclk, aresetn);

endinterface : axi4lite_if
