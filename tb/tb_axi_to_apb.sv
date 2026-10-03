`timescale 1ns / 1ps

module tb_axi_to_apb;

    localparam DATA_WIDTH = 32;
    localparam ADDR_WIDTH = 32;
    localparam CLK_PERIOD = 10; // 100 MHz

    logic                    aclk = 0;
    logic                    aresetn = 0;

    // AXI4-Lite signals
    logic [ADDR_WIDTH-1:0]   s_axi_awaddr = 0;
    logic [2:0]              s_axi_awprot = 0;
    logic                    s_axi_awvalid = 0;
    logic                    s_axi_awready;

    logic [DATA_WIDTH-1:0]   s_axi_wdata = 0;
    logic [(DATA_WIDTH/8)-1:0] s_axi_wstrb = 0;
    logic                    s_axi_wvalid = 0;
    logic                    s_axi_wready;

    logic [1:0]              s_axi_bresp;
    logic                    s_axi_bvalid;
    logic                    s_axi_bready = 0;

    logic [ADDR_WIDTH-1:0]   s_axi_araddr = 0;
    logic [2:0]              s_axi_arprot = 0;
    logic                    s_axi_arvalid = 0;
    logic                    s_axi_arready;

    logic [DATA_WIDTH-1:0]   s_axi_rdata;
    logic [1:0]              s_axi_rresp;
    logic                    s_axi_rvalid;
    logic                    s_axi_rready = 0;

    // APB3 signals
    wire [ADDR_WIDTH-1:0]    m_apb_paddr;
    wire                     m_apb_psel;
    wire                     m_apb_penable;
    wire                     m_apb_pwrite;
    wire [DATA_WIDTH-1:0]    m_apb_pwdata;
    wire [(DATA_WIDTH/8)-1:0] m_apb_pstrb;
    logic [DATA_WIDTH-1:0]   m_apb_prdata = 0;
    logic                    m_apb_pready = 1;
    logic                    m_apb_pslverr = 0;

    // Clock Generation
    always #(CLK_PERIOD/2) aclk = ~aclk;
    // Watchdog
    initial begin
        #100000;
        $display("[TIMEOUT] Simulation hung, DUT never responded");
        $finish;
    end

    // DUT Instantiation
    axi_to_apb_bridge #(
        .DATA_WIDTH(DATA_WIDTH),
        .ADDR_WIDTH(ADDR_WIDTH)
    ) dut (.*);

    // ==========================================
    // APB Responder Model
    // ==========================================
    int wait_cycles = 0;
    int errors = 0;
    bit inject_err  = 0;
    logic [DATA_WIDTH-1:0] mem [bit [ADDR_WIDTH-1:0]];

    int stall_counter = 0;

    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            m_apb_pready  <= 1'b1;
            m_apb_pslverr <= 1'b0;
            m_apb_prdata  <= '0;
            stall_counter <= 0;
        end else begin
            if (m_apb_psel && !m_apb_penable) begin
                // SETUP Phase
                if (wait_cycles == 0) begin
                    m_apb_pready  <= 1'b1;
                    m_apb_pslverr <= inject_err;
                    if (!m_apb_pwrite) begin
                        m_apb_prdata <= mem.exists(m_apb_paddr) ? mem[m_apb_paddr] : 32'hDEADBEEF;
                    end
                end else begin
                    m_apb_pready  <= 1'b0;
                    stall_counter <= wait_cycles;
                end
            end else if (m_apb_psel && m_apb_penable) begin
                // ACCESS Phase
                if (wait_cycles > 0 && !m_apb_pready) begin
                    if (stall_counter > 1) begin
                        stall_counter <= stall_counter - 1;
                        m_apb_pready  <= 1'b0;
                    end else begin
                        m_apb_pready  <= 1'b1;
                        m_apb_pslverr <= inject_err;
                        if (!m_apb_pwrite) begin
                            m_apb_prdata <= mem.exists(m_apb_paddr) ? mem[m_apb_paddr] : 32'hDEADBEEF;
                        end
                    end
                end else if (m_apb_pready) begin
                    // Transfer Completes
                    if (m_apb_pwrite && !m_apb_pslverr) begin
                        mem[m_apb_paddr] = m_apb_pwdata;
                    end
                    // Return ready to 1 if default is zero-wait, else default to idle state
                    m_apb_pready  <= (wait_cycles == 0) ? 1'b1 : 1'b0;
                    m_apb_pslverr <= 1'b0;
                end
            end else begin
                // IDLE Phase
                m_apb_pready  <= (wait_cycles == 0) ? 1'b1 : 1'b0;
                m_apb_pslverr <= 1'b0;
            end
        end
    end

    // ==========================================
    // Protocol Assertions
    // ==========================================
    // Verify APB PENABLE is never asserted without PSEL
        assert_penable_needs_psel: assert property (@(posedge aclk) disable iff (!aresetn)
            m_apb_penable |-> m_apb_psel
        ) else begin
            $error("[PROTOCOL VIOLATION] PENABLE asserted without PSEL!");
        errors++;
        end
    
        assert_penable_hold: assert property (@(posedge aclk) disable iff (!aresetn)
            (m_apb_psel && m_apb_penable && !m_apb_pready) |=> (m_apb_psel && m_apb_penable)
        ) else begin
            $error("[PROTOCOL VIOLATION] PENABLE deasserted before PREADY was 1!");
            errors++;
        end
    // ==========================================
    // Verification Tasks
    // ==========================================
    task automatic axi_write(
        input  logic [ADDR_WIDTH-1:0] addr,
        input  logic [DATA_WIDTH-1:0] data,
        output logic [1:0]            resp
    );
        @(posedge aclk);
        s_axi_awaddr  <= addr;
        s_axi_awvalid <= 1'b1;
        s_axi_wdata   <= data;
        s_axi_wstrb   <= 4'b1111;
        s_axi_wvalid  <= 1'b1;
        s_axi_bready  <= 1'b1;

        fork
            begin
                wait (s_axi_awready);
                @(posedge aclk);
                s_axi_awvalid <= 1'b0;
            end
            begin
                wait (s_axi_wready);
                @(posedge aclk);
                s_axi_wvalid <= 1'b0;
            end
        join

        wait (s_axi_bvalid);
        resp = s_axi_bresp;
        @(posedge aclk);
        s_axi_bready <= 1'b0;
    endtask

    task automatic axi_read(
        input  logic [ADDR_WIDTH-1:0] addr,
        output logic [DATA_WIDTH-1:0] data,
        output logic [1:0]            resp
    );
        @(posedge aclk);
        s_axi_araddr  <= addr;
        s_axi_arvalid <= 1'b1;
        s_axi_rready  <= 1'b1;

        wait (s_axi_arready);
        @(posedge aclk);
        s_axi_arvalid <= 1'b0;

        wait (s_axi_rvalid);
        data = s_axi_rdata;
        resp = s_axi_rresp;
        @(posedge aclk);
        s_axi_rready <= 1'b0;
    endtask

    // ==========================================
    // Test Sequence
    // ==========================================
    logic [DATA_WIDTH-1:0] rd_val;
    logic [1:0] resp_val;

    initial begin
        // Reset sequence
        aresetn = 0;
        repeat (5) @(posedge aclk);
        aresetn = 1;
        repeat (2) @(posedge aclk);

        $display("------------------------------------------------------------");
        $display("[TEST 1] Zero-Wait APB Write & Read (PREADY permanently 1)");
        $display("------------------------------------------------------------");
        wait_cycles = 0;
        inject_err  = 0;

        axi_write(32'h0000_1000, 32'hA5A5_1234, resp_val);
        if (resp_val !== 2'b00 || mem[32'h0000_1000] !== 32'hA5A5_1234) begin
            $error("[FAIL] Zero-wait write failed! resp=%b, data=%h", resp_val, mem[32'h0000_1000]);
            errors++;
        end else
            $display("[PASS] Zero-wait write complete. Mem=0x%08X", mem[32'h0000_1000]);

        axi_read(32'h0000_1000, rd_val, resp_val);
        if (resp_val !== 2'b00 || rd_val !== 32'hA5A5_1234) begin
            $error("[FAIL] Zero-wait read failed! resp=%b, data=%h", resp_val, rd_val);
            errors++;
        end else
            $display("[PASS] Zero-wait read complete. Read=0x%08X", rd_val);

        $display("\n------------------------------------------------------------");
        $display("[TEST 2] Stalled APB Transfer (PREADY delayed 3 cycles)");
        $display("------------------------------------------------------------");
        wait_cycles = 3;

        axi_write(32'h0000_1004, 32'h5A5A_9876, resp_val);
        if (resp_val !== 2'b00 || mem[32'h0000_1004] !== 32'h5A5A_9876) begin
            $error("[FAIL] 3-cycle stall write failed!");
            errors++;
        end else
            $display("[PASS] Stalled write complete. Mem=0x%08X", mem[32'h0000_1004]);

        axi_read(32'h0000_1004, rd_val, resp_val);
        if (resp_val !== 2'b00 || rd_val !== 32'h5A5A_9876) begin
            $error("[FAIL] 3-cycle stall read failed!");
            errors++;
        end else
            $display("[PASS] Stalled read complete. Read=0x%08X", rd_val);

        $display("\n------------------------------------------------------------");
        $display("[TEST 3] APB Slave Error Propagation (PSLVERR -> SLVERR)");
        $display("------------------------------------------------------------");
        wait_cycles = 0;
        inject_err  = 1;

        axi_write(32'h0000_2000, 32'hBAD0_0001, resp_val);
        if (resp_val !== 2'b10) begin
            $error("[FAIL] Expected AXI SLVERR (2'b10) on write, got %b", resp_val);
            errors++;
        end else
            $display("[PASS] Write SLVERR correctly mapped to BRESP=2'b10");

        axi_read(32'h0000_2000, rd_val, resp_val);
        if (resp_val !== 2'b10) begin
            $error("[FAIL] Expected AXI SLVERR (2'b10) on read, got %b", resp_val);
            errors++;
        end else
            $display("[PASS] Read SLVERR correctly mapped to RRESP=2'b10");

        $display("\n============================================================");
        if (errors == 0)
            $display("ALL TESTS PASSED SUCCESSFULLY");
        else
            $display("FAILED WITH %0d ERRORS", errors);
        $display("============================================================");
        $finish;
    end

endmodule