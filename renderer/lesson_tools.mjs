import { randomUUID } from "node:crypto";
import { mkdir, readFile, readdir, rename, rm, writeFile } from "node:fs/promises";
import path from "node:path";
import { Note } from "tonal";
import { handle as musicHandle } from "./music_tools.mjs";

const LESSON_SCHEMA_V1 = "gscore.lesson.v1";
const LESSON_SCHEMA_V2 = "gscore.lesson.v2";
const ATTEMPT_SCHEMA = "gscore.lesson.attempt.v1";
const REQUEST_SCHEMA = "gscore.lesson.open.v1";
const ATTEMPT_SENTINEL = "\n__GSCORE_ATTEMPT_END__\n";
const MAX_TEXT = 4000;
const MAX_ACTIVITIES = 12;
const MAX_LESSON_BYTES = 512 * 1024;
const SAFE_ID = /^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$/;

function fail(code, message) {
  const error = new Error(message);
  error.code = code;
  throw error;
}

function record(value, name) {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    fail("INVALID_LESSON", `${name} must be an object.`);
  }
  return value;
}

function strictFields(value, allowed, name) {
  const unexpected = Object.keys(value).find((key) => !allowed.includes(key));
  if (unexpected) fail("INVALID_LESSON", `${name}.${unexpected} is not supported.`);
}

function text(value, name, max = MAX_TEXT) {
  if (typeof value !== "string" || !value.trim() || value.length > max) {
    fail("INVALID_LESSON", `${name} must be non-empty text of at most ${max} characters.`);
  }
  return value.trim();
}

function safeId(value, name) {
  if (typeof value !== "string" || !SAFE_ID.test(value)) {
    fail("INVALID_ID", `${name} must contain only letters, numbers, underscores, or hyphens.`);
  }
  return value;
}

function musicResult(request, expectedOp) {
  const response = musicHandle(request);
  if (!response.ok || response.op !== expectedOp) {
    fail(response.error?.code ?? "MUSIC_VALIDATION_FAILED", response.error?.message ?? `Music validation failed for ${expectedOp}.`);
  }
  return response.result;
}

