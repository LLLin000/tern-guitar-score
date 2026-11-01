# Tern Guitar Score (`gscore`)

Interactive guitar tablature player and practice companion for [Tern](https://docs.stencil.so/tern/),
built on alphaTab (layout + SoundFont synthesis) and a resident mpv audio engine.

## What it does

- **Formats.** `.musicxml`, `.xml`, `.mxl`, `.gp`, `.gp3`, `.gp4`, `.gp5`, `.gpx` — all eight
  verified end to end (import → render → audio → interactive notes).
- **Real audio.** alphaTab's bundled Sonivox SoundFont is exported offline to a 44.1 kHz stereo
  WAV with peak normalisation and a `tanh` soft limiter (no clipped samples).
- **True audio clock.** Playback state comes from mpv's `time-pos`, not a Luau timer, so the
  cursor cannot drift away from what you hear.
- **Transport.** Play/pause, stop, ±5 s seek, bar-range loop, click-a-note-to-seek, and a
  pitch-preserving speed cycle (0.75× / 1.0× / 1.25×) via mpv's `scaletempo2`.
- **Count-in.** One bar of metronome clicks (accented downbeat) rendered per score, played
  before the first real beat.
- **Multi-score layout.** Several scores side by side in split panes, each with its own
  transport.
- **Agent channel.** `selection.json` (`music_context_v1`) exports the selected bars as
  structured music: stable note ids, string/fret, absolute MIDI, durations, tuplets, ties,
  hammer-ons, slides, tuning and time signature.

## Architecture

Four layers, each owning one concern:

```
Tern Native UI (Luau)        shots, hit boxes, cursor, toolbar, split panes
  ↓
Practice Controller (Luau)   transport state machine, A-B range, count-in, speed
  ↓
Score Engine (alphaTab)      layout, MIDI, note semantics, PNG systems, WAV
  ↓
Audio Engine (mpv + IPC)     playback, seek, speed, loop, authoritative time-pos
```

Luau never synthesises audio and never keeps its own playback clock.

## Files

| File | Role |
| --- | --- |
| `plugin.toml` | Manifest: blocks `score` and `library`, file associations |
| `host.luau` | Blocks: rendering orchestration, hit boxes, transport, selection export |
| `window.luau` | Window commands, split layout, agent request poller |
| `hits.css` | Coordinate classes (`.gx`/`.gy`/`.gw`/`.gh`), cursor, toolbar, library |
| `renderer/index.mjs` | alphaTab → PNG systems + note/beat bounds + `full.wav` + `count_in.wav` |
| `audio_backend.py` | Resident mpv process + JSON IPC over a Windows named pipe |
| `pickfile.py` | Native Windows file dialog, filtered to score formats |

`player.py` and `slice.py` are retired: mpv seeks natively, so pre-sliced segments are no longer
needed.

## Interactive Practice Workflow (P2)

The companion turns selected measures into practice variations that open side by side:

1. **Select measures**: Click or Shift-click measures on any score pane.
2. **Request draft**:
   - **In UI**: Click the **wand button (`🪄`)** on the toolbar. It writes a structured `draft-request.json` (with `selection_file`, `source_pane`, `request_id`, `bars`, `template`, `bpm`), which `window.luau`'s background executor automatically picks up, generates via `tools/generate_draft.py`, and opens beside the original score.
   - **Via CLI / Agent**: Run `python tools/generate_draft.py --open` to create and open a variation immediately.
3. **Musical semantics & validation**:
   - Sounding pitch is strictly validated against `expected_midi = tuning[string - 1] + fret`. Incoherent notes are rejected, not silently invented.
   - Empty selections are rejected rather than falling back to unrelated exercises.
   - `alternate_picking`: writes MusicXML `<down-bow/>` and `<up-bow/>` stroke direction notations according to time signature capacity.
   - `arpeggio`: annotates classical right-hand fingerings (`p`, `i`, `m`, `a`).
   - `slow_drill`: preserves source rhythm while doubling note durations for motor placement.
4. **Practice & compare**:
   - The variation opens as a split pane beside the original score labeled `[Draft]`.
   - Existing panes are preserved (never closed) so original and variations stay side by side.
   - Both original and drafts can be independently played, looped, auditioned, or modified.

```bash
# Generate an alternate-picking study at 60 BPM and open beside the original
python tools/generate_draft.py --template alternate_picking --bpm 60 --open

# Generate an arpeggio study from chord tones in the selection
python tools/generate_draft.py --template arpeggio --bpm 72 --open

# Slow drill: double duration for finger placement practice
python tools/generate_draft.py --template slow_drill --bpm 50 --open
```

## Agent interface

Drop a request file in the plugin data directory; the window half polls it every 400 ms.

```jsonc
// <plugin data>/open-request.json
{"file": "D:/scores/study.gp5"}     // open one score beside the focused pane
{"root": "D:/scores"}               // every score in a folder, one pane each
{"library": "D:/scores"}            // the library picker at that folder
{"dump": true}                      // write the current pane list to panes.txt
{"close": [123, 456]}               // close panes by id
```

Selecting bars in a score writes `<plugin data>/selection.json`:

```jsonc
{
  "version": "1.1.0",
  "protocol": "music_context_v1",
  "path": "...", "title": "...",
  "bars": [4, 7],
  "playback_range_ms": {"t0": 12470, "t1": 24940},
  "tempo_bpm": 77, "median_beat_ms": 390,
  "time_signature": [4, 4], "tuning_midi": [40, 45, 50, 55, 59, 64],
  "notes": [{"id": 1234, "bar": 4, "string": 6, "fret": 0, "midi": 40,
             "duration_ticks": 480, "is_tie": false, "is_hammer_pull": false,
             "is_slide": false, "is_ghost": false, "is_dead": false}],
  "beats": [{"t": 12470, "beat_ids": [12]}]
}
```

## Running

```bash
# Layout + audio for one score
node renderer/index.mjs --input score.gp5 --out <cache dir> --width 800

# The resident audio backend (started by the plugin; runnable standalone for testing)
python audio_backend.py <cache dir>
```

The plugin start sends commands by appending JSONL to `<cache dir>/audio_cmd.jsonl`; the backend
consumes the file atomically and reports state in `audio_state.json` every 30 ms.

## Tests

Both suites run against the repo-local fixture `tests/fixtures/sample.musicxml`, so they need no
private paths.

```bash
python tests/test_audio_backend.py     # burst queue, 1.25x ratio, 6s pause watchdog
python tests/test_concurrency.py       # atomic cmds/ queue, monotonic seq, A-B bounds,
                                       # 10s pause resume position, zero orphan mpv (Job Object)
python tests/test_interactive_workflow.py # P2 end-to-end: selection -> generate draft -> render -> play
```


## Known limits

- Viewport follow issues a TSP `["reveal", key, "nearest"]` frame op when the active system
  changes, and the active row carries `role="score-active"` as a fallback highlight. The reveal
  path has not been verified against a live Tern window yet.
- Count-in length assumes one tempo for the first bar; 6/8 and other compound metres need the
  time signature's beat unit rather than the numerator.
- Viewport width changes re-render into a separate cache directory (`<score>@<width>`) but the
  open pane does not re-request a render at its new width.
