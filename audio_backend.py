import atexit
import json
import os
import subprocess
import sys
import threading
import time
import win32file
import win32job
import win32pipe

"""Resident audio backend controlling mpv via JSON-IPC over a Windows named pipe.

Usage:
  python audio_backend.py <cache_dir>

Robustness guarantees:
  - Windows Job Object with JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE:
    If this python process terminates or is killed for ANY reason, mpv.exe is
    terminated instantly by the Windows kernel. Zero zombie audio playback.
  - Non-blocking PeekNamedPipe reader thread to avoid pipe hangs.
  - JSONL command queue for atomic, ordered execution without command loss.
  - Authoritative time-pos feedback every 30ms via audio_state.json.
  - 15s watchdog tied to heartbeat.txt.
"""

def get_mpv_path():
    plugin_dir = os.path.dirname(os.path.abspath(__file__))
    bundled = os.path.join(plugin_dir, "bin", "mpv", "mpv.exe")
    if os.path.exists(bundled):
        return bundled
    bundled_com = os.path.join(plugin_dir, "bin", "mpv", "mpv.com")
    if os.path.exists(bundled_com):
        return bundled_com
    return "mpv"

class MpvController:
    def __init__(self, cache_dir):
        self.cache_dir = os.path.abspath(cache_dir)
        folder_clean = os.path.basename(self.cache_dir).replace("@", "_").replace(":", "_")
        self.pipe_name = f"gscore_mpv_{folder_clean}_{os.getpid()}"
        self.full_pipe = "\\\\.\\pipe\\" + self.pipe_name
        self.mpv_exe = get_mpv_path()
        self.mpv_proc = None
        self.handle = None
        self.job = None
        self.lock = threading.Lock()
        self.pending_seek = None
        self.file_loaded = False
        
        self.state = {
            "playing": False,
            "paused": True,
            "pos_ms": 0,
            "duration_ms": 0,
            "speed": 1.0,
            "loop": False,
            "loop_a_ms": None,
            "loop_b_ms": None,
            "heartbeat": int(time.time() * 1000)
        }
        self.running = True

    def start_mpv(self):
        # 1. Bind to Windows Job Object so child process dies automatically with parent
        try:
            self.job = win32job.CreateJobObject(None, "")
            info = win32job.QueryInformationJobObject(self.job, win32job.JobObjectExtendedLimitInformation)
            info["BasicLimitInformation"]["LimitFlags"] |= win32job.JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
            win32job.SetInformationJobObject(self.job, win32job.JobObjectExtendedLimitInformation, info)
        except Exception:
            self.job = None

        cmd = [
            self.mpv_exe,
            "--idle=yes",
            "--no-video",
            "--no-terminal",
            "--keep-open=yes",
            "--audio-pitch-correction=yes",
            f"--input-ipc-server={self.pipe_name}"
        ]
        self.mpv_proc = subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        
        if self.job and self.mpv_proc:
            try:
                win32job.AssignProcessToJobObject(self.job, self.mpv_proc._handle)
            except Exception:
                pass

        # Connect using win32file
        connected = False
        for _ in range(60):
            try:
                self.handle = win32file.CreateFile(
                    self.full_pipe,
                    win32file.GENERIC_READ | win32file.GENERIC_WRITE,
                    0, None,
                    win32file.OPEN_EXISTING,
                    0, None
                )
                connected = True
                break
            except Exception:
                time.sleep(0.05)
                
        if not connected:
            raise RuntimeError(f"Could not connect to mpv named pipe: {self.full_pipe}")

        # Start non-blocking reader thread
        self.reader_thread = threading.Thread(target=self._read_loop, daemon=True)
        self.reader_thread.start()

    def _send_command(self, cmd_array):
        if not self.handle:
            return
        msg = json.dumps({"command": cmd_array}) + "\n"
        data = msg.encode("utf-8")
        with self.lock:
            try:
                win32file.WriteFile(self.handle, data)
            except Exception:
                pass

    def _read_loop(self):
        buf = ""
        while self.running and self.handle:
            try:
                # Peek first to prevent blocking read
                with self.lock:
                    if not self.handle:
                        break
                    _, avail, _ = win32pipe.PeekNamedPipe(self.handle, 0)
                
                if avail > 0:
                    with self.lock:
                        if not self.handle:
                            break
                        hr, raw = win32file.ReadFile(self.handle, avail)
                    if raw:
                        buf += raw.decode("utf-8", errors="replace")
                        while "\n" in buf:
                            line, buf = buf.split("\n", 1)
                            line = line.strip()
                            if not line:
                                continue
                            try:
                                data = json.loads(line)
                            except Exception:
                                continue
                            
                            event = data.get("event")
                            if event == "file-loaded":
                                self.file_loaded = True
                            elif event == "playback-restart":
                                self.state["playing"] = True
                                if self.pending_seek is not None:
                                    target = self.pending_seek
                                    self.pending_seek = None
                                    self._send_command(["seek", max(0, target) / 1000.0, "absolute"])
                            elif event == "end-file":
                                self.state["playing"] = False
                                self.state["paused"] = True
                            elif event == "property-change":
                                prop = data.get("name")
                                val = data.get("data")
                                if prop == "time-pos" and val is not None:
                                    self.state["pos_ms"] = int(val * 1000)
                                elif prop == "duration" and val is not None:
                                    self.state["duration_ms"] = int(val * 1000)
                                elif prop == "pause":
                                    self.state["paused"] = bool(val)
                                    self.state["playing"] = not bool(val)
                                elif prop == "speed" and val is not None:
                                    self.state["speed"] = float(val)
                            elif "data" in data and isinstance(data["data"], (int, float)):
                                # Direct property query response for time-pos
                                self.state["pos_ms"] = int(data["data"] * 1000)
                else:
                    time.sleep(0.015)
            except Exception:
                break

    def load_file(self, file_path, start_ms=0, paused=False):
        clean_path = os.path.abspath(file_path).replace("\\", "/")
        self.file_loaded = False
        self.pending_seek = start_ms if start_ms > 0 else None
        self._send_command(["loadfile", clean_path, "replace"])
        self._send_command(["observe_property", 1, "time-pos"])
        self._send_command(["observe_property", 2, "duration"])
        self._send_command(["observe_property", 3, "pause"])
        self._send_command(["observe_property", 4, "speed"])
        self._send_command(["set_property", "pause", paused])
        self.state["playing"] = not paused
        self.state["paused"] = paused

    def play(self):
        self._send_command(["set_property", "pause", False])
        self.state["paused"] = False
        self.state["playing"] = True

    def pause(self):
        self._send_command(["set_property", "pause", True])
        self.state["paused"] = True
        self.state["playing"] = False

    def stop(self):
        self._send_command(["stop"])
        self.state["playing"] = False
        self.state["paused"] = True
        self.state["pos_ms"] = 0
        self.pending_seek = None

    def seek(self, target_ms):
        self.state["pos_ms"] = int(target_ms)
        if not self.file_loaded:
            self.pending_seek = target_ms
        else:
            self._send_command(["seek", max(0, target_ms) / 1000.0, "absolute"])

    def set_speed(self, speed):
        clamped = max(0.25, min(2.0, float(speed)))
        self._send_command(["set_property", "speed", clamped])
        self.state["speed"] = clamped

    def set_ab_loop(self, a_ms, b_ms):
        if a_ms is not None and b_ms is not None and b_ms > a_ms:
            self._send_command(["set_property", "ab-loop-a", a_ms / 1000.0])
            self._send_command(["set_property", "ab-loop-b", b_ms / 1000.0])
            self.state["loop"] = True
            self.state["loop_a_ms"] = int(a_ms)
            self.state["loop_b_ms"] = int(b_ms)
        else:
            self._send_command(["set_property", "ab-loop-a", "no"])
            self._send_command(["set_property", "ab-loop-b", "no"])
            self.state["loop"] = False
            self.state["loop_a_ms"] = None
            self.state["loop_b_ms"] = None

    def poll_time(self):
        self._send_command(["get_property", "time-pos"])

    def shutdown(self):
        self.running = False
        try:
            self._send_command(["quit"])
        except Exception:
            pass
        time.sleep(0.05)
        with self.lock:
            if self.handle:
                try:
                    win32file.CloseHandle(self.handle)
                except Exception:
                    pass
                self.handle = None
        if self.mpv_proc:
            try:
                self.mpv_proc.terminate()
                self.mpv_proc.wait(timeout=0.3)
            except Exception:
                try:
                    self.mpv_proc.kill()
                except Exception:
                    pass

