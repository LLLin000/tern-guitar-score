import type { CustomToolFactory } from "@oh-my-pi/pi-coding-agent";
// ponytail: a Node child avoids OMP's Bun resolver missing renderer-local npm deps; one process per query.
const calculatorUrl = new URL("../../renderer/music_tools.mjs", import.meta.url).href;
const queryScript = `import { handle } from ${JSON.stringify(calculatorUrl)};
process.stdout.write(JSON.stringify(handle(JSON.parse(process.argv[1]))));`;
export function normalizeRequest(params: {
  op: string;
  symbol?: string;
  tonic?: string;
  mode?: string;
  notes?: string[];
  tuning?: string[];
  capo?: number;
  maxFret?: number;
  shape_index?: number;
}): Record<string, unknown> {
  const request: Record<string, unknown> = { op: params.op };
  const symbol = params.symbol?.trim();
  if (["chord.describe", "guitar.shapes", "guitar.diagram"].includes(params.op) && symbol) {
    request.symbol = symbol;
  }
  if (params.op === "key.describe") {
    const tonic = params.tonic?.trim();
    if (tonic) request.tonic = tonic;
    if (params.mode) request.mode = params.mode;
  } else if (params.op === "chord.detect") {
    if (params.notes?.length) request.notes = params.notes;
  } else if (params.op === "guitar.shapes" || params.op === "guitar.diagram") {
    if (params.tuning?.length) request.tuning = params.tuning;
    if (Number.isInteger(params.capo)) request.capo = params.capo;
    // OMP models may emit 0 for an unused optional number; reserve 0 as no cap.
    if (Number.isInteger(params.maxFret) && params.maxFret! > 0) request.maxFret = params.maxFret;
    if (params.op === "guitar.diagram" && Number.isInteger(params.shape_index)) {
      request.shape_index = params.shape_index;
    }
  }
  return request;
}


const factory: CustomToolFactory = (pi) => ({
  name: "gscore_music_query",
  label: "Guitar music query",
  description: "Read-only chord, key, detection, and curated guitar-shape calculations. guitar.shapes returns stable shape_id references plus notes, MIDI, and the actual lowestNote/lowestMidi; copy the shape_id into a v2 Lesson and never infer bass from the chord label. Shapes support standard tuning and capo 0 only. Empty optional fields are ignored; maxFret=0 means no cap. Detection may be ambiguous. guitar.diagram returns geometry metadata, not raw SVG text.",
  parameters: pi.zod.object({
    op: pi.zod.enum([
      "chord.describe",
      "key.describe",
      "chord.detect",
      "guitar.shapes",
      "guitar.diagram",
    ]),
    symbol: pi.zod.string().optional(),
    tonic: pi.zod.string().optional(),
    mode: pi.zod.enum(["major", "minor"]).optional(),
    notes: pi.zod.array(pi.zod.string()).optional(),
    tuning: pi.zod.array(pi.zod.string()).optional(),
    capo: pi.zod.number().int().optional(),
    maxFret: pi.zod.number().int().optional(),
    shape_index: pi.zod.number().int().optional(),
  }),
  async execute(_toolCallId, params, _onUpdate, _ctx, signal) {
    const execution = await pi.exec("node", [
      "--input-type=module",
      "--eval",
      queryScript,
      JSON.stringify(normalizeRequest(params)),
    ], { cwd: pi.cwd, signal });
    if (execution.killed) throw new Error("Music query was cancelled.");
    if (execution.code !== 0) throw new Error(execution.stderr || `Music query failed (${execution.code}).`);
    let response;
    try {
      response = JSON.parse(execution.stdout);
    } catch {
      throw new Error("Music calculator returned invalid JSON.");
    }
    if (!response.ok) {
      return {
        content: [{ type: "text", text: JSON.stringify(response) }],
        details: response,
      };
    }
    if (response.op === "guitar.diagram") {
      const { svg, ...diagram } = response.result;
      return {
        content: [{ type: "text", text: JSON.stringify({ ...response, result: diagram }) }],
        details: { mime: diagram.mime, alt: diagram.alt, svg },
      };
    }
    return {
      content: [{ type: "text", text: JSON.stringify(response) }],
      details: response,
    };
  },
});

export default factory;
