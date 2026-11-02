"""Automated regression suite for the gscore audio engine (audio_backend.py).

Covers:
  1. Count-in playback reaches the end after an existing A-B loop is cleared.
  2. Command bursts consume the JSONL queue without drops.
  3. True speed ratio: 1.25x advances ~1.25x wall time.
  4. Live mpv stem mixing preserves playing/paused state, position, speed and A-B loop.
  5. Pause watchdog keeps the backend alive and position stable.
  6. Hermetic PCM mixing: sums/clips, empty input, format mismatch.

Usage:
  python tests/test_audio_backend.py [path/to/score]
  python tests/test_audio_backend.py --unit  (mix tests only, no mpv/render)
"""
import array
import json
import os
import subprocess
import sys
import tempfile
import time
import wave

PLUGIN_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PYTHON_EXE = sys.executable
NODE_EXE = r"C:\Program Files\nodejs\node.exe"

_CLI_ARGS = [a for a in sys.argv[1:] if not a.startswith("-")]
SAMPLE_PATH = _CLI_ARGS[0] if _CLI_ARGS else os.path.join(PLUGIN_DIR, "tests", "fixtures", "sample.musicxml")
OUT_DIR = os.path.join(PLUGIN_DIR, ".test_cache")

sys.path.insert(0, PLUGIN_DIR)
from audio_backend import mix_wav_files

_MIX_SR = 44100


def _write_wav(path, samples, nchannels=2, framerate=44100):
    with wave.open(path, "wb") as w:
        w.setnchannels(nchannels)
        w.setsampwidth(2)
        w.setframerate(framerate)
        w.writeframes(array.array("h", samples).tobytes())


def _read_wav(path):
    with wave.open(path, "rb") as w:
        params = w.getparams()
        raw = w.readframes(params.nframes)
    samples = array.array("h")
    samples.frombytes(raw)
    return params, list(samples)
def _read_json(path):
    for _ in range(20):
        try:
            with open(path, encoding="utf-8") as f:
                return json.load(f)
        except (OSError, ValueError):
            time.sleep(0.01)
    raise RuntimeError(f"Could not read valid JSON from {path}")



def test_mix_sums_and_clips():
    with tempfile.TemporaryDirectory() as d:
        ref = os.path.join(d, "ref.wav")
        s1 = os.path.join(d, "s1.wav")
        s2 = os.path.join(d, "s2.wav")
        out = os.path.join(d, "mix.wav")
        samples = [1000, -1000] * 4  # 4 stereo frames
        _write_wav(ref, [0] * 8)
        _write_wav(s1, samples)
        _write_wav(s2, samples)
        mix_wav_files([s1, s2], ref, out)
        params, got = _read_wav(out)
        assert params.nchannels == 2 and params.framerate == _MIX_SR, params
        assert got == [v * 2 for v in samples], f"stems must sum at unity gain: {got}"
        # hard-clip both rails
        _write_wav(s1, [20000] * 8)
        _write_wav(s2, [20000] * 8)
        mix_wav_files([s1, s2], ref, out)
        _, got = _read_wav(out)
        assert got == [32767] * 8, f"positive overload must clip: {got}"
        _write_wav(s1, [-20000] * 8)
        _write_wav(s2, [-20000] * 8)
        mix_wav_files([s1, s2], ref, out)
        _, got = _read_wav(out)
        assert got == [-32768] * 8, f"negative overload must clip: {got}"
        # over-long stems truncate, short stems pad with silence
        _write_wav(s1, [1000] * 16)  # 8 frames vs 4-frame ref
        _write_wav(s2, [500] * 4)  # 2 frames vs 4-frame ref
        mix_wav_files([s1, s2], ref, out)
        params, got = _read_wav(out)
        assert params.nframes == 4, params
        assert got == [1500] * 4 + [1000] * 4, f"truncate/pad mismatch: {got}"


def test_mix_empty_is_silence():
    with tempfile.TemporaryDirectory() as d:
        ref = os.path.join(d, "ref.wav")
        out = os.path.join(d, "mix.wav")
        _write_wav(ref, [1234, -1234] * 4)
        mix_wav_files([], ref, out)
        params, got = _read_wav(out)
        assert params.nframes == 4 and params.nchannels == 2, params
        assert got == [0] * 8, f"empty mix must be silence: {got}"


def test_mix_rejects_format_mismatch():
    with tempfile.TemporaryDirectory() as d:
        ref = os.path.join(d, "ref.wav")
        bad = os.path.join(d, "bad.wav")
        out = os.path.join(d, "mix.wav")
        _write_wav(ref, [0] * 8, nchannels=2, framerate=_MIX_SR)
        _write_wav(bad, [0] * 8, nchannels=1, framerate=_MIX_SR)
        try:
            mix_wav_files([bad], ref, out)
        except ValueError:
            pass
        else:
            raise AssertionError("mono stem against stereo ref must raise ValueError")
        assert not os.path.exists(out), "failed mix must not leave output"
        assert not os.path.exists(out + ".tmp"), "failed mix must not leave temp file"
        _write_wav(bad, [0] * 8, nchannels=2, framerate=22050)
        try:
            mix_wav_files([bad], ref, out)
        except ValueError:
            pass
        else:
            raise AssertionError("22050 Hz stem against 44100 Hz ref must raise ValueError")
        assert not os.path.exists(out), "failed mix must not leave output"




