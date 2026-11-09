/**
 * AOT_TRANSPILER.JS - 6502 to 8086 Static Binary Transpiler
 * Target: MS-DOS / Intel 8088 @ 4.77 MHz (Toshiba T1000)
 * CGA Mode 4 (320x200 4-color) High-Level Virtualization
 */

const fs = require('fs');
const path = require('path');

// 6502 index registers: one of X/Y lives in BL (BH kept 0, so BX indexes memory directly),
// the other in CL (CH kept 0). Chosen per ROM by chooseIndexRegisters().
let RX8 = 'bl', RY8 = 'cl';

// Peephole fusion sets (filled per ROM): ADC/SBC addresses whose carry-in is known to come
// from an immediately preceding CLC/SEC, and the CLC/SEC addresses folded into them.
let fusedCarryOps = new Set(), foldedFlagOps = new Set();

// PLA;PLA pairs proven to discard the current routine's return address (6502 stack depth 0
// relative to the routine entry). With native CALL/RET they become a single POP of the x86
// return address. Keyed by the address of the first PLA / second PLA.
let returnDropFirst = new Set(), returnDropSecond = new Set();


// 6502 flag bits used by the liveness analysis
const F_C = 1, F_Z = 2, F_N = 4, F_V = 8, F_ALL = 15;

const opcodes = {
  0x00: { name: 'BRK', mode: 'imp', len: 1 },
  0x01: { name: 'ORA', mode: 'izx', len: 2 },
  0x05: { name: 'ORA', mode: 'zp',  len: 2 },
  0x06: { name: 'ASL', mode: 'zp',  len: 2 },
  0x08: { name: 'PHP', mode: 'imp', len: 1 },
  0x09: { name: 'ORA', mode: 'imm', len: 2 },
  0x0A: { name: 'ASL', mode: 'acc', len: 1 },
  0x0D: { name: 'ORA', mode: 'abs', len: 3 },
  0x0E: { name: 'ASL', mode: 'abs', len: 3 },
  0x10: { name: 'BPL', mode: 'rel', len: 2 },
  0x11: { name: 'ORA', mode: 'izy', len: 2 },
  0x15: { name: 'ORA', mode: 'zpx', len: 2 },
  0x16: { name: 'ASL', mode: 'zpx', len: 2 },
  0x18: { name: 'CLC', mode: 'imp', len: 1 },
  0x19: { name: 'ORA', mode: 'aby', len: 3 },
  0x1D: { name: 'ORA', mode: 'abx', len: 3 },
  0x1E: { name: 'ASL', mode: 'abx', len: 3 },
  0x20: { name: 'JSR', mode: 'abs', len: 3 },
  0x21: { name: 'AND', mode: 'izx', len: 2 },
  0x24: { name: 'BIT', mode: 'zp',  len: 2 },
  0x25: { name: 'AND', mode: 'zp',  len: 2 },
  0x26: { name: 'ROL', mode: 'zp',  len: 2 },
  0x28: { name: 'PLP', mode: 'imp', len: 1 },
  0x29: { name: 'AND', mode: 'imm', len: 2 },
  0x2A: { name: 'ROL', mode: 'acc', len: 1 },
  0x2C: { name: 'BIT', mode: 'abs', len: 3 },
  0x2D: { name: 'AND', mode: 'abs', len: 3 },
  0x2E: { name: 'ROL', mode: 'abs', len: 3 },
  0x30: { name: 'BMI', mode: 'rel', len: 2 },
  0x31: { name: 'AND', mode: 'izy', len: 2 },
  0x35: { name: 'AND', mode: 'zpx', len: 2 },
  0x36: { name: 'ROL', mode: 'zpx', len: 2 },
  0x38: { name: 'SEC', mode: 'imp', len: 1 },
  0x39: { name: 'AND', mode: 'aby', len: 3 },
  0x3D: { name: 'AND', mode: 'abx', len: 3 },
  0x3E: { name: 'ROL', mode: 'abx', len: 3 },
  0x40: { name: 'RTI', mode: 'imp', len: 1 },
  0x41: { name: 'EOR', mode: 'izx', len: 2 },
  0x45: { name: 'EOR', mode: 'zp',  len: 2 },
  0x46: { name: 'LSR', mode: 'zp',  len: 2 },
  0x48: { name: 'PHA', mode: 'imp', len: 1 },
  0x49: { name: 'EOR', mode: 'imm', len: 2 },
  0x4A: { name: 'LSR', mode: 'acc', len: 1 },
  0x4C: { name: 'JMP', mode: 'abs', len: 3 },
  0x4D: { name: 'EOR', mode: 'abs', len: 3 },
  0x4E: { name: 'LSR', mode: 'abs', len: 3 },
  0x50: { name: 'BVC', mode: 'rel', len: 2 },
  0x51: { name: 'EOR', mode: 'izy', len: 2 },
  0x55: { name: 'EOR', mode: 'zpx', len: 2 },
  0x56: { name: 'LSR', mode: 'zpx', len: 2 },
  0x58: { name: 'CLI', mode: 'imp', len: 1 },
  0x59: { name: 'EOR', mode: 'aby', len: 3 },
  0x5D: { name: 'EOR', mode: 'abx', len: 3 },
  0x5E: { name: 'LSR', mode: 'abx', len: 3 },
  0x60: { name: 'RTS', mode: 'imp', len: 1 },
  0x61: { name: 'ADC', mode: 'izx', len: 2 },
  0x65: { name: 'ADC', mode: 'zp',  len: 2 },
  0x66: { name: 'ROR', mode: 'zp',  len: 2 },
  0x68: { name: 'PLA', mode: 'imp', len: 1 },
  0x69: { name: 'ADC', mode: 'imm', len: 2 },
  0x6A: { name: 'ROR', mode: 'acc', len: 1 },
  0x6C: { name: 'JMP', mode: 'ind', len: 3 },
  0x6D: { name: 'ADC', mode: 'abs', len: 3 },
  0x6E: { name: 'ROR', mode: 'abs', len: 3 },
  0x70: { name: 'BVS', mode: 'rel', len: 2 },
  0x71: { name: 'ADC', mode: 'izy', len: 2 },
  0x75: { name: 'ADC', mode: 'zpx', len: 2 },
  0x76: { name: 'ROR', mode: 'zpx', len: 2 },
  0x78: { name: 'SEI', mode: 'imp', len: 1 },
  0x79: { name: 'ADC', mode: 'aby', len: 3 },
  0x7D: { name: 'ADC', mode: 'abx', len: 3 },
  0x7E: { name: 'ROR', mode: 'abx', len: 3 },
  0x81: { name: 'STA', mode: 'izx', len: 2 },
  0x84: { name: 'STY', mode: 'zp',  len: 2 },
  0x85: { name: 'STA', mode: 'zp',  len: 2 },
  0x86: { name: 'STX', mode: 'zp',  len: 2 },
  0x88: { name: 'DEY', mode: 'imp', len: 1 },
  0x8A: { name: 'TXA', mode: 'imp', len: 1 },
  0x8C: { name: 'STY', mode: 'abs', len: 3 },
  0x8D: { name: 'STA', mode: 'abs', len: 3 },
  0x8E: { name: 'STX', mode: 'abs', len: 3 },
  0x90: { name: 'BCC', mode: 'rel', len: 2 },
  0x91: { name: 'STA', mode: 'izy', len: 2 },
  0x94: { name: 'STY', mode: 'zpx', len: 2 },
  0x95: { name: 'STA', mode: 'zpx', len: 2 },
  0x96: { name: 'STX', mode: 'zpy', len: 2 },
  0x98: { name: 'TYA', mode: 'imp', len: 1 },
  0x99: { name: 'STA', mode: 'aby', len: 3 },
  0x9A: { name: 'TXS', mode: 'imp', len: 1 },
  0x9D: { name: 'STA', mode: 'abx', len: 3 },
  0xA0: { name: 'LDY', mode: 'imm', len: 2 },
  0xA1: { name: 'LDA', mode: 'izx', len: 2 },
  0xA2: { name: 'LDX', mode: 'imm', len: 2 },
  0xA4: { name: 'LDY', mode: 'zp',  len: 2 },
  0xA5: { name: 'LDA', mode: 'zp',  len: 2 },
  0xA6: { name: 'LDX', mode: 'zp',  len: 2 },
  0xA8: { name: 'TAY', mode: 'imp', len: 1 },
  0xA9: { name: 'LDA', mode: 'imm', len: 2 },
  0xAA: { name: 'TAX', mode: 'imp', len: 1 },
  0xAC: { name: 'LDY', mode: 'abs', len: 3 },
  0xAD: { name: 'LDA', mode: 'abs', len: 3 },
  0xAE: { name: 'LDX', mode: 'abs', len: 3 },
  0xB0: { name: 'BCS', mode: 'rel', len: 2 },
  0xB1: { name: 'LDA', mode: 'izy', len: 2 },
  0xB4: { name: 'LDY', mode: 'zpx', len: 2 },
  0xB5: { name: 'LDA', mode: 'zpx', len: 2 },
  0xB6: { name: 'LDX', mode: 'zpy', len: 2 },
  0xB8: { name: 'CLV', mode: 'imp', len: 1 },
  0xB9: { name: 'LDA', mode: 'aby', len: 3 },
  0xBA: { name: 'TSX', mode: 'imp', len: 1 },
  0xBC: { name: 'LDY', mode: 'abx', len: 3 },
  0xBD: { name: 'LDA', mode: 'abx', len: 3 },
  0xBE: { name: 'LDX', mode: 'aby', len: 3 },
  0xC0: { name: 'CPY', mode: 'imm', len: 2 },
  0xC1: { name: 'CMP', mode: 'izx', len: 2 },
  0xC4: { name: 'CPY', mode: 'zp',  len: 2 },
  0xC5: { name: 'CMP', mode: 'zp',  len: 2 },
  0xC6: { name: 'DEC', mode: 'zp',  len: 2 },
  0xC8: { name: 'INY', mode: 'imp', len: 1 },
  0xC9: { name: 'CMP', mode: 'imm', len: 2 },
  0xCA: { name: 'DEX', mode: 'imp', len: 1 },
  0xCC: { name: 'CPY', mode: 'abs', len: 3 },
  0xCD: { name: 'CMP', mode: 'abs', len: 3 },
  0xCE: { name: 'DEC', mode: 'abs', len: 3 },
  0xD0: { name: 'BNE', mode: 'rel', len: 2 },
  0xD1: { name: 'CMP', mode: 'izy', len: 2 },
  0xD5: { name: 'CMP', mode: 'zpx', len: 2 },
  0xD6: { name: 'DEC', mode: 'zpx', len: 2 },
  0xD8: { name: 'CLD', mode: 'imp', len: 1 },
  0xD9: { name: 'CMP', mode: 'aby', len: 3 },
  0xDD: { name: 'CMP', mode: 'abx', len: 3 },
  0xDE: { name: 'DEC', mode: 'abx', len: 3 },
  0xE0: { name: 'CPX', mode: 'imm', len: 2 },
  0xE1: { name: 'SBC', mode: 'izx', len: 2 },
  0xE4: { name: 'CPX', mode: 'zp',  len: 2 },
  0xE5: { name: 'SBC', mode: 'zp',  len: 2 },
  0xE6: { name: 'INC', mode: 'zp',  len: 2 },
  0xE8: { name: 'INX', mode: 'imp', len: 1 },
  0xE9: { name: 'SBC', mode: 'imm', len: 2 },
  0xEA: { name: 'NOP', mode: 'imp', len: 1 },
  0xEC: { name: 'CPX', mode: 'abs', len: 3 },
  0xED: { name: 'SBC', mode: 'abs', len: 3 },
  0xEE: { name: 'INC', mode: 'abs', len: 3 },
  0xF0: { name: 'BEQ', mode: 'rel', len: 2 },
  0xF1: { name: 'SBC', mode: 'izy', len: 2 },
  0xF5: { name: 'SBC', mode: 'zpx', len: 2 },
  0xF6: { name: 'INC', mode: 'zpx', len: 2 },
  0xF8: { name: 'SED', mode: 'imp', len: 1 },
  0xF9: { name: 'SBC', mode: 'aby', len: 3 },
  0xFD: { name: 'SBC', mode: 'abx', len: 3 },
  0xFE: { name: 'INC', mode: 'abx', len: 3 }
};

