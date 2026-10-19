#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""The solo of an AUX: one hears what is SENT to it, and only that.

Soloing an aux makes its return (and its FX) heard, fed by the sends of the objects that send to it —
and NOTHING else: not the senders' own (dry) output, not the rest of the project. Asserted with no
screen, by export and difference (the same method as scenario_bridge_sends.py):

  wet_ref = E(full mix) − E(the same mix with the send disabled)      — what the send adds, alone
  solo(aux) must equal wet_ref, to the LSB                            — so the dry is ABSENT
  solo(aux) with the send disabled must be silent                     — so nothing else leaks in

Cases: a plain sender (post-fader, then pre-fader with its fader lowered), a GROUP as the sender, a
CHILD of a group sending out of it, an aux INSIDE a group (sender outside, then sender inside), two
auxes (one soloed: one wet; both: both wets), an aux soloed together with an ordinary object (the
object is heard WHOLE, the aux with its sends), a muted sender (stays silent), an aux soloed only by
INHERITANCE (a soloed group holding it: it pulls no sender), and solo.clear giving the full mix back
bit for bit. Fixtures are impulses (48 kHz / 24-bit mono): a sample index is a place in time.

    objekat.app/Contents/MacOS/objekat --headless --api --no-recent --language=en --socket=/tmp/as.sock
    ./scenario_aux_solo.py /tmp/as.sock /tmp/trial_aux_solo/project.objekat [--only S1,S2]