export function validateLesson(input) {
  const lesson = record(input, "lesson");
  const schema = lesson.schema ?? LESSON_SCHEMA_V1;
  if (schema === LESSON_SCHEMA_V2) return validateLessonV2(lesson);
  if (schema !== LESSON_SCHEMA_V1) fail("UNSUPPORTED_SCHEMA", `Unsupported Lesson schema '${schema}'.`);
  const goal = text(lesson.goal, "goal");
  if (!Array.isArray(lesson.activities) || lesson.activities.length < 1 || lesson.activities.length > MAX_ACTIVITIES) {
    fail("INVALID_LESSON", `activities must contain 1–${MAX_ACTIVITIES} items.`);
  }

  const ids = new Set();
  const activities = lesson.activities.map((raw, index) => {
    const activity = record(raw, `activities[${index}]`);
    const id = safeId(activity.id, `activities[${index}].id`);
    if (ids.has(id)) fail("DUPLICATE_ACTIVITY_ID", `Activity id '${id}' is duplicated.`);
    ids.add(id);

    if (activity.type === "explanation") {
      return {
        id,
        type: "explanation",
        title: typeof activity.title === "string" && activity.title.trim() ? text(activity.title, `${id}.title`, 120) : "Explanation",
        text: text(activity.text, `${id}.text`),
      };
    }

    if (activity.type === "chord_diagram") {
      const symbol = text(activity.symbol, `${id}.symbol`, 80);
      const shapeIndex = activity.shape_index ?? 0;
      if (!Number.isInteger(shapeIndex) || shapeIndex < 0) fail("INVALID_POSITION", `${id}.shape_index must be a non-negative integer.`);
      const shapes = musicResult({ op: "guitar.shapes", symbol }, "guitar.shapes");
      if (shapeIndex >= shapes.positions.length) fail("NO_MATCHING_SHAPE", `No matching database shape ${shapeIndex + 1} exists for ${symbol}.`);
      const diagram = musicResult({ op: "guitar.diagram", symbol, shape_index: shapeIndex }, "guitar.diagram");
      return {
        id,
        type: "chord_diagram",
        symbol: shapes.symbol,
        name: shapes.name,
        bass: shapes.bass,
        pitchClasses: musicResult({ op: "chord.describe", symbol }, "chord.describe").pitchClasses,
        shape_index: shapeIndex,
        shape: shapes.positions[shapeIndex],
        svg: diagram.svg,
        mime: diagram.mime,
        alt: diagram.alt,
        width: diagram.width,
        height: diagram.height,
      };
    }

    if (activity.type === "quiz") {
      if (activity.question_type !== "slash_bass") {
        fail("UNSUPPORTED_QUESTION", `${id}.question_type must be 'slash_bass' in this Lesson version.`);
      }
      const symbol = text(activity.symbol, `${id}.symbol`, 80);
      const chord = musicResult({ op: "chord.describe", symbol }, "chord.describe");
      if (!chord.bass) fail("QUESTION_REQUIRES_SLASH_CHORD", `${symbol} has no explicit slash bass for this quiz type.`);
      if (!Array.isArray(activity.choices) || activity.choices.length < 2 || activity.choices.length > 6) {
        fail("INVALID_CHOICES", `${id}.choices must contain 2–6 answers.`);
      }
      const pitchClasses = new Set();
      const choices = activity.choices.map((choice, choiceIndex) => {
        const value = text(choice, `${id}.choices[${choiceIndex}]`, 12);
        const note = Note.get(value);
        if (/\d/.test(value) || note.empty) fail("INVALID_CHOICE_NOTE", `${id}.choices[${choiceIndex}] must be a note name without an octave.`);
        if (pitchClasses.has(note.chroma)) fail("DUPLICATE_CHOICES", `${id}.choices must use distinct pitch classes.`);
        pitchClasses.add(note.chroma);
        return value;
      });
      if (activity.correct_answer !== chord.bass) {
        fail("INCORRECT_ANSWER_KEY", `${id}.correct_answer must match the calculated slash bass '${chord.bass}'.`);
      }
      const correctIndex = choices.indexOf(chord.bass);
      if (correctIndex < 0) fail("ANSWER_NOT_IN_CHOICES", `${id}.choices must include the calculated slash bass '${chord.bass}'.`);
      return {
        id,
        type: "quiz",
        question_type: "slash_bass",
        symbol,
        prompt: `Which note is the bass of ${symbol}?`,
        choices,
        correct_index: correctIndex + 1,
      };
    }

    fail("UNSUPPORTED_ACTIVITY", `${id}.type must be explanation, chord_diagram, or quiz.`);
  });

  return { goal, activities };
}

function resolveShapeRef(value, name) {
  const ref = record(value, name);
  strictFields(ref, ["symbol", "id"], name);
  const symbol = text(ref.symbol, `${name}.symbol`, 80);
  const id = text(ref.id, `${name}.id`);
  if (!/^gshape_[0-9a-f]{64}$/.test(id)) fail("INVALID_SHAPE_REF", `${name}.id is not a calculator shape reference.`);

  const shapes = musicResult({ op: "guitar.shapes", symbol }, "guitar.shapes");
  const shapeIndex = shapes.positions.findIndex((position) => position.shape_id === id);
  if (shapeIndex < 0) fail("INVALID_SHAPE_REF", `${name} does not identify a current shape for ${symbol}.`);
  const shape = shapes.positions[shapeIndex];
  const chord = musicResult({ op: "chord.describe", symbol }, "chord.describe");
  const chordChromas = new Set(chord.pitchClasses.map((note) => Note.get(note).chroma));
  const shapeChromas = new Set(shape.notes.map((note) => Note.get(note).chroma));
  if ([...shapeChromas].some((chroma) => !chordChromas.has(chroma))) {
    fail("SHAPE_PITCH_MISMATCH", `${name} contains a pitch outside ${symbol}.`);
  }
  if ([...chordChromas].some((chroma) => !shapeChromas.has(chroma))) {
    fail("INCOMPLETE_CHORD_SHAPE", `${name} does not contain every chord tone of ${symbol}.`);
  }
  const lowestIndex = shape.midi.indexOf(Math.min(...shape.midi));
  if (shape.lowestMidi !== shape.midi[lowestIndex] || shape.lowestNote !== shape.notes[lowestIndex]) {
    fail("SHAPE_LOWEST_PITCH_MISMATCH", `${name} lowest pitch does not match its calculated notes.`);
  }
  return { shape_ref: { symbol, id }, shapeIndex, symbol: shapes.symbol, chord, shape };
}

