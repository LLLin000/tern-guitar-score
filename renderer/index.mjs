// alphaTab -> per-system PNGs + note/beat bounds + whole-piece WAV + per-pitch WAV.
// Usage: node index.mjs --input score.musicxml --out DIR [--width 1000]
import * as alphaTab from "@coderline/alphatab";
import * as alphaSkia from "@coderline/alphaskia";
import * as fs from "fs";
import * as path from "path";

const here = path.dirname(new URL(import.meta.url).pathname).replace(/^\/([A-Za-z]:)/, "$1");
const arg = (name, dflt) => {
  const i = process.argv.indexOf("--" + name);
  return i > 0 ? process.argv[i + 1] : dflt;
};

const input = arg("input");
const outDir = arg("out", "out");
const width = Number(arg("width", "1000"));
if (!input) {
  console.error("missing --input");
  process.exit(2);
}
fs.mkdirSync(outDir, { recursive: true });

alphaTab.Environment.enableAlphaSkia(
  fs.readFileSync(path.join(here, "node_modules/@coderline/alphatab/dist/font/Bravura.otf")).buffer,
  alphaSkia
);

const settings = new alphaTab.Settings();
settings.core.engine = "skia";
settings.core.includeNoteBounds = true;

const score = alphaTab.importer.ScoreLoader.loadScoreFromBytes(
  new Uint8Array(fs.readFileSync(input)),
  settings
);

// ---------- tempo map (playback order, from the tick lookup)
const TICKS_PER_QUARTER = 960;

// ---------- render systems
const renderer = new alphaTab.rendering.ScoreRenderer(settings);
renderer.width = width;
const chunks = [];
renderer.partialLayoutFinished.on((r) => renderer.renderResult(r.id));
renderer.partialRenderFinished.on((r) =>
  // r.width/height are layout units; the PNG's own pixels are what object-fit
  // will honour, so declare those or every child percentage drifts
  chunks.push({
    img: r.renderResult, x: r.x, y: r.y,
    w: r.renderResult.width, h: r.renderResult.height,
  })
);
renderer.renderScore(score, [0]);

// ---------- render systems already collected chunks above
const PAD = 6;
const norm = (v, c, size) => Math.max(0, Math.min(size, v - c)) / size;

// static beats, keyed by the score's own Beat objects
const beatBounds = new Map();
const beatBar = new Map();
const rawMeasures = [];
const rawNotes = [];
const lookup = renderer.boundsLookup;
if (lookup) {
  for (const sys of lookup.staffSystems) {
    for (const mbb of sys.bars) {
      for (const sb of mbb.bars) {
        const mv = sb.visualBounds;
        const idx = sb.bar && sb.bar.masterBar ? sb.bar.masterBar.index : -1;
        if (mv && mv.w > 0 && idx >= 0) rawMeasures.push({ mb: idx, x: mv.x, y: mv.y, w: mv.w, h: mv.h });
        for (const bb of sb.beats || []) {
          const beat = bb.beat;
          const vb = bb.visualBounds;
          if (beat && vb && vb.w > 0 && !beatBounds.has(beat)) {
            beatBounds.set(beat, vb);
            beatBar.set(beat, idx);
          }
          for (const nb of bb.notes || []) {
            const hb = nb.noteHeadBounds;
            if (!hb || !hb.w) continue;
            const n = nb.note;
            rawNotes.push({ beat, string: n ? n.string : null, fret: n ? n.fret : null,
              x: hb.x, y: hb.y, w: hb.w, h: hb.h });
          }
        }
      }
    }
  }
}

// ---------- playback timeline from MidiFileGenerator's tick lookup
const M = alphaTab.midi;
const midiFile = new M.MidiFile();
const generator = new M.MidiFileGenerator(score, settings, new M.AlphaSynthMidiFileHandler(midiFile));
generator.generate();
const tickLookup = generator.tickLookup;

