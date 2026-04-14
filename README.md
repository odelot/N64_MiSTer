# N64_MiSTer — RetroAchievements Fork

This is a fork of the official [N64_MiSTer](https://github.com/MiSTer-devel/N64_MiSTer) core with **RetroAchievements** support for Nintendo 64 on MiSTer FPGA.

> **Status:** Experimental / Proof of Concept — requires the modified [Main_MiSTer binary](https://github.com/odelot/Main_MiSTer) to function.

## How to Test

Pre-built core binaries are available on the [Releases](https://github.com/odelot/N64_MiSTer/releases) page — no compilation or Quartus needed.

1. Download the `.rbf` core file from the latest release.
2. Copy the core file to the `/media/fat/_Console` folder on your MiSTer SD card.
3. You will also need the modified Main_MiSTer binary from [odelot/Main_MiSTer](https://github.com/odelot/Main_MiSTer) (see its README for setup instructions, including RetroAchievements credentials).

## What's Different from the Original

The [upstream N64_MiSTer](https://github.com/MiSTer-devel/N64_MiSTer) core emulates the Nintendo 64 console. This fork adds the FPGA-side infrastructure needed to expose emulated RDRAM to the ARM binary for RetroAchievements evaluation. All original core features are preserved.

### Files Added

| File | Purpose |
|------|--------|
| `rtl/ra_ram_mirror_n64.sv` | State machine that reads targeted RDRAM byte addresses from DDR3 and writes values to the RA DDRAM mirror region using the Selective Address protocol |
| `rtl/ddram_arb_n64.sv` | DDR3 bus arbiter — shares access between the N64 core's 8 DDR3Mux clients (CPU, RSP, RDP, VI, PI, etc.) and the RA mirror |

### Files Modified

| File | Change |
|------|--------|
| `N64.sv` | RA mirror and arbiter instantiated, VBlank signal connected from VI module, DDRAM interface wired through arbiter instead of directly to N64 core |

### How the RAM Mirroring Works

The N64 has a large RDRAM address space (4–8 MB) stored in DDR3 on the MiSTer board. This core uses the **Selective Address protocol** (Option C): the ARM binary writes a list of addresses it needs to evaluate, and the FPGA reads only those values from RDRAM and writes them back to a separate DDRAM mirror region.

**Memory regions exposed:**

| Region | Address Range | Size | Source |
|--------|--------------|------|--------|
| RDRAM | `$000000–$7FFFFF` | 4–8 MB | DDR3 (N64 RDRAM stored by DDR3Mux at word address `0x06000000`) |

**Key implementation details:**

- **Separate DDRAM base address** — N64 savestates occupy `0x3C000000–0x3FFFFFFF` (4 slots × 16 MB), which collides with the default RA mirror region at `0x3D000000`. The N64 RA mirror is relocated to ARM physical address `0x38000000` to avoid this conflict.

- **DDR3 bus arbitration** — The N64 core has 8 internal DDR3Mux clients (CPU, RSP, RDP, VI, PI, etc.) that can saturate the DDR3 bus. The arbiter (`ddram_arb_n64.sv`) gives the N64 core full priority by default (`S_PASSTHRU` state). A starvation counter (512 cycles, ~4 µs at 125 MHz) detects when the RA mirror has been waiting too long and temporarily stalls the N64 core to drain any in-flight burst and service the RA request. A burst mode optimization chains consecutive RA operations (waiting 16 cycles for the next request) to avoid re-entering the starvation wait between each transaction.

- **Clock domain crossing** — The DDR3 controller runs at 125 MHz (`clk_2x`) while the RA mirror state machine runs at ~62.5 MHz (`clk_1x`). Two-stage flip-flop synchronizers handle the toggle req/ack signals crossing between clock domains.

- **Direct byte mapping (1:1)** — The N64 CPU's `byteswap32` + `memorymux` 32-bit half-swap already places RDRAM byte N at DDRAM byte N within each 64-bit word. No additional XOR or byte reordering is needed on the FPGA side. For each requested address, the mirror issues a 64-bit DDR3 read and extracts the target byte using `address[2:0]` as the byte index.

- **RDRAM address translation** — The DDR3Mux hardcodes bits `[28:25]=0011` for N64 RDRAM. The mirror constructs the DDR3 word address as `{4'b0011, 5'd0, byte_addr[22:3]}` and extracts the byte at position `byte_addr[2:0]`.

- **8-VBlank warmup** — The mirror waits ~133 ms (8 VBlanks) after system reset before starting operations, ensuring the VI module that generates VBlank has fully stabilized.

- **Up to 4096 addresses per VBlank** — The mirror supports reading up to 4096 individual byte addresses per frame, more than enough for typical achievement evaluation.

**Per-VBlank flow:**
1. On VBlank rising edge (after warmup), the mirror writes the header with `busy=1`.
2. It reads the address request list from DDRAM at offset `0x40000` (count + request_id + address pairs).
3. For each address, it issues a DDR3 read at the RDRAM location and extracts the target byte.
4. Values are collected 8 bytes at a time into 64-bit words and written to the response cache at offset `0x48000`.
5. A response header with `response_id` and `response_frame` is written so the ARM can detect new data.
6. The header `busy` flag is cleared and debug counters are updated.

---

## Original Features (preserved from upstream)

## Hardware Requirements
SDRAM of any size is required.
32Mbyte SDRAM can only be used for games up to 16Mbyte in size.

## Bios
Rename your PIF ROM file (e.g. `pif.ntsc.rom` ) and place it in the `./games/N64/` folder as `boot.rom`

## Error messages

If there is a recognized problem, an overlay is displayed, showing which error has occured.
Errors are hex encoded by bits, so the error code can represent more than 1 error.

List of Errors:
- Bit 0 - Memory access to unmapped area
- Bit 1 - CPU Instruction not implemented, currently used for cache command only
- Bit 2 - CPU stall timeout
- Bit 3 - DDR3 timeout    
- Bit 4 - FPU internal exception    
- Bit 5 - PI error
- Bit 6 - critical Exception occurred (heuristic, typically games crash when that happens, but can be false positive)
- Bit 7 - PIF used up all 64 bytes for external communication or EEPROM command have unusual length
- Bit 8 - RSP Instruction not implemented
- Bit 9 - RSP stall timeout
- Bit 10 - RDP command not implemented
- Bit 11 - RDP combine mode not implemented
- Bit 12 - RDP combine alpha functionality not implemented
- Bit 13 - SDRAM Mux timeout
- Bit 14 - not implemented texture mode is used
- Bit 15 - not implemented render mode (2 pass or copy) is used
- Bit 16 - RSP read Fifo overflow
- Bit 17 - DDR3 - RSP write Fifo overflow
- Bit 18 - RSP IMEM/DMEM write/read address collision detected
- Bit 19 - One fo the DDR3 requesters wants to write or read outside of RDRAM 
- Bit 20 - RSP DMA wants to write outside of RDRAM 
- Bit 21 - RDP pixel writeback wants to write outside of RDRAM
- Bit 22 - RDP Z writeback wants to write outside of RDRAM
- Bit 23 - RSP PC is modified by register access while RSP runs
- Bit 24 - VI line processing wasn't able to complete in time
- Bit 25 - RDP Mux missed request
- Bit 26 - CPU Writefifo full (should never happen, internal CPU logic bug)
- Bit 27 - TLB access from multiple sources in parallel (should never happen, internal CPU logic bug)
- Bit 28 - PI DMA wants to write outside of RDRAM