function validateDiagramHitRegions(diagram, shape, name) {
  if (!Array.isArray(diagram.hit_regions)) {
    fail("INVALID_HIT_REGIONS", `${name} diagram is missing renderer-derived hit regions.`);
  }
  const noteByString = new Map();
  let noteIndex = 0;
  shape.actualFrets.forEach((fret, index) => {
    if (fret < 0) return;
    noteByString.set(6 - index, {
      fret,
      pitch: shape.notes[noteIndex],
      midi: shape.midi[noteIndex],
      lowest: shape.midi[noteIndex] === shape.lowestMidi,
    });
    noteIndex += 1;
  });
  if (diagram.hit_regions.length !== noteByString.size) {
    fail("INVALID_HIT_REGIONS", `${name} diagram must have one hit region for every sounding string.`);
  }
  const seen = new Set();
  for (const region of diagram.hit_regions) {
    const expected = noteByString.get(region?.string);
    const id = `s${region?.string}f${region?.fret}`;
    if (!expected || seen.has(id) || region.id !== id || region.fret !== expected.fret
        || region.pitch !== expected.pitch || region.midi !== expected.midi || region.lowest !== expected.lowest
        || ![region.x, region.y, region.w, region.h].every(Number.isFinite)
        || region.x < 0 || region.y < 0 || region.w <= 0 || region.h <= 0
        || region.x + region.w > 1 || region.y + region.h > 1) {
      fail("INVALID_HIT_REGIONS", `${name} contains a hit region that does not match the verified shape.`);
    }
    seen.add(id);
  }
}

