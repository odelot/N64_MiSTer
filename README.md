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
| `rtl/ra_ram_mirror_n64.sv` | Lightweight VBlank heartbeat writer (v4): writes `RACH` header, frame counter, and debug/version word to DDRAM so ARM can gate achievement frames reliably |
| `rtl/ddram_arb_n64.sv` | DDR3 arbiter between N64 core and RA writes; keeps N64 as primary and services RA when bus is available |

### Files Modified

| File | Change |
|------|--------|
| `N64.sv` | RA mirror and arbiter instantiated; RA mirror now clocks from reliable VI interrupt (`vi_irq`) and writes heartbeat data at 0x38000000 |

### How the Memory Path Works Now

The current N64 RA implementation no longer streams address/value batches each VBlank. Instead, it uses a split model:

1. **FPGA heartbeat path**: `ra_ram_mirror_n64.sv` writes only metadata (`RACH`, frame counter, debug/version) at DDRAM base 0x38000000, one update per VI interrupt.
2. **Direct memory path**: Main_MiSTer maps N64 RDRAM directly at physical 0x30000000 and reads bytes on demand during `rc_client_do_frame()`.

This removes the old Option C transfer loop and avoids per-VBlank memory copy traffic for achievement evaluation.

**Memory regions exposed:**

| Region | Address Range | Size | Source |
|--------|--------------|------|--------|
| RDRAM | `$000000–$7FFFFF` | 4–8 MB | Direct ARM mmap of physical `0x30000000` |

**Key implementation details:**

- **Separate DDRAM base address** — N64 savestates occupy `0x3C000000–0x3FFFFFFF` (4 slots × 16 MB), which collides with the default RA mirror region at `0x3D000000`. The N64 RA mirror is relocated to ARM physical address `0x38000000` to avoid this conflict.

- **Reliable VBlank signal** — heartbeat uses VI interrupt (`vi_irq`) rather than video VBlank, improving frame gating stability.

- **Direct byte mapping handled on ARM** — Main_MiSTer reads direct RDRAM bytes using `addr ^ 3` conversion to align N64 endianness expectations for rcheevos.

- **Optional snapshot mode** — if `n64_snapshot=1` in `retroachievements.cfg`, Main_MiSTer copies 8 MB of RDRAM at each VI frame and evaluates that stable snapshot.

- **8-VBlank warmup** — The mirror waits ~133 ms (8 VBlanks) after system reset before starting operations, ensuring the VI module that generates VBlank has fully stabilized.

**Per-frame flow:**
1. On VI interrupt rising edge (after warmup), FPGA writes heartbeat header/frame/debug.
2. Main_MiSTer observes frame advance at 0x38000000 and starts one achievement frame.
3. rcheevos reads N64 memory from direct mapped RDRAM (or snapshot buffer when enabled).
4. No address-list upload and no value-cache download are required.

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