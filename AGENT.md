# AGENT.md — NES88 AOT Static Binary Transpiler & CGA Runtime Guide

This document describes the architecture, build pipeline, runtime layout, and verification workflow for transpiling NROM NES games (`.nes`) into native 16-bit 8088 real-mode MS-DOS executables (`.com` + `.chr`) targeting a 4.77 MHz Intel 8088 (e.g., Toshiba T1000) with CGA Mode 4 ($320 \times 200$, 4-color) graphics.

---

## 1. Quick Start: Generating a `.COM` + `.CHR` Game

### Single Game Build
To transpile and assemble a specific `.nes` ROM (for example `battle.nes`):

```powershell
# 1. Run the offline 6502-to-8088 AOT transpiler
#    Produces <game>.asm and <game>.chr (48 KB ROM+CHR package)
#    Optional: add --nosound to strip APU traps and disable speaker output
node transpiler/aot_transpiler.js battle.nes
node transpiler/aot_transpiler.js battle.nes --nosound

# 2. Assemble the generated 16-bit NASM file into a flat DOS .COM binary
D:\cc65\bin\nasm.exe -f bin battle.asm -o battle.com
```

### Runtime Flags
- `<game>.com` — Runs normally with CGA Mode 4 graphics and PC Speaker audio.
- `<game>.com --nosound` — Disables PC Speaker synthesis and bypasses 60 Hz APU updates at runtime.
- `<game>.com T` — Runs for 240 ticks (4 seconds) and dumps VRAM/OAM/RAM to `<GAME>.DMP`.

### Batch Build All `.nes` ROMs in the Workspace
```powershell
.\build_all_aot.bat
```
`build_all_aot.bat` iterates over every `*.nes` file in the directory, runs `node aot_transpiler.js`, and assembles `<game>.com` via `D:\cc65\bin\nasm.exe`.

### Runtime Files Required on Target DOS Machine
Each game requires **two files** in the same directory:
1. `<game>.com` — Native 16-bit 8088 real-mode executable (code + HLE CGA runtime).
2. `<game>.chr` — 48 KB binary asset package loaded into `nes_ram_seg` at startup:
   - `0000h..1FFFh` (8 KB): Pre-converted 2-bpp CGA Mode 4 tiles (4 even scanline words + 4 odd scanline words per tile).
   - `2000h..9FFFh` (32 KB): Raw 6502 PRG-ROM mapped into `nes_ram_seg:8000h..FFFFh` for indexed data/table reads.
   - `A000h..BFFFh` (8 KB): Raw 6502 CHR-ROM mapped into `nes_ram_seg:2000h..3FFFh` for `$2007` VRAM reads from pattern tables.

---

## 2. Architectural Constraints & Register Convention

### Static Binary Translation (No CPU Interpreter Loop)
`aot_transpiler.js` performs iterative Control-Flow Graph (CFG) discovery starting from the 6502 `RESET`, `NMI`, and `IRQ` vectors, automatically resolving:
- Standard branches and `JSR`/`JMP` targets.
- Stack-dispatched jump tables (`JumpEngine`: `PLA..PLA..JMP ($xxxx)`).
- Indexed ROM pointer tables (`LDA tbl_lo,X; ... LDA tbl_hi,X; ... JMP ($xxxx)`).
- Indirect pointer tables in PRG-ROM.

### 6502 $\rightarrow$ 8088 Register Mapping
| 6502 State | 8088 Register / Segment | Notes |
| :--- | :--- | :--- |
| **Accumulator (`A`)** | `AL` | 8-bit accumulator |
| **Index `X`** | `BL` | 8-bit index register |
| **Index `Y`** | `BH` | 8-bit index register |
| **Carry Flag (`C`)** | `DH` bit 0 | Preserved across non-carry instructions; loaded into x86 `CF` via `rcr dh, 1` and saved via `rol dh, 1`. Inverted for `SBC`/`CMP` via `cmc`. |
| **Z / N Flags** | x86 `ZF` / `SF` | Updated via `inc reg; dec reg` (which preserves `CF`) or arithmetic ops. |
| **Hardware Stack (`$0100+S`)** | `DS:DI` | `DI` holds `$0100 + S` in `nes_ram_seg`. |
| **64 KB 6502 Memory** | `DS` (`nes_ram_seg`) | `0000h..07FFh` = 2 KB RAM, `2000h..3FFFh` = raw CHR-ROM, `4000h..5FFFh` = CGA CHR tiles, `8000h..FFFFh` = 32 KB PRG-ROM. |
| **O(1) Address Translation** | `ES` (`xlate_seg`) | 64 KB segment mapping `(addr6502 << 1)` $\rightarrow$ native `CS` offset (`loc_XXXX`) for `hle_rts` and `dispatch_indirect`. |

---

## 3. PPU High-Level Virtualization (`cga_runtime.asm`)

- **Memory-Mapped Traps**: Reads/writes to `$2000–$2007`, `$4014` (OAM DMA), and `$4016` (Joypad) are intercepted at compile time (and via `hle_write_si` / `hle_sta_izy` for dynamic pointers) and routed to assembly routines in `cga_runtime.asm`.
- **Dual-Nametable & Vertical Scroll Support**:
  - `vram_nametable` stores both Nametable 0 (`$2000..$23BF` at offset `0..959`) and Nametable 2 (`$2800..$2BBF` at offset `960..1919`) contiguously.
  - `flush_dirty_tiles` computes the visible starting row from `ppu_scroll_y` (`$2005`) and `ppu_ctrl` bit 1 (`$2000`), wrapping seamlessly across the 60-row (`1920`-byte) dual-nametable buffer.
- **Decoupled 60 Hz Timer / Dirty-Tile Video Blitter**:
  - `INT 08h` programs the 8253 PIT Channel 0 to 60 Hz (`divisor = 19886 = 4DAEh`), sending PIC EOI and setting `ppu_status` bit 7 (`80h`) on every tick before checking the `in_timer_isr` re-entrancy guard.
  - Video flushes occur every `frameskip_max` ticks (default `3` = 20 FPS), adjustable at runtime using keys `1`–`9`.

---

## 4. Keyboard Controls (`INT 09h`)

| NES Input / Function | Primary Key | Alternate Key(s) |
| :--- | :--- | :--- |
| **D-Pad Up / Down / Left / Right** | Arrow Keys | `W` / `S` / `A` / `D` |
| **A Button** | `Z` | `J` |
| **B Button** | `X` | `K` |
| **Start** | `Enter` | `Space` |
| **Select** | `Tab` | `Left Shift` or `C` |
| **Frameskip 1..9 (60 FPS .. 6.7 FPS)** | `1` – `9` | Default is `3` (20 FPS) |
| **Exit to DOS** | `ESC` | Restores text mode & PIC/PIT vectors |

---

## 5. Automated Testing & Screenshot Verification

Passing any command-line argument to a compiled `.com` binary (e.g., `battle.com T`) runs the game for 240 ticks (4 seconds at 60 Hz), dumps the nametable, OAM, and 16 KB CGA VRAM (`0B800h:0000h..3FFFh`) to `<GAME>.DMP` (`17,664` bytes), and exits cleanly to DOS:

```powershell
& "C:\Program Files\DOSBox Staging\dosbox.exe" -noprimaryconf -nolocalconf -c "mount c d:\sandbox\nes88" -c "c:" -c "battle.com T" -c "exit"
```
Bytes `0x0500..0x44FF` of `<GAME>.DMP` contain the raw CGA Mode 4 framebuffer (even lines at `0x0000..0x1F3F`, odd lines at `0x2000..0x3F3F`, 80 bytes per scanline, 2 bits per pixel).