// tempo marks in playback order (repeats already expanded)
const marks = [];
{
  let last = -1;
  for (const mb of tickLookup.masterBars) {
    for (const tc of mb.tempoChanges || []) {
      if (tc.tick > last) { marks.push({ tick: tc.tick, tempo: tc.tempo }); last = tc.tick; }
    }
  }
  if (!marks.length) marks.push({ tick: 0, tempo: score.tempo || 120 });
  let ms = 0, prev = marks[0];
  marks[0].ms = 0;
  for (const m of marks.slice(1)) {
    ms += ((m.tick - prev.tick) * 60000) / (prev.tempo * TICKS_PER_QUARTER);
    m.ms = ms;
    prev = m;
  }
}
function msOfTick(t) {
  let m = marks[0];
  for (const x of marks) { if (x.tick <= t) m = x; else break; }
  return m.ms + ((t - m.tick) * 60000) / (m.tempo * TICKS_PER_QUARTER);
}

// measure playback ranges, in playback order (a repeat yields several)
const measureTimes = [];
for (const mb of tickLookup.masterBars) {
  const idx = mb.masterBar ? mb.masterBar.index : -1;
  if (idx < 0) continue;
  measureTimes.push({
    mb: idx,
    t0: Math.round(msOfTick(mb.start)),
    t1: Math.round(msOfTick(mb.end)),
  });
}

// occurrences: every playback position that carries beats, with the beats sounding there
const beatIds = new Map();
for (const beat of beatBounds.keys()) beatIds.set(beat, beatIds.size);
const timeline = [];
for (const mb of tickLookup.masterBars) {
  let b = mb.firstBeat;
  while (b) {
    const ids = [];
    for (const item of Object.values(b.highlightedBeats || {})) {
      const id = beatIds.get(item.beat);
      if (id !== undefined) ids.push(id);
    }
    if (ids.length) timeline.push({ t: Math.round(msOfTick(mb.start + b.start)), nb: ids });
    b = b.nextBeat;
  }
}
timeline.sort((a, b) => a.t - b.t);

const inChunk = (bb, c) => bb.y + bb.h > c.y - 4 && bb.y < c.y + c.h + 4;

const systems = chunks.map((c) => {
  const raw = [...beatBounds]
    .filter(([, vb]) => inChunk(vb, c))
    .map(([beat, vb]) => ({ i: beatIds.get(beat), x0: vb.x - 6, w0: vb.w + 12, vy: vb.y - 3, vh: vb.h + 6 }))
    .sort((a, b) => a.x0 - b.x0);
  const beats = raw.map((b, k) => {
    const next = raw[k + 1] ? raw[k + 1].x0 - 8 : b.x0 + b.w0;
    const x1 = Math.max(b.x0 + b.w0, Math.min(next, b.x0 + c.w * 0.5));
    return {
      i: b.i,
      m: (() => {
        for (const [beat, id] of beatIds) if (id === b.i) return beatBar.get(beat) ?? -1;
        return -1;
      })(),
      x: Math.max(0, b.x0 - c.x) / c.w,
      w: Math.min(c.w, x1 - b.x0) / c.w,
      y: Math.max(0, b.vy - c.y) / c.h,
      h: Math.min(c.h - Math.max(0, b.vy - c.y), b.vh) / c.h,
    };
  });
  return {
  png: null, w: c.w, h: c.h,
  measures: rawMeasures.filter((m) => inChunk(m, c)).map((m) => ({
    mb: m.mb,
    x: Math.max(0, m.x - c.x) / c.w,
    y: Math.max(0, m.y - c.y) / c.h,
    w: Math.min(c.w, m.w) / c.w,
    h: Math.min(c.h - Math.max(0, m.y - c.y), m.h) / c.h,
  })),
  beats,
  notes: rawNotes.filter((n) => inChunk(n, c)).map((n) => {
    const x0 = Math.max(0, n.x - PAD - c.x);
    const y0 = Math.max(0, n.y - PAD - c.y);
    const x1 = Math.min(c.w, n.x + n.w + PAD - c.x);
    const y1 = Math.min(c.h, n.y + n.h + PAD - c.y);
    return {
      b: beatIds.get(n.beat) ?? -1,
      m: beatBar.get(n.beat) ?? -1,
      string: n.string, fret: n.fret,
      x: x0 / c.w, y: y0 / c.h, w: (x1 - x0) / c.w, h: (y1 - y0) / c.h,
    };
  }),
  };
});

