// DDRAM Arbiter for N64 RetroAchievements  (v2 — burst mode)
//
// Sits between N64 core (n64top) and the physical DDRAM interface.
// The N64 core is the primary master; the RA module is secondary.
//
// The N64 core's 8 DDR3Mux clients can saturate the DDRAM bus, so a
// starvation counter detects when RA has been waiting too long and
// forcefully stalls N64 until the in-flight burst drains.
//
// Once RA is admitted, the arbiter stays in "RA burst mode": it keeps
// servicing back-to-back RA requests (write or read) without returning
// to passthrough, until RA has no more pending ops.  This avoids the
// 512-cycle re-starvation penalty between every single RA transaction.
//
// RA uses toggle req/ack protocol for both write and read channels.

module ddram_arb_n64 (
	input         clk,
	input         reset,

	// Physical DDRAM interface (directly to top-level DDRAM ports)
	input         PHY_BUSY,
	output  [7:0] PHY_BURSTCNT,
	output [28:0] PHY_ADDR,
	input  [63:0] PHY_DOUT,
	input         PHY_DOUT_READY,
	output        PHY_RD,
	output [63:0] PHY_DIN,
	output  [7:0] PHY_BE,
	output        PHY_WE,

	// N64 core DDRAM interface (from n64top)
	output        N64_BUSY,
	input   [7:0] N64_BURSTCNT,
	input  [28:0] N64_ADDR,
	output [63:0] N64_DOUT,
	output        N64_DOUT_READY,
	input         N64_RD,
	input  [63:0] N64_DIN,
	input   [7:0] N64_BE,
	input         N64_WE,

	// RetroAchievements write channel (toggle req/ack)
	input  [28:0] ra_wr_addr,
	input  [63:0] ra_wr_din,
	input   [7:0] ra_wr_be,
	input         ra_wr_req,
	output reg    ra_wr_ack,

	// RetroAchievements read channel (toggle req/ack)
	input  [28:0] ra_rd_addr,
	input         ra_rd_req,
	output reg    ra_rd_ack,
	output reg [63:0] ra_rd_dout
);

// ---------------------------------------------------------------------------
// Reset synchronizer
// ---------------------------------------------------------------------------
reg rst_s1 = 1, rst_s2 = 1;
always @(posedge clk) begin
	rst_s1 <= reset;
	rst_s2 <= rst_s1;
end

// ---------------------------------------------------------------------------
// CDC synchronizers for RA req signals (clk_1x mirror -> clk_2x arbiter)
// ---------------------------------------------------------------------------
reg ra_wr_req_s1, ra_wr_req_s2;
reg ra_rd_req_s1, ra_rd_req_s2;
always @(posedge clk) begin
	ra_wr_req_s1 <= ra_wr_req;  ra_wr_req_s2 <= ra_wr_req_s1;
	ra_rd_req_s1 <= ra_rd_req;  ra_rd_req_s2 <= ra_rd_req_s1;
end

// State machine
localparam S_PASSTHRU  = 3'd0;
localparam S_RA_WR     = 3'd1;
localparam S_RA_RD     = 3'd2;
localparam S_RA_WAIT   = 3'd3;
localparam S_RA_CHECK  = 3'd4;  // burst mode: check for next RA op

reg [2:0] state = S_PASSTHRU;

// Track pending N64 read bursts
reg        n64_rd_active = 0;
reg  [7:0] n64_burst_cnt = 0;

// ---------------------------------------------------------------------------
// Starvation detection (only needed for initial entry into RA mode)
// ---------------------------------------------------------------------------
wire ra_pending_sync = (ra_wr_req_s2 != ra_wr_ack) || (ra_rd_req_s2 != ra_rd_ack);
reg [11:0] starve_cnt = 0;
localparam [11:0] STARVE_LIMIT = 12'd512; // ~4 us @ 125 MHz
wire stalling = (starve_cnt >= STARVE_LIMIT) && ra_pending_sync;

// Combinational mux
assign PHY_BURSTCNT = (state == S_PASSTHRU) ? N64_BURSTCNT : 8'd1;
assign PHY_ADDR     = (state == S_PASSTHRU) ? N64_ADDR     :
                      (state == S_RA_WR)    ? ra_wr_addr   : ra_rd_addr;
assign PHY_DIN      = (state == S_PASSTHRU) ? N64_DIN      : ra_wr_din;
assign PHY_BE       = (state == S_PASSTHRU) ? N64_BE       :
                      (state == S_RA_WR)    ? ra_wr_be     : 8'hFF;