function convertTile(plane0, plane1) {
  const evenBytes = [];
  const oddBytes = [];

  for (let y = 0; y < 8; y++) {
    const p0 = plane0[y];
    const p1 = plane1[y];
    let b0 = 0; // pixels 0..3
    let b1 = 0; // pixels 4..7

    for (let px = 0; px < 4; px++) {
      const bit = 7 - px;
      const col = ((p0 >> bit) & 1) | (((p1 >> bit) & 1) << 1);
      b0 = (b0 << 2) | col;
    }

    for (let px = 4; px < 8; px++) {
      const bit = 7 - px;
      const col = ((p0 >> bit) & 1) | (((p1 >> bit) & 1) << 1);
      b1 = (b1 << 2) | col;
    }

    if ((y & 1) === 0) {
      evenBytes.push(b0, b1);
    } else {
      oddBytes.push(b0, b1);
    }
  }

  return Buffer.from([...evenBytes, ...oddBytes]);
}

function convertChr(chrBuf) {
  const numTiles = Math.floor(chrBuf.length / 16);
  const outBuf = Buffer.alloc(8192);

  for (let i = 0; i < Math.min(numTiles, 512); i++) {
    const tileOffset = i * 16;
    const plane0 = chrBuf.subarray(tileOffset, tileOffset + 8);
    const plane1 = chrBuf.subarray(tileOffset + 8, tileOffset + 16);
    const converted = convertTile(plane0, plane1);
    converted.copy(outBuf, i * 16);
  }

  return outBuf;
}

