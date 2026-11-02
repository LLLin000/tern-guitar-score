import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";

const root = dirname(dirname(fileURLToPath(import.meta.url)));
const cli = join(root, "renderer", "music_tools.mjs");
const ternSvgTags = new Set([
  "svg",
  "g",
  "defs",
  "linearGradient",
  "stop",
  "path",
  "circle",
  "line",
  "rect",
  "mask",
  "text",
]);

function request(payload) {
  const result = spawnSync(process.execPath, [cli], {
    cwd: join(root, "renderer"),
    encoding: "utf8",
    input: `${JSON.stringify(payload)}\n`,
  });
  assert.equal(result.error, undefined, result.error?.message);
  assert.ok(result.stdout, `CLI produced no JSON: ${result.stderr}`);
  const response = JSON.parse(result.stdout);
  assert.equal(response.schema, "gscore.music.v1");
  return { result, response };
}

test("chord.describe returns root-ordered Cmaj7 chord facts", () => {
  const { result, response } = request({ op: "chord.describe", symbol: "Cmaj7" });
  assert.equal(result.status, 0, result.stderr);
  assert.equal(response.result.chordRoot, "C");
  assert.equal(response.result.quality, "major seventh");
  assert.deepEqual(response.result.pitchClasses, ["C", "E", "G", "B"]);
  assert.deepEqual(response.result.rootIntervals, ["1P", "3M", "5P", "7M"]);
  assert.equal(response.result.bass, null);
  assert.equal(response.result.inversion, 0);
  assert.equal(response.result.voicing, null);
});

test("chord.describe separates chord tones from slash bass and unknown voicing", () => {
  const { result, response } = request({ op: "chord.describe", symbol: "C/E" });
  assert.equal(result.status, 0, result.stderr);
  assert.equal(response.result.chordRoot, "C");
  assert.equal(response.result.bass, "E");
  assert.equal(response.result.quality, "major");
  assert.deepEqual(response.result.pitchClasses, ["C", "E", "G"]);
  assert.deepEqual(response.result.rootIntervals, ["1P", "3M", "5P"]);
  assert.equal(response.result.inversion, 1);
  assert.equal(response.result.voicing, null);
  assert.equal("notes" in response.result, false);
  assert.equal("intervals" in response.result, false);
});

test("chord.describe does not label a non-chord slash bass as an inversion", () => {
  const { result, response } = request({ op: "chord.describe", symbol: "C/D" });
  assert.equal(result.status, 0, result.stderr);
  assert.equal(response.result.bass, "D");
  assert.deepEqual(response.result.pitchClasses, ["C", "E", "G"]);
  assert.equal(response.result.inversion, null);
  assert.equal(response.result.voicing, null);
});

test("key.describe returns the C-major scale and diatonic triads", () => {
  const { result, response } = request({ op: "key.describe", tonic: "C", mode: "major" });
  assert.equal(result.status, 0, result.stderr);
  assert.deepEqual(response.result.scale, ["C", "D", "E", "F", "G", "A", "B"]);
  assert.deepEqual(response.result.triads, ["C", "Dm", "Em", "F", "G", "Am", "Bdim"]);
});

test("key.describe returns separate A-minor scale and chord constructions", () => {
  const { result, response } = request({ op: "key.describe", tonic: "A", mode: "minor" });
  assert.equal(result.status, 0, result.stderr);
  assert.equal(response.result.chordConstruction, "variant_specific");
  assert.deepEqual(response.result.variants.natural.scale, ["A", "B", "C", "D", "E", "F", "G"]);
  assert.deepEqual(response.result.variants.harmonic.scale, ["A", "B", "C", "D", "E", "F", "G#"]);
  assert.deepEqual(response.result.variants.melodic.scale, ["A", "B", "C", "D", "E", "F#", "G#"]);
  assert.deepEqual(response.result.variants.natural.triads, ["Am", "Bdim", "C", "Dm", "Em", "F", "G"]);
  assert.deepEqual(response.result.variants.harmonic.triads, ["Am", "Bdim", "Caug", "Dm", "E", "F", "G#dim"]);
  assert.deepEqual(response.result.variants.melodic.triads, ["Am", "Bm", "Caug", "D", "E", "F#dim", "G#dim"]);
  assert.deepEqual(response.result.variants.harmonic.seventhChords, ["AmMaj7", "Bm7b5", "C+maj7", "Dm7", "E7", "Fmaj7", "G#o7"]);
  assert.deepEqual(response.result.variants.melodic.seventhChords, ["Am6", "Bm7", "C+maj7", "D7", "E7", "F#m7b5", "G#m7b5"]);
});