function validateLessonV2(lesson) {
  if (lesson.schema !== LESSON_SCHEMA_V2) fail("UNSUPPORTED_SCHEMA", "Lesson v2 requires schema 'gscore.lesson.v2'.");
  if ("revision" in lesson) fail("REVISION_ASSIGNED_BY_PUBLISHER", "revision is assigned when the Lesson is published.");
  strictFields(lesson, ["schema", "lesson_id", "goal", "activities"], "lesson");
  if (lesson.lesson_id !== undefined) safeId(lesson.lesson_id, "lesson_id");
  const goal = text(lesson.goal, "goal");
  if (!Array.isArray(lesson.activities) || lesson.activities.length < 1 || lesson.activities.length > MAX_ACTIVITIES) {
    fail("INVALID_LESSON", `activities must contain 1–${MAX_ACTIVITIES} items.`);
  }

  const ids = new Set();
  const shapes = new Map();
  const activities = lesson.activities.map((raw, index) => {
    const name = `activities[${index}]`;
    const activity = record(raw, name);
    const id = safeId(activity.id, `${name}.id`);
    if (ids.has(id)) fail("DUPLICATE_ACTIVITY_ID", `Activity id '${id}' is duplicated.`);
    ids.add(id);

    if (activity.type === "explanation") {
      strictFields(activity, ["id", "type", "content"], name);
      return { id, type: "explanation", content: text(activity.content, `${id}.content`) };
    }

    if (activity.type === "visual") {
      strictFields(activity, ["id", "type", "renderer", "intent", "items", "emphasis", "interaction"], name);
      if (activity.renderer !== "guitar.chord") {
        fail("UNSUPPORTED_RENDERER", `${id}.renderer must be 'guitar.chord'.`);
      }
      if (activity.intent !== "compare") fail("UNSUPPORTED_VISUAL_INTENT", `${id}.intent must be 'compare'.`);
      if (!Array.isArray(activity.items) || activity.items.length !== 2) {
        fail("INVALID_VISUAL_ITEMS", `${id}.items must contain exactly two shape references.`);
      }
      const emphasis = record(activity.emphasis, `${id}.emphasis`);
      strictFields(emphasis, ["property"], `${id}.emphasis`);
      if (emphasis.property !== "lowest_sounding_pitch") {
        fail("UNSUPPORTED_EMPHASIS", `${id}.emphasis.property must be 'lowest_sounding_pitch'.`);
      }
      const interaction = record(activity.interaction, `${id}.interaction`);
      strictFields(interaction, ["action"], `${id}.interaction`);
      if (interaction.action !== "select_pitch") {
        fail("UNSUPPORTED_INTERACTION", `${id}.interaction.action must be 'select_pitch'.`);
      }

      const items = activity.items.map((rawItem, itemIndex) => {
        const itemName = `${id}.items[${itemIndex}]`;
        const item = record(rawItem, itemName);
        strictFields(item, ["shape_ref"], itemName);
        const resolved = resolveShapeRef(item.shape_ref, `${itemName}.shape_ref`);
        const diagram = musicResult({
          op: "guitar.diagram",
          symbol: resolved.symbol,
          shape_index: resolved.shapeIndex,
        }, "guitar.diagram");
        validateDiagramHitRegions(diagram, resolved.shape, `${itemName}.shape_ref`);
        shapes.set(resolved.shape_ref.id, resolved);
        return {
          shape_ref: resolved.shape_ref,
          symbol: resolved.symbol,
          shape: { ...resolved.shape, pitchClasses: resolved.chord.pitchClasses },
          diagram,
        };
      });
      if (items[0].shape.lowestMidi === items[1].shape.lowestMidi) {
        fail("NO_LOWEST_PITCH_CONTRAST", `${id} must compare different lowest sounding pitches.`);
      }
      return { id, type: "visual", renderer: activity.renderer, intent: activity.intent, items, emphasis, interaction };
    }

    if (activity.type === "quiz") {
      strictFields(activity, ["id", "type", "question", "options", "answer"], name);
      const question = text(activity.question, `${id}.question`);
      if (!Array.isArray(activity.options) || activity.options.length < 2 || activity.options.length > 6) {
        fail("INVALID_CHOICES", `${id}.options must contain 2–6 note names.`);
      }
      const seenChromas = new Set();
      const options = activity.options.map((option, optionIndex) => {
        const value = text(option, `${id}.options[${optionIndex}]`, 12);
        const note = Note.get(value);
        if (/\d/.test(value) || note.empty) fail("INVALID_CHOICE_NOTE", `${id}.options[${optionIndex}] must be a note name without an octave.`);
        if (seenChromas.has(note.chroma)) fail("DUPLICATE_CHOICES", `${id}.options must use distinct pitch classes.`);
        seenChromas.add(note.chroma);
        return value;
      });
      const answer = record(activity.answer, `${id}.answer`);
      strictFields(answer, ["derived_from", "property"], `${id}.answer`);
      if (answer.property !== "lowest_sounding_pitch_class") {
        fail("UNSUPPORTED_ANSWER_PROPERTY", `${id}.answer.property must be 'lowest_sounding_pitch_class'.`);
      }
      const answerRef = resolveShapeRef(answer.derived_from, `${id}.answer.derived_from`);
      const visualShape = shapes.get(answerRef.shape_ref.id);
      if (!visualShape || visualShape.symbol !== answerRef.symbol) {
        fail("ANSWER_SHAPE_NOT_IN_LESSON", `${id}.answer must refer to a shape shown earlier in this Lesson.`);
      }
      const lowestChroma = Note.get(visualShape.shape.lowestNote).chroma;
      const correctIndex = options.findIndex((option) => Note.get(option).chroma === lowestChroma);
      if (correctIndex < 0) fail("ANSWER_NOT_IN_CHOICES", `${id}.options must include the calculated bass pitch class.`);
      return {
        id,
        type: "quiz",
        question,
        options,
        correct_index: correctIndex + 1,
        correct_choice: options[correctIndex],
        answer_source: { derived_from: visualShape.shape_ref, property: answer.property },
      };
    }

    fail("UNSUPPORTED_ACTIVITY", `${id}.type must be explanation, visual, or quiz.`);
  });

  return { schema: LESSON_SCHEMA_V2, goal, activities };
}

