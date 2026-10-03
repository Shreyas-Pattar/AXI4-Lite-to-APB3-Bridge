`timescale 1ns / 1ps

module axi_to_apb_bridge #(
    parameter DATA_WIDTH = 32,
    parameter ADDR_WIDTH = 32
)(
    input  wire                    aclk,
    input  wire                    aresetn,

    // AXI4-Lite Slave Interface
    // Write Address Channel
    input  wire [ADDR_WIDTH-1:0]   s_axi_awaddr,
    input  wire [2:0]              s_axi_awprot,
    input  wire                    s_axi_awvalid,
    output reg                     s_axi_awready,

    // Write Data Channel
    input  wire [DATA_WIDTH-1:0]   s_axi_wdata,
    input  wire [(DATA_WIDTH/8)-1:0] s_axi_wstrb,
    input  wire                    s_axi_wvalid,
    output reg                     s_axi_wready,

    // Write Response Channel
    output reg  [1:0]              s_axi_bresp,
    output reg                     s_axi_bvalid,
    input  wire                    s_axi_bready,

    // Read Address Channel
    input  wire [ADDR_WIDTH-1:0]   s_axi_araddr,
    input  wire [2:0]              s_axi_arprot,
    input  wire                    s_axi_arvalid,
    output reg                     s_axi_arready,

    // Read Data Channel
    output reg  [DATA_WIDTH-1:0]   s_axi_rdata,
    output reg  [1:0]              s_axi_rresp,
    output reg                     s_axi_rvalid,
    input  wire                    s_axi_rready,

    // APB3 Master Interface
    output reg  [ADDR_WIDTH-1:0]   m_apb_paddr,
    output reg                     m_apb_psel,
    output reg                     m_apb_penable,
    output reg                     m_apb_pwrite,
    output reg  [DATA_WIDTH-1:0]   m_apb_pwdata,
    output reg  [(DATA_WIDTH/8)-1:0] m_apb_pstrb,
    input  wire [DATA_WIDTH-1:0]   m_apb_prdata,
    input  wire                    m_apb_pready,
    input  wire                    m_apb_pslverr
);

    // AXI Responses
    localparam RESP_OKAY   = 2'b00;
    localparam RESP_SLVERR = 2'b10;

    // FSM State Encoding
    localparam [2:0]
        ST_IDLE       = 3'd0,
        ST_APB_SETUP  = 3'd1,
        ST_APB_ACCESS = 3'd2,
        ST_AXI_WRESP  = 3'd3,
        ST_AXI_RRESP  = 3'd4;

    reg [2:0] state;

    // Internal registers
    reg [ADDR_WIDTH-1:0]   reg_addr;
    reg [DATA_WIDTH-1:0]   reg_wdata;
    reg [(DATA_WIDTH/8)-1:0] reg_wstrb;
    reg                    reg_write_op;

    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            state         <= ST_IDLE;
            s_axi_awready <= 1'b0;
            s_axi_wready  <= 1'b0;
            s_axi_bresp   <= RESP_OKAY;
            s_axi_bvalid  <= 1'b0;
            s_axi_arready <= 1'b0;
            s_axi_rdata   <= {DATA_WIDTH{1'b0}};
            s_axi_rresp   <= RESP_OKAY;
            s_axi_rvalid  <= 1'b0;
            m_apb_paddr   <= {ADDR_WIDTH{1'b0}};
            m_apb_psel    <= 1'b0;
            m_apb_penable <= 1'b0;
            m_apb_pwrite  <= 1'b0;
            m_apb_pwdata  <= {DATA_WIDTH{1'b0}};
            m_apb_pstrb   <= {(DATA_WIDTH/8){1'b0}};
            reg_addr      <= {ADDR_WIDTH{1'b0}};
            reg_wdata     <= {DATA_WIDTH{1'b0}};
            reg_wstrb     <= {(DATA_WIDTH/8){1'b0}};
            reg_write_op  <= 1'b0;
        end else begin
            case (state)
                ST_IDLE: begin
                    s_axi_bvalid  <= 1'b0;
                    s_axi_rvalid  <= 1'b0;
                    m_apb_psel    <= 1'b0;
                    m_apb_penable <= 1'b0;

                    // Prioritize Write if both write channels present, else check Read
                    if (s_axi_awvalid && s_axi_wvalid) begin
                        s_axi_awready <= 1'b1;
                        s_axi_wready  <= 1'b1;
                        reg_addr      <= s_axi_awaddr;
                        reg_wdata     <= s_axi_wdata;
                        reg_wstrb     <= s_axi_wstrb;
                        reg_write_op  <= 1'b1;
                        state         <= ST_APB_SETUP;
                    end else if (s_axi_arvalid) begin
                        s_axi_arready <= 1'b1;
                        reg_addr      <= s_axi_araddr;
                        reg_write_op  <= 1'b0;
                        state         <= ST_APB_SETUP;
                    end
                end

                ST_APB_SETUP: begin
                    // Clear AXI handshake pulses
                    s_axi_awready <= 1'b0;
                    s_axi_wready  <= 1'b0;
                    s_axi_arready <= 1'b0;

                    // Drive APB Setup phase
                    m_apb_psel    <= 1'b1;
                    m_apb_penable <= 1'b0;
                    m_apb_paddr   <= reg_addr;
                    m_apb_pwrite  <= reg_write_op;
                    m_apb_pwdata  <= reg_wdata;
                    m_apb_pstrb   <= reg_wstrb;

                    state         <= ST_APB_ACCESS;
                end

                ST_APB_ACCESS: begin
                    // Enable phase assertion
                    m_apb_penable <= 1'b1;

                    // CRITICAL FIX: Only exit when PENABLE is active on the bus AND PREADY is high
                    if (m_apb_penable && m_apb_pready) begin
                        m_apb_psel    <= 1'b0;
                        m_apb_penable <= 1'b0;

                        if (reg_write_op) begin
                            s_axi_bresp  <= m_apb_pslverr ? RESP_SLVERR : RESP_OKAY;
                            s_axi_bvalid <= 1'b1;
                            state        <= ST_AXI_WRESP;
                        end else begin
                            s_axi_rdata  <= m_apb_prdata;
                            s_axi_rresp  <= m_apb_pslverr ? RESP_SLVERR : RESP_OKAY;
                            s_axi_rvalid <= 1'b1;
                            state        <= ST_AXI_RRESP;
                        end
                    end
                end

                ST_AXI_WRESP: begin
                    if (s_axi_bready && s_axi_bvalid) begin
                        s_axi_bvalid <= 1'b0;
                        state        <= ST_IDLE;
                    end
                end

                ST_AXI_RRESP: begin
                    if (s_axi_rready && s_axi_rvalid) begin
                        s_axi_rvalid <= 1'b0;
                        state        <= ST_IDLE;
                    end
                end

                default: state <= ST_IDLE;
            endcase
        end
    end

endmodule