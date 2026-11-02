---
name: guitar-tutor
description: Teach guitar harmony and theory with verified music calculations, renderer-backed guitar visuals, and revision-scoped Lesson feedback.
---

# Guitar tutor workflow

Use this skill when the learner asks for a guitar lesson, chord explanation, inversion, voicing comparison, or a short theory quiz.

1. Clarify the learning goal from the prompt. Adapt explanation depth to evidence in the conversation; do not assume one quiz proves mastery.
2. Call `gscore_music_query` for chord tones, slash bass, key facts, and available guitar shapes. Treat the returned calculation as authoritative for those fields. A shape is a curated database result, not a guarantee of comfort or a universal fingering solver.
3. Default new Tern Lessons to `gscore.lesson.v2`. Build only supported activities:
   - `explanation`: `{id, type:"explanation", content}`
   - `visual`: `{id, type:"visual", renderer:"guitar.chord", intent:"compare", items:[{shape_ref}, {shape_ref}], emphasis:{property:"lowest_sounding_pitch"}, interaction:{action:"select_pitch"}}`
   - `quiz`: `{id, type:"quiz", question, options, answer:{derived_from:shape_ref, property:"lowest_sounding_pitch_class"}}`
4. Copy `{symbol, id}` shape refs from `gscore_music_query` `guitar.shapes` output. The validator re-resolves each shape, checks actual string/fret pitches and renderer hit regions, and derives the quiz answer. Use two shapes with distinct lowest MIDI pitches. Do not provide SVG, pixel coordinates, answer indices, or a manual revision.
5. If the goal is not a comparison of two supported guitar shapes, teach in chat rather than inventing an unsupported v2 visual. Use v1 only to maintain an existing v1 Lesson; its activities remain `explanation` (`title?`, `text`), `chord_diagram` (`symbol`, `shape_index?`), and `slash_bass` quiz (`symbol`, `choices`, `correct_answer`).
6. Publish only the complete lesson. Reusing `lesson_id` appends a new immutable revision; the publisher assigns the revision and queues a `gscore.lesson` pane. Report it as queued, not visibly open, until Tern confirms the pane appeared.
7. For a v2 learner response, call `gscore_read_lesson_attempts` with the exact `lesson_id` and `revision`. Use the recorded wrong answer to change the explanation or example, then publish a new revision with the same `lesson_id`; keep earlier revisions intact. Omit `revision` only for a legacy v1 all-revisions read.

The project-level tool and skill are discovered when OMP runs with this repository as its working directory. A shell/Agent host must also inherit `GSCORE_DATA_DIR` from the linked or installed Tern plugin; this shared-filesystem path is currently same-host only.