// Gate N64 bus ops when stalling, in RA mode, or in reset
assign PHY_WE       = rst_s2                             ? 1'b0    :
                      (state == S_RA_WR)                 ? 1'b1    :
                      (state == S_PASSTHRU && !stalling) ? N64_WE  : 1'b0;
assign PHY_RD       = rst_s2                             ? 1'b0    :
                      (state == S_RA_RD)                 ? 1'b1    :
                      (state == S_PASSTHRU && !stalling) ? N64_RD  : 1'b0;

// Stall N64 when RA owns the bus, starvation forces a drain, or in reset
assign N64_BUSY       = rst_s2                ? 1'b1 :
                        (state != S_PASSTHRU) ? 1'b1 :
                        stalling              ? 1'b1 : PHY_BUSY;
assign N64_DOUT       = PHY_DOUT;
assign N64_DOUT_READY = (state == S_PASSTHRU) ? PHY_DOUT_READY : 1'b0;

// Burst patience counter declaration (driven in main always block)
reg [4:0] ra_burst_patience = 0;

always @(posedge clk) begin
	if (rst_s2) begin
		state              <= S_PASSTHRU;
		n64_rd_active      <= 1'b0;
		n64_burst_cnt      <= 8'd0;
		starve_cnt         <= 12'd0;
		ra_wr_ack          <= 1'b0;
		ra_rd_ack          <= 1'b0;
		ra_rd_dout         <= 64'd0;
		ra_burst_patience  <= 5'd0;
	end
	else begin

	// Track pending N64 read bursts (only when passthru and not stalling)
	if (state == S_PASSTHRU && !stalling) begin
		if (N64_RD && !PHY_BUSY) begin
			n64_rd_active <= 1'b1;
			n64_burst_cnt <= N64_BURSTCNT;
		end
	end
	if (n64_rd_active && PHY_DOUT_READY && state == S_PASSTHRU) begin
		if (n64_burst_cnt <= 8'd1)
			n64_rd_active <= 1'b0;
		else
			n64_burst_cnt <= n64_burst_cnt - 8'd1;
	end

	// Starvation counter
	if (state == S_PASSTHRU && ra_pending_sync)
		starve_cnt <= (starve_cnt < STARVE_LIMIT) ? starve_cnt + 12'd1 : starve_cnt;
	else if (state == S_PASSTHRU)
		starve_cnt <= 12'd0;
	// starve_cnt retains its value in RA states (keeps stalling asserted)

	// Burst patience counter
	if (state == S_RA_WR || state == S_RA_RD || state == S_RA_WAIT)
		ra_burst_patience <= 5'd16;
	else if (state == S_RA_CHECK && ra_burst_patience != 0)
		ra_burst_patience <= ra_burst_patience - 5'd1;
	else if (state == S_PASSTHRU)
		ra_burst_patience <= 5'd0;

	case (state)
	S_PASSTHRU: begin
		// Enter RA mode when bus is idle (natural gap or forced drain)
		if (!PHY_BUSY && !n64_rd_active &&
		    (!N64_WE || stalling) && (!N64_RD || stalling)) begin
			if (ra_wr_req_s2 != ra_wr_ack)
				state <= S_RA_WR;
			else if (ra_rd_req_s2 != ra_rd_ack)
				state <= S_RA_RD;
		end
	end

	S_RA_WR: begin
		if (!PHY_BUSY) begin
			ra_wr_ack <= ra_wr_req_s2;
			state <= S_RA_CHECK;
		end
	end

	S_RA_RD: begin
		if (!PHY_BUSY)
			state <= S_RA_WAIT;
	end

	S_RA_WAIT: begin
		if (PHY_DOUT_READY) begin
			ra_rd_dout <= PHY_DOUT;
			ra_rd_ack  <= ra_rd_req_s2;
			state      <= S_RA_CHECK;
		end
	end

	// Burst mode: after completing an RA op, check for next immediately.
	// Wait up to 16 clk_2x cycles for the mirror to toggle its next req.
	S_RA_CHECK: begin
		if (ra_wr_req_s2 != ra_wr_ack)
			state <= S_RA_WR;
		else if (ra_rd_req_s2 != ra_rd_ack)
			state <= S_RA_RD;
		else if (ra_burst_patience == 0)
			state <= S_PASSTHRU;
	end
	endcase

	end // !rst_s2
end

endmodule