test("chord.detect reports candidates and pitch-set evidence", () => {
  const { result, response } = request({ op: "chord.detect", notes: ["D", "F#", "A", "C"] });
  assert.equal(result.status, 0, result.stderr);
  assert.equal(response.result.ambiguous, false);
  const candidate = response.result.candidates.find((item) => item.symbol === "D7");
  assert.ok(candidate);
  assert.equal(candidate.chordRoot, "D");
  assert.equal(candidate.quality, "dominant seventh");
  assert.deepEqual(candidate.pitchClasses, ["D", "F#", "A", "C"]);
  assert.deepEqual(candidate.rootIntervals, ["1P", "3M", "5P", "7m"]);
  assert.equal(candidate.match.exactPitchClassSet, true);
  assert.deepEqual(candidate.match.missingPitchClasses, []);
  assert.deepEqual(candidate.match.extraPitchClasses, []);
});

test("chord.detect labels enharmonic candidate ambiguity without duplicating pitch classes", () => {
  const { result, response } = request({ op: "chord.detect", notes: ["C", "E", "G"] });
  assert.equal(result.status, 0, result.stderr);
  assert.equal(response.result.ambiguous, true);
  assert.ok(response.result.candidates.length > 1);
  const alternate = response.result.candidates.find((item) => item.chordRoot === "E");
  assert.ok(alternate);
  assert.deepEqual(alternate.pitchClasses, ["E", "G", "B#"]);
  assert.equal(alternate.bass, "C");
  assert.equal(alternate.inversion, null);
  assert.equal(alternate.match.exactPitchClassSet, true);
});

test("guitar.shapes returns pitch and playability provenance", () => {
  const { result, response } = request({ op: "guitar.shapes", symbol: "C" });
  assert.equal(result.status, 0, result.stderr);
  assert.deepEqual(response.result.tuning, ["E2", "A2", "D3", "G3", "B3", "E4"]);
  assert.equal(response.result.capo, 0);
  assert.deepEqual(response.result.constraints, { maxFret: null, handStretch: "not_evaluated" });
  assert.ok(response.result.positions.every((position) => !Object.hasOwn(position, "capo")));
  const position = response.result.positions[0];
  assert.deepEqual(position.frets, [-1, 3, 2, 0, 1, 0]);
  assert.deepEqual(position.actualFrets, [-1, 3, 2, 0, 1, 0]);
  assert.deepEqual(position.notes, ["C3", "E3", "G3", "C4", "E4"]);
  assert.equal(position.lowestNote, "C3");
  assert.equal(position.lowestMidi, 48);
  assert.equal(position.maxFret, 3);
});

test("guitar.shapes returns stable content references for validated positions", () => {
  const first = request({ op: "guitar.shapes", symbol: "C" }).response.result;
  const second = request({ op: "guitar.shapes", symbol: "C" }).response.result;

  assert.match(first.positions[0].shape_id, /^gshape_[0-9a-f]{64}$/);
  assert.equal(second.positions[0].shape_id, first.positions[0].shape_id);
  assert.notEqual(first.positions[0].shape_id, first.positions[1].shape_id);
});

test("guitar.shapes returns only positions with the requested slash-chord bass", () => {
  const { result, response } = request({ op: "guitar.shapes", symbol: "C/E" });
  assert.equal(result.status, 0, result.stderr);
  assert.equal(response.result.bass, "E");
  assert.ok(response.result.positions.length > 0);
  assert.ok(response.result.positions.every((position) => Math.min(...position.midi) % 12 === 4));
  assert.equal(response.result.positions[0].lowestNote, "E2");
  assert.equal(response.result.positions[0].lowestMidi, 40);
});