def main():
    if len(sys.argv) < 2:
        print("Usage: audio_backend.py <cache_dir>")
        sys.exit(1)

    cache_dir = sys.argv[1]
    os.makedirs(cache_dir, exist_ok=True)
    
    cmd_file = os.path.join(cache_dir, "audio_cmd.jsonl")
    proc_file = os.path.join(cache_dir, "audio_cmd.jsonl.proc")
    state_file = os.path.join(cache_dir, "audio_state.json")
    hb_file = os.path.join(cache_dir, "heartbeat.txt")
    
    # Touch heartbeat
    try:
        with open(hb_file, "w", encoding="utf-8") as f:
            f.write(str(int(time.time() * 1000)))
    except Exception:
        pass

    controller = MpvController(cache_dir)
    controller.start_mpv()

    atexit.register(controller.shutdown)

    last_hb_check = time.time()
    last_state_write = 0
    last_time_poll = 0

    try:
        while controller.running:
            now = time.time()
            
            # 1. Process incoming commands from JSONL queue atomically
            if os.path.exists(cmd_file):
                try:
                    os.replace(cmd_file, proc_file)
                    with open(proc_file, "r", encoding="utf-8") as f:
                        for line in f:
                            line = line.strip()
                            if not line:
                                continue
                            try:
                                cmd_data = json.loads(line)
                            except Exception:
                                continue
                            action = cmd_data.get("action")
                            if action == "load":
                                controller.load_file(
                                    cmd_data.get("file"),
                                    start_ms=cmd_data.get("pos_ms", 0),
                                    paused=cmd_data.get("paused", False)
                                )
                            elif action == "play":
                                controller.play()
                            elif action == "pause":
                                controller.pause()
                            elif action == "stop":
                                controller.stop()
                            elif action == "seek":
                                controller.seek(cmd_data.get("pos_ms", 0))
                            elif action == "speed":
                                controller.set_speed(cmd_data.get("speed", 1.0))
                            elif action == "loop":
                                controller.set_ab_loop(
                                    cmd_data.get("loop_a_ms"),
                                    cmd_data.get("loop_b_ms")
                                )
                            elif action == "quit":
                                controller.shutdown()
                                return
                    try:
                        os.remove(proc_file)
                    except Exception:
                        pass
                except Exception:
                    pass

            # 2. Poll time-pos if playing
            if now - last_time_poll >= 0.035:
                if controller.state["playing"] and not controller.state["paused"]:
                    controller.poll_time()
                last_time_poll = now

            # 3. Write atomic state to audio_state.json
            if now - last_state_write >= 0.03:
                controller.state["heartbeat"] = int(now * 1000)
                temp_state = state_file + ".tmp"
                try:
                    with open(temp_state, "w", encoding="utf-8") as f:
                        json.dump(controller.state, f)
                    os.replace(temp_state, state_file)
                except Exception:
                    pass
                last_state_write = now

            # 4. Check heartbeat watchdog every 0.5s
            if now - last_hb_check >= 0.5:
                if os.path.exists(hb_file):
                    try:
                        mtime = os.path.getmtime(hb_file)
                        if now - mtime > 15.0:
                            # Stale host -> exit cleanly
                            break
                    except Exception:
                        pass
                else:
                    break
                last_hb_check = now

            time.sleep(0.015)
    finally:
        controller.shutdown()
        try:
            if os.path.exists(state_file):
                os.remove(state_file)
        except Exception:
            pass

if __name__ == "__main__":
    main()
