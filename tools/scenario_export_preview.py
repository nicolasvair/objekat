#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""What an export SHOWS of itself while it is being made.

Three things were added to the export on 16 September 2026, and this scenario is what can be
asserted of them with no screen:

  • a DIRECT render stays in the panel that launched it (a background one closes it), and
    `export.run` never OPENS a panel by itself — an export driven by a script must not put a
    window on the screen of whoever is working;
  • the waveform GROWS: the engine taps each rendered block, and `export.preview` says how many
    buckets have been filled. Caught mid-flight, that number is strictly between nothing and all
    of it — which is the only way to prove growth rather than a drawing made at the end;
  • the file can be LISTENED to while it is written: the render's temporary wave is a valid wave
    from end to end (Tracktion's writer rewrites its header every six seconds of audio), so
    `audible_seconds` climbs during the render and stops short of the whole — the render runs
    ahead of the flush.

The render has to LAST for any of that to be catchable, so the scenario lays a handful of objects
and renders a long range rather than the four hundred milliseconds of the fixture.

    objekat.app/Contents/MacOS/objekat --headless --api --no-audio --no-recent --socket=/tmp/o.sock
    ./scenario_export_preview.py /tmp/o.sock /tmp/trial/project.objekat.json

Exit: 0 if everything passes, 1 as soon as one assertion fails.
"""

import sys, os, json, time, wave, array

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from objekat_cli import ObjekatClient, ObjekatError

if len(sys.argv) != 3:
    print(__doc__)
    sys.exit(2)

SOCK = sys.argv[1]
PROJ = sys.argv[2]
BIP  = os.path.join(HERE, "fixtures", "bip.wav")
OUT  = lambda n: os.path.join(os.path.dirname(PROJ), n)

# Long enough that the render takes visible time AND crosses several of the writer's flushes
# (one every six seconds of audio).
RANGE_END = 600.0

ok, ko = 0, 0

def step(label, fn):
    global ok, ko
    try:
        r = fn()
        ok += 1
        print("  OK   %-34s %s" % (label, json.dumps(r, ensure_ascii=False)[:130]))
        return r
    except ObjekatError as e:
        ko += 1
        print("  FAIL %-34s %s" % (label, e.args[0]))
        return None

def check(label, cond, detail=""):
    global ok, ko
    if cond:
        ok += 1
        print("  OK   %-34s" % label)
    else:
        ko += 1
        print("  FAIL %-34s %s" % (label, detail))

def wav_peak(path):
    """The loudest sample of a WAV, in 0…1. Re-reading the FILE is the only way to tell whether
    the peaks the panel draws come from the sound or from somewhere else — 24 bits is read by
    hand, `wave` hands the bytes over as they are (@see the CLI's own 24-bit caution)."""
    with wave.open(path, "rb") as w:
        sw, raw = w.getsampwidth(), w.readframes(w.getnframes())
    if sw == 2:
        a = array.array("h"); a.frombytes(raw)
        return max(abs(v) for v in a) / 32768.0 if len(a) else 0.0
    if sw == 3:
        peak = 0
        for i in range(0, len(raw) - 2, 3):
            v = abs(int.from_bytes(raw[i:i + 3], "little", signed=True))
            if v > peak: peak = v
        return peak / 8388608.0
    raise RuntimeError("unexpected sample width: %d" % sw)


with ObjekatClient(SOCK) as c:
    c.send("app.set_dialog_policy", {"policy": "assume_yes"})
    c.send("project.new")
    c.send("project.save_as", {"path": PROJ})

    # Material spread over the range: a render of pure silence would be over before the first
    # poll, and a waveform of nothing proves nothing about the peaks.
    for lane in range(4):
        for k in range(6):
            c.send("object.add", {"path": BIP, "lane": lane, "start": 20.0 * k + 3.0 * lane})

    # --- no job at all
    try:
        c.send("export.preview")
        check("preview refuses with no job", False, "it answered")
    except ObjekatError as e:
        check("preview refuses with no job", e.code == "invalid_state", e.code)

    # --- the panel is KEPT, never opened
    st = step("status, panel closed", lambda: c.send("export.status"))
    check("panel closed at rest", st and st.get("panel_open") is False, st)

    r = step("run, no panel open", lambda: c.send("export.run", {
        "format": "wav", "sample_rate": 44100,
        "start": 0.0, "end": 2.0, "path": OUT("quiet.wav")}))
    st = c.send("export.status")
    check("a script opens no panel", st.get("panel_open") is False, st)
    if r:
        step("  job.wait", lambda: c.send("job.wait", {"id": r["job_id"], "timeout_ms": 60000}))
        # The peaks come from the ENGINE's tap on the render, the file from the writer beside it.
        # If the two agree on the loudest sample, what the panel draws really is what was written.
        q = step("preview, short render", lambda: c.send("export.preview"))
        if q:
            f = wav_peak(OUT("quiet.wav"))
            check("the peaks ARE the file",
                  abs(q["peak_amplitude"] - f) < 0.01,
                  "tap %.4f vs file %.4f" % (q["peak_amplitude"], f))

    # --- a direct render KEEPS the panel it was launched from
    step("panel open", lambda: c.send("export.panel", {"open": True}))
    r = step("run direct, panel open", lambda: c.send("export.run", {
        "format": "wav", "sample_rate": 44100, "background": False,
        "start": 0.0, "end": RANGE_END, "path": OUT("long.wav")}))

    # --- and this is where the growth is caught, mid-render
    samples = []
    if r:
        deadline = time.time() + 120
        while time.time() < deadline:
            st = c.send("export.status")
            if not st.get("running"):
                break
            try:
                samples.append((st, c.send("export.preview")))
            except ObjekatError:
                break
            time.sleep(0.05)
        step("  job.wait", lambda: c.send("job.wait", {"id": r["job_id"], "timeout_ms": 120000}))

    print("  ..   %d samples taken while rendering" % len(samples))
    check("caught it mid-render", len(samples) >= 2, "%d samples" % len(samples))

    mid = [p for _, p in samples]
    if mid:
        total = mid[0]["peaks_total"]
        filled = [p["peaks_filled"] for p in mid]
        check("panel held through the render",
              all(s.get("panel_open") is True for s, _ in samples),
              [s.get("panel_open") for s, _ in samples][:8])
        check("the waveform GROWS",
              any(0 < f < total for f in filled),
              "filled=%s total=%s" % (filled[:8], total))
        check("and never goes back",
              all(b >= a for a, b in zip(filled, filled[1:])),
              filled[:16])
        # The engine's tap is only remade when the render is really launched, and only zeroed
        # when its graph is built: read in between, it holds the PREVIOUS export's peaks, whole.
        # Nothing of this render exists while it prepares, and nothing must be reported.
        prep = [p["peaks_filled"] for s, p in samples if s.get("phase") == "preparing"]
        check("nothing shown while preparing", all(f == 0 for f in prep), prep[:8])
        audible = [p["audible_seconds"] for p in mid]
        check("something is audible before the end",
              any(0 < a < RANGE_END for a in audible),
              "audible=%s" % audible[:8])
        check("the listening never runs past the render",
              all(a <= RANGE_END + 0.5 for a in audible), audible[:8])
        # The two numbers are deliberately different: the render runs ahead of the writer's flush.
        check("the flush lags the render",
              any(p["audible_seconds"] < p["peaks_filled"] / total * RANGE_END - 0.5
                  for p in mid),
              [(p["audible_seconds"], p["peaks_filled"]) for p in mid[:6]])

    # --- once it is done
    done = step("preview, finished", lambda: c.send("export.preview"))
    if done:
        check("every bucket filled",
              done["peaks_filled"] == done["peaks_total"],
              "%s / %s" % (done["peaks_filled"], done["peaks_total"]))
        check("real signal in the peaks", done["peak_amplitude"] > 0.001, done["peak_amplitude"])
        check("the listening follows the final file",
              done["source"] == OUT("long.wav"), done["source"])
        check("the whole file is audible",
              abs(done["audible_seconds"] - RANGE_END) < 1.0, done["audible_seconds"])
        check("range remembered", abs(done["rendered_duration"] - RANGE_END) < 0.01,
              done["rendered_duration"])
    st = c.send("export.status")
    check("the panel keeps the result", st.get("panel_open") is True, st)

    # --- the peaks are the SOUND and not a decoration: the same project, rendered over a stretch
    #     where nothing plays, must give a flat waveform.
    r = step("run over silence", lambda: c.send("export.run", {
        "format": "wav", "sample_rate": 44100,
        "start": 300.0, "end": 310.0, "path": OUT("silence.wav")}))
    if r:
        step("  job.wait", lambda: c.send("job.wait", {"id": r["job_id"], "timeout_ms": 60000}))
        q = step("preview, silence", lambda: c.send("export.preview"))
        check("a silent render draws flat", q and q["peak_amplitude"] < 0.0001,
              q and q["peak_amplitude"])

    # --- a background render hands over to the strip
    r = step("run background", lambda: c.send("export.run", {
        "format": "wav", "sample_rate": 44100, "background": True,
        "start": 0.0, "end": 2.0, "path": OUT("bg.wav")}))
    st = c.send("export.status")
    check("the panel gives way", st.get("panel_open") is False, st)
    if r:
        step("  job.wait", lambda: c.send("job.wait", {"id": r["job_id"], "timeout_ms": 60000}))

    step("panel close", lambda: c.send("export.panel", {"open": False}))
    step("app.dialogs", lambda: c.send("app.dialogs"))

print("\n=== %d OK, %d FAILED ===" % (ok, ko))
sys.exit(1 if ko else 0)
