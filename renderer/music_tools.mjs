import { createHash } from "node:crypto";
import { Chord, Interval, Key, Note } from "tonal";
import { createRequire } from "node:module";
import path from "node:path";
import { pathToFileURL } from "node:url";

const require = createRequire(import.meta.url);
const svgdom = require("svgdom");
const guitarDb = require("@tombatossals/chords-db/lib/guitar.json"); // The published root entry is missing in 0.5.1.
const schema = "gscore.music.v1";
const chordDbSource = "@tombatossals/chords-db@0.5.1";
let svguitar;

class ToolError extends Error {
  constructor(code, message) {
    super(message);
    this.code = code;
  }
}

function fail(code, message) {
  throw new ToolError(code, message);
}

function text(value, field) {
  if (typeof value !== "string" || value.trim() === "") {
    fail("INVALID_REQUEST", `${field} must be a non-empty string.`);
  }
  return value.trim();
}

function getChord(symbol) {
  const chord = Chord.get(text(symbol, "symbol"));
  if (chord.empty || !chord.tonic) fail("INVALID_CHORD", "Tonal could not parse this chord symbol.");
  return chord;
}

function chordPitchClasses(chord) {
  const rootChroma = Note.get(chord.tonic).chroma;
  const notes = [...new Set(chord.notes)]
    .filter((note) => chord.chroma[(Note.get(note).chroma - rootChroma + 12) % 12] === "1");
  const tones = notes.filter((note) =>
    note !== chord.bass || !notes.some((other) =>
      other !== note && Note.get(other).chroma === Note.get(note).chroma
    )
  );
  const byOffset = new Map();
  for (const note of tones) {
    const offset = (Note.get(note).chroma - rootChroma + 12) % 12;
    if (!byOffset.has(offset)) byOffset.set(offset, note);
  }
  return [...byOffset.entries()].sort(([left], [right]) => left - right).map(([, note]) => note);
}

function describeChord(request) {
  const symbol = text(request.symbol, "symbol");
  const chord = getChord(symbol);
  const pitchClasses = chordPitchClasses(chord);
  const inversion = chord.bass
    ? pitchClasses.findIndex((note) => note === chord.bass)
    : 0;
  return {
    symbol,
    name: chord.name,
    chordRoot: chord.tonic,
    bass: chord.bass || null,
    quality: chord.type,
    pitchClasses,
    rootIntervals: pitchClasses.map((note) => Interval.distance(chord.tonic, note)),
    inversion: inversion < 0 ? null : inversion,
    voicing: null,
  };
}

function describeKey(request) {
  const tonic = text(request.tonic, "tonic");
  const mode = request.mode ?? "major";
  if (mode === "major") {
    const key = Key.majorKey(tonic);
    if (!key.scale.length) fail("INVALID_KEY", "Tonal could not parse this major key.");
    return {
      tonic: key.tonic,
      mode,
      chordConstruction: "major_scale",
      scale: key.scale,
      triads: key.triads,
      seventhChords: key.chords,
      harmonicFunctions: key.chordsHarmonicFunction,
    };
  }
  if (mode === "minor") {
    const key = Key.minorKey(tonic);
    if (!key.natural?.scale?.length) fail("INVALID_KEY", "Tonal could not parse this minor key.");
    const variants = Object.fromEntries(["natural", "harmonic", "melodic"].map((name) => {
      const variant = key[name];
      return [name, {
        scale: variant.scale,
        triads: variant.triads,
        seventhChords: variant.chords,
        harmonicFunctions: variant.chordsHarmonicFunction,
      }];
    }));
    return {
      tonic: key.tonic,
      mode,
      relativeMajor: key.relativeMajor,
      chordConstruction: "variant_specific",
      variants,
    };
  }
  fail("INVALID_MODE", "mode must be 'major' or 'minor'.");
}

function detectChord(request) {
  if (!Array.isArray(request.notes) || request.notes.length < 2 || request.notes.length > 16) {
    fail("INVALID_REQUEST", "notes must contain 2 to 16 pitch names.");
  }
  for (const note of request.notes) {
    if (typeof note !== "string" || Note.get(note).empty) {
      fail("INVALID_NOTE", `Invalid pitch name: ${String(note)}.`);
    }
  }
  const inputPitchClasses = [...new Set(request.notes.map(Note.pitchClass))];
  const inputChromas = new Set(inputPitchClasses.map((note) => Note.get(note).chroma));
  const candidates = Chord.detect(request.notes).map((symbol) => {
    const chord = describeChord({ symbol });
    const candidateChromas = new Set(chord.pitchClasses.map((note) => Note.get(note).chroma));
    return {
      symbol: chord.symbol,
      name: chord.name,
      chordRoot: chord.chordRoot,
      bass: chord.bass || null,
      inversion: chord.inversion,
      quality: chord.quality,
      pitchClasses: chord.pitchClasses,
      rootIntervals: chord.rootIntervals,
      match: {
        exactPitchClassSet: candidateChromas.size === inputChromas.size
          && [...candidateChromas].every((chroma) => inputChromas.has(chroma)),
        missingPitchClasses: chord.pitchClasses.filter((note) => !inputChromas.has(Note.get(note).chroma)),
        extraPitchClasses: inputPitchClasses.filter((note) => !candidateChromas.has(Note.get(note).chroma)),
      },
    };
  });
  return {
    notes: request.notes,
    inputPitchClasses,
    candidates,
    ambiguous: candidates.length > 1,
  };
}


