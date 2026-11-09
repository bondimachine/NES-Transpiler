#!/usr/bin/env node
/**
 * BENCH.JS - FPS / CPU-load benchmark for NES88 transpiled games.
 *
 * Builds each ROM with `aot_transpiler.js --bench`, assembles it with NASM, runs it headless in
 * DOSBox-X configured as a CGA PC with an 8086 at a fixed instruction rate, and reports the stats
 * the runtime writes to <GAME>.BEN. Also saves the final CGA frame as <game>.png for visual checks.
 *
 * Usage: node bench.js [--frames=1200] [--cycles=240] [--out=dir] [--json=file] [--ref=dir --refjson=file] rom1.nes rom2.nes ...
 *
 * Note: DOSBox-X "cycles" are instructions per millisecond, not 8088 bus cycles, so results are a
 * relative instruction-throughput proxy; 240 approximates a 4.77 MHz PC/XT.
 */
const fs = require('fs');
const path = require('path');
const zlib = require('zlib');
const { execFileSync, spawn } = require('child_process');

const args = process.argv.slice(2);
const opt = (name, def) => {
  const a = args.find(x => x.startsWith(`--${name}=`));
  return a ? a.slice(name.length + 3) : def;
};
const frames = parseInt(opt('frames', '1200'), 10);
const cycles = parseInt(opt('cycles', '240'), 10);
const outDir = path.resolve(opt('out', 'bench_out'));
const jsonOut = opt('json', null);
const profileTop = args.includes('--profile') ? 12 : 0;   // print a sampling profile per game
const refRoot = opt('ref', null) && path.resolve(opt('ref', null));  // previous --out dir to compare with
const refJson = opt('refjson', null) && JSON.parse(fs.readFileSync(opt('refjson', null), 'utf8'));
const roms = args.filter(a => !a.startsWith('--'));
// Optional per-game input scripts (see DEFAULT_BENCH_SCRIPT in aot_transpiler.js), keyed by the
// 8-char lowercase game name, from --scripts=file.json
const scripts = JSON.parse(fs.readFileSync(opt('scripts', path.join(__dirname, 'bench_scripts.json')), 'utf8'));
const NASM = process.env.NASM || 'nasm';
const DOSBOX = process.env.DOSBOX || 'dosbox-x';
const PIT_HZ = 1193182;

if (roms.length === 0) {
  console.error('Usage: node bench.js [--frames=N] [--cycles=N] [--out=dir] [--json=file] game.nes ...');
  process.exit(1);
}

function writePng(file, width, height, rgb) {
  const crcTable = new Int32Array(256).map((_, n) => {
    let c = n;
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xEDB88320 ^ (c >>> 1) : c >>> 1;
    return c;
  });
  const crc = buf => {
    let c = -1;
    for (const b of buf) c = crcTable[(c ^ b) & 0xFF] ^ (c >>> 8);
    return (c ^ -1) >>> 0;
  };
  const chunk = (type, data) => {
    const len = Buffer.alloc(4); len.writeUInt32BE(data.length);
    const td = Buffer.concat([Buffer.from(type), data]);
    const c = Buffer.alloc(4); c.writeUInt32BE(crc(td));
    return Buffer.concat([len, td, c]);
  };
  const raw = Buffer.alloc((width * 3 + 1) * height);
  for (let y = 0; y < height; y++) {
    raw[y * (width * 3 + 1)] = 0;
    rgb.copy(raw, y * (width * 3 + 1) + 1, y * width * 3, (y + 1) * width * 3);
  }
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(width, 0); ihdr.writeUInt32BE(height, 4);
  ihdr[8] = 8; ihdr[9] = 2;
  fs.writeFileSync(file, Buffer.concat([
    Buffer.from([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]),
    chunk('IHDR', ihdr), chunk('IDAT', zlib.deflateSync(raw)), chunk('IEND', Buffer.alloc(0))
  ]));
}

function dumpToPng(dmpFile, pngFile) {
  const d = fs.readFileSync(dmpFile);
  const vram = d.subarray(0x500, 0x500 + 16384);
  const pal = [[0, 0, 0], [85, 255, 255], [255, 85, 255], [255, 255, 255]];
  const rgb = Buffer.alloc(320 * 200 * 3);
  for (let y = 0; y < 200; y++) {
    const rowBase = (y & 1) * 0x2000 + (y >> 1) * 80;
    for (let x = 0; x < 320; x++) {
      const b = vram[rowBase + (x >> 2)];
      const c = pal[(b >> (6 - 2 * (x & 3))) & 3];
      rgb.set(c, (y * 320 + x) * 3);
    }
  }
  writePng(pngFile, 320, 200, rgb);
}