NOT `--no-audio` (the sends ride the audio bridge, which reads the device's clock); exits 2 if
`app.info` says audio is not running. Exit: 0 if everything passes, 1 otherwise.
"""

import os, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from objekat_cli import ObjekatClient, ObjekatError
import bridge_scenario_common as B

args = sys.argv[1:]
ONLY = None
if "--only" in args:
    i = args.index("--only")
    ONLY = set(args[i + 1].split(","))
    del args[i:i + 2]
if len(args) != 2:
    print(__doc__)
    sys.exit(2)
SOCK, PROJ = args
DIR = os.path.dirname(PROJ)
os.makedirs(DIR, exist_ok=True)

T = B.Tally(ObjekatError)
check = T.check
SR = B.SR
LSB = 1.0 / 8388607.0
TOL = 2.0 * LSB          # two exports of one state are identical; one LSB of rounding either side


def want(s):
    return ONLY is None or s in ONLY


def out(name):
    return os.path.join(DIR, name)


def fixtures():
    # X: an impulse at 1 s; Y: at 1.5 s; O: at 2 s — three places in time that never overlap.
    B._write24(out("x.wav"), [0.2 if i == SR else 0.0 for i in range(3 * SR)])
    B._write24(out("y.wav"), [0.1 if i == SR + SR // 2 else 0.0 for i in range(3 * SR)])
    B._write24(out("o.wav"), [0.05 if i == 2 * SR else 0.0 for i in range(3 * SR)])


def wait(c):
    c.send("wait_idle")
    time.sleep(0.25)


def fresh(c, name):
    c.send("solo.clear")
    c.send("project.new")
    os.makedirs(out(name), exist_ok=True)
    c.send("project.save_as", {"path": out(name + "/project.objekat")})


_n = [0]


def render(c, tag):
    wait(c)
    _n[0] += 1
    path = out("%03d_%s.wav" % (_n[0], tag))
    r = c.send("export.run", {"format": "wav", "sample_rate": SR, "dithering": False,
                              "start": 0.0, "end": 3.0, "path": path})
    c.send("job.wait", {"id": r["job_id"], "timeout_ms": 180000})
    return B.read_wav(path)[0]


def sub(a, b):
    n = min(len(a), len(b))
    return [a[i] - b[i] for i in range(n)]


def add(a, b):
    n = min(len(a), len(b))
    return [a[i] + b[i] for i in range(n)]


def maxabs(s):
    return max((abs(v) for v in s), default=0.0)


def at(s, sec):
    return s[int(round(sec * SR))]


def same(label, got, want_, tol=TOL):
    d = maxabs(sub(got, want_))
    check(label, d <= tol, "max |diff| %.3e (tolerance %.1e)" % (d, tol))
    return d


def silent(label, s, tol=TOL):
    m = maxabs(s)
    check(label, m <= tol, "max %.3e" % m)


def obj(c, path, lane, start=0.0):
    return c.send("object.add", {"path": out(path), "lane": lane, "start": start})["id"]


def aux(c, lane):
    return c.send("aux.create", {"start": 0.0, "end": 3.0, "lane": lane})["id"]


def send(c, x, a, db):
    c.send("send.set_level", {"id": x, "aux": a, "db": db})


def enable(c, x, a, on):
    c.send("send.enable", {"id": x, "aux": a, "enabled": on})


def solo(c, ids):
    c.send("solo.clear")
    if ids:
        c.send("solo.set", {"ids": ids, "on": True})


def fx_on_aux(c, a, db):
    """An FX on the aux's return: a gain stage, so that 'the aux's FX are heard' is a number."""
    pid = c.send("plugin.add_gain_stage", {"host": a, "face": "gain"})["plugin"]["id"]
    c.send("plugin.set_param", {"plugin": pid, "index": 0, "value": db})


def wet_of(c, tag, x, a):
    """(full, wet): the full mix and what the send x→a alone adds to it, with no solo."""
    solo(c, [])
    full = render(c, tag + "_full")
    enable(c, x, a, False)
    off = render(c, tag + "_off")
    enable(c, x, a, True)
    return full, sub(full, off)


def the_aux_solo(c, tag, x, a, wet, extra_roots=()):
    """Solo `a` (with `extra_roots`), and the two halves of the proof."""
    solo(c, [a] + list(extra_roots))
    got = render(c, tag + "_solo")
    if not extra_roots:
        check(tag + ": the wet is there (peak %.4f)" % maxabs(wet), maxabs(wet) > 1e-3, maxabs(wet))
        same(tag + ": solo(aux) == the wet alone (no dry, nothing else)", got, wet)
        enable(c, x, a, False)
        silent(tag + ": solo(aux) with the send disabled is silent", render(c, tag + "_solo_off"))
        enable(c, x, a, True)
    return got


# --------------------------------------------------------------------------------------------------

def section_S1(c):
    print("\n--- S1  a plain sender, an FX on the aux, another object; solo(aux) = the wet; clear = the mix")
    fresh(c, "S1")
    x = obj(c, "x.wav", 0)
    o = obj(c, "o.wav", 3)
    a = aux(c, 5)
    fx_on_aux(c, a, -3.0)
    send(c, x, a, -6.0)
    full, wet = wet_of(c, "S1", x, a)
    dry_peak = at(full, 1.0) - at(wet, 1.0)
    ratio = B.db(abs(at(wet, 1.0)) / abs(dry_peak))
    check("S1: wet / dry = the send level + the aux FX (-9 dB): %.3f" % ratio, abs(ratio + 9.0) < 0.05, ratio)
    got = the_aux_solo(c, "S1", x, a, wet)
    check("S1: at 1 s only the wet (%.4f), not dry + wet (%.4f)" % (at(got, 1.0), at(full, 1.0)),
          abs(at(got, 1.0) - at(wet, 1.0)) <= TOL)
    check("S1: the other object is absent at 2 s", abs(at(got, 2.0)) <= TOL, at(got, 2.0))
    # the ordinary object soloed WITH the aux: the object whole, the aux with its sends
    solo(c, [])
    c.send("object.set_mute", {"ids": [x], "muted": True})
    o_only = render(c, "S1_o_only")                      # x muted: only o is left (its send is gated)
    c.send("object.set_mute", {"ids": [x], "muted": False})
    got = the_aux_solo(c, "S1b", x, a, wet, extra_roots=[o])
    same("S1b: solo(aux + another object) == that object whole + the wet", got, add(o_only, wet))
    # the SENDER soloed with its aux: heard whole, dry and wet (it is audible on its own right)
    solo(c, [x, a])
    got = render(c, "S1c_solo_x_a")
    solo(c, [x])
    same("S1c: solo(sender + its aux) == solo(sender): dry + wet", got, render(c, "S1c_solo_x"))
    # a muted sender stays silent
    c.send("object.set_mute", {"ids": [x], "muted": True})
    solo(c, [a])
    silent("S1d: solo(aux) with the sender muted is silent", render(c, "S1d"))
    c.send("object.set_mute", {"ids": [x], "muted": False})
    # back to the mix, bit for bit (the dry gate is lifted, the send is back in its place)
    solo(c, [])
    same("S1e: solo.clear gives the full mix back, bit for bit", render(c, "S1e_clear"), full, tol=0.0)
    solo(c, [a])
    render(c, "S1f_again")
    solo(c, [])
    same("S1f: a second solo / clear round trip, bit for bit", render(c, "S1f_clear"), full, tol=0.0)


def section_S2(c):
    print("\n--- S2  the fader of the sender: post-fader follows it, pre-fader does not; the dry is gone either way")
    fresh(c, "S2")
    x = obj(c, "x.wav", 0)
    a = aux(c, 5)
    send(c, x, a, -6.0)
    c.send("object.set_gain", {"ids": [x], "db": -10.0})
    full, wet = wet_of(c, "S2post", x, a)
    r = B.db(abs(at(wet, 1.0)) / abs(at(full, 1.0) - at(wet, 1.0)))
    check("S2 post: the wet follows the fader (wet / dry -6 dB): %.3f" % r, abs(r + 6.0) < 0.05, r)
    the_aux_solo(c, "S2 post", x, a, wet)
    c.send("send.set_position", {"id": x, "aux": a, "position": "pre_fader"})
    full, wet = wet_of(c, "S2pre", x, a)
    r = B.db(abs(at(wet, 1.0)) / abs(at(full, 1.0) - at(wet, 1.0)))
    check("S2 pre: the wet ignores the -10 dB fader (wet / dry +4 dB): %.3f" % r, abs(r - 4.0) < 0.05, r)
    the_aux_solo(c, "S2 pre", x, a, wet)
    solo(c, [])
    same("S2: solo.clear gives the full mix back, bit for bit", render(c, "S2_clear"), full, tol=0.0)


def section_S3(c):
    print("\n--- S3  a GROUP sends; then a CHILD of a group sends out of it")
    fresh(c, "S3")
    x = obj(c, "x.wav", 0)
    y = obj(c, "y.wav", 1)
    o = obj(c, "o.wav", 3)
    a = aux(c, 5)
    g = c.send("group.create", {"ids": [x, y]})["id"]
    send(c, g, a, -6.0)
    full, wet = wet_of(c, "S3g", g, a)
    check("S3 group: the wet carries both children (1 s and 1.5 s)",
          abs(at(wet, 1.0)) > 1e-3 and abs(at(wet, 1.5)) > 1e-3)
    the_aux_solo(c, "S3 group", g, a, wet)
    solo(c, [])
    same("S3 group: solo.clear, bit for bit", render(c, "S3g_clear"), full, tol=0.0)
    c.send("send.remove", {"id": g, "aux": a})
    send(c, x, a, -6.0)
    full, wet = wet_of(c, "S3c", x, a)
    got = the_aux_solo(c, "S3 child", x, a, wet)
    check("S3 child: its sibling is absent (1.5 s)", abs(at(got, 1.5)) <= TOL, at(got, 1.5))
    solo(c, [])
    same("S3 child: solo.clear, bit for bit", render(c, "S3c_clear"), full, tol=0.0)


def section_S4(c):
    print("\n--- S4  the aux INSIDE a group: sender outside, then sender inside the same group")
    fresh(c, "S4")
    x = obj(c, "x.wav", 0)
    y = obj(c, "y.wav", 1)
    o = obj(c, "o.wav", 3)
    a = aux(c, 5)
    g = c.send("group.create", {"ids": [y, a]})["id"]
    send(c, x, a, -6.0)
    full, wet = wet_of(c, "S4out", x, a)
    got = the_aux_solo(c, "S4 sender outside", x, a, wet)
    check("S4 sender outside: the aux's sibling is absent (1.5 s)", abs(at(got, 1.5)) <= TOL, at(got, 1.5))
    solo(c, [])
    same("S4 sender outside: solo.clear, bit for bit", render(c, "S4out_clear"), full, tol=0.0)
    fresh(c, "S4b")
    x = obj(c, "x.wav", 0)
    y = obj(c, "y.wav", 1)
    o = obj(c, "o.wav", 3)
    a = aux(c, 5)
    g = c.send("group.create", {"ids": [x, y, a]})["id"]
    send(c, x, a, -6.0)
    full, wet = wet_of(c, "S4in", x, a)
    got = the_aux_solo(c, "S4 sender inside", x, a, wet)
    check("S4 sender inside: its sibling is absent (1.5 s)", abs(at(got, 1.5)) <= TOL, at(got, 1.5))
    solo(c, [])
    same("S4 sender inside: solo.clear, bit for bit", render(c, "S4in_clear"), full, tol=0.0)


def section_S5(c):
    print("\n--- S5  two auxes: one soloed = its wet only; both soloed = both wets")
    fresh(c, "S5")
    x = obj(c, "x.wav", 0)
    y = obj(c, "y.wav", 1)
    a = aux(c, 5)
    b = aux(c, 6)
    send(c, x, a, -6.0)
    send(c, x, b, -12.0)
    send(c, y, b, -6.0)
    solo(c, [])
    full = render(c, "S5_full")
    enable(c, x, a, False)
    no_xa = render(c, "S5_no_xa")
    enable(c, x, b, False)
    enable(c, y, b, False)
    no_sends = render(c, "S5_no_sends")
    enable(c, x, a, True)
    enable(c, x, b, True)
    enable(c, y, b, True)
    wet_xa = sub(full, no_xa)
    wet_all = sub(full, no_sends)
    solo(c, [a])
    got = render(c, "S5_solo_a")
    same("S5: solo(A) == the wet of x->A alone (not x->B, not y->B, no dry)", got, wet_xa)
    solo(c, [a, b])
    got = render(c, "S5_solo_ab")
    same("S5: solo(A + B) == every wet, and no dry", got, wet_all)
    solo(c, [])
    same("S5: solo.clear, bit for bit", render(c, "S5_clear"), full, tol=0.0)


def section_S6(c):
    print("\n--- S6  an aux soloed only by INHERITANCE (its group is soloed): it pulls no sender")
    fresh(c, "S6")
    x = obj(c, "x.wav", 0)
    y = obj(c, "y.wav", 1)
    a = aux(c, 5)
    g = c.send("group.create", {"ids": [y, a]})["id"]
    send(c, x, a, -6.0)
    c.send("object.set_mute", {"ids": [x], "muted": True})
    want_ = render(c, "S6_x_muted")              # x silent and its send gated: y alone
    c.send("object.set_mute", {"ids": [x], "muted": False})
    solo(c, [g])
    same("S6: solo(group holding the aux) == the group's own content, no sender pulled in",
         render(c, "S6_solo_g"), want_)
    solo(c, [])


def section_S7(c):
    print("\n--- S7  an aux does not send: there is no aux -> aux chain to follow")
    fresh(c, "S7")
    a = aux(c, 5)
    b = aux(c, 6)
    T.expect_error("S7: a send from an aux to another aux is refused",
                   lambda: c.send("send.create", {"id": a, "aux": b}))


fixtures()
with ObjekatClient(SOCK) as c:
    B.require_audio(c)
    c.send("app.set_dialog_policy", {"policy": "assume_yes"})
    for sec, fn in (("S1", section_S1), ("S2", section_S2), ("S3", section_S3), ("S4", section_S4),
                    ("S5", section_S5), ("S6", section_S6), ("S7", section_S7)):
        if want(sec):
            fn(c)

sys.exit(T.finish())
