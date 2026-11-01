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
  arpeggio           p-i-m-a plucking marks
  slow_drill         source rhythm at the requested slower tempo
"""

import argparse
import json
import os
import sys

DIVISIONS = 960          # alphaTab playback ticks per quarter note
QUARTER, EIGHTH, SIXTEENTH = DIVISIONS, DIVISIONS // 2, DIVISIONS // 4
NOTE_TYPE_TICKS = {
    "whole": 4 * DIVISIONS, "half": 2 * DIVISIONS, "quarter": DIVISIONS,
    "eighth": DIVISIONS // 2, "16th": DIVISIONS // 4, "32nd": DIVISIONS // 8,
    "64th": DIVISIONS // 16, "128th": DIVISIONS // 32, "256th": DIVISIONS // 64,
}

MIDI_NOTE_NAMES = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
STANDARD_TUNING = [40, 45, 50, 55, 59, 64]   # string 1 (low E) .. string 6 (high E)


def midi_to_pitch(midi):
    octave = (int(midi) // 12) - 1
    name = MIDI_NOTE_NAMES[int(midi) % 12]
    if len(name) == 2:
        return name[0], octave, 1
    return name, octave, 0


def rhythmic_notation(note):
    """Preserve an alphaTab beat duration as MusicXML duration/type/dots/tuplet."""
    duration = note.get("duration_ticks")
    if not isinstance(duration, int) or duration <= 0:
        duration = EIGHTH
    dots = note.get("dots") or 0
    if not isinstance(dots, int) or not 0 <= dots <= 3:
        raise SystemExit(f"unsupported dot count: {dots}")

    actual = normal = 1
    tuplet = note.get("tuplet")
    if tuplet:
        try:
            actual, normal = (int(value) for value in str(tuplet).split(":"))
        except (TypeError, ValueError):
            raise SystemExit(f"invalid tuplet ratio: {tuplet}")
        if actual <= 0 or normal <= 0:
            raise SystemExit(f"invalid tuplet ratio: {tuplet}")

    dot_numerator = (1 << (dots + 1)) - 1
    dot_denominator = 1 << dots
    base_numerator = duration * actual * dot_denominator
    base_denominator = normal * dot_numerator
    for note_type, base_ticks in NOTE_TYPE_TICKS.items():
        if base_numerator == base_ticks * base_denominator:
            time_modification = (actual, normal) if tuplet else None
            return duration, note_type, dots, time_modification
    raise SystemExit(
        f"unsupported source rhythm: {duration} ticks, {dots} dots, tuplet {tuplet}"
    )


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
            out.append('      <note>')
            if note.get("rest"):
                out.append('        <rest/>')
            else:
                if note.get("chord"):
                    out.append('        <chord/>')
                midi = note["midi"]
                step, octv, alt = midi_to_pitch(midi)
                out.append('        <pitch>')
                out.append(f'          <step>{step}</step>')
                if alt:
                    out.append(f'          <alter>{alt}</alter>')
                out.append(f'          <octave>{octv}</octave>')
                out.append('        </pitch>')
            out.append(f'        <duration>{note["duration"]}</duration>')
            out.append('        <voice>1</voice>')
            out.append(f'        <type>{note["type"]}</type>')
            for _ in range(note.get("dots", 0)):
                out.append('        <dot/>')
            if note.get("time_modification"):
                actual, normal = note["time_modification"]
                out.extend([
                    '        <time-modification>',
                    f'          <actual-notes>{actual}</actual-notes>',
                    f'          <normal-notes>{normal}</normal-notes>',
                    '        </time-modification>',
                ])
            technical = []
            if note.get("stroke"):
                technical.append(f'<{note["stroke"]}/>')
            if note.get("finger"):
                technical.append(f'<pluck>{note["finger"]}</pluck>')
            if not note.get("rest"):
                xml_string = 7 - note["string"] if 1 <= note["string"] <= 6 else note["string"]
                technical.extend([
                    f'<string>{xml_string}</string>',
                    f'<fret>{note["fret"]}</fret>',
                ])
            if technical:
                out.append('        <notations>')
                out.append('          <technical>' + ''.join(technical) + '</technical>')
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
        beat_events = {}
        for event in data.get("beats") or []:
            bar = event.get("bar")
            if bar in by_bar:
                for beat_id in event.get("beat_ids") or []:
                    beat_events.setdefault(bar, {}).setdefault(beat_id, event)
        for b in bars:
            measure = []
            events = beat_events.get(b)
            if not events:
                events = {
                    note.get("beat", note.get("id", i)): {
                        "duration_ticks": note.get("duration_ticks"),
                        "dots": note.get("dots", 0),
                        "tuplet": note.get("tuplet"),
                    }
                    for i, note in enumerate(by_bar[b])
                }
            notes_by_beat = {}
            for note in by_bar[b]:
                notes_by_beat.setdefault(note.get("beat", note.get("id")), []).append(note)
            for beat_id, event in sorted(
                events.items(), key=lambda item: (item[1].get("tick", 0), item[0])
            ):
                group = notes_by_beat.get(beat_id, [])
                if not group:
                    duration, note_type, dots, time_modification = rhythmic_notation(event)
                    measure.append({
                        "rest": True,
                        "duration": duration,
                        "type": note_type,
                        "dots": dots,
                        "time_modification": time_modification,
                    })
                    continue
                for i, note in enumerate(group):
                    source = dict(note)
                    if not source.get("duration_ticks"):
                        source["duration_ticks"] = event.get("duration_ticks")
                    duration, note_type, dots, time_modification = rhythmic_notation(source)
                    measure.append({
                        "string": note["string"],
                        "fret": note["fret"],
                        "midi": note_midi(note, tuning),
                        "duration": duration,
                        "type": note_type,
                        "dots": dots,
                        "time_modification": time_modification,
                        "chord": i > 0,
                    })
            measures.append(measure)

    else:
        raise SystemExit(f"unknown template: {template}")

    return build_musicxml(title, target_bpm, time_sig, tuning, measures), title


def main():
    ap = argparse.ArgumentParser(description="Generate a practice variation from a gscore selection")
    ap.add_argument("--selection", help="selection.json")
    ap.add_argument("--template", default="alternate_picking",
                    choices=["alternate_picking", "arpeggio", "slow_drill"])
    ap.add_argument("--bpm", type=int, default=60)
    ap.add_argument("--out", help="output .musicxml path")
    ap.add_argument("--open", action="store_true", help="ask Tern to open it beside the source pane")
    args = ap.parse_args()

    plugin_data = os.path.expandvars(r"%LOCALAPPDATA%\Tern\plugin-data\gscore")
    sel = args.selection
    if not sel:
        sel = os.path.join(plugin_data, "selection.json")
    if not sel or not os.path.exists(sel):
        raise SystemExit(f"selection file not found: {sel}")

    with open(sel, encoding="utf-8") as f:
        data = json.load(f)

    xml_text, title = transform(data, args.template, args.bpm)

    out = args.out
    if not out:
        stem = os.path.splitext(os.path.basename(data.get("path") or "score"))[0]
        drafts = os.path.join(plugin_data, "drafts")
        os.makedirs(drafts, exist_ok=True)
        out = os.path.join(drafts, f"draft_{stem}_{args.template}.musicxml")

    os.makedirs(os.path.dirname(os.path.abspath(out)), exist_ok=True)
    with open(out, "w", encoding="utf-8") as f:
        f.write(xml_text)

    note_count = sum(1 for line in xml_text.splitlines() if "<fret>" in line)
    print(f"draft written: {out}")
    print(f"  title: {ascii(title)}")
    print(f"  template: {args.template} @ {args.bpm} BPM")
    print(f"  notes: {note_count}")

    if args.open:
        req = os.path.join(plugin_data, "open-request.json")
        with open(req, "w", encoding="utf-8") as f:
            json.dump({"file": os.path.abspath(out).replace("\\", "/"), "draft": True}, f)
        print(f"  opened beside the source pane")


if __name__ == "__main__":
    main()