function build(rom) {
  const name = path.basename(rom, path.extname(rom)).replace(/[^A-Za-z0-9]/g, '').slice(0, 8).toLowerCase();
  const dir = path.join(outDir, name);
  fs.mkdirSync(dir, { recursive: true });
  for (const f of fs.readdirSync(dir)) fs.unlinkSync(path.join(dir, f));
  fs.copyFileSync(rom, path.join(dir, `${name}.nes`));
  const script = scripts[name] ? [`--bench-script=${scripts[name]}`] : [];
  execFileSync('node', [path.join(__dirname, 'aot_transpiler.js'), `${name}.nes`, `--bench=${frames}`, ...script, ...(process.env.TARGS ? process.env.TARGS.split(" ") : [])], { cwd: dir, stdio: 'pipe' });
  try {
    execFileSync(NASM, ['-f', 'bin', `${name}.asm`, '-o', `${name}.com`], { cwd: dir, stdio: 'pipe' });
  } catch (e) {
    console.error(`NASM failed for ${name}:\n${e.stderr}`);
    process.exit(1);
  }
  return { name, dir, comSize: fs.statSync(path.join(dir, `${name}.com`)).size };
}

function run(game) {
  return new Promise((resolve) => {
    const timeLimit = Math.ceil(frames * 20 / 60) + 60;
    const p = spawn(DOSBOX, [
      '-defaultconf', '-silent', '-nogui', '-nomenu', '-fastlaunch', '-time-limit', String(timeLimit),
      '-set', 'dosbox machine=cga', '-set', 'cpu cputype=8086', '-set', 'cpu core=normal',
      '-set', `cpu cycles=fixed ${cycles}`, '-set', 'mixer nosound=true', '-set', 'cpu turbo=true',
      '-c', `mount c "${game.dir}"`, '-c', 'c:', '-c', `${game.name}.com${args.includes('--invert') ? ' --invert' : ''}`, '-c', 'exit'
    ], { stdio: 'ignore' });
    p.on('exit', () => resolve());
  });
}

// Maps profiler samples (one word per even CS offset) to runtime routines and 6502
// subroutines using a NASM listing of the game.
function profileOf(game, hist) {
  if (hist.length < 65536) return null;
  const lst = path.join(game.dir, `${game.name}.lst`);
  execFileSync(NASM, ['-f', 'bin', `${game.name}.asm`, '-o', `${game.name}.tmp`, '-l', `${game.name}.lst`], { cwd: game.dir, stdio: 'pipe' });
  const routines = JSON.parse(fs.readFileSync(path.join(game.dir, `${game.name}.routines.json`), 'utf8'));
  const rows = [];           // [csOffset, label]
  let label = '?', inText = true;
  for (const line of fs.readFileSync(lst, 'utf8').split('\n')) {
    const src = line.slice(40);
    if (/^\s*section\s+\.(data|bss)/.test(src)) inText = false;
    if (/^\s*section\s+\.text/.test(src)) inText = true;
    const lb = src.match(/^([A-Za-z_][\w]*):/);
    if (lb) label = lb[1];
    const m = line.match(/^\s*\d+\s+([0-9A-F]{8})\s+[0-9A-F]/);
    if (m && inText) rows.push([parseInt(m[1], 16) + 0x100, label]);
  }
  const entries = routines.entries;
  const routineOf = a => {
    let lo = 0, hi = entries.length - 1, best = null;
    while (lo <= hi) { const mid = (lo + hi) >> 1; if (entries[mid] <= a) { best = entries[mid]; lo = mid + 1; } else hi = mid - 1; }
    return best === null ? '?' : `6502 $${best.toString(16).toUpperCase()}`;
  };
  const cats = {}, fns = {};
  let total = 0, ri = 0;
  for (let off = 0; off < 65536; off += 2) {
    const n = hist.readUInt16LE(off);
    if (!n) continue;
    total += n;
    let name;
    if (off === 0) name = 'BIOS/DOS';
    else {
      while (ri + 1 < rows.length && rows[ri + 1][0] <= off) ri++;
      const lbl = rows[ri] && rows[ri][0] <= off ? rows[ri][1] : '?';
      name = lbl.startsWith('loc_') ? routineOf(parseInt(lbl.slice(4), 16)) : lbl;
    }
    const cat = name.startsWith('6502') ? 'game code'
      : /^(flush_dirty_tiles|draw_sprites|mark_all_dirty)$/.test(name) ? 'render'
      : /^(hle_jsr|hle_rts|dispatch_indirect)$/.test(name) ? 'JSR/RTS emulation'
      : /^hle_/.test(name) ? 'I/O traps'
      : /^bench_idle_(enter|exit)$/.test(name) ? 'idle (frame wait)'
      : /^bench_/.test(name) ? 'bench overhead'
      : name === 'BIOS/DOS' ? 'BIOS/DOS' : 'runtime other';
    cats[cat] = (cats[cat] || 0) + n;
    fns[name] = (fns[name] || 0) + n;
  }
  const pct = n => +(100 * n / total).toFixed(1);
  return {
    samples: total,
    categories: Object.fromEntries(Object.entries(cats).sort((a, b) => b[1] - a[1]).map(([k, v]) => [k, pct(v)])),
    top: Object.entries(fns).sort((a, b) => b[1] - a[1]).slice(0, profileTop).map(([k, v]) => [k, pct(v)])
  };
}

