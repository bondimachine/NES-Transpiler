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
- `<game>.com --invert` — Starts with inverted colours (key `I` toggles at runtime).
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

- **Emulated JSR** (games with return-address tricks): inlined as `lea di,[di-2]` / `mov word [di+1], ret` / `jmp target` (no helper call); RTS still goes through `hle_rts`.

### 6502 $\rightarrow$ 8088 Register Mapping
| 6502 State | 8088 Register / Segment | Notes |
| :--- | :--- | :--- |
| **Accumulator (`A`)** | `AL` | 8-bit accumulator |
| **Index `X`** | `BL` or `CL` | Chosen per ROM. The register in `BX` (with `BH = 0` kept invariant) indexes memory directly (`[bx + abs]`, `[bx + si]` for `(zp),Y`); the one in `CL` (`CH = 0`) is copied to `SI`. Y gets `BX` only when its static advantage is >= 3x. Runtime helpers see the choice via `REG_X` / `REG_Y` / `REG_Y16`. |
| **Index `Y`** | `CL` or `BL` | See above. |
| **Carry Flag (`C`)** | `DH` bit 0 | Preserved across non-carry instructions; loaded into x86 `CF` via `rcr dh, 1` and saved via `rol dh, 1`. Inverted for `SBC`/`CMP` via `cmc`. |
| **Z / N Flags** | x86 `ZF` / `SF` | Updated via `inc reg; dec reg` (which preserves `CF`) or arithmetic ops. A global flag-liveness analysis skips these fix-ups (and `cmc` / carry save) when no later instruction reads the flag. JSR/RTS/RTI and indirect jumps are treated as reading all flags. |
| **Hardware Stack (`$0100+S`)** | `DS:DI` | `DI` holds `$0100 + S` in `nes_ram_seg`. |
| **64 KB 6502 Memory** | `DS` (`nes_ram_seg`) | `0000h..07FFh` = 2 KB RAM, `0800h..0E3Fh` = CGA tile offsets and `1000h..16C3h` = on-screen tile shadow (runtime tables in the RAM-mirror range, which is not emulated), `2000h..3FFFh` = raw CHR-ROM, `4000h..5FFFh` = CGA CHR tiles, `8000h..FFFFh` = 32 KB PRG-ROM. |
| **O(1) Address Translation** | `ES` (`xlate_seg`) | 64 KB segment mapping `(addr6502 << 1)` $\rightarrow$ native `CS` offset (`loc_XXXX`) for `hle_rts` and `dispatch_indirect`. |

---

## 3. PPU High-Level Virtualization (`cga_runtime.asm`)

- **Memory-Mapped Traps**: Reads/writes to `$2000–$2007`, `$4014` (OAM DMA), and `$4016` (Joypad) are intercepted at compile time (and via `hle_write_si` / `hle_sta_izy` for dynamic pointers) and routed to assembly routines in `cga_runtime.asm`.
- **Dual-Nametable & Vertical Scroll Support**:
  - `vram_nametable` stores both Nametable 0 (`$2000..$23BF` at offset `0..959`) and Nametable 2 (`$2800..$2BBF` at offset `960..1919`) contiguously.
  - `flush_dirty_tiles` computes the visible starting row from `ppu_scroll_y` (`$2005`) and `ppu_ctrl` bit 1 (`$2000`), wrapping seamlessly across the 60-row (`1920`-byte) dual-nametable buffer.
- **Decoupled 60 Hz Timer / Dirty-Tile Video Blitter**:
  - `INT 08h` programs the 8253 PIT Channel 0 to 60 Hz (`divisor = 19886 = 4DAEh`), sending PIC EOI and setting `ppu_status` bit 7 (`80h`) on every tick before checking the `in_timer_isr` re-entrancy guard.
  - Video flushes occur every `frameskip_cur` ticks. `frameskip_max` (default `3` = 20 FPS, keys `1`–`9`) is the minimum. Adaptive frameskip raises `frameskip_cur` (up to `FRAMESKIP_LIMIT` = 8) whenever ticks were dropped since the last render, and lowers it again after `FRAMESKIP_CALM` clean renders.