async function atomicWrite(file, contents) {
  await mkdir(path.dirname(file), { recursive: true });
  const temporary = `${file}.${randomUUID()}.tmp`;
  try {
    await writeFile(temporary, contents, { encoding: "utf8", flag: "wx" });
    await rename(temporary, file);
  } catch (error) {
    await rm(temporary, { force: true });
    throw error;
  }
}

function requireDataDir(value) {
  if (typeof value !== "string" || !value.trim()) {
    fail("DATA_DIR_UNAVAILABLE", "GSCORE_DATA_DIR is not set; run this OMP tool in a Tern host shell with the gscore plugin linked or installed.");
  }
  return path.resolve(value);
}

async function publishLesson(request) {
  const dataDir = requireDataDir(request.data_dir);
  const targetPane = request.target_pane;
  if (targetPane !== undefined && (typeof targetPane !== "string" || !SAFE_ID.test(targetPane))) {
    fail("INVALID_TARGET_PANE", "target_pane must be a safe Tern pane identifier.");
  }
  const validated = validateLesson(request.lesson);
  const id = request.lesson?.lesson_id ? safeId(request.lesson.lesson_id, "lesson_id") : `lesson_${randomUUID()}`;
  const lessonDir = path.join(dataDir, "lessons", id);
  await mkdir(lessonDir, { recursive: true });
  const files = await readdir(lessonDir);
  const revision = files.reduce((max, file) => {
    const match = /^r(\d+)\.json$/.exec(file);
    return match ? Math.max(max, Number(match[1])) : max;
  }, 0) + 1;

  const published = {
    schema: validated.schema ?? LESSON_SCHEMA_V1,
    lesson_id: id,
    revision,
    goal: validated.goal,
    activities: validated.activities,
    created_at_ms: Date.now(),
  };
  const contents = `${JSON.stringify(published)}\n`;
  if (Buffer.byteLength(contents, "utf8") > MAX_LESSON_BYTES) {
    fail("LESSON_TOO_LARGE", "The published Lesson exceeds Tern's 512 KiB limit.");
  }
  await atomicWrite(path.join(lessonDir, `r${revision}.json`), contents);

  const requestId = randomUUID();
  const openRequest = {
    schema: REQUEST_SCHEMA,
    lesson_id: id,
    revision,
    request_id: requestId,
    ...(targetPane !== undefined ? { target_pane: targetPane } : {}),
  };
  await atomicWrite(path.join(dataDir, "lesson_requests", `req_${requestId}.json`), `${JSON.stringify(openRequest)}\n`);
  return {
    schema: published.schema,
    ok: true,
    op: "lesson.publish",
    result: { lesson_id: id, revision, goal: published.goal, activity_count: published.activities.length, request_id: requestId },
  };
}