function transpileRom(romPath, noSound = false, bench = false) {
  console.log(`\n============================================================`);
  console.log(`Transpiling: ${romPath}${noSound ? ' (--nosound)' : ''}${bench ? ` (--bench ${bench} frames)` : ''}`);
  console.log(`============================================================`);

  const rom = fs.readFileSync(romPath);
  const prgUnits = rom[4];
  const chrUnits = rom[5];
  const f6 = rom[6];
  const f7 = rom[7];
  const mapper = ((f6 >> 4) & 0x0F) | (f7 & 0xF0);
  const mirror = (f6 & 1) ? 'Vertical' : 'Horizontal';

  console.log(`PRG: ${prgUnits}x16KB, CHR: ${chrUnits}x8KB, Mapper: ${mapper}, Mirroring: ${mirror}`);

  const prgOffset = 16;
  const prgSize = prgUnits * 16384;
  const prg = rom.subarray(prgOffset, prgOffset + prgSize);
  const baseAddr = prgUnits === 1 ? 0xC000 : 0x8000;

  // Build 32KB PRG-ROM image for DS:8000h..FFFFh (mirrors 16KB NROM-128 at both 8000h and C000h)
  const prg32k = Buffer.alloc(32768);
  if (prgUnits === 1) {
    prg.copy(prg32k, 0, 0, 16384);
    prg.copy(prg32k, 16384, 0, 16384);
  } else {
    prg.copy(prg32k, 0, 0, 32768);
  }

  // Raw 8KB CHR-ROM and Pre-converted 8KB CGA CHR
  const rawChr8k = Buffer.alloc(8192);
  let chrConverted;
  if (chrUnits > 0) {
    const chrOffset = prgOffset + prgSize;
    const chr = rom.subarray(chrOffset, chrOffset + 8192);
    chr.copy(rawChr8k, 0, 0, Math.min(chr.length, 8192));
    chrConverted = convertChr(chr);
  } else {
    chrConverted = Buffer.alloc(8192);
  }

  const baseName = path.basename(romPath, path.extname(romPath));
  const chrFileName = `${baseName.toUpperCase()}.CHR`;
  const combinedData = Buffer.concat([prg32k, rawChr8k, chrConverted]);
  fs.writeFileSync(`${baseName}.chr`, combinedData);
  console.log(`Wrote ROM+CHR package: ${baseName}.chr (${combinedData.length} bytes)`);

  function readByte(addr) {
    if (addr < baseAddr || addr >= 0x10000) return 0;
    return prg[addr - baseAddr];
  }

  function readWord(addr) {
    return readByte(addr) | (readByte(addr + 1) << 8);
  }

  const nmiVec = readWord(0xFFFA);
  const resetVec = readWord(0xFFFC);
  const irqVec = readWord(0xFFFE);

  console.log(`Vectors: RESET=$${resetVec.toString(16).toUpperCase()}, NMI=$${nmiVec.toString(16).toUpperCase()}, IRQ=$${irqVec.toString(16).toUpperCase()}`);

  // Detect JumpEngine routines (routines that pop return address via PLA..PLA and end with JMP (ind))
  const jumpEngines = new Set();
  for (let i = 0; i < prg.length - 20; i++) {
    let pla = 0, pha = 0;
    for (let p = i; p < i + 40; p++) {
      if (prg[p] === 0x68) pla++;
      if (prg[p] === 0x48) pha++;
      if (prg[p] === 0x6C) {
        if (pla >= 2 && pha === 0) jumpEngines.add(baseAddr + i);
        break;
      }
      if (prg[p] === 0x60 || prg[p] === 0x40 || prg[p] === 0x4C) break;
    }
  }

  // Enhanced Iterative CFG & Jump-Table Traversal
  const visited = new Set();
  const dataBytes = new Set();
  const jumpTableTargets = new Set([resetVec, nmiVec, irqVec]);
  const queue = [resetVec, nmiVec, irqVec];

  function isValidTarget(t) {
    if (t < baseAddr || t >= 0xFFFA) return false;
    if (dataBytes.has(t) && !jumpTableTargets.has(t)) return false;
    return !!opcodes[readByte(t)];
  }

  let rtsMinus1Tables = 0;
  // Plausible code start: the next few instructions all decode (no BRK, stays in ROM)
  function plausibleCode(t) {
    let p = t;
    for (let k = 0; k < 6; k++) {
      if (!isValidTarget(p) || readByte(p) === 0x00) return false;
      const inf = opcodes[readByte(p)];
      if (inf.name === 'RTS' || inf.name === 'JMP' || inf.name === 'RTI') return true;
      p += inf.len;
    }
    return true;
  }

  // skipInvalid: keep scanning past words that are not code addresses (tables shared with
  // other data), accepting only entries that decode as plausible code
  function addTable(addr, isRtsMinus1 = false, maxEntries = 64, skipInvalid = false) {
    if (isRtsMinus1) rtsMinus1Tables++;
    for (let k = 0; k < maxEntries; k++) {
      const p = addr + k * 2;
      if (p >= 0xFFFA || visited.has(p) || jumpTableTargets.has(p)) break;
      let w = readWord(p);
      if (w === 0 && k === 0) continue; // e.g. 1942 task 0 slot is 0000h
      if (isRtsMinus1) w = (w + 1) & 0xFFFF;
      if (skipInvalid) {
        if (!plausibleCode(w)) continue;
      } else if (!isValidTarget(w)) break;
      dataBytes.add(p);
      dataBytes.add(p + 1);
      dataBytes.delete(w);
      jumpTableTargets.add(w);
      if (!visited.has(w)) queue.push(w);
    }
  }

  let changed = true;
  while (changed) {
    changed = false;
    while (queue.length > 0) {
      let pc = queue.pop();
      while (pc >= baseAddr && pc < 0xFFFA && !visited.has(pc) && (!dataBytes.has(pc) || jumpTableTargets.has(pc))) {
        const op = readByte(pc);
        const info = opcodes[op];
        if (!info) break;
        visited.add(pc);
        changed = true;

        if (info.name === 'JMP') {
          if (info.mode === 'abs') {
            const target = readWord(pc + 1);
            if (isValidTarget(target)) queue.push(target);
          }
          break;
        } else if (info.name === 'JSR') {
          const target = readWord(pc + 1);
          if (isValidTarget(target)) queue.push(target);
          if (jumpEngines.has(target)) {
            addTable(pc + 3, false, 64);
            break;
          }
          jumpTableTargets.add(pc + 3);
          pc += info.len;
        } else if (info.mode === 'rel') {
          let offset = readByte(pc + 1);
          if (offset >= 128) offset -= 256;
          const target = pc + 2 + offset;
          if (isValidTarget(target)) queue.push(target);
          pc += info.len;
        } else if (info.name === 'RTS' || info.name === 'RTI' || info.name === 'BRK') {
          break;
        } else {
          pc += info.len;
        }
      }
    }

    // Scan visited instructions for ROM word-table loads
    for (const pc of Array.from(visited)) {
      const op = readByte(pc);
      // Pattern B: LDA abs,X/Y (BD/B9) ... LDA abs+1,X/Y (BD/B9)
      if (op === 0xBD || op === 0xB9) {
        const t1 = readWord(pc + 1);
        for (let d = 4; d <= 8; d++) {
          if (readByte(pc + d) === op && readWord(pc + d + 1) === t1 + 1 && t1 >= baseAddr) {
            const isRts = (readByte(pc + 3) === 0x91); // e.g. 1942 task stack setup STA ($88),Y
            addTable(t1, isRts, 32);
          }
        }
      }
      // Pattern D: LDA tbl,Y/X ... INY/INX ... LDA tbl,Y/X (same table, index bumped in
      // between), e.g. Excitebike: LDA $C000,Y; STA $00; INY; LDA $C000,Y; STA $01; JMP ($0000)
      if (op === 0xBD || op === 0xB9) {
        const t1 = readWord(pc + 1);
        const inc = op === 0xB9 ? 0xC8 : 0xE8;
        for (let d = 3; d <= 6; d++) {
          if (readByte(pc + d) === inc && readByte(pc + d + 1) === op && readWord(pc + d + 2) === t1 && t1 >= baseAddr) {
            addTable(t1, false, 64, true);
          }
        }
      }
      // Pattern C: LDA abs (AD) STA zp (85) LDA abs+1 (AD) STA zp+1 (85)
      if (op === 0xAD && readByte(pc + 3) === 0x85 && readByte(pc + 5) === 0xAD && readByte(pc + 8) === 0x85) {
        const p1 = readWord(pc + 1), p2 = readWord(pc + 6);
        if (p2 === p1 + 1 && p1 >= baseAddr) {
          const ptr = readWord(p1);
          if (ptr >= baseAddr) addTable(ptr === p1 ? p1 + 2 : ptr, false, 32);
        }
      }
    }
  }

  console.log(`Discovered ${visited.size} reachable instructions across PRG ROM`);

  // Generate NASM Output
  let out = `; ==============================================================================
; NES88 AOT Transpiled Binary: ${baseName}.nes
; Architecture: Intel 8088 / MS-DOS Real Mode (CGA Mode 4 320x200)
; ==============================================================================
${bench ? `%define BENCH 1\nBENCH_FRAMES equ ${bench}\nBENCH_MAX_TICKS equ ${Math.min(60000, bench * 20)}\n` : ''}org 100h
cpu 8086
;@INDEX_REGISTERS@

start:
    mov sp, 0FFFEh
    call runtime_init

    ; Initialize 6502 CPU registers & segments
    xor ax, ax              ; A = 0
    xor bx, bx              ; X/Y = 0 (BH = 0 invariant)
    xor cx, cx              ; Y/X = 0 (CH = 0 invariant)
    xor dx, dx              ; DH = 0 invariant
    mov ds, [cs:nes_ram_seg]
    mov es, [cs:xlate_seg]
    mov di, 01FDh           ; 6502 Stack Pointer in DS ($0100..$01FF)

    ; Start execution at RESET vector
    jmp loc_${resetVec.toString(16).toUpperCase()}

loc_unhandled:
    jmp hle_rts

; ------------------------------------------------------------------------------
; 6502 TRANSLATED CODE SECTION
; ------------------------------------------------------------------------------
`;

  const sortedAddresses = Array.from(visited).sort((a, b) => a - b);

  // Give BX to whichever index register makes the reachable code cheaper (extra x86
  // instructions per access under each assignment, counted statically)
  {
    const costXinBx = { aby: 1, zpx: 3, izx: 4, zpy: 4, izy: 2 };
    const costYinBx = { abx: 1, zpx: 4, izx: 5, zpy: 3 };
    let cx = 0, cy = 0;
    for (const pc of sortedAddresses) {
      const m = opcodes[readByte(pc)].mode;
      cx += costXinBx[m] || 0;
      cy += costYinBx[m] || 0;
    }
    // X-indexed accesses (object tables) tend to be hotter than their static count, so Y
    // only gets BX when that is clearly cheaper (measured on the bench ROMs)
    [RX8, RY8] = cy * 3 < cx ? ['cl', 'bl'] : ['bl', 'cl'];
    if (forceIndexRegs === 'x') [RX8, RY8] = ['bl', 'cl'];   // --index-regs=x: X in BX
    if (forceIndexRegs === 'y') [RX8, RY8] = ['cl', 'bl'];   // --index-regs=y: Y in BX
    console.log(`Index registers: X=${RX8.toUpperCase()}, Y=${RY8.toUpperCase()} (static cost ${Math.min(cx, cy)} vs ${Math.max(cx, cy)})`);
    // Tell the runtime helpers (joypad index reads, STA (zp),Y) which register is which
    out = out.replace(';@INDEX_REGISTERS@',
      `%define REG_X ${RX8}\n%define REG_Y ${RY8}\n%define REG_Y16 ${RY8 === 'bl' ? 'bx' : 'cx'}`);
  }

  // 6502 stack depth of each instruction relative to the entry of the subroutine that
  // contains it (JSR targets; JSR itself is depth-neutral). null = unknown/conflicting.
  const stackDepth = computeStackDepths();
  function computeStackDepths() {
    const depth = new Map();
    const entries = new Set();
    for (const pc of sortedAddresses) {
      const info = opcodes[readByte(pc)];
      if (info.name === 'JSR' && !jumpEngines.has(readWord(pc + 1))) entries.add(readWord(pc + 1));
    }
    const work = [];
    for (const e of entries) if (visited.has(e)) work.push([e, 0]);
    while (work.length) {
      const [pc, d] = work.pop();
      if (!visited.has(pc)) continue;
      if (depth.has(pc)) {
        if (depth.get(pc) !== d && depth.get(pc) !== null) { depth.set(pc, null); }
        else continue;
      } else depth.set(pc, d);
      const cur = depth.get(pc);
      const info = opcodes[readByte(pc)];
      const nd = cur === null ? null : cur + (info.name === 'PHA' || info.name === 'PHP' ? 1 : (info.name === 'PLA' || info.name === 'PLP' ? -1 : 0));
      const next = [];
      if (info.name === 'JMP') { if (info.mode === 'abs') next.push(readWord(pc + 1)); }
      else if (info.name === 'JSR') { if (!jumpEngines.has(readWord(pc + 1))) next.push(pc + 3); }
      else if (info.name === 'RTS' || info.name === 'RTI' || info.name === 'BRK') { /* leaves */ }
      else if (info.mode === 'rel') {
        let off = readByte(pc + 1);
        if (off >= 128) off -= 256;
        next.push(pc + 2 + off, pc + 2);
      } else next.push(pc + info.len);
      for (const t of next) {
        if (nd === null) { if (depth.get(t) !== null) work.push([t, null]); }
        else if (depth.get(t) !== nd) work.push([t, nd]);
      }
    }
    // A conflict must also poison everything downstream: re-propagate nulls
    return new Map([...depth].map(([k, v]) => [k, v]));
  }

  // Returns descriptions of code patterns that read or forge return addresses on the
  // 6502 stack (incompatible with native CALL/RET).
  function detectStackTricks() {
    const found = [];
    if (rtsMinus1Tables > 0) found.push('RTS-1 address tables');
    for (let i = 0; i < sortedAddresses.length; i++) {
      const pc = sortedAddresses[i];
      const info = opcodes[readByte(pc)];
      // TSX then stack-page indexing ($0100..$01FF,X) shortly after: reading/patching return
      // addresses (plain $01xx,X loops such as RAM clears are fine)
      if (info.mode === 'abx' && readWord(pc + 1) >= 0x0100 && readWord(pc + 1) <= 0x01FF) {
        for (let k = i - 1; k >= 0 && k >= i - 8; k--) {
          if (opcodes[readByte(sortedAddresses[k])].name === 'TSX') {
            found.push(`TSX stack access at $${pc.toString(16).toUpperCase()}`);
            break;
          }
        }
      }
      // PLA; PLA: discards a return address (e.g. to return two levels up). Fine for native
      // CALL/RET when provably at routine stack depth 0 (translated to POP), a trick otherwise.
      if (info.name === 'PLA' && readByte(pc + 1) === 0x68 && visited.has(pc + 1)) {
        if (stackDepth.get(pc) === 0) {
          returnDropFirst.add(pc);
          returnDropSecond.add(pc + 1);
        } else {
          found.push(`PLA;PLA return-address pop at $${pc.toString(16).toUpperCase()}`);
        }
      }
      // PHA, PHA ... RTS in straight-line code: pushed-address dispatch
      if (info.name === 'RTS') {
        let p = pc, pushes = 0;
        for (let k = i - 1; k >= 0 && k >= i - 6; k--) {
          const prev = sortedAddresses[k];
          const pi = opcodes[readByte(prev)];
          if (prev + pi.len !== p) break;
          if (pi.name === 'PHA') pushes++;
          if (pi.name === 'PLA' || pi.name === 'JSR' || pi.name === 'JMP' || pi.name === 'RTS' || pi.mode === 'rel') break;
          p = prev;
        }
        if (pushes >= 2) found.push(`push-and-RTS dispatch at $${pc.toString(16).toUpperCase()}`);
      }
      if (found.length >= 4) break;
    }
    return found;
  }
  const definedLabels = new Set(sortedAddresses);

  // Global flag liveness (backward dataflow over the CFG): for each instruction, which 6502
  // flags may be read after it before being overwritten. Lets the code generator skip
  // flag fix-ups (NZ tests, CMC, carry save/restore) whose result is never observed.
  // Subroutine boundaries are conservative: JSR, RTS, RTI and indirect jumps see all flags live.
  const liveOut = computeFlagLiveness();

  // CLC; ADC -> ADD and SEC; SBC -> SUB when the ADC/SBC cannot be reached any other way
  {
    const targets = new Set([resetVec, nmiVec, irqVec, ...jumpTableTargets]);
    for (const pc of sortedAddresses) {
      const info = opcodes[readByte(pc)];
      if (info.mode === 'rel') {
        let off = readByte(pc + 1);
        if (off >= 128) off -= 256;
        targets.add(pc + 2 + off);
      } else if ((info.name === 'JMP' && info.mode === 'abs') || info.name === 'JSR') {
        targets.add(readWord(pc + 1));
        if (info.name === 'JSR') targets.add(pc + 3);
      }
    }
    fusedCarryOps = new Set();
    foldedFlagOps = new Set();
    for (const pc of sortedAddresses) {
      const nm = opcodes[readByte(pc)].name;
      if ((nm === 'CLC' || nm === 'SEC') && visited.has(pc + 1) && !targets.has(pc + 1)) {
        const next = opcodes[readByte(pc + 1)].name;
        if ((nm === 'CLC' && next === 'ADC') || (nm === 'SEC' && next === 'SBC')) {
          fusedCarryOps.add(pc + 1);
          foldedFlagOps.add(pc);
        }
      }
    }
    console.log(`Peephole: fused ${fusedCarryOps.size} CLC/ADC and SEC/SBC pairs`);

  }

  function flagUseDef(info) {
    const n = info.name;
    switch (n) {
      case 'ADC': case 'SBC': return { use: F_C, def: F_C | F_Z | F_N | F_V };
      case 'CMP': case 'CPX': case 'CPY': return { use: 0, def: F_C | F_Z | F_N };
      case 'ASL': case 'LSR': return { use: 0, def: F_C | F_Z | F_N };
      case 'ROL': case 'ROR': return { use: F_C, def: F_C | F_Z | F_N };
      case 'AND': case 'ORA': case 'EOR':
      case 'LDA': case 'LDX': case 'LDY': case 'TAX': case 'TAY': case 'TXA': case 'TYA':
      case 'TSX': case 'PLA': case 'INC': case 'DEC': case 'INX': case 'INY': case 'DEX': case 'DEY':
        return { use: 0, def: F_Z | F_N };
      case 'BIT': return { use: 0, def: F_Z | F_N | F_V };
      case 'CLC': case 'SEC': return { use: 0, def: F_C };
      case 'BEQ': case 'BNE': return { use: F_Z, def: 0 };
      case 'BMI': case 'BPL': return { use: F_N, def: 0 };
      case 'BCC': case 'BCS': return { use: F_C, def: 0 };
      case 'BVC': case 'BVS': return { use: F_V, def: 0 };
      case 'PHP': return { use: F_ALL, def: 0 };
      case 'PLP': return { use: 0, def: F_ALL };
      default: return { use: 0, def: 0 };
    }
  }

  function computeFlagLiveness() {
    const succs = new Map();
    const preds = new Map();
    const fixedIn = new Map();     // Instructions whose live-in is forced to F_ALL
    for (const pc of sortedAddresses) preds.set(pc, []);
    for (const pc of sortedAddresses) {
      const info = opcodes[readByte(pc)];
      let s = [];
      let opaque = false;          // Control leaves to code we cannot see
      if (info.name === 'JMP') {
        if (info.mode === 'abs') s = [readWord(pc + 1)]; else opaque = true;
      } else if (info.name === 'JSR' || info.name === 'RTS' || info.name === 'RTI' || info.name === 'BRK') {
        fixedIn.set(pc, true);
      } else if (info.mode === 'rel') {
        let off = readByte(pc + 1);
        if (off >= 128) off -= 256;
        s = [pc + 2 + off, pc + 2];
      } else {
        s = [pc + info.len];
      }
      if (s.some(t => !visited.has(t))) opaque = true;
      succs.set(pc, { list: s.filter(t => visited.has(t)), opaque });
      for (const t of s) if (preds.has(t)) preds.get(t).push(pc);
    }
    const liveIn = new Map();
    const out = new Map();
    for (const pc of sortedAddresses) { liveIn.set(pc, F_ALL); out.set(pc, F_ALL); }
    // Start optimistic (nothing live) for analysable instructions, then iterate to fixpoint
    for (const pc of sortedAddresses) if (!fixedIn.has(pc)) { liveIn.set(pc, 0); out.set(pc, 0); }
    const work = [...sortedAddresses].reverse();
    const inWork = new Set(work);
    while (work.length) {
      const pc = work.pop();
      inWork.delete(pc);
      if (fixedIn.has(pc)) continue;
      const sc = succs.get(pc);
      let o = sc.opaque ? F_ALL : 0;
      for (const t of sc.list) o |= liveIn.get(t);
      const { use, def } = flagUseDef(opcodes[readByte(pc)]);
      const i = use | (o & ~def);
      out.set(pc, o);
      if (i !== liveIn.get(pc)) {
        liveIn.set(pc, i);
        for (const p of preds.get(pc)) if (!inWork.has(p)) { work.push(p); inWork.add(p); }
      }
    }
    return out;
  }

  // Native x86 CALL/RET for JSR/RTS is much cheaper than emulating the 6502 return stack,
  // but breaks code that manipulates return addresses. Use it for large ROMs (needed to
  // fit 64 KB) and for any ROM where no return-address trick is detected.
  returnDropFirst = new Set();
  returnDropSecond = new Set();
  const stackTricks = detectStackTricks();
  const useCompactJsr = visited.size >= 8000 || stackTricks.length === 0;
  console.log(useCompactJsr
    ? `JSR/RTS: native CALL/RET${stackTricks.length ? ` (forced by size despite: ${stackTricks.join('; ')})` : ''}`
    : `JSR/RTS: emulated 6502 stack (${stackTricks.join('; ')})`);
  if (!useCompactJsr) {
    returnDropFirst = new Set();     // Emulated stack: PLA;PLA works as written
    returnDropSecond = new Set();
  } else if (returnDropFirst.size) {
    console.log(`JSR/RTS: ${returnDropFirst.size} PLA;PLA return-address drop(s) translated to POP`);
  }
  out = out.replace('loc_unhandled:\n    jmp hle_rts', `loc_unhandled:\n    ${useCompactJsr ? 'ret' : 'jmp hle_rts'}`);

  // Benchmark-only: detect 6502 idle (wait-for-frame) loops that only poll RAM, so the
  // runtime can measure idle time and count game frames (one per loop exit).
  const idleHeads = new Set();
  const idleExits = new Set();
  if (bench) {
    const pollOps = new Set(['LDA', 'LDX', 'LDY', 'CMP', 'CPX', 'CPY', 'AND', 'ORA', 'EOR', 'BIT']);
    for (const pc of sortedAddresses) {
      const info = opcodes[readByte(pc)];
      if (info.name === 'JMP' && info.mode === 'abs' && readWord(pc + 1) === pc) {
        idleHeads.add(pc);
        continue;
      }
      if (info.mode !== 'rel') continue;
      let off = readByte(pc + 1);
      if (off >= 128) off -= 256;
      const head = pc + 2 + off;
      if (head > pc || pc - head > 12) continue;
      let p = head, ok = true;
      while (p < pc) {
        const ii = opcodes[readByte(p)];
        if (!ii || !visited.has(p) || !pollOps.has(ii.name)) { ok = false; break; }
        if (ii.mode === 'zp') { /* RAM */ }
        else if (ii.mode === 'abs') { if (readWord(p + 1) >= 0x0800) { ok = false; break; } }
        else if (ii.mode !== 'imm') { ok = false; break; }
        p += ii.len;
      }
      if (ok && p === pc && head < pc) {
        idleHeads.add(head);
        idleExits.add(pc);
      }
    }
    console.log(`Bench: ${idleHeads.size} idle loops instrumented`);
  }

  const noFallthroughOps = new Set(['JMP', 'RTS', 'RTI', 'BRK']);
  let overlapFixCount = 0;
  for (let idx = 0; idx < sortedAddresses.length; idx++) {
    const pc = sortedAddresses[idx];
    const op = readByte(pc);
    const info = opcodes[op];
    out += `\nloc_${pc.toString(16).toUpperCase()}:\n`;
    if (!info) {
      out += useCompactJsr ? `    ret\n` : `    jmp hle_rts\n`;
      continue;
    }
    const flagsLive = liveOut.get(pc);
    if (idleHeads.has(pc)) out += `    call bench_idle_enter\n`;
    out += translateInstruction(pc, op, info, readByte, readWord, baseAddr, definedLabels, flagsLive, jumpEngines, useCompactJsr, noSound);
    if (idleExits.has(pc)) out += `    call bench_idle_exit\n`;
    const nextSeq = pc + info.len;
    if (!noFallthroughOps.has(info.name) && sortedAddresses[idx + 1] !== nextSeq && definedLabels.has(nextSeq)) {
      out += `    jmp loc_${nextSeq.toString(16).toUpperCase()}\n`;
      overlapFixCount++;
    }
  }
  if (overlapFixCount > 0) {
    console.log(`Fixed ${overlapFixCount} overlapping instruction fallthroughs (e.g. BIT-skip tricks)`);
  }

  // Collect all valid indirect/return targets for xlate_seg initialization
  const validIndirectTargets = new Set();
  for (const t of jumpTableTargets) {
    if (definedLabels.has(t)) validIndirectTargets.add(t);
  }
  // Exhaustive scan: any ROM word that points at translated code may be an indirect jump
  // target. Skipped only for large ROMs, where the 4-byte table entries would not fit in 64 KB.
  // (Independent of JSR mode: native CALL/RET still needs these for JMP (ind) dispatch.)
  if (visited.size < 8000) {
    for (let i = 0; i < prgSize - 1; i++) {
      const w = readWord(baseAddr + i);
      if (definedLabels.has(w)) validIndirectTargets.add(w);
      if (definedLabels.has(w + 1)) validIndirectTargets.add(w + 1);
    }
  }

  const indirectList = Array.from(validIndirectTargets).sort((a, b) => a - b);
  let jumpTableAsm = `indirect_jump_count: dw ${indirectList.length}\nindirect_jump_table:\n`;
  if (indirectList.length === 0) {
    jumpTableAsm += `    dw 0, 0\n`;
  } else {
    for (const t of indirectList) {
      jumpTableAsm += `    dw 0${t.toString(16).toUpperCase()}h, loc_${t.toString(16).toUpperCase()}\n`;
    }
  }

  // Append CGA Runtime
  const runtimeAsm = fs.readFileSync(path.join(__dirname, 'cga_runtime.asm'), 'utf8');
  let cleanedRuntime = runtimeAsm
    .replace("rom_filename:       db 'GAME.CHR', 0", `rom_filename:       db '${chrFileName}', 0`)
    .replace("dump_filename:      db 'DUMP.BIN', 0", `dump_filename:      db '${baseName.toUpperCase()}.DMP', 0`)
    .replace("bench_filename:     db 'BENCH.BEN', 0", `bench_filename:     db '${baseName.toUpperCase()}.BEN', 0`)
    .replace("bench_script:       dw 0FFFFh", `bench_script:\n${benchScriptAsm(benchScript)}    dw 0FFFFh`)
    .replace('nmi_vector_dispatch:\n    ret', `nmi_vector_dispatch:\n    jmp loc_${nmiVec.toString(16).toUpperCase()}`)
    .replace('indirect_jump_count: dw 0\nindirect_jump_table: dw 0', jumpTableAsm);
  if (noSound) {
    cleanedRuntime = cleanedRuntime.replace('sound_enabled:      db 1', 'sound_enabled:      db 0');
  }
  if (bench && !out.includes('call hle_write_4016')) {
    console.log('Bench: no $4016 strobe found, counting NMIs as game frames');
    out = '%define BENCH_NMI_FRAMES 1\n' + out;
  }
  out += '\n' + cleanedRuntime;

  const outAsmFile = `${baseName}.asm`;
  fs.writeFileSync(outAsmFile, out);
  if (bench) {
    // Routine entry points (for the bench profiler to attribute samples to 6502 subroutines)
    const entries = new Set([resetVec, nmiVec, irqVec, ...jumpTableTargets]);
    for (const pc of sortedAddresses) {
      const info = opcodes[readByte(pc)];
      if (info.name === 'JSR') entries.add(readWord(pc + 1));
    }
    fs.writeFileSync(`${baseName}.routines.json`, JSON.stringify({
      reset: resetVec, nmi: nmiVec, entries: [...entries].filter(e => definedLabels.has(e)).sort((x, y) => x - y)
    }));
  }
  console.log(`Generated NASM assembly: ${outAsmFile} (${(out.length / 1024).toFixed(1)} KB, ${indirectList.length} xlate targets)`);

  return outAsmFile;
}

