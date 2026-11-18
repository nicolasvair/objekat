#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Cut / copy / paste of MIDI NOTES — the piano roll as a surface of the keyboard.

    objekat.app/Contents/MacOS/objekat --headless --api --no-audio --no-recent --socket=/tmp/o.sock
    ./scenario_midi_clipboard.py /tmp/o.sock

@see EditViewModel+MIDINotes.swift (pasteMidiNotes, midiPasteTargetClipID, pasteGoesToMidiNotes),
EditViewModel+EditMenu.swift (the routing of the three shortcuts). The notes have their OWN clipboard;
the context decides which one ⌘V reads: notes selected OR a piano roll clicked -> the notes, in THAT
piano roll's clip, at the caret; a click in the timeline (or `caret.set`) -> the objects again.

  T1  copy / paste: branch midi_notes, rhythm and pitches kept, new ids, copies selected, caret at the end
  T2  cut, click the piano roll's background, paste: the notes come back (not the objects)
  T3  paste into ANOTHER clip (the one whose piano roll was clicked), at the caret
  T4  ⌘V x3 chains one after the other (the caret goes to the end of each paste)
  T5  notes and objects: the context decides; caret.set leaves the piano-roll context
  T6  one undo = the exact state (notes, selection-independent, clip length)
  T7  deleting the selected notes (the API door of ⌫ is midi.delete_notes) and its undo
  T8  overflow: a non-looping clip is lengthened (ONE undo); a LOOPING clip is not; a piano roll closed,
      or a group folded, is no context any more; a clip cropped on its left
  T9  the caret outside a click: a plain click in the timeline lets go of the selected notes

