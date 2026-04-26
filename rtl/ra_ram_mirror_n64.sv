// RetroAchievements RAM Mirror for N64 — VBlank Frame Counter (v4)
//
// Simplified module: detects VBlank (VI interrupt), increments a frame
// counter, and writes a small header to DDRAM so the ARM can:
//   1. Detect that the FPGA mirror is active (magic word)
//   2. Gate achievement processing on VBlank (frame counter)
//
// Memory reads are done directly by the ARM via mmap'd RDRAM.
//
// DDRAM Layout (at DDRAM_BASE, ARM phys 0x38000000):
//   [0x00000] Header:   magic(32) + 0(8) + flags(8) + 0(16)
//   [0x00008] Frame:    frame_counter(32) + 0(32)
//   [0x00010] Debug:    {ver(8), 0(8), vblank_cnt(16), 0(32)}

module ra_ram_mirror_n64 #(
	parameter [28:0] DDRAM_BASE = 29'h07000000  // ARM phys 0x38000000 >> 3
)(
	input             clk,           // clk_1x (~62.5 MHz)
	input             reset,
	input             vblank,

	// DDRAM write interface (toggle req/ack)
	output reg [28:0] ddram_wr_addr,
	output reg [63:0] ddram_wr_din,
	output reg  [7:0] ddram_wr_be,
	output reg        ddram_wr_req,
	input             ddram_wr_ack,

	// DDRAM read interface (unused, active low)
	output reg [28:0] ddram_rd_addr,
	output reg        ddram_rd_req,
	input             ddram_rd_ack,
	input      [63:0] ddram_rd_dout,

	// Status
	output reg        active,
	output reg [31:0] dbg_frame_counter
);

// FPGA version stamp (ARM checks this to verify bitstream)
localparam [7:0] FPGA_VERSION = 8'h04;  // N64 v4 (VBlank-only, no address list)

// ======================================================================
// Clock domain crossing synchronizer (DDRAM arbiter is on clk_2x)
// ======================================================================
reg dwr_ack_s1, dwr_ack_s2;
always @(posedge clk) begin
	dwr_ack_s1 <= ddram_wr_ack; dwr_ack_s2 <= dwr_ack_s1;
end

// ======================================================================
// VBlank edge detection
// ======================================================================
reg vblank_prev;
wire vblank_rising = vblank & ~vblank_prev;
always @(posedge clk) begin
	if (reset)
		vblank_prev <= 1'b1;
	else
		vblank_prev <= vblank;
end

// ======================================================================
// Free-running VBlank heartbeat (for diagnostics)
// ======================================================================
reg [15:0] vblank_heartbeat;
always @(posedge clk) begin
	if (reset)
		vblank_heartbeat <= 16'd0;
	else if (vblank_rising)
		vblank_heartbeat <= vblank_heartbeat + 16'd1;
end

// ======================================================================
// Post-reset warmup: wait for N VBlanks before starting FSM.
// This ensures the VI module has actually started generating real
// VBlank signals (reset_intern_1x inside n64top may stay asserted
// much longer than reset_or, delaying VI by 17ms+).
// ======================================================================
localparam [3:0] WARMUP_VBLANKS = 4'd8;  // wait 8 VBlanks (~133ms)
reg [3:0] warmup_cnt;
wire warmup_done = (warmup_cnt == 0);

always @(posedge clk) begin
	if (reset)
		warmup_cnt <= WARMUP_VBLANKS;
	else if (!warmup_done && vblank_rising)
		warmup_cnt <= warmup_cnt - 4'd1;
end

// ======================================================================
// State machine — simplified: just write header + frame counter
// ======================================================================
localparam S_IDLE     = 3'd0;
localparam S_WR_WAIT  = 3'd1;
localparam S_WR_HDR0  = 3'd2;  // Write header (magic + busy=0)
localparam S_WR_HDR1  = 3'd3;  // Write frame counter
localparam S_WR_DBG   = 3'd4;  // Write debug info

reg [2:0]  state;
reg [2:0]  return_state;

reg [31:0] frame_counter;
always @(posedge clk) dbg_frame_counter <= frame_counter;

// ======================================================================
// Main state machine
// ======================================================================
always @(posedge clk) begin
	if (reset) begin
		state         <= S_IDLE;
		active        <= 1'b0;
		frame_counter <= 32'd0;
		ddram_wr_req  <= 1'b0;
		ddram_rd_req  <= 1'b0;
		ddram_rd_addr <= 29'd0;
	end
	else begin
		case (state)

		// =============================================================
		// IDLE: Wait for VBlank rising edge (after warmup)
		// =============================================================
		S_IDLE: begin
			active <= 1'b0;
			if (vblank_rising && warmup_done) begin
				active <= 1'b1;
				// Write header with busy=1 to signal frame start
				ddram_wr_addr <= DDRAM_BASE;
				ddram_wr_din  <= {16'h0100, 8'h01, 8'd0, 32'h52414348};
				ddram_wr_be   <= 8'hFF;
				ddram_wr_req  <= ~ddram_wr_req;
				return_state  <= S_WR_HDR0;
				state         <= S_WR_WAIT;
			end
		end

		// =============================================================
		S_WR_WAIT: begin
			if (ddram_wr_req == dwr_ack_s2)
				state <= return_state;
		end

		// Write header with busy=0 (frame processing done)
		S_WR_HDR0: begin
			ddram_wr_addr <= DDRAM_BASE;
			ddram_wr_din  <= {16'h0100, 8'h00, 8'd0, 32'h52414348};
			ddram_wr_be   <= 8'hFF;
			ddram_wr_req  <= ~ddram_wr_req;
			return_state  <= S_WR_HDR1;
			state         <= S_WR_WAIT;
		end

		// Write frame counter
		S_WR_HDR1: begin
			frame_counter <= frame_counter + 32'd1;
			ddram_wr_addr <= DDRAM_BASE + 29'd1;
			ddram_wr_din  <= {32'd0, frame_counter + 32'd1};
			ddram_wr_be   <= 8'hFF;
			ddram_wr_req  <= ~ddram_wr_req;
			return_state  <= S_WR_DBG;
			state         <= S_WR_WAIT;
		end

		// Debug word (offset 0x10): version + heartbeat
		S_WR_DBG: begin
			ddram_wr_addr <= DDRAM_BASE + 29'd2;
			ddram_wr_din  <= {FPGA_VERSION, 8'd0,
			                  vblank_heartbeat,
			                  32'd0};
			ddram_wr_be   <= 8'hFF;
			ddram_wr_req  <= ~ddram_wr_req;
			return_state  <= S_IDLE;
			state         <= S_WR_WAIT;
		end

		endcase
	end
end

endmodule