// Bench input script: comma-separated "first-end:buttons[/period:on]" entries (frames, hex
// buttons: 01=A 02=B 04=Select 08=Start 10=Up 20=Down 40=Left 80=Right; period power of 2).
const DEFAULT_BENCH_SCRIPT = '30-40:08,90-100:08,150-65535:82,150-65535:01/32:8';
function benchScriptAsm(script) {
  let s = '';
  for (const e of script.split(',')) {
    const m = e.trim().match(/^(\d+)-(\d+):([0-9a-fA-F]{1,2})(?:\/(\d+):(\d+))?$/);
    if (!m) throw new Error(`Bad bench script entry: ${e}`);
    const period = m[4] ? parseInt(m[4], 10) : 0;
    if (period && (period & (period - 1))) throw new Error(`Bench script period must be a power of 2: ${e}`);
    s += `    dw ${m[1]}, ${m[2]}\n    db 0${m[3]}h, ${period ? period - 1 : 0}, ${period ? m[5] : 1}\n`;
  }
  return s;
}

function translateInstruction(pc, op, info, readByte, readWord, baseAddr, definedLabels, flagsLive, jumpEngines, useCompactJsr, noSound = false) {
  let s = '';
  const carryLive = (flagsLive & F_C) !== 0;
  const nzLive = (flagsLive & (F_Z | F_N)) !== 0;
  const name = info.name;
  const mode = info.mode;

  function imm8() { return '0' + readByte(pc + 1).toString(16).toUpperCase().padStart(2, '0') + 'h'; }
  function zp8() { return '0' + readByte(pc + 1).toString(16).toUpperCase().padStart(2, '0') + 'h'; }
  function abs16() { return '0' + readWord(pc + 1).toString(16).toUpperCase().padStart(4, '0') + 'h'; }
  function absVal() { return readWord(pc + 1); }

  function getLabel(addr) {
    if (definedLabels.has(addr)) return `loc_${addr.toString(16).toUpperCase()}`;
    return 'loc_unhandled';
  }

  // Flag-setting helper for loads/transfers: sets ZF and SF while preserving CF when live
  function setNZ(reg) {
    if (!nzLive) return '';
    if (carryLive) return `    inc ${reg}\n    dec ${reg}\n`;
    return `    test ${reg}, ${reg}\n`;
  }

  function cmcIfLive() { return carryLive ? `    cmc\n` : ''; }

  // Effective address computation without touching flags. X and Y live in BL/CL (or CL/BL,
  // chosen per ROM); the one held in BX (BH = 0) indexes memory directly, the other is
  // copied to SI. Zero-page indexing wraps within page 0 like the 6502.
  // Returns { pre, mem, post }: post (if any) must follow the instruction using mem.
  function loadEA(m) {
    const xInBx = RX8 === 'bl';
    const isX = m === 'abx' || m === 'zpx' || m === 'izx';
    const inBx = isX === xInBx;
    if (m === 'abx' || m === 'aby') {
      return inBx ? { pre: '', mem: `[bx + ${abs16()}]`, post: '' }
                  : { pre: `    mov si, cx\n`, mem: `[si + ${abs16()}]`, post: '' };
    }
    if (m === 'zpx' || m === 'zpy' || m === 'izx') {
      const wrap = (inBx ? `    lea dx, [bx + ${zp8()}]\n` : `    mov si, cx\n    lea dx, [si + ${zp8()}]\n`) +
                   `    mov dh, 0\n    mov si, dx\n`;
      if (m === 'izx') return { pre: wrap + `    mov si, [si]\n`, mem: '[si]', post: '' };
      return { pre: wrap, mem: '[si]', post: '' };
    }
    if (m === 'izy') {
      if (inBx) return { pre: `    mov si, [${zp8()}]\n`, mem: '[bx + si]', post: '' };
      // Y is in CX: swap it into BX (XCHG leaves flags alone) around the access
      return { pre: `    mov si, [${zp8()}]\n    xchg bx, cx\n`, mem: '[bx + si]', post: `    xchg bx, cx\n` };
    }
    return { pre: '', mem: `[${abs16()}]`, post: '' };
  }

  // Helper for PPU/IO read into a register (al, bl, bh)
  function emitReadAbs(reg, a) {
    if (a < 0x2000 || a >= 0x8000) {
      return `    mov ${reg}, [${abs16()}]\n` + setNZ(reg);
    }
    if (a === 0x2002) {
      if (reg === 'al') return `    call hle_read_2002\n` + setNZ('al');
      return `    call hle_read_2002_dl\n    mov ${reg}, dl\n` + setNZ(reg);
    }
    if (a === 0x2004) {
      if (reg === 'al') return `    call hle_read_2004\n` + setNZ('al');
      return `    push ax\n    call hle_read_2004\n    mov ${reg}, al\n    pop ax\n` + setNZ(reg);
    }
    if (a === 0x2007) {
      if (reg === 'al') return `    call hle_read_2007\n` + setNZ('al');
      return `    push ax\n    call hle_read_2007\n    mov ${reg}, al\n    pop ax\n` + setNZ(reg);
    }
    if (a === 0x4015 && !noSound) {
      return `    mov ${reg}, [cs:apu_regs + 21]\n` + setNZ(reg);
    }
    if (a === 0x4016) {
      if (reg === 'al') return `    call hle_read_4016\n` + setNZ('al');
      return `    push ax\n    call hle_read_4016\n    mov ${reg}, al\n    pop ax\n` + setNZ(reg);
    }
    if (a === 0x4017) {
      return `    mov ${reg}, 0\n` + setNZ(reg);
    }
    return `    mov ${reg}, [${abs16()}]\n` + setNZ(reg);
  }

  // Helper for PPU/IO write from a register (al, bl, bh)
  function emitWriteAbs(reg, a) {
    if (a < 0x2000) {
      return `    mov [${abs16()}], ${reg}\n`;
    }
    const trapMap = {
      0x2000: 'hle_write_2000',
      0x2001: 'hle_write_2001',
      0x2003: 'hle_write_2003',
      0x2004: 'hle_write_2004',
      0x2005: 'hle_write_2005',
      0x2006: 'hle_write_2006',
      0x2007: 'hle_write_2007',
      0x4014: 'hle_write_4014',
      0x4016: 'hle_write_4016'
    };
    if (!noSound) {
      trapMap[0x4002] = 'hle_write_4002';
      trapMap[0x4003] = 'hle_write_4003';
      trapMap[0x4006] = 'hle_write_4006';
      trapMap[0x4007] = 'hle_write_4007';
      trapMap[0x400A] = 'hle_write_400A';
      trapMap[0x400B] = 'hle_write_400B';
      trapMap[0x400F] = 'hle_write_400F';
      trapMap[0x4015] = 'hle_write_4015';
    }
    const fn = trapMap[a];
    if (fn) {
      if (reg === 'al') return `    call ${fn}\n`;
      return `    push ax\n    mov al, ${reg}\n    call ${fn}\n    pop ax\n`;
    }
    if (!noSound && a >= 0x4000 && a <= 0x4015) {
      return `    mov [cs:apu_regs + ${a - 0x4000}], ${reg}\n`;
    }
    return `    ; Unmapped IO write $${a.toString(16)}\n`;
  }

  // 1. LOAD INSTRUCTIONS
  if (name === 'LDA') {
    if (mode === 'imm') s += `    mov al, ${imm8()}\n` + setNZ('al');
    else if (mode === 'zp') s += `    mov al, [${zp8()}]\n` + setNZ('al');
    else if (mode === 'abs') s += emitReadAbs('al', absVal());
    else if (mode === 'abx' && absVal() === 0x4016) {
      s += `    call hle_read_4016_x\n` + setNZ('al');
    } else if (mode === 'aby' && absVal() === 0x4016) {
      s += `    call hle_read_4016_y\n` + setNZ('al');
    } else {
      const ea = loadEA(mode);
      s += ea.pre + `    mov al, ${ea.mem}\n` + setNZ('al');
    }
  } else if (name === 'LDX') {
    if (mode === 'imm') s += `    mov ${RX8}, ${imm8()}\n` + setNZ(RX8);
    else if (mode === 'zp') s += `    mov ${RX8}, [${zp8()}]\n` + setNZ(RX8);
    else if (mode === 'abs') s += emitReadAbs(RX8, absVal());
    else {
      const ea = loadEA(mode);
      s += ea.pre + `    mov ${RX8}, ${ea.mem}\n` + setNZ(RX8);
    }
  } else if (name === 'LDY') {
    if (mode === 'imm') s += `    mov ${RY8}, ${imm8()}\n` + setNZ(RY8);
    else if (mode === 'zp') s += `    mov ${RY8}, [${zp8()}]\n` + setNZ(RY8);
    else if (mode === 'abs') s += emitReadAbs(RY8, absVal());
    else {
      const ea = loadEA(mode);
      s += ea.pre + `    mov ${RY8}, ${ea.mem}\n` + setNZ(RY8);
    }
  }

  // 2. STORE INSTRUCTIONS (Never modify flags!)
  else if (name === 'STA') {
    if (mode === 'zp') s += `    mov [${zp8()}], al\n`;
    else if (mode === 'abs') s += emitWriteAbs('al', absVal());
    else if (mode === 'zpx' || mode === 'izx') {
      const ea = loadEA(mode);
      s += ea.pre + `    mov ${ea.mem}, al\n`;
    } else if (mode === 'abx' || mode === 'aby') {
      const a = absVal();
      const ea = loadEA(mode);
      if (a < 0x1F00) {
        s += ea.pre + `    mov ${ea.mem}, al\n`;
      } else {
        s += ea.pre + `    lea si, ${ea.mem}\n    call hle_write_si\n`;
      }
    } else if (mode === 'izy') {
      s += `    mov si, [${zp8()}]\n    call hle_sta_izy\n`;
    }
  } else if (name === 'STX') {
    if (mode === 'zp') s += `    mov [${zp8()}], ${RX8}\n`;
    else if (mode === 'abs') s += emitWriteAbs(RX8, absVal());
    else {
      const ea = loadEA(mode);
      s += ea.pre + `    mov ${ea.mem}, ${RX8}\n`;
    }
  } else if (name === 'STY') {
    if (mode === 'zp') s += `    mov [${zp8()}], ${RY8}\n`;
    else if (mode === 'abs') s += emitWriteAbs(RY8, absVal());
    else {
      const ea = loadEA(mode);
      s += ea.pre + `    mov ${ea.mem}, ${RY8}\n`;
    }
  }

  // 3. ARITHMETIC & LOGIC
  else if (name === 'ADC') {
    const xop = fusedCarryOps.has(pc) ? 'add' : 'adc';     // CLC folded in
    if (mode === 'imm') s += `    ${xop} al, ${imm8()}\n`;
    else if (mode === 'zp') s += `    ${xop} al, [${zp8()}]\n`;
    else if (mode === 'abs') s += `    ${xop} al, [${abs16()}]\n`;
    else {
      const ea = loadEA(mode);
      s += ea.pre + `    ${xop} al, ${ea.mem}\n`;
    }
  } else if (name === 'SBC') {
    // 6502 carry = NOT x86 borrow: CMC in, SBB, CMC out. With SEC folded in it is a plain SUB.
    const pre = fusedCarryOps.has(pc) ? `    sub al, ` : `    cmc\n    sbb al, `;
    if (mode === 'imm') s += `${pre}${imm8()}\n` + cmcIfLive();
    else if (mode === 'zp') s += `${pre}[${zp8()}]\n` + cmcIfLive();
    else if (mode === 'abs') s += `${pre}[${abs16()}]\n` + cmcIfLive();
    else {
      const ea = loadEA(mode);
      s += ea.pre + `${pre}${ea.mem}\n` + cmcIfLive();
    }
  } else if (name === 'AND' || name === 'ORA' || name === 'EOR') {
    const xop = name === 'AND' ? 'and' : (name === 'ORA' ? 'or' : 'xor');
    const cfSave = carryLive ? `    rcr dh, 1\n` : '';
    const cfRest = carryLive ? `    rol dh, 1\n` : '';
    if (mode === 'imm') s += cfSave + `    ${xop} al, ${imm8()}\n` + cfRest;
    else if (mode === 'zp') s += cfSave + `    ${xop} al, [${zp8()}]\n` + cfRest;
    else if (mode === 'abs') s += cfSave + `    ${xop} al, [${abs16()}]\n` + cfRest;
    else {
      const ea = loadEA(mode);
      s += ea.pre + cfSave + `    ${xop} al, ${ea.mem}\n` + cfRest;
    }
  }

  // 4. COMPARISONS (6502 Carry is inverted relative to x86 borrow: CMC)
  else if (name === 'CMP') {
    if (mode === 'imm') s += `    cmp al, ${imm8()}\n` + cmcIfLive();
    else if (mode === 'zp') s += `    cmp al, [${zp8()}]\n` + cmcIfLive();
    else if (mode === 'abs') s += `    cmp al, [${abs16()}]\n` + cmcIfLive();
    else {
      const ea = loadEA(mode);
      s += ea.pre + `    cmp al, ${ea.mem}\n` + cmcIfLive();
    }
  } else if (name === 'CPX') {
    if (mode === 'imm') s += `    cmp ${RX8}, ${imm8()}\n` + cmcIfLive();
    else if (mode === 'zp') s += `    cmp ${RX8}, [${zp8()}]\n` + cmcIfLive();
    else if (mode === 'abs') s += `    cmp ${RX8}, [${abs16()}]\n` + cmcIfLive();
  } else if (name === 'CPY') {
    if (mode === 'imm') s += `    cmp ${RY8}, ${imm8()}\n` + cmcIfLive();
    else if (mode === 'zp') s += `    cmp ${RY8}, [${zp8()}]\n` + cmcIfLive();
    else if (mode === 'abs') s += `    cmp ${RY8}, [${abs16()}]\n` + cmcIfLive();
  }

  // 5. BIT TEST (Preserves AL and CF; sets ZF = (AL & mem)==0, SF = mem.7, OF = mem.6)
  else if (name === 'BIT') {
    const a = mode === 'zp' ? readByte(pc + 1) : absVal();
    const src = mode === 'zp' ? `[${zp8()}]` : `[${abs16()}]`;
    const needZ = (flagsLive & F_Z) !== 0, needN = (flagsLive & F_N) !== 0, needV = (flagsLive & F_V) !== 0;
    const cfSave = carryLive ? `    rcr dh, 1\n` : '';
    const cfRest = carryLive ? `    rol dh, 1\n` : '';
    const load = a === 0x2002 ? `    call hle_read_2002_dl\n` : `    mov dl, ${src}\n`;
    if (!needZ && !needN && !needV) {
      if (a === 0x2002) s += `    call hle_read_2002_dl\n`;   // Keep the read side effects
      else s += `    ; BIT (flags unused)\n`;
    } else if (!needV && !(needZ && needN)) {
      s += load + cfSave + (needZ ? `    test dl, al\n` : `    test dl, 80h\n`) + cfRest;
    } else if (a === 0x2002) {
      s += `    call hle_bit_2002\n`;
    } else {
      s += `    mov dl, ${src}\n    call hle_bit\n`;
    }
  }

  // 6. INCREMENT & DECREMENT (x86 inc/dec sets ZF and SF and preserves CF!)
  else if (name === 'INX') s += `    inc ${RX8}\n`;
  else if (name === 'DEX') s += `    dec ${RX8}\n`;
  else if (name === 'INY') s += `    inc ${RY8}\n`;
  else if (name === 'DEY') s += `    dec ${RY8}\n`;
  else if (name === 'INC') {
    if (mode === 'zp') s += `    inc byte [${zp8()}]\n`;
    else if (mode === 'abs') s += `    inc byte [${abs16()}]\n`;
    else {
      const ea = loadEA(mode);
      s += ea.pre + `    inc byte ${ea.mem}\n`;
    }
  } else if (name === 'DEC') {
    if (mode === 'zp') s += `    dec byte [${zp8()}]\n`;
    else if (mode === 'abs') s += `    dec byte [${abs16()}]\n`;
    else {
      const ea = loadEA(mode);
      s += ea.pre + `    dec byte ${ea.mem}\n`;
    }
  }

  // 7. SHIFTS & ROTATES
  else if (name === 'ASL') {
    if (mode === 'acc') s += `    shl al, 1\n`;
    else if (mode === 'zp') s += `    shl byte [${zp8()}], 1\n`;
    else if (mode === 'abs') s += `    shl byte [${abs16()}], 1\n`;
    else {
      const ea = loadEA(mode);
      s += ea.pre + `    shl byte ${ea.mem}, 1\n`;
    }
  } else if (name === 'LSR') {
    if (mode === 'acc') s += `    shr al, 1\n`;
    else if (mode === 'zp') s += `    shr byte [${zp8()}], 1\n`;
    else if (mode === 'abs') s += `    shr byte [${abs16()}], 1\n`;
    else {
      const ea = loadEA(mode);
      s += ea.pre + `    shr byte ${ea.mem}, 1\n`;
    }
  } else if (name === 'ROL' || name === 'ROR') {
    const xop = name === 'ROL' ? 'rcl' : 'rcr';
    if (mode === 'acc') s += `    ${xop} al, 1\n` + (nzLive ? `    inc al\n    dec al\n` : '');
    else {
      const ea = mode === 'zp' ? { pre: '', mem: `[${zp8()}]` } : (mode === 'abs' ? { pre: '', mem: `[${abs16()}]` } : loadEA(mode));
      if (!nzLive) s += ea.pre + `    ${xop} byte ${ea.mem}, 1\n`;
      else s += ea.pre + `    mov dl, ${ea.mem}\n    ${xop} dl, 1\n    inc dl\n    dec dl\n    mov ${ea.mem}, dl\n`;
    }
  }

  // 8. TRANSFERS
  else if (name === 'TAX') s += `    mov ${RX8}, al\n` + setNZ(RX8);
  else if (name === 'TAY') s += `    mov ${RY8}, al\n` + setNZ(RY8);
  else if (name === 'TXA') s += `    mov al, ${RX8}\n` + setNZ('al');
  else if (name === 'TYA') s += `    mov al, ${RY8}\n` + setNZ('al');
  else if (name === 'TSX') s += `    mov dx, di\n    mov ${RX8}, dl\n    mov dh, 0\n` + setNZ(RX8);
  else if (name === 'TXS') s += `    mov dl, ${RX8}\n    mov dh, 01h\n    mov di, dx\n    mov dh, 0\n`;

  // 9. STACK (Interrupt-safe & flag-preserving 6502 stack in DS:[DI])
  else if (name === 'PHA') s += `    lea di, [di - 1]\n    mov [di + 1], al\n`;
  else if (name === 'PLA' && returnDropFirst.has(pc)) s += `    pop si                  ; PLA;PLA: drop this routine's native return address\n`;
  else if (name === 'PLA' && returnDropSecond.has(pc)) s += `    ; PLA (second byte of the dropped return address)\n`;
  else if (name === 'PLA') s += `    lea di, [di + 1]\n    mov al, [di]\n` + setNZ('al');
  else if (name === 'PHP') s += `    lahf\n    lea di, [di - 1]\n    mov [di + 1], ah\n`;
  else if (name === 'PLP') s += `    lea di, [di + 1]\n    mov ah, [di]\n    sahf\n`;

  // 10. BRANCHES (NASM cpu 8086 automatically uses 2-byte short jump or 5-byte far trampoline)
  else if (mode === 'rel') {
    let offset = readByte(pc + 1);
    if (offset >= 128) offset -= 256;
    const target = pc + 2 + offset;
    const targetLabel = getLabel(target);

    const condMap = {
      'BEQ': 'jz',  'BNE': 'jnz',
      'BCS': 'jc',  'BCC': 'jnc',
      'BMI': 'js',  'BPL': 'jns',
      'BVS': 'jo',  'BVC': 'jno'
    };
    const cond = condMap[name] || 'jz';
    s += `    ${cond} ${targetLabel}\n`;
  }

  // 11. JUMPS & CALLS
  else if (name === 'JMP') {
    if (mode === 'abs') {
      const target = absVal();
      s += `    jmp ${getLabel(target)}\n`;
    } else if (mode === 'ind') {
      s += `    mov si, [${abs16()}]\n    jmp dispatch_indirect\n`;
    }
  } else if (name === 'JSR') {
    const target = absVal();
    if (!useCompactJsr || jumpEngines.has(target)) {
      const ret6502 = '0' + ((pc + 2) & 0xFFFF).toString(16).toUpperCase().padStart(4, '0') + 'h';
      // Emulated 6502 JSR, inlined: push the return address (PC + 2) on the 6502 stack and
      // jump (LEA / MOV / JMP leave the flags alone, like the hle_jsr helper did)
      s += `    lea di, [di - 2]\n    mov word [di + 1], ${ret6502}\n    jmp ${getLabel(target)}\n`;
    } else {
      s += `    call ${getLabel(target)}\n`;
    }
  } else if (name === 'RTS') {
    s += useCompactJsr ? `    ret\n` : `    jmp hle_rts\n`;
  } else if (name === 'RTI') {
    s += `    ret\n`;
  }

  // 12. FLAGS & MISC
  else if (name === 'CLC') s += foldedFlagOps.has(pc) ? `    ; CLC (folded into ADD)\n` : `    clc\n`;
  else if (name === 'SEC') s += foldedFlagOps.has(pc) ? `    ; SEC (folded into SUB)\n` : `    stc\n`;
  else if (name === 'CLD') s += `    cld\n`;
  else if (name === 'SED') s += `    ; SED\n`;
  else if (name === 'CLI') s += `    ; CLI (6502 IRQ enable)\n`;
  else if (name === 'SEI') s += `    ; SEI (6502 IRQ disable)\n`;
  else if (name === 'CLV') s += `    ; CLV\n`;
  else if (name === 'NOP') s += `    nop\n`;
  else if (name === 'BRK') s += `    jmp hle_rts\n`;
  else {
    throw new Error(`Unhandled instruction ${name} (${mode}) at $${pc.toString(16)}`);
  }

  if (s === '') {
    throw new Error(`Empty translation for ${name} (${mode}) at $${pc.toString(16)}`);
  }

  // (zp),Y with Y in CX swaps BX/CX around the access: swap back right after it
  if (mode === 'izy' && RY8 === 'cl' && s.includes('[bx + si]')) {
    const lines = s.split('\n');
    const k = lines.findIndex(l => l.includes('[bx + si]'));
    lines.splice(k + 1, 0, '    xchg bx, cx');
    s = lines.join('\n');
  }

  return s;
}

const cliArgs = process.argv.slice(2);
const noSoundFlag = cliArgs.includes('--nosound') || cliArgs.includes('-nosound') || cliArgs.includes('/nosound');
// --bench[=frames]: build an instrumented binary that plays a scripted input sequence for
// <frames> game frames (joypad strobes, default 600), then writes <GAME>.BEN stats and <GAME>.DMP.
const benchArg = cliArgs.find(a => /^--bench(=\d+)?$/.test(a));
const benchTicks = benchArg ? (parseInt(benchArg.split('=')[1], 10) || 600) : false;
const regsArg = cliArgs.find(a => a.startsWith('--index-regs='));
const forceIndexRegs = regsArg ? regsArg.slice('--index-regs='.length) : null;
const scriptArg = cliArgs.find(a => a.startsWith('--bench-script='));
const benchScript = scriptArg ? scriptArg.slice('--bench-script='.length) : DEFAULT_BENCH_SCRIPT;
const romFile = cliArgs.find(a => !a.startsWith('-') && !a.startsWith('/')) || 'nuts.nes';
transpileRom(romFile, noSoundFlag, benchTicks);
