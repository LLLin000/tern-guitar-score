"""Automated end-to-end test for P2 Interactive Practice Workflow.

Validates the full loop:
  1. Selection export structure (music_context_v1 protocol).
  2. tools/generate_draft.py creates a valid guitar TAB practice variation MusicXML.
  3. alphaTab renders and synthesizes the draft score (PNG + SoundFont full.wav + count_in.wav).
  4. audio_backend.py loads and plays the generated draft with mpv.
  5. Clean teardown with zero zombie processes.
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
    print("=== Testing P2 Interactive Practice Workflow ===")
    os.makedirs(TEST_CACHE, exist_ok=True)

    # 1. Simulate selection from bars 0..1 of fixture
    sel_file = os.path.join(TEST_CACHE, "test_selection.json")
    selection = {
        "version": "1.1.0",
        "protocol": "music_context_v1",
        "path": FIXTURE_SCORE,
        "title": "Chromatic Drill",
        "bars": [0, 1],
        "playback_range_ms": {"t0": 0, "t1": 4000},
        "tempo_bpm": 60,
        "time_signature": [4, 4],
        "tuning_midi": [40, 45, 50, 55, 59, 64],
        "notes": [
            {"id": 1, "bar": 0, "string": 6, "fret": 1, "midi": 41, "duration_ticks": 480},
            {"id": 2, "bar": 0, "string": 6, "fret": 2, "midi": 42, "duration_ticks": 480},
            {"id": 3, "bar": 0, "string": 6, "fret": 3, "midi": 43, "duration_ticks": 480},
            {"id": 4, "bar": 0, "string": 6, "fret": 4, "midi": 44, "duration_ticks": 480},
            {"id": 5, "bar": 1, "string": 5, "fret": 1, "midi": 46, "duration_ticks": 480},
            {"id": 6, "bar": 1, "string": 5, "fret": 2, "midi": 47, "duration_ticks": 480},
            {"id": 7, "bar": 1, "string": 5, "fret": 3, "midi": 48, "duration_ticks": 480},
            {"id": 8, "bar": 1, "string": 5, "fret": 4, "midi": 49, "duration_ticks": 480},
        ],
        "beats": [{"t": 0, "beat_ids": [1]}, {"t": 500, "beat_ids": [2]}]
    }
    with open(sel_file, "w", encoding="utf-8") as f:
        json.dump(selection, f)

    # 2. Agent generates draft variation
    print("[1/4] Generating practice variation (arpeggio template)...")
    draft_xml = os.path.join(TEST_CACHE, "draft_arpeggio.musicxml")
    r = subprocess.run([
        PYTHON_EXE, os.path.join(PLUGIN_DIR, "tools", "generate_draft.py"),
        "--selection", sel_file,
        "--template", "arpeggio",
        "--bpm", "72",
        "--out", draft_xml
    ], capture_output=True, text=True, cwd=PLUGIN_DIR)
    assert r.returncode == 0, f"Draft generation failed: {r.stderr}"
    assert os.path.exists(draft_xml) and os.path.getsize(draft_xml) > 500
    print(f"    Draft MusicXML created ({os.path.getsize(draft_xml)} bytes)")

    # 3. alphaTab renders draft score
    print("[2/4] Rendering draft in alphaTab...")
    draft_render_dir = os.path.join(TEST_CACHE, "draft_render")
    r = subprocess.run([
        NODE_EXE, os.path.join(PLUGIN_DIR, "renderer", "index.mjs"),
        "--input", draft_xml,
        "--out", draft_render_dir,
        "--width", "640"
    ], capture_output=True, text=True, cwd=PLUGIN_DIR)
    assert r.returncode == 0, f"alphaTab render failed: {r.stderr}"
    draft_meta = json.loads(r.stdout)
    assert draft_meta["duration"] > 0
    full_wav = os.path.join(draft_render_dir, "full.wav")
    count_in_wav = os.path.join(draft_render_dir, "count_in.wav")
    assert os.path.exists(full_wav) and os.path.getsize(full_wav) > 10000
    assert os.path.exists(count_in_wav) and os.path.getsize(count_in_wav) > 10000
    print(f"    alphaTab synthesized: duration={draft_meta['duration']}ms, wav={os.path.getsize(full_wav)}B")

    # 4. Audio backend plays draft
    print("[3/4] Testing mpv playback of generated draft...")
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
            json.dump({"action": "load", "file": full_wav, "pos_ms": 0, "paused": False}, f)

        time.sleep(1.0)
        with open(state_file, "r", encoding="utf-8") as f:
            st = json.load(f)
        print(f"    Draft playing state: playing={st['playing']}, pos={st['pos_ms']}ms, dur={st['duration_ms']}ms")
        assert st["playing"] is True and st["pos_ms"] > 300, "Draft should be playing"

        # Quit
        cmd2 = os.path.join(cmds_dir, "00000002.json")
        with open(cmd2, "w", encoding="utf-8") as f:
            json.dump({"action": "quit"}, f)
        time.sleep(0.4)
    finally:
        if proc.poll() is None:
            proc.terminate()
            proc.wait(timeout=2.0)

    # 5. Clean teardown
    print("[4/4] Verifying clean teardown...")
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
    print(f"    Leftover mpv count: {mpv_count}")
    assert mpv_count == 0, "No zombie mpv processes permitted"

    print("\n>>> P2 INTERACTIVE PRACTICE WORKFLOW VERIFIED SUCCESSFULLY! <<<")

if __name__ == "__main__":
    run()
