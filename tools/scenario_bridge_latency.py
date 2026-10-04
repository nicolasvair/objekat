#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Sample alignment of the audio bridge — the key reaches a plugin on the SAME sample as the signal
it was meant for, whether the key is younger or older than that signal (docs/plan_sidechain.md §4,
§6 step 1.12).

The measuring tools are the engine's own `latencyTester` (declares AND applies a delay) and the
`objKeyProbe` (output LEFT = the signal the plugin receives, output RIGHT = the key, sample for
sample). An impulse goes through both paths; the peaks of an export say where each landed:

    idx(L) == idx(R)        the key is aligned with the signal, to the sample.

Cases: A nothing anywhere · B the key OLDER (a latency on the source) · C the key YOUNGER (a latency
before the probe) · D different stems · E inside groups, one two levels deep · F the source is a STEM
carrying a latency · G the probe on a STEM BUS · H the source's latency CHANGES while running (the
first build after it needs a second pass) · I the source is outside the host's span (silent key) ·
J whether the renderer compensates absolute output latency (decides what the absolute index must be).

    objekat.app/Contents/MacOS/objekat --headless --api --no-audio --no-recent --language=en \
        --socket=/tmp/o.sock
    ./scenario_bridge_latency.py /tmp/o.sock /tmp/trial/project.objekat