function parseCompleteAttempt(contents, lessonId) {
  if (!contents.endsWith(ATTEMPT_SENTINEL)) return null;
  try {
    const attempt = JSON.parse(contents.slice(0, -ATTEMPT_SENTINEL.length));
    if (attempt.schema !== ATTEMPT_SCHEMA || attempt.lesson_id !== lessonId) return null;
    if (!Number.isInteger(attempt.revision) || attempt.revision < 1) return null;
    if (typeof attempt.attempt_id !== "string" || !SAFE_ID.test(attempt.attempt_id)) return null;
    if (!Number.isInteger(attempt.selected_index) || attempt.selected_index < 1) return null;
    if (typeof attempt.selected_choice !== "string" || typeof attempt.correct !== "boolean") return null;
    if (!Number.isFinite(attempt.attempted_at_ms)) return null;
    if (attempt.sequence === undefined) attempt.sequence = 0;
    if (!Number.isInteger(attempt.sequence) || attempt.sequence < 0) return null;
    return attempt;
  } catch {
    return null;
  }
}

async function readAttempts(request) {
  const dataDir = requireDataDir(request.data_dir);
  const lessonId = safeId(request.lesson_id, "lesson_id");
  const revision = request.revision;
  if (revision !== undefined && (!Number.isInteger(revision) || revision < 1)) {
    fail("INVALID_REVISION", "revision must be a positive integer when supplied.");
  }
  const revisionResult = revision === undefined ? {} : { revision };
  const directory = path.join(dataDir, "lesson_attempts", lessonId);
  let files;
  try {
    files = await readdir(directory);
  } catch (error) {
    if (error.code === "ENOENT") {
      return {
        schema: LESSON_SCHEMA_V1,
        ok: true,
        op: "lesson.attempts",
        result: {
          lesson_id: lessonId,
          ...revisionResult,
          attempts: [],
          ignored_incomplete_or_invalid: 0,
          duplicate_attempts_ignored: 0,
        },
      };
    }
    throw error;
  }

  const attempts = [];
  const seenAttemptIds = new Set();
  let ignoredIncompleteOrInvalid = 0;
  let duplicateAttemptsIgnored = 0;
  for (const file of files.sort()) {
    if (!/^attempt_[A-Za-z0-9_-]+\.json$/.test(file)) continue;
    try {
      const contents = await readFile(path.join(directory, file), "utf8");
      const attempt = parseCompleteAttempt(contents, lessonId);
      if (!attempt) {
        ignoredIncompleteOrInvalid += 1;
      } else if (revision !== undefined && attempt.revision !== revision) {
        continue;
      } else if (seenAttemptIds.has(attempt.attempt_id)) {
        duplicateAttemptsIgnored += 1;
      } else {
        seenAttemptIds.add(attempt.attempt_id);
        attempts.push(attempt);
      }
    } catch {
      ignoredIncompleteOrInvalid += 1;
    }
  }
  attempts.sort((a, b) => a.attempted_at_ms - b.attempted_at_ms || a.sequence - b.sequence || a.attempt_id.localeCompare(b.attempt_id));
  return {
    schema: LESSON_SCHEMA_V1,
    ok: true,
    op: "lesson.attempts",
    result: {
      lesson_id: lessonId,
      ...revisionResult,
      attempts,
      ignored_incomplete_or_invalid: ignoredIncompleteOrInvalid,
      duplicate_attempts_ignored: duplicateAttemptsIgnored,
    },
  };
}

export async function handle(request) {
  try {
    record(request, "request");
    if (request.op === "lesson.validate") {
      const lesson = validateLesson(request.lesson);
      return { schema: lesson.schema ?? LESSON_SCHEMA_V1, ok: true, op: request.op, result: lesson };
    }
    if (request.op === "lesson.publish") return await publishLesson(request);
    if (request.op === "lesson.attempts") return await readAttempts(request);
    fail("UNKNOWN_OPERATION", `Unknown Lesson operation '${request.op}'.`);
  } catch (error) {
    return {
      schema: request?.lesson?.schema ?? LESSON_SCHEMA_V1,
      ok: false,
      op: request?.op ?? null,
      error: { code: error.code ?? "LESSON_ERROR", message: error.message },
    };
  }
}

export const lessonProtocol = { LESSON_SCHEMA_V1, LESSON_SCHEMA_V2, ATTEMPT_SCHEMA, REQUEST_SCHEMA, ATTEMPT_SENTINEL };