function positionFrets(position) {
  return position.frets.map((fret) =>
    fret < 0 ? -1 : fret === 0 ? 0 : position.baseFret + fret - 1
  );
}

function positionNotes(position) {
  return position.frets.flatMap((fret, index) => {
    if (fret < 0) return [];
    const actualFret = fret === 0 ? 0 : position.baseFret + fret - 1;
    const openNote = guitarDb.tunings.standard[index];
    return [actualFret === 0 ? openNote : Note.transpose(openNote, Interval.fromSemitones(actualFret))];
  });
}

function shapeId(symbol, tuning, capo, position) {
  const identity = JSON.stringify([
    chordDbSource, symbol, tuning, capo, position.actualFrets, position.fingers, position.notes, position.midi,
  ]);
  return `gshape_${createHash("sha256").update(identity).digest("hex")}`;
}

function fitsChord(notes, chord) {
  const chordClasses = new Set(chordPitchClasses(chord).map((note) => Note.get(note).chroma));
  const noteClasses = notes.map((note) => Note.get(note).chroma);
  if (!noteClasses.includes(Note.get(chord.tonic).chroma) || !noteClasses.every((pitch) => chordClasses.has(pitch))) {
    return false;
  }
  if (!chord.bass) return true;
  const lowestNote = notes.reduce((lowest, note) => Note.midi(note) < Note.midi(lowest) ? note : lowest);
  return Note.get(lowestNote).chroma === Note.get(chord.bass).chroma;
}

function guitarShapes(request) {
  const symbol = text(request.symbol, "symbol");
  const target = getChord(symbol);
  const tuning = request.tuning ?? guitarDb.tunings.standard;
  if (!Array.isArray(tuning) || tuning.length !== guitarDb.tunings.standard.length
      || tuning.some((note, index) => note !== guitarDb.tunings.standard[index])) {
    fail("UNSUPPORTED_TUNING", "guitar.shapes currently supports standard E2-A2-D3-G3-B3-E4 tuning only.");
  }
  const capo = request.capo ?? 0;
  if (!Number.isInteger(capo) || capo < 0) fail("INVALID_REQUEST", "capo must be a non-negative integer.");
  if (capo !== 0) fail("UNSUPPORTED_CAPO", "guitar.shapes uses uncapped database positions; capo must be 0.");
  const maxFret = request.maxFret ?? null;
  if (maxFret !== null && (!Number.isInteger(maxFret) || maxFret < 0)) {
    fail("INVALID_REQUEST", "maxFret must be a non-negative integer.");
  }
  const groups = (guitarDb.chords[target.tonic] ?? []).filter((group) => {
    const candidate = Chord.get(`${group.key}${group.suffix}`);
    return !candidate.empty && candidate.tonic === target.tonic && candidate.chroma === target.chroma;
  });
  const positions = groups.flatMap((group) =>
    group.positions.flatMap((position) => {
      // chords-db's boolean `capo` is shape metadata, not a user capo setting.
      const { capo: _databaseCapoMarker, ...shapeData } = position;
      const actualFrets = positionFrets(position);
      const positionMaxFret = Math.max(...actualFrets);
      if (maxFret !== null && positionMaxFret > maxFret) return [];
      const notes = positionNotes(position);
      if (!fitsChord(notes, target)) return [];
      const midi = notes.map(Note.midi);
      const lowestIndex = midi.indexOf(Math.min(...midi));
      const shape = {
        suffix: group.suffix,
        ...shapeData,
        actualFrets,
        maxFret: positionMaxFret,
        lowestNote: notes[lowestIndex],
        lowestMidi: midi[lowestIndex],
        notes,
        midi,
      };
      return [{ ...shape, shape_id: shapeId(symbol, tuning, capo, shape) }];
    })
  );
  if (positions.length === 0) fail("NO_MATCHING_SHAPE", "No matching database shape satisfies this chord and fret limit.");
  return {
    symbol,
    name: target.name,
    chordRoot: target.tonic,
    bass: target.bass || null,
    tuning,
    capo,
    constraints: { maxFret, handStretch: "not_evaluated" },
    source: chordDbSource,
    positions,
  };
}

