#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""The loop and the head, Ableton's way: while playing, touching the loop NEVER moves the head. It only decides what happens at
the NEXT return. Outside a recording (a recording keeps its own, already conforming path: patch 0050).

Headless, on the virtual card (`--virtual-audio`), never a window. An empty project: the transport runs all the same, and the
position is read every 20 ms (`transport.state.position`, the audible one). "No jump" = no gap beyond 60 ms between what the
clock says and what the position did, except the return the loop is expected to make (end -> start).

  T1  C9   playback started outside the region (before it): linear, enters at the start, loops at the end
  T2  C1   region set after the head (loop [1,2], head 1.5, region -> [4,5]): no jump, 2 is passed, loops on [4,5]
  T3  C2   region set before the head: linear, no loop
  T4  C3   region set around the head (none before): no jump, loops at the NEW end
  T5  C4   end dragged under the head: linear.   C5  end dragged back over it: loops at the new end.
           C6  start dragged after the head: no jump, enters, then loops
  T6  C7   loop switched on before / inside / after the head: rolls in then loops / loops / linear
  T7  C8   loop switched off inside the region: no jump, linear
  T8  C11  pause, region changed, resume: back exactly where the pause was (region before / after / within 0.1 s of its end)
  T9  C10  ⌥-click (jumpPlayhead) before / inside / after the region: no re-framing
  T10      a 40 ms loop laid just ahead of the head catches it every time (exactness; read on the play head itself)

    ./scenario_transport_loop_ableton.py /path/to/objekat.app

