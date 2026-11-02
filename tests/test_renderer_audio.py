"""Focused regression: per-track WAV stems + same-length click-only metronome stem.

Runs the real renderer on tests/fixtures/sample.musicxml and validates the
shared host contract: existing full.wav + count_in.wav preserved, plus
track-{index}.wav per track, metronome.wav (same duration/format, click-only),
and tracks.json with {tracks:[{index,name,channels}]}. Stems share one gain
(no per-stem independent normalization). Also covers --audio-out/--no-audio.
"""
import copy
import json
import os
import struct
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET

PLUGIN_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
NODE_EXE = r"C:\Program Files\nodejs\node.exe"
RENDERER = os.path.join(PLUGIN_DIR, "renderer", "index.mjs")
FIXTURE = os.path.join(PLUGIN_DIR, "tests", "fixtures", "sample.musicxml")


def render(args):
    r = subprocess.run(
        [NODE_EXE, RENDERER] + args,
        capture_output=True, text=True, encoding="utf-8", cwd=PLUGIN_DIR,
    )
    assert r.returncode == 0, f"Renderer failed: {r.stderr}"
    return json.loads(r.stdout)


def read_wav(path):
    with open(path, "rb") as f:
        buf = f.read()
    assert buf[:4] == b"RIFF" and buf[8:12] == b"WAVE", f"bad WAV header: {path}"
    channels = struct.unpack("<H", buf[22:24])[0]
    rate = struct.unpack("<I", buf[24:28])[0]
    bits = struct.unpack("<H", buf[34:36])[0]
    n = struct.unpack("<I", buf[40:44])[0]
    samples = struct.unpack("<%dh" % (n // 2), buf[44:44 + n])
    return {"channels": channels, "rate": rate, "bits": bits, "nbytes": n, "samples": samples}


def rms(samples):
    return (sum(s * s for s in samples) / max(1, len(samples))) ** 0.5


def make_two_track_fixture(path):
    tree = ET.parse(FIXTURE)
    root = tree.getroot()
    part_list = root.find("part-list")
    part_specs = part_list.findall("score-part")
    second_spec = copy.deepcopy(part_specs[0])
    second_spec.set("id", "P2")
    second_spec.find("part-name").text = "Piano"
    for element in second_spec.iter():
        if "id" in element.attrib:
            element.set("id", element.get("id").replace("P1", "P2"))
        if element.tag == "midi-channel":
            element.text = "2"
        elif element.tag == "midi-program":
            element.text = "1"
    part_list.append(second_spec)

    first_part = root.find("part")
    second_part = copy.deepcopy(first_part)
    second_part.set("id", "P2")
    root.append(second_part)
    tree.write(path, encoding="utf-8", xml_declaration=True)


def run():
    assert os.path.exists(FIXTURE), f"Fixture not found: {FIXTURE}"
    tmp = tempfile.mkdtemp(prefix="gscore_stems_")
    fixture = os.path.join(tmp, "two-track.musicxml")
    make_two_track_fixture(fixture)
    out = os.path.join(tmp, "render")
    audio = os.path.join(tmp, "audio")

    # 1. Default render: stems land under --out when --audio-out is unset.
    data = render(["--input", fixture, "--out", out, "--width", "640"])
    manifest_path = os.path.join(out, "tracks.json")
    assert os.path.exists(manifest_path), "tracks.json missing"
    manifest = json.load(open(manifest_path, encoding="utf-8"))
    assert data.get("tracks") == manifest["tracks"], "stdout tracks must match tracks.json"
    assert len(manifest["tracks"]) == 2, "expected the generated two-track score"
    assert set(manifest["tracks"][0]["channels"]).isdisjoint(manifest["tracks"][1]["channels"])
    for t in manifest["tracks"]:
        assert set(t) == {"index", "name", "channels"}, f"bad track entry: {t}"
        assert t["channels"], f"track {t['index']} must list midi channels"

    full = read_wav(os.path.join(out, "full.wav"))
    assert os.path.getsize(os.path.join(out, "count_in.wav")) > 1000, "count_in.wav missing"
    assert full["channels"] == 2 and full["rate"] == 44100 and full["bits"] == 16

    stems = []
    for t in manifest["tracks"]:
        stem = read_wav(os.path.join(out, f"track-{t['index']}.wav"))
        assert (stem["channels"], stem["rate"], stem["bits"]) == (2, 44100, 16)
        assert stem["nbytes"] == full["nbytes"], "stem must match full.wav length"
        assert rms(stem["samples"]) > 0, f"track-{t['index']}.wav is silent"
        stems.append(stem)
    assert stems[0]["samples"] != stems[1]["samples"], "track stems must contain separate parts"

    metro = read_wav(os.path.join(out, "metronome.wav"))
    assert (metro["channels"], metro["rate"], metro["bits"]) == (2, 44100, 16)
    assert metro["nbytes"] == full["nbytes"], "metronome.wav must match full.wav length"
    assert rms(metro["samples"]) > 0, "metronome.wav is silent"

    # 2. Split dirs: resize render must not touch stable audio assets.
    out2 = os.path.join(tmp, "render2")
    before = {f: os.path.getmtime(os.path.join(out, f)) for f in sorted(os.listdir(out))}
    r = subprocess.run(
        [NODE_EXE, RENDERER, "--input", fixture, "--out", out2,
         "--audio-out", out, "--no-audio", "--width", "900"],
        capture_output=True, text=True, encoding="utf-8", cwd=PLUGIN_DIR,
    )
    assert r.returncode == 0, f"no-audio render failed: {r.stderr}"
    no_audio_data = json.loads(r.stdout)
    assert no_audio_data.get("tracks") == manifest["tracks"], "--no-audio must preserve track metadata"
    assert no_audio_data["systems"][0]["w"] > data["systems"][0]["w"], "resize render must use the new width"
    assert os.path.exists(os.path.join(out2, "system-001.png")), "PNGs must render to --out"
    after = {f: os.path.getmtime(os.path.join(out, f)) for f in sorted(os.listdir(out))}
    assert before == after, "--no-audio must not overwrite audio assets"
    assert not os.path.exists(os.path.join(out2, "full.wav")), "no WAVs under --out in --no-audio mode"

    # 3. Explicit --audio-out routes new audio there.
    data3 = render(["--input", fixture, "--out", out2, "--audio-out", audio, "--width", "640"])
    assert data3.get("audioOut") == audio
    for f in ["full.wav", "count_in.wav", "metronome.wav", "tracks.json"]:
        assert os.path.exists(os.path.join(audio, f)), f"{f} missing under --audio-out"

    print(">>> TRACK STEMS REGRESSION: ALL PASSED <<<")


if __name__ == "__main__":
    sys.exit(run())