function ensureSvgdom() {
  if (svguitar) return svguitar.SVGuitarChord;
  const fontDir = path.dirname(require.resolve("svguitar/fonts/OpenSans-Regular.ttf"));
  svgdom.setFontDir(fontDir);
  svgdom.setFontFamilyMappings({ Arial: "OpenSans-Regular.ttf" });
  svgdom.preloadFonts();
  const window = svgdom.createSVGWindow();
  // The bundled renderer captures window/document at require time.
  const previousWindow = globalThis.window;
  const previousDocument = globalThis.document;
  const hadWindow = Object.hasOwn(globalThis, "window");
  const hadDocument = Object.hasOwn(globalThis, "document");
  globalThis.window = window;
  globalThis.document = window.document;
  try {
    svguitar = require("svguitar");
  } finally {
    if (hadWindow) globalThis.window = previousWindow;
    else delete globalThis.window;
    if (hadDocument) globalThis.document = previousDocument;
    else delete globalThis.document;
  }
  return svguitar.SVGuitarChord;
}

function asSvguitarFingers(shape) {
  return shape.frets.map((fret, index) => {
    const string = 6 - index;
    const position = fret < 0 ? "x" : fret;
    const finger = shape.fingers[index];
    return finger > 0 ? [string, position, String(finger)] : [string, position];
  });
}

function asSvguitarBarres(shape) {
  const byFingerAndFret = new Map();
  shape.fingers.forEach((finger, index) => {
    const fret = shape.frets[index];
    if (finger > 0 && fret > 0) {
      const key = `${finger}:${fret}`;
      byFingerAndFret.set(key, [...(byFingerAndFret.get(key) ?? []), index]);
    }
  });
  return [...byFingerAndFret.entries()].flatMap(([key, indices]) => {
    if (indices.length < 2 || indices.some((index, offset) => offset > 0 && index !== indices[offset - 1] + 1)) return [];
    const [finger, fret] = key.split(":").map(Number);
    return [{
      fromString: 6 - indices[0],
      toString: 6 - indices.at(-1),
      fret,
      text: String(finger),
    }];
  });
}

function svgAttributeNumber(tag, name) {
  const value = tag.match(new RegExp(`(?:^|\\s)${name}=["']([^"']+)["']`))?.[1];
  return value === undefined ? NaN : Number(value);
}

function diagramHitRegions(svg, viewBox, shape) {
  const [minX, minY, width, height] = viewBox.trim().split(/[\s,]+/).map(Number);
  const notesByString = new Map();
  let noteIndex = 0;
  for (let index = 0; index < shape.actualFrets.length; index += 1) {
    const fret = shape.actualFrets[index];
    if (fret < 0) continue;
    notesByString.set(6 - index, {
      fret,
      pitch: shape.notes[noteIndex],
      midi: shape.midi[noteIndex],
    });
    noteIndex += 1;
  }

  const regions = [];
  const seen = new Set();
  for (const match of svg.matchAll(/<circle\b[^>]*>/gi)) {
    const tag = match[0];
    const classes = tag.match(/\bclass=["']([^"']*)["']/i)?.[1] ?? "";
    const stringMatch = classes.match(/(?:^|\s)(?:finger|open)-string-(\d+)(?:\s|$)/);
    if (!stringMatch) continue;
    const svgString = Number(stringMatch[1]);
    const string = 6 - svgString;
    const note = notesByString.get(string);
    const open = /(?:^|\s)open-string(?:\s|$)/.test(classes);
    const fretMatch = classes.match(/(?:^|\s)finger-fret-(\d+)(?:\s|$)/);
    const fret = open ? 0 : shape.baseFret + Number(fretMatch?.[1]);
    if (!note || note.fret !== fret) {
      fail("HITBOX_SHAPE_MISMATCH", "Rendered SVG note targets do not match the verified guitar shape.");
    }
    const cx = svgAttributeNumber(tag, "cx");
    const cy = svgAttributeNumber(tag, "cy");
    const radius = svgAttributeNumber(tag, "r");
    if (![cx, cy, radius].every(Number.isFinite) || radius <= 0) {
      fail("INVALID_HITBOX_GEOMETRY", "Rendered SVG note target has invalid geometry.");
    }
    const targetRadius = Math.max(radius, 20);
    const left = Math.max(0, cx - targetRadius - minX);
    const top = Math.max(0, cy - targetRadius - minY);
    const right = Math.min(width, cx + targetRadius - minX);
    const bottom = Math.min(height, cy + targetRadius - minY);
    const id = `s${string}f${fret}`;
    if (seen.has(id) || right <= left || bottom <= top) {
      fail("INVALID_HITBOX_GEOMETRY", "Rendered SVG note target is duplicate or outside the diagram.");
    }
    seen.add(id);
    regions.push({
      id,
      string,
      fret,
      pitch: note.pitch,
      midi: note.midi,
      lowest: note.midi === shape.lowestMidi,
      x: left / width,
      y: top / height,
      w: (right - left) / width,
      h: (bottom - top) / height,
    });
  }
  if (regions.length !== notesByString.size) {
    fail("MISSING_HITBOX", "The rendered SVG does not expose a selectable target for every sounding string.");
  }
  return regions;
}