Exit: 0 if every assertion passes, 1 if one fails, 2 on bad usage.
"""

import os, subprocess, sys, tempfile, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from objekat_cli import ObjekatClient, ObjekatError

if len(sys.argv) != 2:
    print(__doc__)
    sys.exit(2)

APP = sys.argv[1]
BIN = os.path.join(APP, "Contents", "MacOS", "objekat")
if not os.path.exists(BIN):
    print("not an app bundle: %s" % APP)
    sys.exit(2)

ok, ko = 0, 0
JUMP = 0.06


def check(label, cond, detail=""):
    global ok, ko
    if cond:
        ok += 1
        print("  OK    %s" % label)
    else:
        ko += 1
        print("  FAIL  %s   %s" % (label, detail))


def section(t):
    print("\n== %s" % t)


tmp = tempfile.mkdtemp(prefix="objk-looptr-")
sock = "/tmp/objk-looptr-%d.sock" % os.getpid()
if os.path.exists(sock):
    os.remove(sock)
proc = subprocess.Popen([BIN, "--headless", "--api", "--no-recent", "--language=en", "--virtual-audio",
                         "--socket=" + sock],
                        stdout=subprocess.DEVNULL, stderr=open(os.path.join(tmp, "app.err"), "w"),
                        env=dict(os.environ, OBJ_SKIP_REAL_CARD="1"))
for _ in range(160):
    if os.path.exists(sock):
        break
    time.sleep(0.25)


def loop(c, a=None, b=None, enabled=True, dragging=None):
    p = {"enabled": enabled}
    if a is not None:
        p["start"], p["end"] = a, b
    if dragging is not None:
        p["dragging"] = dragging
    return c.send("debug.transport_loop", p)


def engine(c):
    return c.send("debug.engine_loop")


def reset(c):
    c.send("transport.stop")
    loop(c, None, None, enabled=False)
    c.send("timesel.clear")


def run(c, duration, events=(), period=0.02):
    """Samples the position every `period`. `events`: (position threshold, fn) fired once, in order, the first time the
    position reaches the threshold. Returns [(wall, position)]."""
    pend = list(events)
    t0 = time.monotonic()
    out = []
    while True:
        now = time.monotonic() - t0
        if now > duration:
            break
        p = c.send("transport.state")["position"]
        out.append((now, p))
        while pend and p >= pend[0][0]:
            pend.pop(0)[1]()
        spare = period - ((time.monotonic() - t0) - now)
        if spare > 0:
            time.sleep(spare)
    return out


def anomalies(samples, wraps=()):
    """The gaps beyond JUMP between the clock and the position, minus the expected returns `wraps` = [(from_end, to_start)].
    The transport's readout stays frozen for ~200 ms after a play / seek (stock Tracktion: it ignores the play head for 200 ms
    after a position change) and then catches up in ONE step: that catch-up is not a jump (a frozen run of F seconds followed
    by a step forward of about F + dt)."""
    out = []
    debt = 0.0
    for (t0, p0), (t1, p1) in zip(samples, samples[1:]):
        dt = t1 - t0
        if p1 == p0:
            debt += dt
            continue
        dev = (p1 - p0) - dt
        if debt > 0.0:
            if p1 > p0 and abs(dev - debt) <= JUMP:
                debt = 0.0
                continue
            debt = 0.0
        if abs(dev) <= JUMP:
            continue
        if any(abs(p0 - hi) < 0.15 and abs(p1 - lo) < 0.15 and p1 < p0 for hi, lo in wraps):
            continue
        out.append((round(t1, 3), round(p0, 3), round(p1, 3)))
    return out


def count_wraps(samples, hi, lo):
    return sum(1 for (t0, p0), (t1, p1) in zip(samples, samples[1:])
               if p1 < p0 - 0.1 and abs(p0 - hi) < 0.15 and abs(p1 - lo) < 0.15)


def any_backward(samples):
    return [(round(p0, 3), round(p1, 3)) for (_, p0), (_, p1) in zip(samples, samples[1:]) if p1 < p0 - 0.03]


try:
    with ObjekatClient(sock) as c:
        c.send("project.new")
        c.send("project.save_as", {"path": os.path.join(tmp, "p", "p.objekat")})

        # ---------------------------------------------------------------- T1
        section("T1 C9: playback started before the region")
        reset(c)
        loop(c, 1.0, 2.0)
        c.send("transport.play", {"seconds": 0.0})
        s = run(c, 3.8)
        c.send("transport.stop")
        a = anomalies(s, [(2.0, 1.0)])
        check("no jump but the returns 2 -> 1", not a, a)
        check("linear up to the region, then it loops (>= 2 returns)", count_wraps(s, 2.0, 1.0) >= 2, count_wraps(s, 2.0, 1.0))
        check("never past the end after entering", max(p for t, p in s if t > 2.5) <= 2.1, max(p for t, p in s if t > 2.5))

        # ---------------------------------------------------------------- T2
        section("T2 C1: region set AFTER the head, while looping elsewhere")
        reset(c)
        loop(c, 1.0, 2.0)
        c.send("transport.play", {"seconds": 1.2})
        c.send("timesel.set", {"start": 4.0, "end": 5.0, "lanes": [0]})
        seen = {}

        def lfs():
            seen["r"] = c.send("debug.loop_from_selection")
        s = run(c, 6.0, [(1.5, lfs)])
        c.send("transport.stop")
        r = seen.get("r", {})
        check("loop_from_selection took the selection: region [4, 5]", r.get("region") == [4.0, 5.0], r)
        el = r.get("engine_loop", {})
        check("engine: looping, rolling in (the head is before)", el.get("isLooping") == 1 and el.get("isRollingIntoLoop") == 1, el)
        check("engine: the transport and the head agree (the periodic pass has nothing to do)",
              el.get("transportLooping") == 1 and el.get("loopStartSamples") == round(4.0 * el.get("sampleRate", 0))
              and el.get("loopEndSamples") == round(5.0 * el.get("sampleRate", 0)), el)
        a = anomalies(s, [(5.0, 4.0)])
        check("no jump but the returns 5 -> 4", not a, a)
        check("the head passed 2 and 3 (no return at 2)", any(2.2 < p < 3.8 for t, p in s), "")
        check("then it loops on [4, 5]", count_wraps(s, 5.0, 4.0) >= 1, count_wraps(s, 5.0, 4.0))

        # ---------------------------------------------------------------- T3
        section("T3 C2: region set BEFORE the head")
        reset(c)
        loop(c, 4.0, 5.0)
        c.send("transport.play", {"seconds": 0.0})
        seen.clear()

        def before():
            seen["r"] = loop(c, 0.3, 0.8)
        s = run(c, 3.0, [(1.0, before)])
        c.send("transport.stop")
        el = seen.get("r", {}).get("engine_loop", {})
        check("engine: not looping", el.get("isLooping") == 0 and el.get("transportLooping") == 0, el)
        a = anomalies(s)
        check("no jump at all", not a, a)
        check("the head went straight on", s[-1][1] > 2.7, s[-1])

        # ---------------------------------------------------------------- T4
        section("T4 C3: region set AROUND the head (no loop before)")
        reset(c)
        c.send("transport.play", {"seconds": 1.5})
        c.send("timesel.set", {"start": 1.0, "end": 2.5, "lanes": [0]})
        seen.clear()

        def around():
            seen["r"] = c.send("debug.loop_from_selection")
        s = run(c, 3.2, [(1.8, around)])
        c.send("transport.stop")
        el = seen.get("r", {}).get("engine_loop", {})
        check("engine: looping, NOT rolling in (the head is inside)", el.get("isLooping") == 1 and el.get("isRollingIntoLoop") == 0, el)
        a = anomalies(s, [(2.5, 1.0)])
        check("no jump but the returns 2.5 -> 1", not a, a)
        check("it loops at the NEW end", count_wraps(s, 2.5, 1.0) >= 1, count_wraps(s, 2.5, 1.0))

        # ---------------------------------------------------------------- T5
        section("T5 C4 / C5 / C6: a bound dragged")
        reset(c)
        loop(c, 1.0, 3.0)
        c.send("transport.play", {"seconds": 1.5})
        seen.clear()

        def drag_end_under():
            for e in (2.6, 2.3, 2.0, 1.8):
                loop(c, 1.0, e, dragging=True)
            seen["r"] = loop(c, 1.0, 1.7, dragging=False)
        s = run(c, 2.6, [(2.0, drag_end_under)])
        c.send("transport.stop")
        el = seen.get("r", {}).get("engine_loop", {})
        check("C4 engine: the end went under the head, not looping", el.get("isLooping") == 0, el)
        a = anomalies(s)
        check("C4 no jump, no return", not a and not any_backward(s), (a, any_backward(s)))
        check("C4 it went straight on past the old end", s[-1][1] > 3.1, s[-1])

        reset(c)
        loop(c, 1.0, 2.5)
        c.send("transport.play", {"seconds": 1.2})
        seen.clear()

        def end_under():
            seen["a"] = loop(c, 1.0, 1.3, dragging=True)

        def end_over():
            for e in (1.5, 2.2):
                loop(c, 1.0, e, dragging=True)
            seen["b"] = loop(c, 1.0, 3.0, dragging=False)
        s = run(c, 4.2, [(1.5, end_under), (1.95, end_over)])
        c.send("transport.stop")
        check("C5 end dragged under the head: not looping", seen["a"]["engine_loop"].get("isLooping") == 0, seen["a"])
        check("C5 end dragged back over it: looping again, not rolling in",
              seen["b"]["engine_loop"].get("isLooping") == 1 and seen["b"]["engine_loop"].get("isRollingIntoLoop") == 0, seen["b"])
        a = anomalies(s, [(3.0, 1.0)])
        check("C5 no jump but the return 3 -> 1", not a, a)
        check("C5 it loops at the NEW end", count_wraps(s, 3.0, 1.0) >= 1, count_wraps(s, 3.0, 1.0))

        reset(c)
        loop(c, 1.0, 3.0)
        c.send("transport.play", {"seconds": 1.5})
        seen.clear()

        def start_after():
            for st in (1.4, 1.9, 2.3):
                loop(c, st, 3.0, dragging=True)
            seen["r"] = loop(c, 2.5, 3.0, dragging=False)
        s = run(c, 4.0, [(1.8, start_after)])
        c.send("transport.stop")
        check("C6 start dragged after the head: rolling in", seen["r"]["engine_loop"].get("isRollingIntoLoop") == 1, seen["r"])
        a = anomalies(s, [(3.0, 2.5)])
        check("C6 no jump but the returns 3 -> 2.5", not a, a)
        check("C6 it enters, then loops on [2.5, 3]", count_wraps(s, 3.0, 2.5) >= 1, count_wraps(s, 3.0, 2.5))

        # ---------------------------------------------------------------- T6
        section("T6 C7: loop switched on")
        for label, start_pos, switch_at, expect in (("before the region", 0.5, 1.0, "enter"),
                                                     ("inside the region", 2.3, 2.5, "loop"),
                                                     ("after the region", 3.5, 3.8, "straight")):
            reset(c)
            loop(c, 2.0, 3.0, enabled=False)
            c.send("transport.play", {"seconds": start_pos})
            seen.clear()

            def on():
                seen["r"] = loop(c, 2.0, 3.0, enabled=True)
            s = run(c, 3.6 if expect != "straight" else 1.6, [(switch_at, on)])
            c.send("transport.stop")
            el = seen["r"]["engine_loop"]
            a = anomalies(s, [(3.0, 2.0)])
            check("C7 %s: no jump but the returns 3 -> 2" % label, not a, a)
            if expect == "enter":
                check("C7 %s: rolling in, then it loops" % label, el.get("isRollingIntoLoop") == 1 and count_wraps(s, 3.0, 2.0) >= 1,
                      (el, count_wraps(s, 3.0, 2.0)))
            elif expect == "loop":
                check("C7 %s: looping at once and loops at the end" % label, el.get("isLooping") == 1 and el.get("isRollingIntoLoop") == 0
                      and count_wraps(s, 3.0, 2.0) >= 1, (el, count_wraps(s, 3.0, 2.0)))
            else:
                check("C7 %s: linear" % label, el.get("isLooping") == 0 and not any_backward(s) and s[-1][1] > 4.5, (el, s[-1]))

        # ---------------------------------------------------------------- T7
        section("T7 C8: loop switched off")
        reset(c)
        loop(c, 1.0, 2.0)
        c.send("transport.play", {"seconds": 0.5})
        seen.clear()

        def off():
            seen["r"] = loop(c, None, None, enabled=False)
        s = run(c, 2.8, [(1.5, off)])
        c.send("transport.stop")
        check("C8 engine: not looping", seen["r"]["engine_loop"].get("isLooping") == 0, seen["r"])
        a = anomalies(s)
        check("C8 no jump, no return", not a and not any_backward(s), (a, any_backward(s)))
        check("C8 it went past the end", s[-1][1] > 2.4, s[-1])

        # ---------------------------------------------------------------- T8
        section("T8 C11: pause, region changed, resume")
        for label, region in (("region BEFORE the pause position", (0.2, 0.7)),
                              ("region AFTER the pause position", (2.0, 3.0)),
                              ("pause position within 0.1 s of the region's end", None)):
            reset(c)
            loop(c, 4.0, 5.0)
            c.send("transport.play", {"seconds": 0.0})
            run(c, 1.0)
            r = c.send("debug.transport_pause")
            P = r["paused_at"]
            st = c.send("transport.state")
            time.sleep(0.2)
            reg = region or (0.5, P + 0.04)
            loop(c, reg[0], reg[1])
            check("C11 %s: paused, still where it was (%.3f)" % (label, P), r["playing"] is False and abs(c.send("transport.state")["paused_at"] - P) < 1e-6, r)
            t0 = time.monotonic()
            c.send("debug.transport_pause")
            p1 = c.send("transport.state")["position"]
            el = time.monotonic() - t0
            check("C11 %s: resumed at the pause position (%.3f -> %.3f)" % (label, P, p1), -0.03 <= p1 - P <= 0.03 + el, (P, p1, el))
            s = run(c, 0.5)
            c.send("transport.stop")
            if region is None:
                # 0.04 s from the end: the head loops several times while the readout is still frozen (200 ms), so only
                # its whereabouts are asserted: it started at P and never left the region
                check("C11 %s: starts at P and stays in the region" % label,
                      abs(s[0][1] - P) < 0.05 and all(reg[0] - 0.03 <= p <= reg[1] + 0.05 for _, p in s), (s[0], s[-1]))
            else:
                a = anomalies(s, [(reg[1], reg[0])])
                check("C11 %s: no re-framing afterwards" % label, not a and s[0][1] > P - 0.05, (a, s[:2]))

        # ---------------------------------------------------------------- T9
        section("T9 C10: ⌥-click (jumpPlayhead)")
        for label, target, expect in (("before the region", 0.3, "enter"), ("inside the region", 2.5, "loop"),
                                       ("after the region", 3.5, "straight")):
            reset(c)
            loop(c, 2.0, 3.0)
            c.send("transport.play", {"seconds": 0.5})
            seen.clear()

            def jump():
                c.send("debug.jump_playhead", {"seconds": target})
                seen["p"] = c.send("transport.state")["position"]
                seen["e"] = engine(c)
            s = run(c, 3.0, [(0.9, jump)])
            c.send("transport.stop")
            check("C10 %s: the head landed on %.1f (%.3f)" % (label, target, seen["p"]), abs(seen["p"] - target) < 0.1, seen["p"])
            e = seen["e"]
            if expect == "enter":
                check("C10 %s: rolling in" % label, e.get("isLooping") == 1 and e.get("isRollingIntoLoop") == 1, e)
            elif expect == "loop":
                check("C10 %s: looping" % label, e.get("isLooping") == 1 and e.get("isRollingIntoLoop") == 0, e)
            else:
                check("C10 %s: linear" % label, e.get("isLooping") == 0, e)
                check("C10 %s: stays linear" % label, not any_backward(s[-30:]) and s[-1][1] > 4.2, s[-1])
            i = next((k for k, (_, p) in enumerate(s) if p >= 0.9), None)
            post = s[i + 1:] if i is not None else s
            a = anomalies(post, [(3.0, 2.0)])
            check("C10 %s: no re-framing after the jump" % label, not a, a)

        # ---------------------------------------------------------------- T10
        section("T10 exactness: a 40 ms loop laid just ahead of the head catches it")
        misses = 0
        trials = 12
        rate = None
        for k in range(trials):
            reset(c)
            c.send("transport.play", {"seconds": 0.5})
            time.sleep(0.25 + 0.013 * k)
            h = engine(c)
            head = h["headSeconds"]
            rate = h["sampleRate"]
            a0 = head + 0.10 + 0.002 * k
            loop(c, a0, a0 + 0.04)
            seen_in = []
            for _ in range(30):
                e = engine(c)
                seen_in.append((e["headSeconds"], e["isLooping"], e["isRollingIntoLoop"]))
                time.sleep(0.01)
            c.send("transport.stop")
            late = [x for x in seen_in if x[0] > a0 + 0.04 + 0.02 or x[0] < head - 0.01]
            if late or seen_in[-1][1] != 1 or seen_in[-1][2] != 0:
                misses += 1
                print("    trial %d: loop [%.3f, %.3f] head was %.3f -> %s" % (k, a0, a0 + 0.04, head, seen_in[-6:]))
        check("the 40 ms loop caught the head in all %d trials (%d missed)" % (trials, misses), misses == 0, misses)
finally:
    proc.terminate()
    try:
        proc.wait(10)
    except subprocess.TimeoutExpired:
        proc.kill()
    if os.path.exists(sock):
        os.remove(sock)

print("\n%d OK, %d FAILED" % (ok, ko))
sys.exit(1 if ko else 0)
