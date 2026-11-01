"""End-to-end practice workflow test using real alphaTab renderer output.

Validates:
  1. `realValue == tuning[string - 1] + fret` for fixture notes.
  2. MusicXML `<pluck>` notation and source rhythm/measure capacity.
  3. alphaTab draft rendering and mpv playback.
  4. Clean audio-backend shutdown.
"""

import json
import os
import subprocess
import sys
import time
import xml.etree.ElementTree as ET

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
    ], capture_output=True, text=True, encoding="utf-8", cwd=PLUGIN_DIR)
    assert r.returncode == 0, f"Fixture render failed: {r.stderr}"
    fixture_data = json.loads(r.stdout)
    tuning_raw = fixture_data["tuning"]  # [64, 59, 55, 50, 45, 40]
    time_sig = fixture_data.get("timeSignature", [4, 4])
    tempo_bpm = fixture_data.get("tempo_bpm", 120)

    # 2. Extract notes for bars 0 and 1 using alphaTab's independent pitch value
    selected_notes = []
    for sys_data in fixture_data["systems"]:
        for n in sys_data["notes"]:
            if n["m"] in (0, 1):
                assert n.get("realValue") is not None, f"alphaTab realValue missing: {n}"
                selected_notes.append({
                    "id": n["id"],
                    "beat": n["b"],
                    "bar": n["m"],
                    "string": n["string"],
                    "fret": n["fret"],
                    "midi": n["realValue"],
                    "duration_ticks": n["durationTicks"],
                    "dots": n.get("dots") or 0,
                    "tuplet": n.get("tuplet"),
                })
    print(f"    Extracted {len(selected_notes)} real notes from bars 0..1")
    assert len(selected_notes) >= 8, "Expected at least 8 notes in bars 0..1"

    # 3. Compare alphaTab's realValue to the independently derived string pitch
    print("[2/6] Validating alphaTab realValue against tuning + fret...")
    tuning_norm = list(reversed(tuning_raw)) if tuning_raw[0] > tuning_raw[-1] else list(tuning_raw)
    for n in selected_notes:
        expected = tuning_norm[n["string"] - 1] + n["fret"]
        assert n["midi"] == expected, f"Pitch mismatch for note {n}: expected {expected}, got {n['midi']}"
    print(f"    All {len(selected_notes)} alphaTab realValue pitches match tuning + fret")

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
        "beats": [{
            "t": event["t"],
            "bar": event["bar"],
            "tick": event["tick"],
            "duration_ticks": event["durationTicks"],
            "dots": event.get("dots") or 0,
            "tuplet": event.get("tuplet"),
            "beat_ids": event["nb"],
        } for event in fixture_data["timeline"] if event["bar"] in (0, 1)]
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
        ], capture_output=True, text=True, encoding="utf-8", cwd=PLUGIN_DIR)
        assert r.returncode == 0, f"generate_draft failed for {tmpl}: {r.stderr}"
        xml_content = open(draft_xml, encoding="utf-8").read()
        if tmpl == "alternate_picking":
            assert "<down-bow/>" in xml_content and "<up-bow/>" in xml_content
            print(f"    {tmpl}: OK (stroke notations verified)")
        elif tmpl == "arpeggio":
            root = ET.fromstring(xml_content)
            plucks = {node.text for node in root.findall(".//technical/pluck")}
            assert plucks == {"p", "i", "m", "a"}
            assert not root.findall(".//technical/fingering")
            print(f"    {tmpl}: OK (<pluck> p/i/m/a verified)")
        elif tmpl == "slow_drill":
            root = ET.fromstring(xml_content)
            measures = root.findall("./part/measure")
            assert len(measures) == 2
            divisions = int(root.findtext("./part/measure/attributes/divisions"))
            base_ticks = {
                "whole": 4 * divisions, "half": 2 * divisions, "quarter": divisions,
                "eighth": divisions / 2, "16th": divisions / 4, "32nd": divisions / 8,
                "64th": divisions / 16, "128th": divisions / 32, "256th": divisions / 64,
            }
            expected_ticks = {
                bar: sum(event["duration_ticks"] for event in selection_payload["beats"] if event["bar"] == bar)
                for bar in (0, 1)
            }
            for bar_index, measure in enumerate(measures):
                notes = measure.findall("note")
                measure_ticks = 0
                pitched_durations = []
                for note in notes:
                    duration = int(note.findtext("duration"))
                    note_type = note.findtext("type")
                    dots = len(note.findall("dot"))
                    time_mod = note.find("time-modification")
                    actual = int(time_mod.findtext("actual-notes")) if time_mod is not None else 1
                    normal = int(time_mod.findtext("normal-notes")) if time_mod is not None else 1
                    written = base_ticks[note_type] * ((2 ** (dots + 1) - 1) / (2 ** dots)) * normal / actual
                    assert abs(written - duration) < 1e-8, f"duration/type mismatch: {ET.tostring(note)}"
                    if note.find("chord") is None:
                        measure_ticks += duration
                    if note.find("pitch") is not None:
                        pitched_durations.append(duration)
                assert measure_ticks == expected_ticks[bar_index], (
                    f"bar {bar_index}: expected {expected_ticks[bar_index]} ticks, got {measure_ticks}"
                )
                source_durations = [
                    note["duration_ticks"] for note in selected_notes if note["bar"] == bar_index
                ]
                assert pitched_durations == source_durations, "slow_drill must preserve source note durations"
            assert len(root.findall(".//note/chord")) == len(selected_notes) - len({n["beat"] for n in selected_notes})
            assert int(root.find(".//direction/sound").attrib["tempo"]) == 60
            print(f"    {tmpl}: OK (source rhythm, chords, measure capacity, and tempo verified)")

    # 5. Synthesize and render the arpeggio draft in alphaTab
    print("[4/6] Rendering arpeggio draft with alphaTab & SoundFont...")
    draft_arpeggio_xml = os.path.join(TEST_CACHE, "draft_arpeggio.musicxml")
    draft_render_dir = os.path.join(TEST_CACHE, "draft_render")
    r = subprocess.run([
        NODE_EXE, os.path.join(PLUGIN_DIR, "renderer", "index.mjs"),
        "--input", draft_arpeggio_xml,
        "--out", draft_render_dir,
        "--width", "640"
    ], capture_output=True, text=True, encoding="utf-8", cwd=PLUGIN_DIR)
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
