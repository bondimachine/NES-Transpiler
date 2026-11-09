# NES88 — Ahead-of-Time (AOT) 6502-to-8088 Static Transpiler

**NES88** is an offline static binary transpiler and High-Level Emulation (HLE) runtime that converts NROM (Mapper 0) Nintendo Entertainment System (`.nes`) ROMs into native 16-bit Intel 8088 real-mode MS-DOS executables (`.com` + `.chr`) targeting a **4.77 MHz Intel 8088** (such as the IBM PC/XT or Toshiba T1000) with **CGA Mode 4** ($320 \times 200$, 4-color) graphics.

---

## Folder Contents

| File | Description |
| :--- | :--- |
| [`aot_transpiler.js`](aot_transpiler.js) | Node.js offline static binary transpiler. Parses `.nes` iNES ROMs, performs recursive control-flow graph (CFG) analysis, pre-converts CHR-ROM graphics into CGA interleaved format, and emits 16-bit 8086 NASM assembly (`.asm`) + binary asset package (`.chr`). |
| [`cga_runtime.asm`](cga_runtime.asm) | 16-bit x86 real-mode runtime template embedded into every transpiled game. Implements PPU HLE register virtualization (`$2000`–`$2007`, `$4014`), dirty-tile CGA Mode 4 rendering, 8x8 and 8x16 sprites with horizontal/vertical flipping, 60 Hz PIT timer interrupts (`INT 08h`), and raw XT keyboard input (`INT 09h`). |
| [`build_all_aot.bat`](build_all_aot.bat) | Batch script that transpiles and assembles all `*.nes` ROMs in the directory into `.com` and `.chr` files. |
| [`AGENT.md`](AGENT.md) | Technical reference for automated agents and developers working on the transpiler and runtime. |

---

## Requirements

- **Node.js** (v16+ recommended) to run `aot_transpiler.js`.
- **NASM** (Netwide Assembler, configured at `D:\cc65\bin\nasm.exe` in `build_all_aot.bat`) to assemble the generated `.asm` files into flat `.com` binaries.
- **MS-DOS / DOSBox / 8088 PC** with at least **192 KB** free conventional memory and CGA graphics compatibility to run the output `.com` executables.

---

## Usage

### 1. Build a Single `.nes` ROM

```powershell
# Step 1: Transpile <game>.nes into <game>.asm and <game>.chr
#         (Optional: pass --nosound to omit APU sound traps at compile time)
node transpiler/aot_transpiler.js game.nes
node transpiler/aot_transpiler.js game.nes --nosound

# Step 2: Assemble <game>.asm into a native DOS .com executable
D:\cc65\bin\nasm.exe -f bin game.asm -o game.com
```

### 2. Batch-Build All `.nes` ROMs in the Folder

Place one or more Mapper 0 `.nes` ROMs in the directory and run:

```powershell
.\transpiler\build_all_aot.bat
# Or build all ROMs without sound traps:
.\transpiler\build_all_aot.bat --nosound
```

### 3. Running a Game in DOS / DOSBox

Copy `<game>.com` and `<game>.chr` to your DOS machine or mount the directory in DOSBox:

```powershell
# Run with PC Speaker sound enabled (default):
dosbox -c "mount c ." -c "c:" -c "game.com"

# Run with PC Speaker disabled at runtime (zero PIT/speaker overhead):
dosbox -c "mount c ." -c "c:" -c "game.com --nosound"
```

> **Note:** Both `<game>.com` and `<game>.chr` must be present in the current working directory when launching the game.

---

## Controls

| NES Input / Function | Primary Key | Alternate Key(s) |
| :--- | :--- | :--- |
| **D-Pad Up / Down / Left / Right** | Arrow Keys | `W` / `S` / `A` / `D` |
| **A Button** | `Z` | `J` |
| **B Button** | `X` | `K` |
| **Start** | `Enter` | `Space` |
| **Select** | `Tab` | `Left Shift` or `C` |
| **Frameskip (`F1`–`F9` HUD)** | `1` – `9` | `1` = 60 FPS, `3` = 20 FPS (default), ..., `9` = 6.7 FPS |
| **Toggle Sound Mute** | `0` | Mutes/unmutes PC Speaker output at runtime |
| **Exit to DOS** | `ESC` | Restores 80x25 text mode, silences speaker, and restores BIOS interrupts |

The active frameskip level (`F1`–`F9`) briefly appears in the top-left CGA border for 1 second whenever keys `1`–`9` are pressed.

---

## Architecture Highlights

1. **Zero Interpreter Overhead:**
   6502 instructions are statically translated 1:1 into native 8086 instructions. Registers map directly to 8086 registers (`A` $\rightarrow$ `AL`, `X` $\rightarrow$ `BL`, `Y` $\rightarrow$ `BH`, `S` $\rightarrow$ `DI`, 6502 Carry $\rightarrow$ `DH` bit 0).
2. **Jump-Table & Overlapping-Instruction Recovery:**
   `aot_transpiler.js` automatically detects RTS-based jump engines (`PLA`/`PLA`/`JMP ($xxxx)`), split low/high ROM pointer tables, and 6502 `BIT`-skip tricks (`.db $2C` / `.db $24` overlapping instructions), emitting explicit fallthrough guards so control flow stays intact.
3. **$O(1)$ Indirect Address Translation:**
   Dynamic 6502 returns (`RTS`) and indirect jumps (`JMP ($xxxx)`) use a dedicated 64 KB lookup segment (`xlate_seg`) mapping `(addr6502 << 1)` directly to the native x86 code offset.
4. **CGA Mode 4 Dirty-Tile & Sprite Engine:**
   - **Pre-Converted CHR:** 2-bit planar NES tiles are converted offline into interleaved 2-bit-per-pixel CGA scanline words (`0B800h` even bank `0000h` / odd bank `2000h`), plus a runtime-generated horizontally flipped CHR table.
   - **Dirty-Tile Tracking:** Only modified nametable tiles and background tiles overlapped by sprites are redrawn each rendered frame.
   - **Scrolling & Mirroring:** Supports horizontal and vertical scrolling across dual nametables (`$2000`/`$2400`/`$2800`), fixed top status bars, and both `8x8` and `8x16` sprites with horizontal and vertical flipping.