- **NMI catch-up**: if a 60 Hz tick arrives while the previous tick's work (render + NMI) is still running, it is dropped but remembered (`nmi_pending`); when the current NMI returns, the next one starts immediately instead of idling until the following tick. At most `NMI_CATCHUP_MAX` (1) extra NMIs per tick, so rendering still runs; games never exceed one NMI per tick on average.
- **Palette mapping**: CGA mode 4 has 4 fixed colours, so NES colours are mapped by brightness (`nes_luma`). Background palette 0's 4 colours are ranked onto black / magenta / cyan / white (attribute tables are still ignored); each sprite palette's 3 colours are ranked onto black / cyan / white, leaving magenta to the background so mid-tone playfields never swallow sprites. Maps become 256-entry byte tables (`XLAT_BG`, `XLAT_SPR` in nes_ram_seg). Background tiles are recoloured into `bg_seg` (which also holds `CGA_TILE_OFFSETS` and `SCREEN_TILE` at the same offsets) only when the background map changes; sprite pixels are translated at draw time.
- **Sprite drawing**: sprites are masked, not ORed: every non-transparent pixel (colour != 0) replaces the background (`mask = pixels != 0`, `dest = dest & ~mask | sprite`). ORing made sprites invisible over colour-3 backgrounds (e.g. Road Fighter's white road).
- **Sprite save-under**: each 8-line sprite block saves the 16 CGA bytes under it (`save_block`, buffer in its own 4 KB DOS block `save_seg`); the next render restores them newest-first (`sprite_restore`) before any tile update, instead of marking the covered tiles for repaint.
- **NMI timing**: after `$2000` bit 7 goes 0→1 the next tick skips NMI dispatch (`nmi_holdoff`), like hardware waiting for the next vblank. Without it, games that enable NMI before saving their PPUCTRL shadow (Urban Champion) could disable NMIs for good.
- **Full-redraw triggers**: everything is evaluated at render time from the current PPU state: a change in BG pattern table / sprite size (`$2000` bits 4–5) since the last render, or a scroll change the hardware scroll cannot handle (combined horizontal + vertical, or a jump larger than `HW_SCROLL_MAX` columns / `VSCROLL_MAX` rows). Mid-frame `$2000` toggles undone before the next render cost nothing, and `$2001` BG-enable toggles never repaint (the CGA screen is never blanked).
- **Hardware vertical scroll** (**off by default**, `VSCROLL_MAX equ 0`: on a Toshiba T1000 LCD it produces black 8-pixel bands, although it is correct in DOSBox; set `VSCROLL_MAX equ 12` to try it on other hardware): with no horizontal scroll, a change of up to `VSCROLL_MAX` tile rows moves the display start by 320 bytes per row (4 scanlines per bank), shifts the shadow by 32 cells per row, blanks the newly exposed scanlines (`cga_clear_lines`) and draws only the new rows. Set `VSCROLL_MAX equ 0` to disable.
- **Hardware horizontal scroll**: horizontal scroll steps of up to `HW_SCROLL_MAX` (4) columns move the 6845 display start address (`scr_origin`, bytes; the 8 KB bank is used as a ring) instead of repainting: the on-screen tile shadow is shifted, border strips cleared, new columns and the fixed HUD rows drawn. All CGA drawing adds `scr_origin` and wraps with `and 1FFFh` (slow paths `cga_tile_wrapped` / `spr_wrapped` near the ring end). Set `HW_SCROLL_MAX equ 0` to disable it if a display controller does not honour CRTC start-address changes. `cga_linearize` un-rotates the screen before dumps.
- **Inverted colours**: `invert_on` selects inverted tile blitters (`not ax`) and sprite blitters (the exact inverse of the masked sprite draw). A toggle request (key `I`, `--invert`) is applied by INT 08h between renders by NOT-ing all of video memory.

---

## 4. Keyboard Controls (`INT 09h`)

| NES Input / Function | Primary Key | Alternate Key(s) |
| :--- | :--- | :--- |
| **D-Pad Up / Down / Left / Right** | Arrow Keys | `W` / `S` / `A` / `D` |
| **A Button** | `Z` | `J` |
| **B Button** | `X` | `K` |
| **Start** | `Enter` | `Space` |
| **Select** | `Tab` | `Left Shift` or `C` |
| **Frameskip 1..9 (60 FPS .. 6.7 FPS)** | `1` – `9` | Minimum ticks per render (adaptive above it). Default is `3` (20 FPS) |
| **Invert colours** | `I` | Toggles inverted colours |
| **Exit to DOS** | `ESC` | Restores text mode & PIC/PIT vectors |

---

## 5. Automated Testing & Screenshot Verification

Passing any command-line argument to a compiled `.com` binary (e.g., `battle.com T`) runs the game for 240 ticks (4 seconds at 60 Hz), dumps the nametable, OAM, and 16 KB CGA VRAM (`0B800h:0000h..3FFFh`) to `<GAME>.DMP` (`17,664` bytes), and exits cleanly to DOS:

```powershell
& "C:\Program Files\DOSBox Staging\dosbox.exe" -noprimaryconf -nolocalconf -c "mount c d:\sandbox\nes88" -c "c:" -c "battle.com T" -c "exit"
```
Bytes `0x0500..0x44FF` of `<GAME>.DMP` contain the raw CGA Mode 4 framebuffer (even lines at `0x0000..0x1F3F`, odd lines at `0x2000..0x3F3F`, 80 bytes per scanline, 2 bits per pixel).


---

## 6. Performance Benchmark (`bench.js`)

`bench.js` measures game speed headlessly in DOSBox-X (CGA machine, 8086 core, `cycles=fixed 240` ≈ 4.77 MHz PC/XT, turbo so runs finish in seconds):

```bash
node bench.js --ref=<previous out dir> --refjson=<previous json> --out=bench_out --json=run.json game1.nes game2.nes
```

- Builds each ROM with `aot_transpiler.js --bench=<frames>` (default 1200), which adds `%ifdef BENCH` instrumentation to the runtime. Normal builds are unaffected.
- **Game frames** are counted as joypad strobes (`$4016` write of 1), or completed NMIs for games that never strobe. Scripted input (`bench_scripts.json`, per 8-char ROM name; default in `DEFAULT_BENCH_SCRIPT`) is timed in game frames, so every build plays the same frames with the same input: `gameFps` = frames ÷ emulated seconds.
- Reports `gameFps`, `renderFps`, `msPerGameFrame` (CPU time per game frame), `msPerRender` (flush + sprites), `lostTicks` (60 Hz ticks skipped because the previous ISR was still busy), and `renderErrors`: at the end the runtime renders the final state incrementally, then with a forced full repaint, and counts differing framebuffer bytes (must be 0).
- With `--ref`, it also compares final NES RAM with the reference run. NMI-driven games (e.g. SMB, Road Fighter) must match exactly; main-loop games drift by a few bytes because their state depends on timing.
- DOSBox-X `cycles` counts instructions, not true 8088 bus cycles, so results are a relative instruction-throughput proxy: code-size savings are under-represented.
- Use 8-character ROM names: the runtime builds `<NAME>.CHR`/`.DMP`/`.BEN` DOS 8.3 file names from the ROM name.
- `--invert` runs every game with inverted colours (the render check then validates the inverted blitters).
- `--profile` adds a sampling profile per game: every 60 Hz tick records the interrupted code address; samples are mapped through a NASM listing to runtime routines and 6502 subroutines (`<game>.routines.json`) and grouped into render / game code / JSR-RTS emulation / I/O traps / idle (frame wait).
- Bench stats also count hardware scroll steps (`raw.hwSteps`) and full repaints (`raw.fullRedraws`).