Exit: 0 if every assertion passes, 1 otherwise.
"""

import os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from objekat_cli import ObjekatClient, ObjekatError

if len(sys.argv) != 2:
    print(__doc__)
    sys.exit(2)

fails = []
count = 0


def check(label, ok, detail=""):
    global count
    count += 1
    if ok:
        print("ok    " + label)
    else:
        fails.append(label)
        print("FAIL  %s  %s" % (label, detail))


def near(a, b, eps=1e-6):
    return a is not None and abs(a - b) < eps


with ObjekatClient(sys.argv[1]) as c:
    def cmd(name, **p):
        return c.send(name, p or None)

    def settle():
        cmd("wait_idle", timeout_ms=120000, settle_ms=200)

    cmd("project.new")
    cmd("project.set_snap", enabled=False)
    tempo = cmd("transport.state")["tempo"]
    spb = 60.0 / tempo

    def notes(i):
        return cmd("midi.list_notes", id=i)["notes"]

    def shape(ns):
        return sorted((n["pitch"], round(n["start_beat"], 6), round(n["length_beats"], 6)) for n in ns)

    def cursor_beats():
        return cmd("transport.state")["cursor"] / spb

    def dur_beats(i):
        return {o["id"]: o for o in cmd("object.list")["objects"]}[i]["duration"] / spb

    def clip(start_beat, length_beats, lane, notes_spec=()):
        i = cmd("midi.create_clip", start=start_beat * spb, end=(start_beat + length_beats) * spb, lane=lane)["id"]
        ids = [cmd("midi.add_note", id=i, pitch=p, start_beat=s, length_beats=l)["note"]["id"]
               for (p, s, l) in notes_spec]
        return i, ids

    SPEC = [(60, 0.0, 1.0), (64, 1.5, 1.0), (67, 2.0, 0.5)]    # block of 2.5 beats
    BLOCK = 2.5

    # ------------------------------------------------------------------ T1
    a, na = clip(0, 8, 0, SPEC)
    b, _ = clip(20, 8, 1)
    cmd("midi.piano_roll", id=a, open=True)
    cmd("midi.piano_roll", id=b, open=True)
    settle()
    s = cmd("midi.select_notes", id=a, note_ids=na)
    check("T1 select_notes: 3 selected, focus on A",
          len(s["selected_note_ids"]) == 3 and s["focused_midi_clip"] == a, str(s))
    r = cmd("edit.copy")
    check("T1 copy: branch midi_notes", r["branch"] == "midi_notes", str(r))
    cmd("midi.focus", id=a, time=4.0 * spb)
    r = cmd("edit.paste")
    check("T1 paste: branch midi_notes", r["branch"] == "midi_notes", str(r))
    ns = notes(a)
    check("T1 six notes now", len(ns) == 6, str(len(ns)))
    want = sorted([(p, round(s_, 6), round(l, 6)) for (p, s_, l) in SPEC] +
                  [(p, round(4.0 + s_, 6), round(l, 6)) for (p, s_, l) in SPEC])
    check("T1 pitches and rhythm kept, laid at beat 4", shape(ns) == want, "%s" % shape(ns))
    check("T1 new ids for the copies", len({n["id"] for n in ns}) == 6 and not (set(na) - {n["id"] for n in ns}))
    sel = cmd("selection.get")
    new_ids = {n["id"] for n in ns} - set(na)
    check("T1 the copies (and only them) are selected", set(sel["selected_note_ids"]) == new_ids, str(sel))
    check("T1 caret at the end of the block (beat 6.5)", near(cursor_beats(), 4.0 + BLOCK), str(cursor_beats()))
    check("T1 the source notes untouched", shape([n for n in ns if n["id"] in set(na)]) == sorted(
        (p, round(s_, 6), round(l, 6)) for (p, s_, l) in SPEC))

    # ------------------------------------------------------------------ T2: cut, background click, paste
    cmd("edit.undo")                                   # back to three notes
    check("T6 undo of one paste: three notes again", len(notes(a)) == 3, str(len(notes(a))))
    cmd("midi.select_notes", id=a, note_ids=na)
    r = cmd("edit.cut")
    check("T2 cut: branch midi_notes, the clip is empty", r["branch"] == "midi_notes" and len(notes(a)) == 0, str(r))
    f = cmd("midi.focus", id=a, time=1.0 * spb)
    check("T2 background click: no note selected, piano roll in context",
          f["selected_note_ids"] == [] and f["focused_midi_clip"] == a, str(f))
    r = cmd("edit.paste")
    check("T2 paste after cut + background click: branch midi_notes (not the objects)",
          r["branch"] == "midi_notes", str(r))
    check("T2 the three notes are back, laid at beat 1",
          shape(notes(a)) == sorted((p, round(1.0 + s_, 6), round(l, 6)) for (p, s_, l) in SPEC), str(shape(notes(a))))

    # ------------------------------------------------------------------ T3: into another clip
    cmd("midi.focus", id=b, time=22.0 * spb)
    r = cmd("edit.paste")
    nb = notes(b)
    check("T3 paste into B (the piano roll clicked), not into the source clip A",
          r["branch"] == "midi_notes" and len(nb) == 3 and len(notes(a)) == 3, "%s %d %d" % (r, len(nb), len(notes(a))))
    check("T3 laid at the caret (beat 2 of B), pitches kept",
          shape(nb) == sorted((p, round(2.0 + s_, 6), round(l, 6)) for (p, s_, l) in SPEC), str(shape(nb)))
    check("T3 absolute pitches kept (60 / 64 / 67)", sorted(n["pitch"] for n in nb) == [60, 64, 67])
    check("T3 caret at 22 + 2.5 beats", near(cursor_beats(), 24.5), str(cursor_beats()))

    # ------------------------------------------------------------------ T4: chain
    cmd("midi.focus", id=b, time=21.0 * spb)
    cmd("edit.undo") if False else None
    for k in range(3):
        cmd("edit.paste")
    nb = notes(b)
    check("T4 three more pastes: 3 + 9 notes", len(nb) == 12, str(len(nb)))
    starts = sorted({round(n["start_beat"], 6) for n in nb if n["pitch"] == 60})
    check("T4 the blocks chain (beat 1, 3.5, 6, + the earlier 2)",
          starts == [1.0, 2.0, 3.5, 6.0], str(starts))
    check("T4 caret at the end of the last block", near(cursor_beats(), 21.0 + 3 * BLOCK), str(cursor_beats()))

    # ------------------------------------------------------------------ T5: notes vs objects
    pre = len([o for o in cmd("object.list")["objects"]])
    cmd("caret.set", lane=3, time=30.0 * spb)
    st = cmd("selection.get")
    check("T5 caret.set leaves the piano-roll context and lets go of the notes",
          st["focused_midi_clip"] is None and st["selected_note_ids"] == [], str(st))
    cmd("select.clear") if False else None
    cmd("selection.set", ids=[a])
    cmd("edit.copy")                                     # the OBJECT clipboard now
    cmd("caret.set", lane=4, time=40.0 * spb)
    r = cmd("edit.paste")
    check("T5 outside the piano roll ⌘V pastes OBJECTS", r["branch"] == "objects", str(r))
    check("T5 one object more", len(cmd("object.list")["objects"]) == pre + 1, str(len(cmd("object.list")["objects"])))
    cmd("midi.focus", id=a, time=2.0 * spb)
    r = cmd("edit.paste")
    check("T5 piano roll clicked again: ⌘V pastes NOTES again (the two clipboards are apart)",
          r["branch"] == "midi_notes", str(r))

    # ------------------------------------------------------------------ T6 (undo exact) on clip B
    before = shape(notes(b))
    dur0 = dur_beats(b)
    cmd("midi.focus", id=b, time=26.0 * spb)
    cmd("edit.paste")
    check("T6 paste added three notes", len(notes(b)) == len(before) + 3)
    cmd("edit.undo")
    check("T6 one undo: the same notes", shape(notes(b)) == before, "%s" % shape(notes(b)))
    check("T6 the clip length as it was", near(dur_beats(b), dur0), "%s vs %s" % (dur_beats(b), dur0))
    cmd("edit.redo")
    check("T6 redo: the notes again", len(notes(b)) == len(before) + 3)

    # ------------------------------------------------------------------ T7: delete the selected notes
    sel = cmd("selection.get")["selected_note_ids"]
    check("T7 the pasted notes are the selection", len(sel) == 3, str(sel))
    n_before = len(notes(b))
    cmd("midi.delete_notes", id=b, note_ids=sel)
    check("T7 deleted", len(notes(b)) == n_before - 3)
    cmd("edit.undo")
    check("T7 undo: back", len(notes(b)) == n_before)

    # ------------------------------------------------------------------ T8: overflow
    cmd("project.new")
    cmd("project.set_snap", enabled=False)
    a, na = clip(0, 4, 0, SPEC)
    cmd("midi.piano_roll", id=a, open=True)
    settle()
    cmd("midi.select_notes", id=a, note_ids=na)
    cmd("edit.copy")
    d0 = dur_beats(a)
    cmd("midi.focus", id=a, time=3.0 * spb)          # block 3 -> 5.5 past the end (4)
    cmd("edit.paste")
    check("T8 overflow: the clip is lengthened to the end of the last note (5.5 beats)",
          near(dur_beats(a), 5.5), "%s (was %s)" % (dur_beats(a), d0))
    cmd("edit.undo")
    check("T8 ONE undo gives the notes AND the length back",
          len(notes(a)) == 3 and near(dur_beats(a), d0), "%d %s" % (len(notes(a)), dur_beats(a)))

    # a LOOPING clip is not lengthened
    cmd("object.set_loop", id=a, enabled=True)
    cmd("midi.focus", id=a, time=3.0 * spb)
    cmd("edit.paste")
    check("T8 looping clip: NOT lengthened by the paste", near(dur_beats(a), d0), str(dur_beats(a)))
    check("T8 looping clip: the notes pasted all the same", len(notes(a)) == 6, str(len(notes(a))))
    cmd("edit.undo")
    cmd("object.set_loop", id=a, enabled=False)

    # a caret BEFORE the clip's start: no note at a negative beat
    cmd("project.new")
    cmd("project.set_snap", enabled=False)
    a, na = clip(0, 4, 0, SPEC)
    b, _ = clip(8, 4, 1)
    cmd("midi.piano_roll", id=a, open=True)
    cmd("midi.piano_roll", id=b, open=True)
    settle()
    cmd("midi.select_notes", id=a, note_ids=na)
    cmd("edit.copy")
    cmd("midi.focus", id=b, time=2.0 * spb)          # before B (which starts at beat 8)
    cmd("edit.paste")
    check("T8 caret before the clip: no note before the clip's start",
          all(n["start_beat"] >= -1e-9 for n in notes(b)) and len(notes(b)) == 3, str(shape(notes(b))))

    # piano roll closed: no context any more
    cmd("midi.piano_roll", id=b, open=False)
    check("T8 closed piano roll: no focus", cmd("selection.get")["focused_midi_clip"] is None)
    cmd("selection.clear")
    r = cmd("edit.paste")
    check("T8 piano roll closed, nothing selected: ⌘V is not a notes' paste", r["branch"] != "midi_notes", str(r))

    # a MIDI clip in a group; the group folded
    cmd("project.new")
    cmd("project.set_snap", enabled=False)
    a, na = clip(0, 4, 0, SPEC)
    m, _ = clip(8, 4, 1)
    g = cmd("group.create", ids=[m])["id"]
    cmd("group.expand", id=g, expanded=True)
    settle()
    kids = [o["id"] for o in cmd("object.list")["objects"] if o.get("parent") == g]
    check("T8 fixture: the clip lives in the open group", len(kids) == 1, str(kids))
    if kids:
        k = kids[0]
        cmd("midi.piano_roll", id=a, open=True)
        cmd("midi.piano_roll", id=k, open=True)
        settle()
        cmd("midi.select_notes", id=a, note_ids=na)
        cmd("edit.copy")
        f = cmd("midi.focus", id=k, time=9.0 * spb)
        r = cmd("edit.paste")
        check("T8 a child of an open group: the notes land in ITS piano roll",
              r["branch"] == "midi_notes" and len(notes(k)) == 3 and len(notes(a)) == 3, "%s %d" % (r, len(notes(k))))
        cmd("group.expand", id=g, expanded=False)
        settle()
        st = cmd("selection.get")
        check("T8 group folded: the piano roll is no context any more", st["focused_midi_clip"] is None, str(st))

    # ------------------------------------------------------------------ T9: a click in the timeline
    cmd("project.new")
    cmd("project.set_snap", enabled=False)
    a, na = clip(0, 4, 0, SPEC)
    cmd("midi.piano_roll", id=a, open=True)
    settle()
    s = cmd("midi.select_notes", id=a, note_ids=na)
    check("T9 notes selected", len(s["selected_note_ids"]) == 3)
    cmd("caret.set", lane=2, time=1.0)
    st = cmd("selection.get")
    check("T9 a click in the timeline (caret.set) lets go of the notes", st["selected_note_ids"] == [], str(st))

print("\n%d assertions, %d failed" % (count, len(fails)))
print("ALL PASS" if not fails else "FAILED:\n  " + "\n  ".join(fails))
sys.exit(1 if fails else 0)
