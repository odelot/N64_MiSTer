// RetroAchievements RAM Mirror for N64 — Selective Address Reading  (v2)
//
// Each VBlank, reads a list of specific addresses from DDRAM (written by ARM),
// fetches the byte values from RDRAM (also in DDRAM), and writes them back
// to DDRAM for the ARM to read via rcheevos.
//
// N64 RDRAM: 4MB or 8MB at DDRAM address 0.
// All RA addresses are byte addresses into RDRAM (0x000000-0x7FFFFF).
// Since RDRAM is in DDRAM, both address-list and RDRAM reads use the
// same DDRAM read channel through the arbiter.
//
// DDRAM Layout (at DDRAM_BASE, ARM phys 0x38000000):
//   [0x00000] Header:   magic(32) + 0(8) + flags(8) + 0(16)
//   [0x00008] Frame:    frame_counter(32) + 0(32)
//   [0x00010] Debug1:   {ver(8), state_snap(8), vblank_cnt(16), timeout_cnt(16), ok_cnt(16)}
//   [0x00018] Debug2:   {first_addr(16), warmup_left(8), patience_seen(8), dispatch_cnt(16), max_timeout(16)}
//
//   [0x40000] AddrReq:  addr_count(32) + request_id(32)       (ARM -> FPGA)
//   [0x40008] Addrs:    addr[0](32) + addr[1](32), ...        (2 per 64-bit word)
//
//   [0x48000] ValResp:  response_id(32) + response_frame(32)  (FPGA -> ARM)
//   [0x48008] Values:   val[0..7](8b each), val[8..15], ...   (8 per 64-bit word)

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

	// DDRAM read interface (toggle req/ack)
	output reg [28:0] ddram_rd_addr,
	output reg        ddram_rd_req,
	input             ddram_rd_ack,
	input      [63:0] ddram_rd_dout,

	// Status
	output reg        active,
	output reg [31:0] dbg_frame_counter
);

// ======================================================================
// Constants
// ======================================================================
localparam [28:0] ADDRLIST_BASE = DDRAM_BASE + 29'h8000;  // byte offset 0x40000 / 8
localparam [28:0] VALCACHE_BASE = DDRAM_BASE + 29'h9000;  // byte offset 0x48000 / 8
localparam [12:0] MAX_ADDRS     = 13'd4096;

// FPGA version stamp (ARM checks this to verify bitstream)
localparam [7:0] FPGA_VERSION   = 8'h03;  // N64 v3 (reverted XOR, 1:1 byte map)

// ======================================================================
// Clock domain crossing synchronizers (DDRAM arbiter is on clk_2x)
// ======================================================================
reg dwr_ack_s1, dwr_ack_s2;
reg drd_ack_s1, drd_ack_s2;
always @(posedge clk) begin
	dwr_ack_s1 <= ddram_wr_ack; dwr_ack_s2 <= dwr_ack_s1;
	drd_ack_s1 <= ddram_rd_ack; drd_ack_s2 <= drd_ack_s1;
end

// ======================================================================
// VBlank edge detection
// ======================================================================
reg vblank_prev;
wire vblank_rising = vblank & ~vblank_prev;
always @(posedge clk) begin
	if (reset)
		vblank_prev <= 1'b1;  // assume VBlank starts HIGH (VI resets to vblank=1)
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
// State machine
// ======================================================================
localparam S_IDLE        = 5'd0;
localparam S_DD_WR_WAIT  = 5'd1;
localparam S_DD_RD_WAIT  = 5'd2;
localparam S_READ_HDR    = 5'd3;
localparam S_PARSE_HDR   = 5'd4;
localparam S_READ_PAIR   = 5'd5;
localparam S_PARSE_ADDR  = 5'd6;
localparam S_DISPATCH    = 5'd7;
localparam S_FETCH_RAM   = 5'd8;   // Issue DDRAM read for RDRAM byte
localparam S_RAM_WAIT    = 5'd9;   // Wait for DDRAM read data
localparam S_EXTRACT     = 5'd10;  // Extract byte from 64-bit word
localparam S_STORE_VAL   = 5'd11;
localparam S_FLUSH_BUF   = 5'd12;
localparam S_WRITE_RESP  = 5'd13;
localparam S_WR_HDR0     = 5'd14;
localparam S_WR_HDR1     = 5'd15;
localparam S_WR_DBG      = 5'd16;
localparam S_WR_DBG2     = 5'd17;

reg [4:0]  state;
reg [4:0]  return_state;

reg [31:0] frame_counter;
always @(posedge clk) dbg_frame_counter <= frame_counter;

reg [63:0] rd_data;
reg [31:0] req_count;
reg [31:0] req_id;
reg [12:0] addr_idx;
reg [63:0] addr_word;
reg [31:0] cur_addr;
reg [63:0] collect_buf;
reg  [3:0] collect_cnt;
reg [12:0] val_word_idx;

reg [63:0] rdram_word;     // 64-bit word read from RDRAM
reg  [7:0] fetch_byte;