function parse(game) {
  const benFile = fs.readdirSync(game.dir).find(f => /\.ben$/i.test(f));
  if (!benFile) return { name: game.name, error: 'no .BEN produced (crash or timeout)' };
  const b = fs.readFileSync(path.join(game.dir, benFile));
  const s = {
    ticks: b.readUInt16LE(0), nmi: b.readUInt16LE(2), lost: b.readUInt16LE(4), flush: b.readUInt16LE(6),
    frames: b.readUInt16LE(8), total: b.readUInt32LE(10), isr: b.readUInt32LE(14),
    render: b.readUInt32LE(18), idle: b.readInt32LE(22), hwSteps: b.readUInt16LE(26), fullRedraws: b.readUInt16LE(28)
  };
  const dmp = fs.readdirSync(game.dir).find(f => /\.dmp$/i.test(f));
  let ramDiff = null, fbDiff = null;
  if (dmp) {
    dumpToPng(path.join(game.dir, dmp), path.join(outDir, `${game.name}.png`));
    // Compare final NES RAM (dump offset 4500h, 2 KB, excluding the $0100 stack page) with --ref
    const refDir = refRoot && path.join(refRoot, game.name);
    const refDmp = refDir && fs.existsSync(refDir) && fs.readdirSync(refDir).find(f => /\.dmp$/i.test(f));
    if (refDmp) {
      const a = fs.readFileSync(path.join(game.dir, dmp)), r = fs.readFileSync(path.join(refDir, refDmp));
      ramDiff = 0;
      for (let i = 0; i < 2048; i++) if ((i >> 8) !== 1 && a[0x4500 + i] !== r[0x4500 + i]) ramDiff++;
      fbDiff = 0;   // Final CGA framebuffer bytes that differ
      for (let i = 0x500; i < 0x4500; i++) if (a[i] !== r[i]) fbDiff++;
    }
  }
  // Render consistency: incremental final frame (appended to .BEN) vs forced full repaint (.DMP)
  let renderErrors = null;
  if (dmp && b.length >= 30 + 16384) {
    const inc = b.subarray(30, 30 + 16384), full = fs.readFileSync(path.join(game.dir, dmp)).subarray(0x500, 0x4500);
    renderErrors = 0;
    for (let i = 0; i < 16384; i++) if (inc[i] !== full[i]) renderErrors++;
  }
  const secs = s.total / PIT_HZ;
  const gameFrames = s.frames;
  const busy = s.total - Math.max(0, s.idle);
  return {
    name: game.name,
    comSize: game.comSize,
    seconds: +secs.toFixed(2),
    gameFps: +(gameFrames / secs).toFixed(2),
    frames: s.frames,
    renderFps: +(s.flush / secs).toFixed(2),
    lostTicks: s.lost,
    cpuLoadPct: +(100 * busy / s.total).toFixed(1),
    msPerGameFrame: +(1000 * busy / PIT_HZ / gameFrames).toFixed(2),
    msPerRender: +(1000 * s.render / PIT_HZ / Math.max(1, s.flush)).toFixed(2),
    renderErrors,
    ramDiff,
    fbDiff,
    profile: profileTop ? profileOf(game, b.subarray(30 + 16384)) : undefined,
    raw: s
  };
}

(async () => {
  fs.mkdirSync(outDir, { recursive: true });
  const games = roms.map(build);
  await Promise.all(games.map(run));
  const results = games.map(parse);
  const cols = ['name', 'frames', 'seconds', 'gameFps', 'renderFps', 'lostTicks', 'cpuLoadPct', 'msPerGameFrame', 'msPerRender', 'renderErrors', 'comSize'];
  console.log(cols.map(c => c.padStart(14)).join(''));
  for (const r of results) {
    if (r.error) { console.log(`${r.name.padStart(14)}  ERROR: ${r.error}`); continue; }
    console.log(cols.map(c => String(r[c]).padStart(14)).join(''));
  }
  if (profileTop) {
    for (const r of results) {
      if (!r.profile) continue;
      console.log(`\n== ${r.name} profile (${r.profile.samples} samples)`);
      console.log('  ' + Object.entries(r.profile.categories).map(([k, v]) => `${k} ${v}%`).join(', '));
      for (const [k, v] of r.profile.top) console.log(`    ${String(v).padStart(5)}%  ${k}`);
    }
  }
  if (refJson) {
    console.log('\nvs reference:');
    for (const r of results) {
      const b = refJson.find(x => x.name === r.name);
      if (!b || r.error) continue;
      const pct = (a, c) => `${a >= c ? '+' : ''}${(100 * (a - c) / c).toFixed(1)}%`;
      console.log(`${r.name.padStart(10)}  gameFps ${b.gameFps} -> ${r.gameFps} (${pct(r.gameFps, b.gameFps)})` +
        `  msPerGameFrame ${pct(r.msPerGameFrame, b.msPerGameFrame)}  msPerRender ${pct(r.msPerRender, b.msPerRender)}` +
        `  renderFps ${pct(r.renderFps, b.renderFps)}  RAM diff bytes: ${r.ramDiff}  framebuffer diff bytes: ${r.fbDiff}`);
    }
  }
  if (jsonOut) fs.writeFileSync(jsonOut, JSON.stringify(results, null, 2));
})();
