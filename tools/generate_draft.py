#!/usr/bin/env python3
"""generate_draft.py — turn a structured selection into a practice variation.

Consumes a `music_context_v1` selection (as written by the gscore panel) and emits a
standalone guitar-TAB MusicXML draft. The note sounding pitch is always re-derived
from tuning + fret, so a selection whose MIDI disagrees with its string/fret is
rejected rather than silently generating an unplayable exercise.

Usage:
  python tools/generate_draft.py --selection sel.json --template arpeggio --bpm 60 --open

Templates:
  alternate_picking  eighth-note stream with explicit down/up stroke marks
  arpeggio           p-i-m-a pattern with fingering marks
  slow_drill         original rhythm with every duration doubled
"""

import argparse
import json
import os
import sys

DIVISIONS = 4              # 1 quarter = 4 divisions
QUARTER, EIGHTH, SIXTEENTH = 4, 2, 1

MIDI_NOTE_NAMES = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
STANDARD_TUNING = [40, 45, 50, 55, 59, 64]   # string 1 (low E) .. string 6 (high E)


def midi_to_pitch(midi):
    octave = (int(midi) // 12) - 1
    name = MIDI_NOTE_NAMES[int(midi) % 12]
    if len(name) == 2:
        return name[0], octave, 1
    return name, octave, 0


def note_midi(note, tuning):
    """Sounding pitch from the tab position; falls back to the note's own midi."""
    string = note.get("string")
    fret = note.get("fret")
    if isinstance(string, int) and isinstance(fret, int) and 1 <= string <= len(tuning):
        return tuning[string - 1] + fret
    return note.get("midi")


def validate_selection(notes, tuning):
    """Reject a selection whose declared MIDI contradicts its string/fret."""
    problems = []
    for n in notes:
        string, fret, declared = n.get("string"), n.get("fret"), n.get("midi")
        if not isinstance(string, int) or not isinstance(fret, int):
            problems.append(f"note {n.get('id')} has no string/fret")
            continue
        if not 1 <= string <= len(tuning):
            problems.append(f"note {n.get('id')} string {string} outside tuning")
            continue
        expected = tuning[string - 1] + fret
        if isinstance(declared, int) and declared != expected:
            problems.append(
                f"note {n.get('id')}: string {string} fret {fret} implies midi {expected}, "
                f"selection says {declared}"
            )
    return problems


def bar_capacity(time_sig, unit):
    """How many `unit`-sized slots fit in one bar of this time signature."""
    num, den = (time_sig + [4, 4])[:2]
    bar_in_quarters = num * (4.0 / den)
    return max(1, int(round(bar_in_quarters * (QUARTER / unit))))


def build_musicxml(title, bpm, time_sig, tuning, measures):
    ts_num, ts_den = (time_sig + [4, 4])[:2]
    out = [
        '<?xml version="1.0" encoding="UTF-8"?>',
        '<!DOCTYPE score-partwise PUBLIC "-//Recordare//DTD MusicXML 4.0 Partwise//EN" '
        '"http://www.musicxml.org/dtds/partwise.dtd">',
        '<score-partwise version="4.0">',
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

    for m_idx, notes in enumerate(measures, start=1):
        out.append(f'    <measure number="{m_idx}">')
        if m_idx == 1:
            out.extend([
                '      <attributes>',
                f'        <divisions>{DIVISIONS}</divisions>',
                '        <key><fifths>0</fifths></key>',
                f'        <time><beats>{ts_num}</beats><beat-type>{ts_den}</beat-type></time>',
                '        <clef><sign>TAB</sign><line>5</line></clef>',
                '        <staff-details>',
                '          <staff-lines>6</staff-lines>',
            ])
            for line in range(1, 7):
                step, octv, alt = midi_to_pitch(tuning[line - 1])
                out.append(f'          <staff-tuning line="{line}">')
                out.append(f'            <tuning-step>{step}</tuning-step>')
                if alt:
                    out.append(f'            <tuning-alter>{alt}</tuning-alter>')
                out.append(f'            <tuning-octave>{octv}</tuning-octave>')
                out.append('          </staff-tuning>')
            out.extend([
                '        </staff-details>',
                '      </attributes>',
                f'      <direction placement="above"><sound tempo="{bpm}"/></direction>',
            ])

        for note in notes:
            midi = note["midi"]
            step, octv, alt = midi_to_pitch(midi)
            out.append('      <note>')
            if note.get("chord"):
                out.append('        <chord/>')
            out.append('        <pitch>')
            out.append(f'          <step>{step}</step>')
            if alt:
                out.append(f'          <alter>{alt}</alter>')
            out.append(f'          <octave>{octv}</octave>')
            out.append('        </pitch>')
            out.append(f'        <duration>{note["duration"]}</duration>')
            out.append('        <voice>1</voice>')
            out.append(f'        <type>{note["type"]}</type>')
            # stick direction / fingering ride on <notations>
            marks = []
            if note.get("stroke"):
                marks.append(f'          <technical><{note["stroke"]}/></technical>')
            if note.get("finger"):
                marks.append(f'          <technical><fingering>{note["finger"]}</fingering></technical>')
            for m in marks:
                out.append('        <notations>')
                out.append(m)
                out.append('        </notations>')
            # tab position: alphaTab numbers strings 1=lowest .. 6=highest,
            # MusicXML numbers 1=highest .. 6=lowest
            xml_string = 7 - note["string"] if 1 <= note["string"] <= 6 else note["string"]
            out.append('        <notations>')
            out.append('          <technical>')
            out.append(f'            <string>{xml_string}</string>')
            out.append(f'            <fret>{note["fret"]}</fret>')
            out.append('          </technical>')
            out.append('        </notations>')
            out.append('      </note>')

        out.append('    </measure>')

    out.extend(['  </part>', '</score-partwise>'])
    return "\n".join(out) + "\n"


def transform(data, template, target_bpm):
    raw_tuning = data.get("tuning_midi") or STANDARD_TUNING
    if len(raw_tuning) < 6:
        raw_tuning = STANDARD_TUNING
    # Normalize tuning to low-to-high order [low E, A, D, G, B, high E]
    # alphaTab's raw array is high-to-low [64, 59, 55, 50, 45, 40]
    if raw_tuning[0] > raw_tuning[-1]:
        tuning = list(reversed(raw_tuning))
    else:
        tuning = list(raw_tuning)
    time_sig = data.get("time_signature") or [4, 4]
    source_notes = data.get("notes") or []

    if not source_notes:
        raise SystemExit(
            "selection has no notes: refusing to invent an unrelated exercise"
        )

    problems = validate_selection(source_notes, tuning)
    if problems:
        raise SystemExit("selection rejected:\n  " + "\n  ".join(problems[:8]))

    by_bar = {}
    for n in source_notes:
        by_bar.setdefault(n.get("bar", 0), []).append(n)
    bars = sorted(by_bar)

    base_title = data.get("title") or "Exercise"
    title = f"{base_title} [Draft: {template.replace('_', ' ').title()}]"
    measures = []

    if template == "alternate_picking":
        slots = bar_capacity(time_sig, EIGHTH)
        for b in bars:
            src = by_bar[b]
            measure = []
            for i in range(slots):
                note = dict(src[i % len(src)])
                measure.append({
                    "string": note["string"],
                    "fret": note["fret"],
                    "midi": note_midi(note, tuning),
                    "duration": EIGHTH,
                    "type": "eighth",
                    "stroke": "down-bow" if i % 2 == 0 else "up-bow",
                })
            measures.append(measure)

    elif template == "arpeggio":
        slots = bar_capacity(time_sig, EIGHTH)
        fingering = ["p", "i", "m", "a"]
        for b in bars:
            src = sorted(by_bar[b], key=lambda n: n["string"])
            measure = []
            for i in range(slots):
                note = dict(src[[0, 1, 2, 1][i % 4] % len(src)])
                measure.append({
                    "string": note["string"],
                    "fret": note["fret"],
                    "midi": note_midi(note, tuning),
                    "duration": EIGHTH,
                    "type": "eighth",
                    "finger": fingering[i % 4],
                })
            measures.append(measure)

    elif template == "slow_drill":
        # keep the original order and simply double every duration
        for b in bars:
            measure = []
            for note in by_bar[b]:
                doubled = min(QUARTER, (note.get("duration_ticks") or 240) // 120)
                dur = doubled if doubled in (1, 2, 4) else EIGHTH
                measure.append({
                    "string": note["string"],
                    "fret": note["fret"],
                    "midi": note_midi(note, tuning),
                    "duration": dur * 2 if dur * 2 <= QUARTER * 2 else QUARTER,
                    "type": {1: "16th", 2: "eighth", 4: "quarter"}.get(dur, "eighth"),
                })
            measures.append(measure)

    else:
        raise SystemExit(f"unknown template: {template}")

    return build_musicxml(title, target_bpm, time_sig, tuning, measures), title


def main():
    ap = argparse.ArgumentParser(description="Generate a practice variation from a gscore selection")
    ap.add_argument("--selection", help="selection.json or draft-request.json")
    ap.add_argument("--template", default="alternate_picking",
                    choices=["alternate_picking", "arpeggio", "slow_drill"])
    ap.add_argument("--bpm", type=int, default=60)
    ap.add_argument("--out", help="output .musicxml path")
    ap.add_argument("--open", action="store_true", help="ask Tern to open it beside the source pane")
    args = ap.parse_args()

    plugin_data = os.path.expandvars(r"%LOCALAPPDATA%\Tern\plugin-data\gscore")
    sel = args.selection
    if not sel:
        for candidate in ("draft-request.json", "selection.json"):
            p = os.path.join(plugin_data, candidate)
            if os.path.exists(p):
                sel = p
                break
    if not sel or not os.path.exists(sel):
        raise SystemExit(f"selection file not found: {sel}")

    with open(sel, encoding="utf-8") as f:
        data = json.load(f)

    # a draft-request carries a pointer to the exported selection
    if data.get("action") == "create_draft":
        pointed = data.get("selection_file")
        if not pointed or not os.path.exists(pointed):
            raise SystemExit("draft-request has no readable selection_file")
        with open(pointed, encoding="utf-8") as f:
            data = json.load(f)
        template = data.get("_template") or args.template
        template = data.get("template", template)
    else:
        template = args.template

    xml_text, title = transform(data, template, args.bpm)

    out = args.out
    if not out:
        stem = os.path.splitext(os.path.basename(data.get("path") or "score"))[0]
        drafts = os.path.join(plugin_data, "drafts")
        os.makedirs(drafts, exist_ok=True)
        out = os.path.join(drafts, f"draft_{stem}_{template}.musicxml")

    os.makedirs(os.path.dirname(os.path.abspath(out)), exist_ok=True)
    with open(out, "w", encoding="utf-8") as f:
        f.write(xml_text)

    note_count = sum(1 for line in xml_text.splitlines() if "<fret>" in line)
    print(f"draft written: {out}")
    print(f"  title: {title}")
    print(f"  template: {template} @ {args.bpm} BPM")
    print(f"  notes: {note_count}")

    if args.open:
        req = os.path.join(plugin_data, "open-request.json")
        with open(req, "w", encoding="utf-8") as f:
            json.dump({"file": os.path.abspath(out).replace("\\", "/"), "draft": True}, f)
        print(f"  opened beside the source pane")


if __name__ == "__main__":
    main()
