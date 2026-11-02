import assert from "node:assert/strict";
import { normalizeRequest } from "../.omp/tools/gscore.ts";

assert.deepEqual(
  normalizeRequest({
    op: "guitar.shapes",
    symbol: " C/E ",
    tonic: "",
    mode: "major",
    notes: [],
    tuning: [],
    capo: 0,
    maxFret: 0,
    shape_index: 0,
  }),
  { op: "guitar.shapes", symbol: "C/E", capo: 0 },
);

assert.deepEqual(
  normalizeRequest({
    op: "guitar.diagram",
    symbol: "C/E",
    tuning: ["E2", "A2", "D3", "G3", "B3", "E4"],
    capo: 2,
    maxFret: 5,
    shape_index: 0,
    tonic: "C",
    mode: "minor",
    notes: ["C", "E"],
  }),
  {
    op: "guitar.diagram",
    symbol: "C/E",
    tuning: ["E2", "A2", "D3", "G3", "B3", "E4"],
    capo: 2,
    maxFret: 5,
    shape_index: 0,
  },
);

assert.deepEqual(
  normalizeRequest({ op: "key.describe", tonic: " A ", mode: "minor", symbol: "C/E", notes: ["C", "E"] }),
  { op: "key.describe", tonic: "A", mode: "minor" },
);

console.log("OMP music request normalization passed");