chunks.forEach((c, i) => {
  const file = `system-${String(i + 1).padStart(3, "0")}.png`;
  fs.writeFileSync(path.join(outDir, file), Buffer.from(c.img.toPng()));
  systems[i].png = file;
});

// ---------- audio: alphaTab's SoundFont synth (sonivox), exported offline
const M2 = alphaTab.midi;
const sfPath = path.join(here, "node_modules/@coderline/alphatab/dist/soundfont/sonivox.sf2");
const sfBytes = new Uint8Array(fs.readFileSync(sfPath));

const silent = () => {
  const listeners = [];
  return {
    on(f) { listeners.push(f); },
    off(f) { const i = listeners.indexOf(f); if (i >= 0) listeners.splice(i, 1); },
    emit(...a) { for (const f of listeners.slice()) f(...a); },
  };
};
const output = {
  sampleRate: 44100,
  open() {}, play() {}, pause() {}, resume() {}, destroy() {}, seek() {},
  get volume() { return 1; }, set volume(_v) {},
  ready: silent(), samplesPlayed: silent(), finished: silent(), sampleRequest: silent(),
};

const synth = new alphaTab.synth.AlphaSynth(output, 200);
await synth.loadSoundFont(sfBytes, false);
const exporter = await synth.exportAudio({
  soundFonts: [sfBytes],
  sampleRate: 44100,
  useSyncPoints: false,
  masterVolume: 1,
  metronomeVolume: 0,
  trackVolume: new Map(),
  trackTranspositionPitches: new Map(),
}, midiFile, [], new Map());

const frames = [];
let maxAbs = 0;
for (;;) {
  const chunk = exporter.render(1000);
  if (!chunk) break;
  frames.push(chunk.samples);
  for (const v of chunk.samples) if (Math.abs(v) > maxAbs) maxAbs = Math.abs(v);
}
// normalize to -1 dBFS headroom, then soft-clip: the synth can sum past 0 dBFS
let peakAbs = 0;
for (const f of frames) for (const v of f) if (Math.abs(v) > peakAbs) peakAbs = Math.abs(v);
// ponytail: plain peak normalize + tanh limiter; upgrade to a look-ahead limiter if pumping shows
const gain = peakAbs > 0 ? Math.min(1, 0.891 / peakAbs) : 1;
const pcm = Buffer.alloc(frames.reduce((a, f) => a + f.length, 0) * 2);
let off = 0;
for (const f of frames) {
  for (let i = 0; i < f.length; i++) {
    const v = Math.tanh(f[i] * gain);
    pcm.writeInt16LE(Math.round(v * 32767), off);
    off += 2;
  }
}
const head = Buffer.alloc(44);
head.write("RIFF", 0);
head.writeUInt32LE(36 + pcm.length, 4);
head.write("WAVE", 8);
head.write("fmt ", 12);
head.writeUInt32LE(16, 16);
head.writeUInt16LE(1, 20);
head.writeUInt16LE(2, 22);
head.writeUInt32LE(44100, 24);
head.writeUInt32LE(44100 * 4, 28);
head.writeUInt16LE(4, 32);
head.writeUInt16LE(16, 34);
head.write("data", 36);
head.writeUInt32LE(pcm.length, 40);
fs.writeFileSync(path.join(outDir, "full.wav"), Buffer.concat([head, pcm]));

console.log(JSON.stringify({
  ok: true,
  title: score.title || path.basename(input),
  duration: Math.round((pcm.length / 4 / 44100) * 1000),
  tuning: (score.tracks[0] && score.tracks[0].staves[0] && score.tracks[0].staves[0].stringTuning
    ? score.tracks[0].staves[0].stringTuning.tunings.slice() : []),
  timeSignature: score.masterBars[0]
    ? [score.masterBars[0].timeSignatureNumerator, score.masterBars[0].timeSignatureDenominator] : [4, 4],
  peak: Number(maxAbs.toFixed(3)),
  timeline,
  measureTimes,
  systems,
}, null, 1));