// State snapshot for debug (captured at FSM entry)
reg  [4:0] dbg_state_snap;

// Debug counters
reg [15:0] dbg_ok_cnt;
reg [15:0] dbg_timeout_cnt;
reg [15:0] dbg_dispatch_cnt;
reg [15:0] dbg_first_addr;
reg [15:0] dbg_max_timeout;

// ======================================================================
// Main state machine
// ======================================================================
always @(posedge clk) begin
	if (reset) begin
		state          <= S_IDLE;
		active         <= 1'b0;
		frame_counter  <= 32'd0;
		ddram_wr_req   <= 1'b0;
		ddram_rd_req   <= 1'b0;
		dbg_state_snap <= S_IDLE;
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
				dbg_state_snap   <= S_IDLE;
				dbg_ok_cnt       <= 16'd0;
				dbg_timeout_cnt  <= 16'd0;
				dbg_max_timeout  <= 16'd0;
				dbg_dispatch_cnt <= 16'd0;
				dbg_first_addr   <= 16'd0;
				// Write header with busy=1
				ddram_wr_addr <= DDRAM_BASE;
				ddram_wr_din  <= {16'd0, 8'h01, 8'd0, 32'h52414348};
				ddram_wr_be   <= 8'hFF;
				ddram_wr_req  <= ~ddram_wr_req;
				return_state  <= S_READ_HDR;
				state         <= S_DD_WR_WAIT;
			end
		end

		// =============================================================
		S_DD_WR_WAIT: begin
			if (ddram_wr_req == dwr_ack_s2)
				state <= return_state;
		end

		S_DD_RD_WAIT: begin
			if (ddram_rd_req == drd_ack_s2) begin
				rd_data <= ddram_rd_dout;
				state   <= return_state;
			end
		end

		// =============================================================
		S_READ_HDR: begin
			ddram_rd_addr <= ADDRLIST_BASE;
			ddram_rd_req  <= ~ddram_rd_req;
			return_state  <= S_PARSE_HDR;
			state         <= S_DD_RD_WAIT;
		end

		S_PARSE_HDR: begin
			req_id <= rd_data[63:32];
			if (rd_data[31:0] == 32'd0) begin
				req_count <= 32'd0;
				state     <= S_WRITE_RESP;
			end else begin
				req_count    <= (rd_data[31:0] > {19'd0, MAX_ADDRS}) ?
				                {19'd0, MAX_ADDRS} : rd_data[31:0];
				addr_idx     <= 13'd0;
				collect_cnt  <= 4'd0;
				collect_buf  <= 64'd0;
				val_word_idx <= 13'd0;
				state        <= S_READ_PAIR;
			end
		end

		// =============================================================
		S_READ_PAIR: begin
			ddram_rd_addr <= ADDRLIST_BASE + 29'd1 + {16'd0, addr_idx[12:1]};
			ddram_rd_req  <= ~ddram_rd_req;
			return_state  <= S_PARSE_ADDR;
			state         <= S_DD_RD_WAIT;
		end

		S_PARSE_ADDR: begin
			if (!addr_idx[0]) begin
				addr_word <= rd_data;
				cur_addr  <= rd_data[31:0];
			end else begin
				cur_addr <= addr_word[63:32];
			end
			state <= S_DISPATCH;
		end

		// =============================================================
		// Route to RDRAM read (all addresses are RDRAM in DDRAM)
		// =============================================================
		S_DISPATCH: begin
			dbg_dispatch_cnt <= dbg_dispatch_cnt + 16'd1;
			if (dbg_dispatch_cnt == 16'd0)
				dbg_first_addr <= cur_addr[15:0];
			state <= S_FETCH_RAM;
		end

		// =============================================================
		// RDRAM read: byte from N64 RDRAM stored in DDRAM at address 0+
		// DDRAM word address = byte_addr[22:3]  (8 bytes per word)
		// Byte within word   = byte_addr[2:0]
		// =============================================================
		S_FETCH_RAM: begin
			// Issue DDRAM read for the 64-bit word containing our byte.
			// N64 RDRAM lives at DDRAM word address 0x06000000 because
			// DDR3Mux hardcodes bits [28:25]=0011 for all clients.
			// cur_addr is a byte offset into RDRAM (0-0x7FFFFF).
			ddram_rd_addr <= {4'b0011, 5'd0, cur_addr[22:3]};
			ddram_rd_req  <= ~ddram_rd_req;
			return_state  <= S_EXTRACT;
			state         <= S_DD_RD_WAIT;
		end

		S_EXTRACT: begin
			// Select the requested byte from the 64-bit DDRAM word.
			//
			// Byte mapping is 1:1: CPU byteswap32 + memorymux 32-bit
			// half-swap places RDRAM byte N at DDRAM byte N within
			// each 64-bit word.  No additional transformation needed.
			case (cur_addr[2:0])
				3'd0: fetch_byte <= rd_data[ 7: 0];
				3'd1: fetch_byte <= rd_data[15: 8];
				3'd2: fetch_byte <= rd_data[23:16];
				3'd3: fetch_byte <= rd_data[31:24];
				3'd4: fetch_byte <= rd_data[39:32];
				3'd5: fetch_byte <= rd_data[47:40];
				3'd6: fetch_byte <= rd_data[55:48];
				3'd7: fetch_byte <= rd_data[63:56];
			endcase
			dbg_ok_cnt <= dbg_ok_cnt + 16'd1;
			state <= S_STORE_VAL;
		end

		// =============================================================
		S_STORE_VAL: begin
			case (collect_cnt[2:0])
				3'd0: collect_buf[ 7: 0] <= fetch_byte;
				3'd1: collect_buf[15: 8] <= fetch_byte;
				3'd2: collect_buf[23:16] <= fetch_byte;
				3'd3: collect_buf[31:24] <= fetch_byte;
				3'd4: collect_buf[39:32] <= fetch_byte;
				3'd5: collect_buf[47:40] <= fetch_byte;
				3'd6: collect_buf[55:48] <= fetch_byte;
				3'd7: collect_buf[63:56] <= fetch_byte;
			endcase
			collect_cnt <= collect_cnt + 4'd1;
			addr_idx    <= addr_idx + 13'd1;

			if (collect_cnt == 4'd7 || (addr_idx + 13'd1 >= req_count[12:0])) begin
				state <= S_FLUSH_BUF;
			end
			else if (addr_idx[0]) begin
				state <= S_READ_PAIR;
			end else begin
				state <= S_PARSE_ADDR;
			end
		end

		// =============================================================
		S_FLUSH_BUF: begin
			ddram_wr_addr <= VALCACHE_BASE + 29'd1 + {16'd0, val_word_idx};
			ddram_wr_din  <= collect_buf;
			ddram_wr_be   <= (collect_cnt == 4'd8) ? 8'hFF
			                 : ((8'd1 << collect_cnt[2:0]) - 8'd1);
			ddram_wr_req  <= ~ddram_wr_req;
			val_word_idx  <= val_word_idx + 13'd1;
			collect_cnt   <= 4'd0;
			collect_buf   <= 64'd0;

			if (addr_idx >= req_count[12:0]) begin
				return_state <= S_WRITE_RESP;
			end else if (!addr_idx[0]) begin
				return_state <= S_READ_PAIR;
			end else begin
				return_state <= S_PARSE_ADDR;
			end
			state <= S_DD_WR_WAIT;
		end

		// =============================================================
		S_WRITE_RESP: begin
			ddram_wr_addr <= VALCACHE_BASE;
			ddram_wr_din  <= {frame_counter + 32'd1, req_id};
			ddram_wr_be   <= 8'hFF;
			ddram_wr_req  <= ~ddram_wr_req;
			return_state  <= S_WR_HDR0;
			state         <= S_DD_WR_WAIT;
		end

		S_WR_HDR0: begin
			ddram_wr_addr <= DDRAM_BASE;
			ddram_wr_din  <= {16'd0, 8'h00, 8'd0, 32'h52414348};
			ddram_wr_be   <= 8'hFF;
			ddram_wr_req  <= ~ddram_wr_req;
			return_state  <= S_WR_HDR1;
			state         <= S_DD_WR_WAIT;
		end

		S_WR_HDR1: begin
			frame_counter <= frame_counter + 32'd1;
			ddram_wr_addr <= DDRAM_BASE + 29'd1;
			ddram_wr_din  <= {32'd0, frame_counter + 32'd1};
			ddram_wr_be   <= 8'hFF;
			ddram_wr_req  <= ~ddram_wr_req;
			return_state  <= S_WR_DBG;
			state         <= S_DD_WR_WAIT;
		end

		// Debug word 1 (offset 0x10):
		// {ver(8), state_snap(8), vblank_heartbeat(16), timeout_cnt(16), ok_cnt(16)}
		S_WR_DBG: begin
			ddram_wr_addr <= DDRAM_BASE + 29'd2;
			ddram_wr_din  <= {FPGA_VERSION, 3'd0, dbg_state_snap,
			                  vblank_heartbeat,
			                  dbg_timeout_cnt, dbg_ok_cnt};
			ddram_wr_be   <= 8'hFF;
			ddram_wr_req  <= ~ddram_wr_req;
			return_state  <= S_WR_DBG2;
			state         <= S_DD_WR_WAIT;
		end

		// Debug word 2 (offset 0x18):
		// {first_addr(16), warmup_left(8), 0(8), dispatch_cnt(16), max_timeout(16)}
		S_WR_DBG2: begin
			ddram_wr_addr <= DDRAM_BASE + 29'd3;
			ddram_wr_din  <= {dbg_first_addr, 4'd0, warmup_cnt, 8'd0,
			                  dbg_dispatch_cnt, dbg_max_timeout};
			ddram_wr_be   <= 8'hFF;
			ddram_wr_req  <= ~ddram_wr_req;
			return_state  <= S_IDLE;
			state         <= S_DD_WR_WAIT;
		end

		endcase
	end
end

endmodule
