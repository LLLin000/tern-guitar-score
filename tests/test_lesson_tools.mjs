import assert from "node:assert/strict";
import { mkdtemp, mkdir, readFile, readdir, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { handle, lessonProtocol, validateLesson } from "../renderer/lesson_tools.mjs";
import { handle as musicHandle } from "../renderer/music_tools.mjs";

const baseLesson = (lessonId) => ({
  ...(lessonId ? { lesson_id: lessonId } : {}),
  goal: "Understand C/E as a first-inversion C major chord",
  activities: [
    { id: "intro", type: "explanation", title: "Root and bass", text: "C/E keeps the C major chord tones but places E in the bass." },
    { id: "diagram", type: "chord_diagram", symbol: "C/E", svg: "<script>ignored</script>" },
    {
      id: "check",
      type: "quiz",
      question_type: "slash_bass",
      symbol: "C/E",
      prompt: "Which note is the root?",
      choices: ["C", "E", "G"],
      correct_answer: "E",
      correct_index: 1,
    },
  ],
});

async function tempDir() {
  return mkdtemp(path.join(os.tmpdir(), "gscore-lesson-"));
}

test("Lesson validation generates diagram data and derives the answer key", () => {
  const lesson = validateLesson(baseLesson());
  const diagram = lesson.activities.find((activity) => activity.type === "chord_diagram");
  const quiz = lesson.activities.find((activity) => activity.type === "quiz");

  assert.deepEqual(diagram.pitchClasses, ["C", "E", "G"]);
  assert.equal(diagram.bass, "E");
  assert.match(diagram.svg, /^<svg\b/);
  assert.doesNotMatch(diagram.svg, /script/i);
  assert.equal(quiz.correct_index, 2);
  assert.equal(quiz.prompt, "Which note is the bass of C/E?");
  assert.equal("correct_answer" in quiz, false);
});

test("Lesson validation rejects a model-supplied false answer key", () => {
  const lesson = baseLesson();
  lesson.activities[2].correct_answer = "C";
  assert.throws(() => validateLesson(lesson), { code: "INCORRECT_ANSWER_KEY" });
});

test("slash-bass quiz requires an explicit slash chord and distinct choices", () => {
  const noSlash = baseLesson();
  noSlash.activities[2].symbol = "C";
  noSlash.activities[2].correct_answer = "C";
  assert.throws(() => validateLesson(noSlash), { code: "QUESTION_REQUIRES_SLASH_CHORD" });

  const duplicates = baseLesson();
  duplicates.activities[2].choices = ["C", "E", "G#", "Ab"];
  assert.throws(() => validateLesson(duplicates), { code: "DUPLICATE_CHOICES" });
});

test("publishing writes immutable revisions and unique open requests", async (t) => {
  const dataDir = await tempDir();
  t.after(() => rm(dataDir, { recursive: true, force: true }));

  const first = await handle({ op: "lesson.publish", data_dir: dataDir, lesson: baseLesson("c-e-demo") });
  const second = await handle({ op: "lesson.publish", data_dir: dataDir, lesson: baseLesson("c-e-demo") });
  assert.equal(first.ok, true);
  assert.equal(second.ok, true);
  assert.equal(first.result.revision, 1);
  assert.equal(second.result.revision, 2);
  assert.notEqual(first.result.request_id, second.result.request_id);

  const published = JSON.parse(await readFile(path.join(dataDir, "lessons", "c-e-demo", "r2.json"), "utf8"));
  assert.equal(published.revision, 2);
  assert.equal(published.lesson_id, "c-e-demo");
  const requests = await readdir(path.join(dataDir, "lesson_requests"));
  assert.equal(requests.length, 2);
});

test("Lesson publisher rejects an invalid Tern pane target", async (t) => {
  const dataDir = await tempDir();
  t.after(() => rm(dataDir, { recursive: true, force: true }));
  const response = await handle({
    op: "lesson.publish",
    data_dir: dataDir,
    target_pane: "../another-window",
    lesson: baseLesson("targeted-lesson"),
  });

  assert.equal(response.ok, false);
  assert.equal(response.error.code, "INVALID_TARGET_PANE");
});

test("attempt reader returns only complete, valid records and rejects unsafe ids", async (t) => {
  const dataDir = await tempDir();
  t.after(() => rm(dataDir, { recursive: true, force: true }));
  const dir = path.join(dataDir, "lesson_attempts", "c-e-demo");
  await mkdir(dir, { recursive: true });
  const complete = {
    schema: lessonProtocol.ATTEMPT_SCHEMA,
    attempt_id: "attempt-z",
    lesson_id: "c-e-demo",
    revision: 1,
    activity_id: "check",
    selected_index: 2,
    selected_choice: "E",
    correct: true,
    attempted_at_ms: 300,
    sequence: 2,
  };
  const legacy = { ...complete, attempt_id: "attempt-legacy", attempted_at_ms: 250, sequence: undefined };
  await writeFile(path.join(dir, "attempt_2.json"), JSON.stringify(complete) + lessonProtocol.ATTEMPT_SENTINEL);
  await writeFile(path.join(dir, "attempt_legacy.json"), JSON.stringify(legacy) + lessonProtocol.ATTEMPT_SENTINEL);
  await writeFile(path.join(dir, "attempt_1.json"), JSON.stringify({ ...complete, attempt_id: "attempt-1", attempted_at_ms: 100 }));
  await writeFile(path.join(dir, "attempt_3.json"), JSON.stringify({ ...complete, attempt_id: "attempt-a", selected_index: 1, selected_choice: "C", correct: false, sequence: 3 }) + lessonProtocol.ATTEMPT_SENTINEL);
  await writeFile(path.join(dir, "attempt_4.json"), JSON.stringify({ ...complete, attempt_id: undefined, attempted_at_ms: 400 }) + lessonProtocol.ATTEMPT_SENTINEL);

  const response = await handle({ op: "lesson.attempts", data_dir: dataDir, lesson_id: "c-e-demo" });
  assert.equal(response.ok, true);
  assert.deepEqual(response.result.attempts.map((attempt) => attempt.attempt_id), ["attempt-legacy", "attempt-z", "attempt-a"]);
  assert.deepEqual(response.result.attempts.map((attempt) => attempt.correct), [true, true, false]);
  assert.equal(response.result.ignored_incomplete_or_invalid, 2);
  const unsafe = await handle({ op: "lesson.attempts", data_dir: dataDir, lesson_id: "../outside" });
  assert.equal(unsafe.error.code, "INVALID_ID");
});

test("attempt reader scopes revisions and deduplicates attempt IDs", async (t) => {
  const dataDir = await tempDir();
  t.after(() => rm(dataDir, { recursive: true, force: true }));
  const dir = path.join(dataDir, "lesson_attempts", "revision-demo");
  await mkdir(dir, { recursive: true });
  const first = {
    schema: lessonProtocol.ATTEMPT_SCHEMA,
    attempt_id: "shared-attempt",
    lesson_id: "revision-demo",
    revision: 1,
    activity_id: "quiz",
    selected_index: 2,
    selected_choice: "E",
    correct: true,
    attempted_at_ms: 100,
    sequence: 1,
  };
  const duplicate = {
    ...first,
    selected_index: 1,
    selected_choice: "C",
    correct: false,
    attempted_at_ms: 900,
    sequence: 9,
  };
  const second = { ...first, attempt_id: "revision-two", revision: 2, attempted_at_ms: 200, sequence: 2 };
  for (const [file, attempt] of [
    ["attempt_a.json", first],
    ["attempt_b.json", duplicate],
    ["attempt_c.json", second],
  ]) {
    await writeFile(path.join(dir, file), JSON.stringify(attempt) + lessonProtocol.ATTEMPT_SENTINEL);
  }

  const all = await handle({ op: "lesson.attempts", data_dir: dataDir, lesson_id: "revision-demo" });
  const revisionOne = await handle({ op: "lesson.attempts", data_dir: dataDir, lesson_id: "revision-demo", revision: 1 });
  const revisionTwo = await handle({ op: "lesson.attempts", data_dir: dataDir, lesson_id: "revision-demo", revision: 2 });

  assert.deepEqual(all.result.attempts.map((attempt) => attempt.attempt_id), ["shared-attempt", "revision-two"]);
  assert.equal(all.result.ignored_incomplete_or_invalid, 0);
  assert.equal(all.result.duplicate_attempts_ignored, 1);
  assert.equal(revisionOne.result.revision, 1);
  assert.deepEqual(revisionOne.result.attempts.map((attempt) => attempt.attempt_id), ["shared-attempt"]);
  assert.equal(revisionOne.result.duplicate_attempts_ignored, 1);
  assert.equal(revisionTwo.result.revision, 2);
  assert.deepEqual(revisionTwo.result.attempts.map((attempt) => attempt.attempt_id), ["revision-two"]);
  const invalid = await handle({ op: "lesson.attempts", data_dir: dataDir, lesson_id: "revision-demo", revision: 0 });
  assert.equal(invalid.error.code, "INVALID_REVISION");
});

test("publishing without the host data directory fails explicitly", async () => {
  const response = await handle({ op: "lesson.publish", lesson: baseLesson() });
  assert.equal(response.ok, false);
  assert.equal(response.error.code, "DATA_DIR_UNAVAILABLE");
});

function shapeRef(symbol, positionIndex = 0) {
  const response = musicHandle({ op: "guitar.shapes", symbol });
  assert.equal(response.ok, true);
  return { symbol, id: response.result.positions[positionIndex].shape_id };
}

test("Lesson v2 resolves actual chord shapes and derives its quiz answer", async () => {
  const c = shapeRef("C");
  const cOverE = shapeRef("C/E");
  const response = await handle({
    op: "lesson.validate",
    lesson: {
      schema: "gscore.lesson.v2",
      goal: "Understand the bass difference between C and C/E",
      activities: [
        { id: "explain", type: "explanation", content: "The chord tones stay the same; the lowest note changes." },
        {
          id: "compare",
          type: "visual",
          renderer: "guitar.chord",
          intent: "compare",
          items: [{ shape_ref: c }, { shape_ref: cOverE }],
          emphasis: { property: "lowest_sounding_pitch" },
          interaction: { action: "select_pitch" },
        },
        {
          id: "quiz",
          type: "quiz",
          question: "Which note is the lowest sounding pitch in C/E?",
          options: ["C", "E", "G"],
          answer: { derived_from: cOverE, property: "lowest_sounding_pitch_class" },
        },
      ],
    },
  });

  assert.equal(response.ok, true);
  assert.equal(response.schema, "gscore.lesson.v2");
  const visual = response.result.activities.find((activity) => activity.type === "visual");
  const [cItem, cOverEItem] = visual.items;
  assert.deepEqual(cItem.shape.actualFrets, [-1, 3, 2, 0, 1, 0]);
  assert.deepEqual(cItem.shape.notes, ["C3", "E3", "G3", "C4", "E4"]);
  assert.deepEqual(cItem.shape.midi, [48, 52, 55, 60, 64]);
  assert.deepEqual(cOverEItem.shape.actualFrets, [0, 3, 2, 0, 1, 0]);
  assert.deepEqual(cOverEItem.shape.notes, ["E2", "C3", "E3", "G3", "C4", "E4"]);
  assert.deepEqual(cOverEItem.shape.midi, [40, 48, 52, 55, 60, 64]);
  for (const item of visual.items) {
    const lowestIndex = item.shape.midi.indexOf(Math.min(...item.shape.midi));
    assert.equal(item.shape.lowestMidi, item.shape.midi[lowestIndex]);
    assert.equal(item.shape.lowestNote, item.shape.notes[lowestIndex]);
    assert.deepEqual([...new Set(item.shape.notes.map((note) => note.replace(/\d+$/, "")))].sort(), ["C", "E", "G"]);
  }
  const quiz = response.result.activities.find((activity) => activity.type === "quiz");
  assert.equal(quiz.correct_index, 2);
  assert.equal(quiz.correct_choice, "E");
});

test("Lesson v2 rejects a shape ID paired with a different chord symbol", async () => {
  const c = shapeRef("C");
  const response = await handle({
    op: "lesson.validate",
    lesson: {
      schema: "gscore.lesson.v2",
      goal: "Compare actual guitar shapes",
      activities: [{
        id: "compare",
        type: "visual",
        renderer: "guitar.chord",
        intent: "compare",
        items: [{ shape_ref: c }, { shape_ref: { symbol: "C/E", id: c.id } }],
        emphasis: { property: "lowest_sounding_pitch" },
        interaction: { action: "select_pitch" },
      }],
    },
  });

  assert.equal(response.ok, false);
  assert.equal(response.error.code, "INVALID_SHAPE_REF");
});

test("Lesson v2 keeps revision ownership in the publisher", async () => {
  const response = await handle({
    op: "lesson.validate",
    lesson: {
      schema: "gscore.lesson.v2",
      revision: 1,
      goal: "A publisher-owned revision",
      activities: [{ id: "intro", type: "explanation", content: "Content." }],
    },
  });

  assert.equal(response.ok, false);
  assert.equal(response.error.code, "REVISION_ASSIGNED_BY_PUBLISHER");
});

test("publishing Lesson v2 keeps explicit schema and immutable revisions", async (t) => {
  const dataDir = await tempDir();
  t.after(() => rm(dataDir, { recursive: true, force: true }));
  const lesson = {
    schema: "gscore.lesson.v2",
    lesson_id: "c-e-v2",
    goal: "Compare the bass",
    activities: [{ id: "intro", type: "explanation", content: "C and C/E have different bass notes." }],
  };

  const first = await handle({ op: "lesson.publish", data_dir: dataDir, lesson });
  const second = await handle({
    op: "lesson.publish",
    data_dir: dataDir,
    lesson: { ...lesson, goal: "Re-explain the bass" },
  });
  const firstRevision = JSON.parse(await readFile(path.join(dataDir, "lessons", "c-e-v2", "r1.json"), "utf8"));
  const secondRevision = JSON.parse(await readFile(path.join(dataDir, "lessons", "c-e-v2", "r2.json"), "utf8"));

  assert.equal(first.ok, true);
  assert.equal(first.schema, "gscore.lesson.v2");
  assert.equal(first.result.revision, 1);
  assert.equal(second.result.revision, 2);
  assert.equal(firstRevision.goal, "Compare the bass");
  assert.equal(firstRevision.schema, "gscore.lesson.v2");
  assert.equal(secondRevision.goal, "Re-explain the bass");
});

test("Lesson v2 refuses a lowest-pitch comparison without a real contrast", async () => {
  const c = shapeRef("C");
  const response = await handle({
    op: "lesson.validate",
    lesson: {
      schema: "gscore.lesson.v2",
      goal: "Compare the same shape",
      activities: [{
        id: "compare",
        type: "visual",
        renderer: "guitar.chord",
        intent: "compare",
        items: [{ shape_ref: c }, { shape_ref: c }],
        emphasis: { property: "lowest_sounding_pitch" },
        interaction: { action: "select_pitch" },
      }],
    },
  });

  assert.equal(response.ok, false);
  assert.equal(response.error.code, "NO_LOWEST_PITCH_CONTRAST");
});