function renderGuitarDiagram(request) {
  const shapes = guitarShapes(request);
  const shapeIndex = request.shape_index ?? 0;
  if (!Number.isInteger(shapeIndex) || shapeIndex < 0 || shapeIndex >= shapes.positions.length) {
    fail("INVALID_POSITION", "shape_index is outside the available shape list.");
  }
  const shape = shapes.positions[shapeIndex];
  const SVGuitarChord = ensureSvgdom();
  const chart = new SVGuitarChord();
  chart
    .configure({
      title: shapes.symbol,
      strings: 6,
      frets: 4,
      position: shape.baseFret,
      tuning: shapes.tuning.map(Note.pitchClass),
      fontFamily: "Arial",
    })
    .chord({
      title: shapes.symbol,
      fingers: asSvguitarFingers(shape),
      barres: asSvguitarBarres(shape),
      position: shape.baseFret,
    })
    .draw();
  // Tern drops unsupported SVG elements and ignores style attributes.
  const svg = chart.toSvg()
    .replace(/<(title|style)\b[^>]*>[\s\S]*?<\/\1>/gi, "")
    .replace(/<\/?tspan\b[^>]*>/gi, "")
    .replace(/\sstyle=(?:"[^"]*"|'[^']*')/gi, "");
  const tags = [...svg.matchAll(/<\/?([A-Za-z][\w:-]*)\b[^>]*>/g)].map((match) => match[1]);
  const allowed = new Set(["svg", "g", "defs", "linearGradient", "stop", "path", "circle", "line", "rect", "mask", "text"]);
  const unsupported = [...new Set(tags.filter((tag) => !allowed.has(tag)))];
  if (unsupported.length) fail("UNSUPPORTED_SVG", `SVG uses unsupported element(s): ${unsupported.join(", ")}.`);
  const viewBox = svg.match(/<svg\b[^>]*\bviewBox="([^"]+)"/i)?.[1];
  const dimensions = viewBox?.trim().split(/[\s,]+/).map(Number);
  const width = dimensions?.[2];
  const height = dimensions?.[3];
  if (!dimensions || dimensions.length !== 4 || !dimensions.every(Number.isFinite) || width <= 0 || height <= 0) {
    fail("INVALID_SVG", "SVG must have a valid viewBox with positive dimensions.");
  }
  const svgBytes = Buffer.byteLength(svg, "utf8");
  if (svgBytes > 262144) fail("SVG_TOO_LARGE", "The SVG exceeds Tern's 256 KiB image limit.");
  const hitRegions = diagramHitRegions(svg, viewBox, shape);
  return {
    mime: "image/svg+xml",
    alt: `${shapes.name}, guitar position ${shapeIndex + 1}`,
    width,
    height,
    viewBox,
    svgBytes,
    svg,
    hit_regions: hitRegions,
  };
}

function dispatch(request) {
  if (!request || typeof request !== "object" || Array.isArray(request)) {
    fail("INVALID_REQUEST", "The request must be a JSON object.");
  }
  switch (request.op) {
    case "chord.describe": return describeChord(request);
    case "key.describe": return describeKey(request);
    case "chord.detect": return detectChord(request);
    case "guitar.shapes": return guitarShapes(request);
    case "guitar.diagram": return renderGuitarDiagram(request);
    default: fail("UNKNOWN_OPERATION", "Unknown music tool operation.");
  }
}

export function handle(request) {
  const op = request && typeof request.op === "string" ? request.op : undefined;
  try {
    return { schema, ok: true, op, result: dispatch(request) };
  } catch (error) {
    return {
      schema,
      ok: false,
      ...(op ? { op } : {}),
      error: {
        code: error instanceof ToolError ? error.code : "INTERNAL_ERROR",
        message: error instanceof ToolError ? error.message : "The music tool failed.",
      },
    };
  }
}

async function main() {
  let input = "";
  for await (const chunk of process.stdin) input += chunk;
  let response;
  try {
    response = handle(JSON.parse(input));
  } catch {
    response = {
      schema,
      ok: false,
      error: { code: "INVALID_JSON", message: "stdin must contain one valid JSON request." },
    };
  }
  process.stdout.write(`${JSON.stringify(response)}\n`);
  if (!response.ok) process.exitCode = 1;
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) await main();