test("guitar.shapes reports an explicit no-match for an unsupported slash bass", () => {
  const { result, response } = request({ op: "guitar.shapes", symbol: "C/D" });
  assert.equal(result.status, 1);
  assert.equal(response.error.code, "NO_MATCHING_SHAPE");
});

test("guitar.shapes rejects unsupported tuning and nonzero capo instead of ignoring them", () => {
  const tuning = request({
    op: "guitar.shapes",
    symbol: "C",
    tuning: ["D2", "G2", "C3", "F3", "A3", "D4"],
  });
  assert.equal(tuning.result.status, 1);
  assert.equal(tuning.response.error.code, "UNSUPPORTED_TUNING");

  const capo = request({ op: "guitar.shapes", symbol: "C", capo: 2 });
  assert.equal(capo.result.status, 1);
  assert.equal(capo.response.error.code, "UNSUPPORTED_CAPO");
});

test("guitar.shapes applies a requested physical fret ceiling", () => {
  const { result, response } = request({ op: "guitar.shapes", symbol: "C", maxFret: 3 });
  assert.equal(result.status, 0, result.stderr);
  assert.deepEqual(response.result.constraints, { maxFret: 3, handStretch: "not_evaluated" });
  assert.ok(response.result.positions.every((position) => position.maxFret <= 3));
});

test("guitar.diagram returns validated geometry metadata and Tern-safe SVG", () => {
  const { result, response } = request({ op: "guitar.diagram", symbol: "C", shape_index: 0 });
  assert.equal(result.status, 0, result.stderr);
  assert.equal(response.result.mime, "image/svg+xml");
  assert.match(response.result.svg, /<svg[^>]*viewBox=/);
  assert.ok(response.result.width > 0);
  assert.ok(response.result.height > 0);
  assert.ok(response.result.svgBytes <= 262144);
  assert.equal(response.result.svgBytes, Buffer.byteLength(response.result.svg));
  assert.doesNotMatch(response.result.svg, /\sstyle=/i);
  const tags = [...response.result.svg.matchAll(/<\/?([A-Za-z][\w:-]*)\b[^>]*>/g)].map((match) => match[1]);
  assert.ok(tags.length > 0);
  assert.deepEqual([...new Set(tags.filter((tag) => !ternSvgTags.has(tag)))], []);
});

test("guitar.diagram derives normalized pitch hit regions from rendered SVG", () => {
  const { result, response } = request({ op: "guitar.diagram", symbol: "C", shape_index: 0 });
  const shape = request({ op: "guitar.shapes", symbol: "C" }).response.result.positions[0];
  assert.equal(result.status, 0, result.stderr);
  const sorted = (values) => values.sort((a, b) => a.string - b.string);
  const expected = shape.actualFrets.flatMap((fret, index) =>
    fret < 0 ? [] : [{ string: 6 - index, fret }]);
  assert.deepEqual(sorted(response.result.hit_regions.map(({ string, fret }) => ({ string, fret }))), sorted(expected));
  const lowest = response.result.hit_regions.filter((region) => region.lowest);
  assert.equal(lowest.length, 1);
  assert.equal(lowest[0].midi, shape.lowestMidi);
  assert.equal(lowest[0].pitch, shape.lowestNote);
  for (const region of response.result.hit_regions) {
    assert.ok(region.id);
    assert.ok(region.x >= 0 && region.x < 1);
    assert.ok(region.y >= 0 && region.y < 1);
    assert.ok(region.w > 0 && region.x + region.w <= 1);
    assert.ok(region.h > 0 && region.y + region.h <= 1);
    assert.ok(region.w * response.result.width >= 39);
    assert.ok(region.h * response.result.height >= 39);
  }
});

test("invalid chord requests return a structured error", () => {
  const { result, response } = request({ op: "chord.describe", symbol: "Hmaj7" });
  assert.equal(result.status, 1);
  assert.equal(response.ok, false);
  assert.equal(response.error.code, "INVALID_CHORD");
});