A DEBUG build (`debug.bridge_report`, `debug.add_test_plugin`). Exit: 0 if everything passes.
"""

import os, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from objekat_cli import ObjekatClient, ObjekatError
import bridge_scenario_common as B

if len(sys.argv) != 3:
    print(__doc__)
    sys.exit(2)

SOCK, PROJ = sys.argv[1], sys.argv[2]
DIR = os.path.dirname(PROJ)
T = B.Tally(ObjekatError)
step, check = T.step, T.check
OUT = lambda n: os.path.join(DIR, n)

IMPULSE = OUT("impulse.wav")
B.make_impulse(IMPULSE)                       # 3 s, one sample at index 48000
AT = B.SR                                     # where it sits in the file


def wait(c):
    c.send("wait_idle")


def render(c, name, t0=0.0, t1=3.0):
    r = c.send("export.run", {"format": "wav", "sample_rate": B.SR, "dithering": False,
                              "start": t0, "end": t1, "path": OUT(name)})
    c.send("job.wait", {"id": r["job_id"], "timeout_ms": 120000})
    ch = B.read_wav(OUT(name))
    return ch[0], ch[1] if len(ch) > 1 else ch[0]


def add_test(c, host, kind, ms=None):
    p = {"host": host, "type": kind}
    if ms is not None:
        p["latency_ms"] = ms
    return c.send("debug.add_test_plugin", p)["plugin"]


def reader(c):
    eng = c.send("debug.bridge_report")["engine"] or {}
    return (eng.get("readers") or [None])[0], eng.get("build") or {}


def fresh(c):
    c.send("project.new")
    c.send("project.save_as", {"path": PROJ})


def detached_stem(c, name="Key"):
    s = c.send("stem.add", {"name": name})["id"]
    c.send("stem.route_to_main", {"id": s, "on": False})
    return s


def run_case(c, label, *, y_lat=None, x_lat=None, expect_declared=None, expect_delay=None,
             y_stem=False, nest=None, key_is_stem=False, probe_on_bus=False, x_start=0.0,
             absolute=None, x_outside=False):
    """Builds Y (a probe, behind `y_lat` ms of delay) keyed by X (an impulse in a detached stem,
    behind `x_lat` ms), renders, and asserts the alignment. Returns the (L, R) channels."""
    fresh(c)
    kstem = detached_stem(c)
    y = c.send("object.add", {"path": IMPULSE, "lane": 0, "start": 0.0})["id"]
    x = c.send("object.add", {"path": IMPULSE, "lane": 1, "start": 10.0 if x_outside else x_start})["id"]
    c.send("stem.assign", {"stem": kstem, "ids": [x]})
    bstem = None
    if y_stem or probe_on_bus:
        bstem = c.send("stem.add", {"name": "Bus"})["id"]
        c.send("stem.assign", {"stem": bstem, "ids": [y]})

    y_host, x_host = y, x
    if nest == "groups":
        gy = c.send("group.create", {"ids": [y]})["id"]
        gx = c.send("group.create", {"ids": [x]})["id"]
        if bstem:
            c.send("stem.assign", {"stem": bstem, "ids": [gy]})
        c.send("stem.assign", {"stem": kstem, "ids": [gx]})
    elif nest == "deep":
        inner = c.send("group.create", {"ids": [y]})["id"]
        c.send("group.create", {"ids": [inner]})
        gx = c.send("group.create", {"ids": [x]})["id"]
        c.send("stem.assign", {"stem": kstem, "ids": [gx]})

    x_tester = None
    if x_lat is not None:
        x_tester = add_test(c, kstem if key_is_stem else x_host, "latencyTester", x_lat)
    if y_lat is not None and not probe_on_bus:
        add_test(c, y_host, "latencyTester", y_lat)
    probe_host = bstem if probe_on_bus else y_host
    probe = add_test(c, probe_host, "objKeyProbe")
    source = kstem if key_is_stem else x
    r = step(label + ": key", lambda: c.send("plugin.set_sidechain", {"host": probe_host, "plugin": probe, "source": source}))
    wait(c)
    time.sleep(0.4)                           # a latency tester asks for a rebuild on its own timer
    wait(c)

    rd, build = reader(c)
    check(label + ": the reader is built and converged", rd is not None and build.get("converged") is True, (rd, build))
    if rd is not None:
        check(label + ": the key is aligned in the graph", rd["status"] == "aligned", rd["status"])
        if expect_declared is not None:
            check(label + ": declared == source age == %d" % expect_declared,
                  rd["declared"] == expect_declared and rd["source_age"] == expect_declared, rd)
        if expect_delay is not None:
            check(label + ": delay == %d" % expect_delay, rd["delay"] == expect_delay, rd)

    left, right = render(c, "lat_%s.wav" % label.split(":")[0].split()[0])
    il, ir = B.peak_index(left), B.peak_index(right)
    if x_outside:
        check(label + ": the key is silent outside the source's span", ir is None, ir)
    else:
        check(label + ": idx(L) == idx(R)", il is not None and il == ir, "L %s R %s" % (il, ir))
        if absolute is not None and il is not None:
            check(label + ": absolute index %d" % absolute, il == absolute, il)
    return {"left": left, "right": right, "x_tester": x_tester}


with ObjekatClient(SOCK) as c:
    c.send("app.set_dialog_policy", {"policy": "assume_yes"})

    # ---- J first: does a render compensate the output latency, i.e. is an impulse behind a 20 ms
    #      plugin written at 48000 (compensated) or at 48000 + 960 (not)? It sets what "absolute" means.
    fresh(c)
    y = c.send("object.add", {"path": IMPULSE, "lane": 0, "start": 0.0})["id"]
    add_test(c, y, "latencyTester", 20)
    wait(c); time.sleep(0.4); wait(c)
    cal_l, _ = render(c, "lat_calibration.wav")
    ical = B.peak_index(cal_l)
    compensated = ical == AT
    print("  ..   J: the renderer %s the output latency (impulse at %s, file position %d)"
          % ("COMPENSATES" if compensated else "does NOT compensate", ical, AT))
    check("J: the calibration impulse was found", ical in (AT, AT + 960), ical)
    ABS = AT if compensated else None         # only assert absolute positions if the renderer compensates

    # ---- A: nothing anywhere
    run_case(c, "A no latency", expect_declared=0, expect_delay=0, absolute=ABS)

    # ---- B: key OLDER than the signal (a latency on the source). 20 ms = 960 samples.
    run_case(c, "B key older", x_lat=20, expect_declared=960, expect_delay=0, absolute=ABS)
    rd1, b1 = reader(c)
    # A second render after a live render's rebuild: the cache is warm, no second pass.
    render(c, "lat_B_again.wav")
    wait(c); time.sleep(0.4); wait(c)
    rd2, b2 = reader(c)
    if b2.get("id") != b1.get("id"):
        check("B: a rebuild with a warm cache takes one pass", b2.get("passes") == 1, b2)
    else:
        print("  ..   B: no rebuild observed after the second render (nothing to say about the warm cache)")

    # ---- C: key YOUNGER than the signal: 30 ms before the probe, 20 ms on the source: delay 480
    run_case(c, "C key younger", y_lat=30, x_lat=20, expect_declared=1440, expect_delay=480, absolute=ABS)

    # ---- D: different stems (the host in a stem that IS heard, the source in a detached one)
    run_case(c, "D different stems", y_stem=True, x_lat=20, absolute=ABS)

    # ---- E: both inside groups, the host two levels deep
    run_case(c, "E in groups", nest="groups", x_lat=20, absolute=ABS)
    run_case(c, "E2 two levels deep", nest="deep", x_lat=20, absolute=ABS)

    # ---- F: the source is a STEM with a latency on its bus
    run_case(c, "F stem source", key_is_stem=True, x_lat=20, expect_declared=960, absolute=ABS)

    # ---- G: the probe sits on a STEM BUS
    run_case(c, "G probe on a bus", probe_on_bus=True, x_lat=20, absolute=ABS)

    # ---- I: the source is outside the host's span: a silent key
    run_case(c, "I source outside", x_outside=True)

    # ---- H: the source's latency CHANGES while running: 20 ms -> 40 ms
    info = run_case(c, "H before", x_lat=20, expect_declared=960)
    rd0, b0 = reader(c)
    if info["x_tester"]:
        step("H: 20 -> 40 ms", lambda: c.send("debug.set_plugin_property",
                                              {"plugin": info["x_tester"], "property": "time", "value": 0.040}))
        deadline = time.time() + 3.0
        rdn, bn = reader(c)
        while time.time() < deadline and bn.get("id") == b0.get("id"):
            time.sleep(0.1)
            rdn, bn = reader(c)
        check("H: the graph was rebuilt", bn.get("id") != b0.get("id"), bn)
        wait(c)
        rdn, bn = reader(c)
        check("H: the first build after the change took two passes", bn.get("passes") == 2, bn)
        check("H: declared == source age == 1920", rdn and rdn["declared"] == 1920 and rdn["source_age"] == 1920, rdn)
        left, right = render(c, "lat_H_after.wav")
        il, ir = B.peak_index(left), B.peak_index(right)
        check("H: idx(L) == idx(R) after the change", il is not None and il == ir, "L %s R %s" % (il, ir))
    else:
        check("H: found the source's latency tester", False)

sys.exit(T.finish())
