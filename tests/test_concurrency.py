"""Concurrency hardening regression suite for gscore audio engine.

Validates:
  1. Atomic per-command queue in `cmds/` (no read-modify-write races).
  2. Strictly increasing state `seq` and stable `instance_id`.
  3. Pending seek delivery after load (via file-loaded / playback-restart).
  4. A-B Loop bounds preservation.
  5. 10s pause watchdog survival and resume position.
  6. Zero orphan mpv processes after exit (Windows Job Object).

Usage:
  python tests/test_concurrency.py [path/to/sample.gp5]
"""
import json
import os
import subprocess
import sys
import time

PLUGIN_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PYTHON_EXE = sys.executable
NODE_EXE = r"C:\Program Files\nodejs\node.exe"

DEFAULT_SAMPLE = os.path.join(PLUGIN_DIR, "tests", "fixtures", "sample.musicxml")
SAMPLE_PATH = sys.argv[1] if len(sys.argv) > 1 else DEFAULT_SAMPLE
OUT_DIR = os.path.join(PLUGIN_DIR, ".test_concurrency_cache")

def count_mpv():
    try:
        out = subprocess.run(
            ["powershell", "-NoProfile", "-Command", "(Get-Process mpv -ErrorAction SilentlyContinue | Measure-Object).Count"],
            capture_output=True, text=True, timeout=10
        )
        return int(out.stdout.strip())
    except Exception:
        return -1

def write_cmd(cmds_dir, seq, payload):
    path = os.path.join(cmds_dir, f"{seq:08d}.json")
    with open(path, "w", encoding="utf-8") as f:
        json.dump(payload, f)

def read_state(state_file):
    with open(state_file, "r", encoding="utf-8") as f:
        return json.load(f)

def run():
    print(f"Running concurrency suite against: {SAMPLE_PATH}")
    assert os.path.exists(SAMPLE_PATH), f"Fixture not found: {SAMPLE_PATH}"
    os.makedirs(OUT_DIR, exist_ok=True)

    baseline_mpv = count_mpv()
    print(f"Baseline mpv processes: {baseline_mpv}")

    # 1. Render
    print("[1/6] Rendering score fixture...")
    r = subprocess.run([
        NODE_EXE, os.path.join(PLUGIN_DIR, "renderer", "index.mjs"),
        "--input", SAMPLE_PATH, "--out", OUT_DIR, "--width", "800"
    ], capture_output=True, text=True, cwd=PLUGIN_DIR)
    assert r.returncode == 0, f"Renderer failed: {r.stderr}"
    data = json.loads(r.stdout)
    full_wav = os.path.join(OUT_DIR, "full.wav")
    assert os.path.exists(full_wav) and os.path.getsize(full_wav) > 10000
    print(f"    duration={data['duration']}ms systems={len(data['systems'])}")

    state_file = os.path.join(OUT_DIR, "audio_state.json")
    hb_file = os.path.join(OUT_DIR, "heartbeat.txt")
    cmds_dir = os.path.join(OUT_DIR, "cmds")
    os.makedirs(cmds_dir, exist_ok=True)

    for f in (state_file,):
        if os.path.exists(f):
            os.remove(f)
    for f in os.listdir(cmds_dir):
        os.remove(os.path.join(cmds_dir, f))

    with open(hb_file, "w", encoding="utf-8") as f:
        f.write(str(int(time.time() * 1000)))

    print("[2/6] Starting audio backend...")
    proc = subprocess.Popen([PYTHON_EXE, os.path.join(PLUGIN_DIR, "audio_backend.py"), OUT_DIR])
    time.sleep(0.8)

    try:
        # --- 2. Atomic command queue
        print("[3/6] Bursting 6 atomic commands (load -> speed -> play -> loop -> seek)...")
        burst = [
            {"action": "load", "file": full_wav, "pos_ms": 0, "paused": True},
            {"action": "speed", "speed": 1.25},
            {"action": "play"},
            {"action": "loop", "loop_a_ms": 500, "loop_b_ms": 1500},
            {"action": "seek", "pos_ms": 2000},
            {"action": "pause"},
        ]
        for i, c in enumerate(burst, start=1):
            write_cmd(cmds_dir, i, c)

        time.sleep(0.8)
        st = read_state(state_file)
        print("    state:", {k: st[k] for k in ("seq", "playing", "paused", "speed", "loop", "loop_a_ms", "loop_b_ms")})
        assert st["paused"] is True, "Last command was pause"
        assert abs(st["speed"] - 1.25) < 0.02, "speed must be 1.25"
        assert st["loop"] is True and st["loop_a_ms"] == 500 and st["loop_b_ms"] == 1500, "A-B loop bounds"
        assert st["pos_ms"] >= 1900, f"seek must apply, got {st['pos_ms']}"
        assert os.listdir(cmds_dir) == [], "cmds dir must be drained"
        instance_id = st["instance_id"]
        print(f"    instance_id={instance_id}  ALL BURST COMMANDS EXECUTED IN ORDER")

        # --- 3. Monotonic seq
        print("[4/6] Verifying monotonic state seq...")
        seqs = []
        for _ in range(6):
            time.sleep(0.1)
            st = read_state(state_file)
            seqs.append(st["seq"])
            assert st["instance_id"] == instance_id, "instance_id must not change"
        assert all(b > a for a, b in zip(seqs, seqs[1:])), f"seq must strictly increase: {seqs}"
        print(f"    seq progression: {seqs}  MONOTONIC OK")

        # --- 4. Resume / polling identity
        print("[5/6] Pausing 10s then resuming; position must be preserved...")
        write_cmd(cmds_dir, 100, {"action": "pause"})
        time.sleep(0.4)
        pos_paused = read_state(state_file)["pos_ms"]
        for _ in range(10):
            time.sleep(1.0)
            with open(hb_file, "w", encoding="utf-8") as f:
                f.write(str(int(time.time() * 1000)))
        assert proc.poll() is None, "backend died during 10s pause"
        st = read_state(state_file)
        assert st["instance_id"] == instance_id, "backend must be the same instance after pause"
        assert abs(st["pos_ms"] - pos_paused) < 250, f"position drifted: {pos_paused} -> {st['pos_ms']}"

        write_cmd(cmds_dir, 101, {"action": "play"})
        time.sleep(0.8)
        st = read_state(state_file)
        assert st["playing"] is True and st["pos_ms"] > pos_paused, "must advance after resume"
        print(f"    resumed {pos_paused} -> {st['pos_ms']}  RESUME OK")

        write_cmd(cmds_dir, 102, {"action": "quit"})
        time.sleep(0.5)
    finally:
        if proc.poll() is None:
            proc.terminate()
            proc.wait(timeout=2.0)

    # --- 5. Job object reclamation
    time.sleep(0.6)
    after_mpv = count_mpv()
    print(f"    mpv after shutdown: {after_mpv} (baseline was {baseline_mpv})")
    assert after_mpv <= baseline_mpv, f"orphan mpv processes leaked: {after_mpv}"

    print("\n>>> CONCURRENCY SUITE PASSED: atomic queue, monotonic seq, resume, job reclamation <<<")

if __name__ == "__main__":
    run()
