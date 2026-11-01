#!/usr/bin/env python3
"""generate_draft.py — Agent tool to generate practice variations from selection.json.

Transforms a selected score section into a standalone, playable MusicXML practice draft
and optionally dispatches it to open beside the original in Tern.

Usage:
  python tools/generate_draft.py [options]

Options:
  --selection PATH    Path to selection.json or draft-request.json
                      (default: %LOCALAPPDATA%/Tern/plugin-data/gscore/selection.json)
  --template TYPE     Variation type: 'alternate_picking', 'arpeggio', 'slow_drill'
                      (default: 'alternate_picking')
  --bpm BPM           Target practice tempo (default: 60)
  --out PATH          Output .musicxml file path (default: in score cache or tools/)
  --open              Notify Tern via open-request.json to open beside current pane
"""

import argparse
import json
import math
import os
import sys

MIDI_NOTE_NAMES = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]

def midi_to_step_octave_alter(midi):
    pitch = int(midi)
    octave = (pitch // 12) - 1
    semitone = pitch % 12
    name = MIDI_NOTE_NAMES[semitone]
    if len(name) == 2:
        step = name[0]
        alter = 1
    else:
        step = name
        alter = 0
    return step, octave, alter

def build_musicxml(title, bpm, time_sig, tuning_midi, measures_notes):
    """
    measures_notes: list of measures; each measure is a list of note dicts:
      {
        "string": int (1=high E .. 6=low E, or 1..6 guitar convention),
        "fret": int,
        "midi": int,
        "duration": int (units in divisions=4, so 4=quarter, 2=eighth, 1=16th),
        "type": "eighth" | "quarter" | "16th",
        "voice": 1,
        "chord": bool
      }
    """
    ts_num, ts_den = time_sig if len(time_sig) >= 2 else (4, 4)
    divisions = 4  # 1 quarter = 4 divisions; eighth = 2 divisions; 16th = 1 division

    lines = [
        '<?xml version="1.0" encoding="UTF-8"?>',
        '<!DOCTYPE score-partwise PUBLIC "-//Recordare//DTD MusicXML 4.0 Partwise//EN" "http://www.musicxml.org/dtds/partwise.dtd">',
        f'<score-partwise version="4.0">',
        f'  <work><work-title>{title}</work-title></work>',
        '  <part-list>',
        '    <score-part id="P1">',
        '      <part-name>Guitar</part-name>',
        '      <score-instrument id="P1-I1"><instrument-name>Acoustic Guitar</instrument-name></score-instrument>',
        '      <midi-instrument id="P1-I1"><midi-channel>1</midi-channel><midi-program>25</midi-program></midi-instrument>',
        '    </score-part>',
        '  </part-list>',
        '  <part id="P1">',
    ]

    # Tuning lines: line 1 = string 6 (low E), line 6 = string 1 (high E)
    # Default standard tuning: [40, 45, 50, 55, 59, 64]
    tuning = tuning_midi if len(tuning_midi) >= 6 else [40, 45, 50, 55, 59, 64]

    for m_idx, m_notes in enumerate(measures_notes, start=1):
        lines.append(f'    <measure number="{m_idx}">')
        if m_idx == 1:
            lines.append('      <attributes>')
            lines.append(f'        <divisions>{divisions}</divisions>')
            lines.append('        <key><fifths>0</fifths></key>')
            lines.append(f'        <time><beats>{ts_num}</beats><beat-type>{ts_den}</beat-type></time>')
            lines.append('        <clef><sign>TAB</sign><line>5</line></clef>')
            lines.append('        <staff-details>')
            lines.append('          <staff-lines>6</staff-lines>')
            for s_line in range(1, 7):
                midi_val = tuning[s_line - 1]
                step, octv, alt = midi_to_step_octave_alter(midi_val)
                lines.append(f'          <staff-tuning line="{s_line}">')
                lines.append(f'            <tuning-step>{step}</tuning-step>')
                if alt != 0:
                    lines.append(f'            <tuning-alter>{alt}</tuning-alter>')
                lines.append(f'            <tuning-octave>{octv}</tuning-octave>')
                lines.append('          </staff-tuning>')
            lines.append('        </staff-details>')
            lines.append('      </attributes>')
            lines.append(f'      <direction placement="above"><sound tempo="{bpm}"/></direction>')

        for note in m_notes:
            step, octv, alt = midi_to_step_octave_alter(note["midi"])
            dur = note.get("duration", 2)
            ntype = note.get("type", "eighth")
            lines.append('      <note>')
            if note.get("chord"):
                lines.append('        <chord/>')
            lines.append('        <pitch>')
            lines.append(f'          <step>{step}</step>')
            if alt != 0:
                lines.append(f'          <alter>{alt}</alter>')
            lines.append(f'          <octave>{octv}</octave>')
            lines.append('        </pitch>')
            lines.append(f'        <duration>{dur}</duration>')
            lines.append('        <voice>1</voice>')
            lines.append(f'        <type>{ntype}</type>')
            lines.append('        <notations>')
            lines.append('          <technical>')
            # alphaTab string index: 1 = lowest (line 1), 6 = highest (line 6)
            s_num = note.get("string", 1)
            # In MusicXML tab notation, string 1 is highest E, 6 is lowest E
            # Convert alphaTab internal (1=low, 6=high) -> MusicXML (6=low, 1=high)
            xml_string = (7 - s_num) if (1 <= s_num <= 6) else s_num
            lines.append(f'            <string>{xml_string}</string>')
            lines.append(f'            <fret>{note.get("fret", 0)}</fret>')
            lines.append('          </technical>')
            lines.append('        </notations>')
            lines.append('      </note>')

        lines.append('    </measure>')

    lines.append('  </part>')
    lines.append('</score-partwise>')
    return "\n".join(lines) + "\n"

def transform_selection(data, template="alternate_picking", target_bpm=60):
    notes = data.get("notes", [])
    if not notes:
        # Fallback to a basic chromatic crawl if selection has no notes
        notes = [{"bar": 0, "string": s, "fret": f, "midi": 40 + s * 5 + f}
                 for s in range(1, 7) for f in range(1, 5)]

    time_sig = data.get("time_signature", [4, 4])
    tuning = data.get("tuning_midi", [40, 45, 50, 55, 59, 64])
    title = f"{data.get('title', 'Exercise')} [Draft: {template.replace('_', ' ').title()}]"

    # Group original notes by bar
    by_bar = {}
    for n in notes:
        by_bar.setdefault(n.get("bar", 0), []).append(n)

    measures = []

    if template == "alternate_picking":
        # Create an eighth-note alternate picking study across the strings present in selection
        unique_bars = sorted(by_bar.keys())
        for b in unique_bars:
            src_notes = by_bar[b]
            m_notes = []
            # 8 eighth notes per 4/4 bar
            count = 8
            for i in range(count):
                src = src_notes[i % len(src_notes)]
                m_notes.append({
                    "string": src["string"],
                    "fret": src["fret"],
                    "midi": src["midi"],
                    "duration": 2,  # eighth
                    "type": "eighth",
                })
            measures.append(m_notes)

    elif template == "arpeggio":
        # Create classical P-I-M-A arpeggio patterns from selected pitch sets
        unique_bars = sorted(by_bar.keys())
        for b in unique_bars:
            src_notes = by_bar[b]
            # Sort by string ascending (low to high)
            sorted_notes = sorted(src_notes, key=lambda n: n["string"])
            m_notes = []
            for i in range(8):
                # Cycle bass -> treble -> bass -> treble
                pattern_idx = [0, 1, 2, 1, 3, 2, 1, 2][i % 8]
                src = sorted_notes[pattern_idx % len(sorted_notes)]
                m_notes.append({
                    "string": src["string"],
                    "fret": src["fret"],
                    "midi": src["midi"],
                    "duration": 2,
                    "type": "eighth",
                })
            measures.append(m_notes)

    elif template == "slow_drill":
        # Keep original sequence but double the duration (quarter notes at half tempo)
        unique_bars = sorted(by_bar.keys())
        for b in unique_bars:
            src_notes = by_bar[b]
            m_notes = []
            # 4 quarter notes per bar
            for i in range(4):
                src = src_notes[i % len(src_notes)]
                m_notes.append({
                    "string": src["string"],
                    "fret": src["fret"],
                    "midi": src["midi"],
                    "duration": 4,  # quarter
                    "type": "quarter",
                })
            measures.append(m_notes)

    xml_text = build_musicxml(title, target_bpm, time_sig, tuning, measures)
    return xml_text, title

def main():
    parser = argparse.ArgumentParser(description="Generate practice variation MusicXML from selection")
    parser.add_argument("--selection", help="Path to selection.json or draft-request.json")
    parser.add_argument("--template", choices=["alternate_picking", "arpeggio", "slow_drill"], default="alternate_picking")
    parser.add_argument("--bpm", type=int, default=60)
    parser.add_argument("--out", help="Output .musicxml file path")
    parser.add_argument("--open", action="store_true", help="Send open-request.json to Tern")
    args = parser.parse_args()

    # Locate selection file
    default_plugin_data = os.path.expandvars(r"%LOCALAPPDATA%\Tern\plugin-data\gscore")
    sel_path = args.selection
    if not sel_path:
        sel_candidate = os.path.join(default_plugin_data, "selection.json")
        req_candidate = os.path.join(default_plugin_data, "draft-request.json")
        if os.path.exists(req_candidate):
            sel_path = req_candidate
        elif os.path.exists(sel_candidate):
            sel_path = sel_candidate

    if not sel_path or not os.path.exists(sel_path):
        print(f"Error: selection file not found (tried {sel_path})", file=sys.stderr)
        sys.exit(1)

    with open(sel_path, "r", encoding="utf-8") as f:
        data = json.load(f)

    # If it was a draft-request wrapper, read the referenced selection
    if data.get("action") == "create_draft" and "selection_file" in data:
        sub_sel = data["selection_file"]
        if os.path.exists(sub_sel):
            with open(sub_sel, "r", encoding="utf-8") as sf:
                data = json.load(sf)

    xml_text, title = transform_selection(data, template=args.template, target_bpm=args.bpm)

    # Output path
    out_path = args.out
    if not out_path:
        src_path = data.get("path", "draft")
        src_name = os.path.splitext(os.path.basename(src_path))[0]
        out_dir = os.path.join(default_plugin_data, "drafts")
        os.makedirs(out_dir, exist_ok=True)
        out_path = os.path.join(out_dir, f"draft_{src_name}_{args.template}.musicxml")

    os.makedirs(os.path.dirname(os.path.abspath(out_path)), exist_ok=True)
    with open(out_path, "w", encoding="utf-8") as f:
        f.write(xml_text)
    print(f"Draft generated successfully: {out_path}")
    print(f"  Title: {title}")
    print(f"  Bars: {len(data.get('bars', [0, 0]))} ({args.template} @ {args.bpm} BPM)")

    if args.open:
        req_file = os.path.join(default_plugin_data, "open-request.json")
        payload = {
            "file": os.path.abspath(out_path).replace("\\", "/"),
            "draft": True
        }
        with open(req_file, "w", encoding="utf-8") as f:
            json.dump(payload, f)
        print(f"Dispatched open-request to Tern for {out_path}")

if __name__ == "__main__":
    main()