def run_mix_unit():
    print("Running hermetic mix unit tests...")
    test_mix_sums_and_clips()
    print("  [mix 1/3] sum + clipping + truncate/pad OK")
    test_mix_empty_is_silence()
    print("  [mix 2/3] empty mix silence OK")
    test_mix_rejects_format_mismatch()
    print("  [mix 3/3] format mismatch OK")


def run():
    run_mix_unit()
    print(f"Running audio backend test against: {SAMPLE_PATH}")
    assert os.path.exists(SAMPLE_PATH), f"Sample file not found: {SAMPLE_PATH}"
    os.makedirs(OUT_DIR, exist_ok=True)

    # 1. Render
    print("[1/6] Rendering score...")
    r = subprocess.run([
        NODE_EXE, os.path.join(PLUGIN_DIR, "renderer", "index.mjs"),
        "--input", SAMPLE_PATH, "--out", OUT_DIR, "--width", "800"
    ], capture_output=True, text=True, encoding="utf-8", cwd=PLUGIN_DIR)
    assert r.returncode == 0, f"Renderer failed: {r.stderr}"
    data = json.loads(r.stdout)
    full_wav = os.path.join(OUT_DIR, "full.wav")
    assert os.path.exists(full_wav) and os.path.getsize(full_wav) > 10000

    cmd_file = os.path.join(OUT_DIR, "audio_cmd.jsonl")
    state_file = os.path.join(OUT_DIR, "audio_state.json")
    hb_file = os.path.join(OUT_DIR, "heartbeat.txt")
    mix_playing = os.path.join(OUT_DIR, "mix_smoke_playing.wav")
    mix_paused = os.path.join(OUT_DIR, "mix_smoke_paused.wav")

    for f in (cmd_file, cmd_file + ".proc", state_file, mix_playing, mix_paused):
        if os.path.exists(f):
            os.remove(f)
    with open(hb_file, "w", encoding="utf-8") as f:
        f.write(str(int(time.time() * 1000)))

    # 2. Start audio backend
    print("[2/6] Starting audio backend...")
    proc = subprocess.Popen([PYTHON_EXE, os.path.join(PLUGIN_DIR, "audio_backend.py"), OUT_DIR])
    time.sleep(0.8)

    try:
        # 3. Load file and verify initial state
        print("[3/6] Loading score and testing count-in loop reset...")
        with open(cmd_file, "w", encoding="utf-8") as f:
            f.write(json.dumps({"action": "load", "file": full_wav, "pos_ms": 0, "paused": True}) + "\n")
        
        # Wait for duration
        for _ in range(40):
            time.sleep(0.05)
            if os.path.exists(state_file):
                try:
                    st = _read_json(state_file)
                    if st.get("duration_ms", 0) > 0:
                        break
                except RuntimeError:
                    pass

        count_in_wav = os.path.join(OUT_DIR, "count_in.wav")
        with wave.open(count_in_wav, "rb") as count_in:
            count_in_ms = count_in.getnframes() * 1000 // count_in.getframerate()
        assert count_in_ms > 0
        commands = [
            {"action": "loop", "loop_a_ms": 0, "loop_b_ms": 500},
            {"action": "loop", "loop_a_ms": None, "loop_b_ms": None},
            {"action": "load", "file": count_in_wav, "pos_ms": 0, "paused": False},
        ]
        with open(cmd_file, "w", encoding="utf-8") as f:
            for command in commands:
                f.write(json.dumps(command) + "\n")
        for _ in range(80):
            time.sleep(0.05)
            st = _read_json(state_file)
            if (abs(st["duration_ms"] - count_in_ms) < 300
                    and st["paused"] and st["pos_ms"] >= st["duration_ms"] - 100):
                break
        else:
            raise AssertionError(f"count-in must finish after clearing A-B loop: {st}")
        assert st["loop"] is False, f"count-in must not retain the prior A-B loop: {st}"

        with open(cmd_file, "w", encoding="utf-8") as f:
            f.write(json.dumps({"action": "load", "file": full_wav, "pos_ms": 0, "paused": True}) + "\n")
        time.sleep(0.4)
        st = _read_json(state_file)
        assert st["paused"] is True and abs(st["duration_ms"] - data["duration"]) < 300, st

        # Send burst: speed 1.25 -> seek 30000 -> play
        seek_target = min(30000, max(500, int(data['duration'] * 0.4)))
        burst = [
            {"action": "speed", "speed": 1.25},
            {"action": "seek", "pos_ms": seek_target},
            {"action": "play"}
        ]
        with open(cmd_file, "w", encoding="utf-8") as f:
            for c in burst:
                f.write(json.dumps(c) + "\n")

        time.sleep(0.7)
        st = _read_json(state_file)
        print("State after burst:", st)
        assert st["paused"] is False, "Must be playing"
        assert abs(st["speed"] - 1.25) < 0.02, f"Speed must be 1.25, got {st['speed']}"
        assert st["pos_ms"] >= seek_target - 500, f"Position must be near {seek_target}, got {st['pos_ms']}"

        # 4. Speed ratio test
        print("[4/6] Verifying 1.25x speed ratio over 1.2s...")
        # Reset to start if near end of short fixture
        if st["pos_ms"] + 2500 > st["duration_ms"]:
            with open(cmd_file, "w", encoding="utf-8") as f:
                f.write(json.dumps({"action": "seek", "pos_ms": 0}) + "\n")
            time.sleep(0.3)
            st = _read_json(state_file)
        t_start = time.time()
        p_start = st["pos_ms"]
        time.sleep(1.2)
        st = _read_json(state_file)
        ratio = ((st["pos_ms"] - p_start) / 1000.0) / (time.time() - t_start)
        print(f"Elapsed: {time.time()-t_start:.2f}s, advanced: {st['pos_ms']-p_start}ms, ratio={ratio:.2f}")
        assert abs(ratio - 1.25) < 0.15, f"Expected ratio ~1.25, got {ratio:.2f}"

        # Exercise the real mpv mix path while playing and while paused.
        print("[5/6] Verifying live stem mix preserves transport...")
        track_stem = os.path.join(OUT_DIR, "track-0.wav")
        metronome_stem = os.path.join(OUT_DIR, "metronome.wav")
        loop_end = min(2000, int(data["duration"] * 0.75))
        assert loop_end > 0, f"Score too short for mix loop: {data['duration']}ms"
        seek_pos = loop_end // 3
        commands = [
            {"action": "loop", "loop_a_ms": 0, "loop_b_ms": loop_end},
            {"action": "seek", "pos_ms": seek_pos},
            {"action": "speed", "speed": 1.25},
            {"action": "play"},
            {"action": "mix", "files": [track_stem, metronome_stem],
             "reference": full_wav, "output": mix_playing},
        ]
        with open(cmd_file, "w", encoding="utf-8") as f:
            for command in commands:
                f.write(json.dumps(command) + "\n")
        time.sleep(0.6)
        st = _read_json(state_file)
        assert os.path.getsize(mix_playing) > 44, "playing mix WAV missing"
        assert st["paused"] is False and st["playing"] is True, f"Mix must keep playback active: {st}"
        assert abs(st["speed"] - 1.25) < 0.02, f"Mix must preserve speed: {st}"
        assert st["loop"] is True and st["loop_a_ms"] == 0 and st["loop_b_ms"] == loop_end, st
        assert 0 <= st["pos_ms"] < loop_end, f"Mix must remain within the A-B loop: {st}"

        paused_pos = st["pos_ms"]
        commands = [
            {"action": "pause"},
            {"action": "mix", "files": [track_stem], "reference": full_wav, "output": mix_paused},
        ]
        with open(cmd_file, "w", encoding="utf-8") as f:
            for command in commands:
                f.write(json.dumps(command) + "\n")
        time.sleep(0.6)
        st = _read_json(state_file)
        assert os.path.getsize(mix_paused) > 44, "paused mix WAV missing"
        assert st["paused"] is True and st["playing"] is False, f"Mix must keep pause: {st}"
        assert abs(st["pos_ms"] - paused_pos) < 300, f"Paused position must be preserved: {st}"
        assert st["speed"] == 1.25, f"Mix must preserve speed: {st}"
        assert st["loop"] is True and st["loop_a_ms"] == 0 and st["loop_b_ms"] == loop_end, st

        # 5. Pause watchdog survival test
        print("[6/6] Testing 6s pause watchdog survival...")
        with open(cmd_file, "w", encoding="utf-8") as f:
            f.write(json.dumps({"action": "pause"}) + "\n")
        time.sleep(0.3)
        st = _read_json(state_file)
        paused_pos = st["pos_ms"]
        for _ in range(6):
            time.sleep(1.0)
            with open(hb_file, "w", encoding="utf-8") as f:
                f.write(str(int(time.time() * 1000)))
        assert proc.poll() is None, "Backend died during pause!"
        st = _read_json(state_file)
        assert st["paused"] is True and abs(st["pos_ms"] - paused_pos) < 200, "Position drifted during pause"

        with open(cmd_file, "w", encoding="utf-8") as f:
            f.write(json.dumps({"action": "quit"}) + "\n")
        time.sleep(0.4)
    finally:
        if proc.poll() is None:
            proc.terminate()
            proc.wait(timeout=2.0)
        for f in (mix_playing, mix_paused):
            if os.path.exists(f):
                os.remove(f)

    print("\n>>> ALL AUDIO BACKEND TESTS PASSED CLEANLY <<<")

if __name__ == "__main__":
    run_mix_unit() if "--unit" in sys.argv else run()
