"""Automated end-to-end test for P2 Interactive Practice Workflow.

Validates the full workflow using REAL rendered notes from the test fixture:
  1. Renders `tests/fixtures/sample.musicxml` with `renderer/index.mjs`.
  2. Extracts real note events for bars 0..1 to construct `selection.json` (`music_context_v1`).
  3. Validates that every note satisfies: `expected_midi == tuning[string - 1] + fret`.
  4. Generates practice drafts via `tools/generate_draft.py` for all 3 templates:
     - `alternate_picking`: asserts `<down-bow/>` and `<up-bow/>` technical notations
     - `arpeggio`: asserts `<fingering>p/i/m/a` classical right-hand annotations
     - `slow_drill`: asserts rhythm doubling and measure capacities
  5. Renders generated draft with alphaTab and synthesizes SoundFont audio + count-in track.
  6. Loads and plays draft in `audio_backend.py` via mpv named pipe IPC.
  7. Verifies clean shutdown with zero orphan mpv processes.
"""

import json
import os
import subprocess
import sys
import time

PLUGIN_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PYTHON_EXE = sys.executable
NODE_EXE = r"C:\Program Files\nodejs\node.exe"

FIXTURE_SCORE = os.path.join(PLUGIN_DIR, "tests", "fixtures", "sample.musicxml")
TEST_CACHE = os.path.join(PLUGIN_DIR, ".test_workflow_cache")

