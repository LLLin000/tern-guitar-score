import type { CustomToolFactory } from "@oh-my-pi/pi-coding-agent";

const lessonUrl = new URL("../../renderer/lesson_tools.mjs", import.meta.url).href;
const lessonScript = `import { handle } from ${JSON.stringify(lessonUrl)}; process.stdout.write(JSON.stringify(await handle(JSON.parse(process.argv[1]))));`;

async function invoke(pi, request, signal) {
  const execution = await pi.exec("node", ["--input-type=module", "--eval", lessonScript, JSON.stringify(request)], {
    cwd: pi.cwd,
    signal,
  });
  if (execution.killed) throw new Error("Lesson operation was cancelled.");
  if (execution.code !== 0) throw new Error(execution.stderr || `Lesson operation failed (${execution.code}).`);
  try {
    return JSON.parse(execution.stdout);
  } catch {
    throw new Error("Lesson service returned invalid JSON.");
  }
}

function result(response) {
  return {
    content: [{ type: "text", text: JSON.stringify(response) }],
    details: response,
  };
}

const factory: CustomToolFactory = (pi) => [
  {
    name: "gscore_publish_lesson",
    label: "Publish guitar lesson",
    description: "Publish a strict gscore.lesson.v1 or gscore.lesson.v2. Omit schema only for legacy v1. v2 activities may use a guitar.chord compare visual with shape_ref values copied from gscore_music_query guitar.shapes output, lowest_sounding_pitch emphasis, select_pitch interaction, and a quiz answer derived from a displayed shape. The validator re-resolves shape IDs, calculates actual sounding notes, derives the answer index, and rejects unsupported combinations. revision is assigned by the publisher. Requires GSCORE_DATA_DIR from a Tern host shell; when TERN_PANE is available, the open request targets that pane.",
    parameters: pi.zod.object({
      lesson: pi.zod.object({
        schema: pi.zod.enum(["gscore.lesson.v1", "gscore.lesson.v2"]).optional(),
        lesson_id: pi.zod.string().optional(),
        goal: pi.zod.string(),
        activities: pi.zod.array(pi.zod.any()),
      }),
    }),
    async execute(_toolCallId, params, _onUpdate, _ctx, signal) {
      const response = await invoke(pi, {
        op: "lesson.publish",
        data_dir: process.env.GSCORE_DATA_DIR,
        target_pane: process.env.TERN_PANE,
        lesson: params.lesson,
      }, signal);
      return result(response);
    },
  },
  {
    name: "gscore_read_lesson_attempts",
    label: "Read lesson attempts",
    description: "Read complete persisted quiz attempts so you can adapt the next explanation or exercise. For gscore.lesson.v2, always provide the exact revision; omitting it preserves the legacy all-revisions v1 read. Incomplete writes are excluded and duplicate attempt_id values are returned once.",
    parameters: pi.zod.object({
      lesson_id: pi.zod.string(),
      revision: pi.zod.number().int().positive().optional(),
    }),
    async execute(_toolCallId, params, _onUpdate, _ctx, signal) {
      const response = await invoke(pi, {
        op: "lesson.attempts",
        data_dir: process.env.GSCORE_DATA_DIR,
        lesson_id: params.lesson_id,
        revision: params.revision,
      }, signal);
      return result(response);
    },
  },
];

export default factory;