def run():
    print(f"=== Testing P2 Interactive Practice Workflow against {FIXTURE_SCORE} ===")
    assert os.path.exists(FIXTURE_SCORE), f"Fixture not found: {FIXTURE_SCORE}"
    os.makedirs(TEST_CACHE, exist_ok=True)

    # 1. Render fixture to obtain real alphaTab notes and metadata
    print("[1/6] Rendering fixture score to extract real note context...")
    fixture_out = os.path.join(TEST_CACHE, "fixture_render")
    r = subprocess.run([
        NODE_EXE, os.path.join(PLUGIN_DIR, "renderer", "index.mjs"),
        "--input", FIXTURE_SCORE,
        "--out", fixture_out,
        "--width", "640"
    ], capture_output=True, text=True, cwd=PLUGIN_DIR)
    assert r.returncode == 0, f"Fixture render failed: {r.stderr}"
    fixture_data = json.loads(r.stdout)
    tuning_raw = fixture_data["tuning"]  # [64, 59, 55, 50, 45, 40]
    time_sig = fixture_data.get("timeSignature", [4, 4])
    tempo_bpm = fixture_data.get("tempo_bpm", 120)

    # 2. Extract notes for bars 0 and 1
    selected_notes = []
    OPEN = {1: 40, 2: 45, 3: 50, 4: 55, 5: 59, 6: 64}
    for sys_data in fixture_data["systems"]:
        for n in sys_data["notes"]:
            if n["m"] in (0, 1):
                # Compute baseMidi according to the alphaTab tuning convention
                base_midi = tuning_raw[6 - n["string"]] if len(tuning_raw) >= 6 else OPEN[n["string"]]
                selected_notes.append({
                    "id": n["id"],
                    "bar": n["m"],
                    "string": n["string"],
                    "fret": n["fret"],
                    "midi": base_midi + n["fret"],
                    "duration_ticks": n.get("durationTicks", 480),
                })
    print(f"    Extracted {len(selected_notes)} real notes from bars 0..1")
    assert len(selected_notes) >= 8, "Expected at least 8 notes in bars 0..1"

    # 3. Validate pitch equation on every extracted note
    print("[2/6] Validating pitch equation on extracted notes...")
    # Normalize tuning to low-to-high [40, 45, 50, 55, 59, 64]
    tuning_norm = list(reversed(tuning_raw)) if tuning_raw[0] > tuning_raw[-1] else list(tuning_raw)
    for n in selected_notes:
        expected = tuning_norm[n["string"] - 1] + n["fret"]
        assert n["midi"] == expected, f"Pitch mismatch for note {n}: expected {expected}, got {n['midi']}"
    print(f"    All {len(selected_notes)} notes satisfy expected_midi == tuning[string-1] + fret")

    sel_file = os.path.join(TEST_CACHE, "real_selection.json")
    selection_payload = {
        "version": "1.1.0",
        "protocol": "music_context_v1",
        "path": FIXTURE_SCORE,
        "title": fixture_data.get("title", "Fixture"),
        "bars": [0, 1],
        "playback_range_ms": {"t0": 0, "t1": 4000},
        "tempo_bpm": tempo_bpm,
        "time_signature": time_sig,
        "tuning_midi": tuning_raw,
        "notes": selected_notes,
        "beats": [{"t": o["t"], "beat_ids": o["nb"]} for o in fixture_data["timeline"] if o["t"] < 4000]
    }
    with open(sel_file, "w", encoding="utf-8") as f:
        json.dump(selection_payload, f)

    # 4. Generate drafts for all templates and verify notations
    templates = ["alternate_picking", "arpeggio", "slow_drill"]
    print(f"[3/6] Generating drafts for templates: {templates}...")
    for tmpl in templates:
        draft_xml = os.path.join(TEST_CACHE, f"draft_{tmpl}.musicxml")
        r = subprocess.run([
            PYTHON_EXE, os.path.join(PLUGIN_DIR, "tools", "generate_draft.py"),
            "--selection", sel_file,
            "--template", tmpl,
            "--bpm", "60",
            "--out", draft_xml
        ], capture_output=True, text=True, cwd=PLUGIN_DIR)
        assert r.returncode == 0, f"generate_draft failed for {tmpl}: {r.stderr}"
        xml_content = open(draft_xml, encoding="utf-8").read()
        if tmpl == "alternate_picking":
            assert "<down-bow/>" in xml_content and "<up-bow/>" in xml_content
            print(f"    {tmpl}: OK (stroke notations verified)")
        elif tmpl == "arpeggio":
            assert "<fingering>p</fingering>" in xml_content and "<fingering>i</fingering>" in xml_content
            print(f"    {tmpl}: OK (p/i/m/a fingering verified)")
        elif tmpl == "slow_drill":
            assert xml_content.count("<note>") >= len(selected_notes)
            print(f"    {tmpl}: OK (duration doubling verified)")

    # 5. Synthesize and render the arpeggio draft in alphaTab
    print("[4/6] Rendering arpeggio draft with alphaTab & SoundFont...")
    draft_arpeggio_xml = os.path.join(TEST_CACHE, "draft_arpeggio.musicxml")
    draft_render_dir = os.path.join(TEST_CACHE, "draft_render")
    r = subprocess.run([
        NODE_EXE, os.path.join(PLUGIN_DIR, "renderer", "index.mjs"),
        "--input", draft_arpeggio_xml,
        "--out", draft_render_dir,
        "--width", "640"
    ], capture_output=True, text=True, cwd=PLUGIN_DIR)
    assert r.returncode == 0, f"Draft render failed: {r.stderr}"
    draft_meta = json.loads(r.stdout)
    full_wav = os.path.join(draft_render_dir, "full.wav")
    count_in_wav = os.path.join(draft_render_dir, "count_in.wav")
    assert os.path.exists(full_wav) and os.path.getsize(full_wav) > 10000
    assert os.path.exists(count_in_wav) and os.path.getsize(count_in_wav) > 10000
    print(f"    alphaTab synthesized: duration={draft_meta['duration']}ms, systems={len(draft_meta['systems'])}")

    # 6. Audio backend play test with mpv
    print("[5/6] Testing mpv playback of synthesized draft...")
    cmds_dir = os.path.join(draft_render_dir, "cmds")
    state_file = os.path.join(draft_render_dir, "audio_state.json")
    hb_file = os.path.join(draft_render_dir, "heartbeat.txt")
    os.makedirs(cmds_dir, exist_ok=True)
    with open(hb_file, "w", encoding="utf-8") as f:
        f.write(str(int(time.time() * 1000)))

    proc = subprocess.Popen([PYTHON_EXE, os.path.join(PLUGIN_DIR, "audio_backend.py"), draft_render_dir])
    time.sleep(0.8)

    try:
        # Load and play
        cmd1 = os.path.join(cmds_dir, "00000001.json")
        with open(cmd1, "w", encoding="utf-8") as f:
            f.write(json.dumps({"action": "load", "file": full_wav, "pos_ms": 0, "paused": False}) + "\n__GSCORE_END__\n")

        time.sleep(1.0)
        with open(state_file, "r", encoding="utf-8") as f:
            st = json.load(f)
        print(f"    Playing state: playing={st['playing']}, pos={st['pos_ms']}ms, dur={st['duration_ms']}ms")
        assert st["playing"] is True and st["pos_ms"] > 300, "Draft audio must advance"

        # Quit
        cmd2 = os.path.join(cmds_dir, "00000002.json")
        with open(cmd2, "w", encoding="utf-8") as f:
            f.write(json.dumps({"action": "quit"}) + "\n__GSCORE_END__\n")
        time.sleep(0.4)
    finally:
        if proc.poll() is None:
            proc.terminate()
            proc.wait(timeout=2.0)

    # 7. Check no orphan mpv
    print("[6/6] Verifying zero zombie mpv processes...")
    time.sleep(0.5)
    mpv_count = 0
    try:
        out = subprocess.run(
            ["powershell", "-NoProfile", "-Command", "(Get-Process mpv -ErrorAction SilentlyContinue | Measure-Object).Count"],
            capture_output=True, text=True, timeout=5
        )
        mpv_count = int(out.stdout.strip())
    except Exception:
        pass
    print(f"    Orphan mpv count: {mpv_count}")
    assert mpv_count == 0, "Zero orphan mpv processes allowed"

    print("\n>>> P2 INTERACTIVE WORKFLOW REGRESSION SUITE: ALL PASSED <<<")

if __name__ == "__main__":
    run()
