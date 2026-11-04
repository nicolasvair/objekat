#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Probe of the private CoreAudio aggregate on the REAL cards of this machine.

The plan "choose another sound card as the input" opens the inputs of a card through a PRIVATE
aggregate device (`kAudioAggregateDeviceIsPrivateKey`) built by UID: the OUTPUT card is the master
clock, the INPUT card is drift compensated. This probe asks the system, on the cards that are really
there, whether that holds, BEFORE any engine code depends on it:

  L  layout       which streams / channels the aggregate gets, in which order, whether the process
                  sees it in its own device list, which sample rates the system leaves or changes
  O  order        the channel order PROVED WITH SIGNAL: a distinct tone per channel of a card, found
                  back on the aggregate's input channel `K + c` (K = inputs of the sub-devices
                  listed before it); the same for the outputs, with tones written by the aggregate
  D  rates        cards at different rates (BlackHole 176.4 kHz next to speakers at 44.1 / 48 kHz)
  T  latency      by loop: an impulse written to BlackHole's output, read back on the aggregate's input
  K  destroy      the aggregate destroyed WHILE it serves as the input, its IOProc running
  S  sine         MINUTES of a sine through it: discontinuities, overload notifications,
                  ActualSampleRate, time stamps

Nothing audible: the speakers receive silence, every tone goes to virtual cards (BlackHole, Muse).
AirPods and any Bluetooth card are NEVER touched (not even listed as candidates). The microphone is
only opened by the last test of the sine series (set --no-mic to skip it): macOS may ask for the
permission of the terminal that runs this.

Always under the audio state guard (tools/audio_state_guard.py): rates, buffers, defaults,
`defaults` and Settings.xml are put back and checked at the end.

    ./probe_aggregate_real_cards.py [--minutes 15] [--quick] [--no-mic] [--json out.json]

Exit: 0 if every test passes, 1 if one fails, 3 if the cards needed are not there.
"""
import argparse, json, os, re, subprocess, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import audio_state_guard as G

results = []     # (id, title, ok(True/False/None=info), detail)
raw = {}


def out(s=""):
    print(s, flush=True)


def record(tid, title, ok, detail=""):
    """ok: True, False, None (information) or "skip" (could not run: nothing is claimed either way)."""
    results.append((tid, title, ok, detail))
    tag = "OK" if ok is True else ("FAIL" if ok is False else ("SKIP" if ok == "skip" else "INFO"))
    out("  %-4s %-4s %-58s %s" % (tag, tid, title, detail))


def console_locked():
    """While the screen is locked macOS serves NO client IO to a command-line process: an IOProc is
    started (status 0, the device even reports `running`) and never called, `afplay` fails with
    AudioQueueStart -66681. Property queries still work, so the layout tests do."""
    r = subprocess.run(["ioreg", "-n", "Root", "-d1", "-a"], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    return b"<key>IOConsoleLocked</key>\n\t<true/>" in r.stdout or b"IOConsoleLocked</key><true/>" in r.stdout.replace(b"\n", b"").replace(b"\t", b"")


def served(j):
    """True if the aggregate's IOProc was really called (IO is served to this process)."""
    return j.get("run", {}).get("agg_callbacks", 0) > 0 or j.get("run", {}).get("writer_callbacks", 0) > 0


def silent_input(tid, title, j, what="input"):
    """The IOProc ran but the aggregate's INPUT is digital silence although a signal was written to the
    card: macOS hands a process without microphone permission zeros for EVERY input (a virtual card
    included). The clock side of the run is still valid; the content side proves nothing."""
    record(tid, title, "skip", "%s read as exact silence while a signal was written: this process has no microphone "
           "permission (TCC), so the content checks prove nothing. Clock side: %d callbacks, overloads %d" % (
               what, j.get("run", {}).get("agg_callbacks", 0), j.get("run", {}).get("overload_notifications", 0)))


def not_served(tid, title, j):
    record(tid, title, "skip", "the IOProc was never called (agg %s, writer %s callbacks): macOS serves no IO to this process%s" % (
        j.get("run", {}).get("agg_callbacks"), j.get("run", {}).get("writer_callbacks"),
        " (the console is LOCKED)" if console_locked() else ""))


def run_probe(label, subs, master=None, drift=(), writer=None, wmode="none", reader=None, aout="silence",
              secs=3, rates=(), extra=()):
    args = ["run", "--label", label, "--secs", str(secs)]
    for u in subs:
        args += ["--sub", u]
    args += ["--master", master or subs[0]]
    for u in drift:
        args += ["--drift", u]
    if writer:
        args += ["--writer", writer, "--wmode", wmode]
    if reader:
        args += ["--reader", reader]
    args += ["--aout", aout]
    for r in rates:
        args += ["--rate", r]
    args += list(extra)
    t = time.time()
    r = subprocess.run([G.ensure_probe()] + args, stdout=subprocess.PIPE, stderr=None if secs >= 60 else subprocess.DEVNULL,
                       timeout=secs + 120)
    try:
        j = json.loads(r.stdout.decode())
    except Exception:
        j = {"error": "no JSON (rc=%s): %s" % (r.returncode, r.stdout.decode()[:200])}
    j["rc"] = r.returncode
    j["wall_s"] = round(time.time() - t, 1)
    raw[label] = j
    return j


def rate_story(j):
    b, a = j.get("rates_preset", {}), j.get("rates_after_create", {})
    run = j.get("rates_during_run", {})
    changed = {u: (b[u], run.get(u, a.get(u))) for u in b if run.get(u, a.get(u)) != b[u]}
    return changed


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--minutes", type=float, default=15.0)
    ap.add_argument("--quick", action="store_true", help="30 s instead of the long sine")
    ap.add_argument("--no-mic", action="store_true")
    ap.add_argument("--json")
    ap.add_argument("--skip-io", action="store_true", help="layout tests only")
    args = ap.parse_args()

    st = G.read_cards()["cards"]

    def find(rx):
        for uid, c in st.items():
            if re.search(rx, c["name"], re.I) and c["transport"] not in ("blue", "blea"):
                return uid
        return None

    BH = find(r"^BlackHole 16ch")
    SPK = find(r"Haut-parleurs|Speakers")
    MIC = find(r"^Microphone MacBook|MacBook.*Microphone")
    MUSE = [u for u, c in st.items() if c["name"].startswith("Muse")]
    IPH = find(r"iPhone")
    if not (BH and SPK and MIC and len(MUSE) >= 2):
        out("cards needed: BlackHole 16ch, speakers, microphone, two Muse devices; found BH=%s SPK=%s MIC=%s MUSE=%s" % (BH, SPK, MIC, MUSE))
        return 3
    out("cards: BH=%s (%s Hz)  SPK=%s (%s Hz)  MIC=%s (%s Hz)  MUSE=%s  iPhone=%s" % (
        BH, st[BH]["rate"], SPK, st[SPK]["rate"], MIC, st[MIC]["rate"], MUSE, IPH))
    ch = lambda u, k: st[u][k]

    # ── L: layout, no IO ───────────────────────────────────────────────────────────────────
    out("\n── L  layout and rates (no IO)")
    combos = [
        ("L1", "speakers(master) + BlackHole", [SPK, BH], SPK, [BH], []),
        ("L2", "speakers 44.1k(master) + BlackHole", [SPK, BH], SPK, [BH], [SPK + "=44100"]),
        ("L3", "Muse(master) + BlackHole", [MUSE[0], BH], MUSE[0], [BH], []),
        ("L4", "BlackHole(master) + microphone", [BH, MIC], BH, [MIC], []),
        ("L5", "speakers(master) + microphone", [SPK, MIC], SPK, [MIC], []),
        ("L6", "speakers(master) + 3 Muse", [SPK] + MUSE[:3], SPK, MUSE[:3], []),
        ("L7", "BlackHole listed first, speakers master", [BH, SPK], SPK, [BH], []),
        ("L8", "speakers + mic + Muse + BlackHole", [SPK, MIC, MUSE[0], BH], SPK, [MIC, MUSE[0], BH], []),
    ]
    if IPH:
        combos.append(("L9", "speakers(master) + iPhone microphone", [SPK, IPH], SPK, [IPH], []))
    for tid, title, subs, master, drift, rates in combos:
        j = run_probe(tid, subs, master, drift, rates=rates, extra=["--no-io"], secs=1)
        if "error" in j:
            record(tid, title, False, j["error"]); continue
        lay = j["layout"]
        exp_in = sum(ch(u, "in") for u in subs); exp_out = sum(ch(u, "out") for u in subs)
        a = lay["aggregate"]
        ok = j["create_status"] == 0 and a["in_channels"] == exp_in and a["out_channels"] == exp_out
        order = [u for u in lay.get("full_sub_device_list", [])]
        detail = "in %d/%d out %d/%d ready %d ms; list order %s; private-listed=%s; agg rate %s" % (
            a["in_channels"], exp_in, a["out_channels"], exp_out, j["ready_ms"],
            "= requested" if order == subs else "DIFFERS %s" % order, lay["listed_in_own_process"], a["rate"])
        record(tid, title, ok and lay["listed_in_own_process"], detail)
        ch_ = rate_story(j)
        for u, (b4, af) in ch_.items():
            record(tid + "r", "  rate of %s moved by the system" % st[u]["name"], None, "%s -> %s" % (b4, af))
        dest = j.get("rates_after_destroy", {})
        for u, v in dest.items():
            if v != j["rates_preset"].get(u):
                record(tid + "d", "  after destroy %s stays at" % st[u]["name"], None, "%s (was %s)" % (v, j["rates_before"].get(u)))

    # ── O: channel order proved with signal ───────────────────────────────────────────────
    if args.skip_io:
        return 0
    out("\n── O  channel order, proved with tones")
    n_bh_in = ch(BH, "in")
    orders = [
        ("O1", "input: Muse(master) + BlackHole", [MUSE[0], BH], MUSE[0], [BH]),
        ("O2", "input: speakers(master) + BlackHole", [SPK, BH], SPK, [BH]),
        ("O3", "input: BlackHole listed first, Muse master", [BH, MUSE[0]], MUSE[0], [BH]),
        ("O4", "input: speakers + Muse + BlackHole", [SPK, MUSE[1], BH], SPK, [MUSE[1], BH]),
    ]
    for tid, title, subs, master, drift in orders:
        j = run_probe(tid, subs, master, drift, writer=BH, wmode="tones", secs=4)
        if "error" not in j and not served(j):
            not_served(tid, title, j); continue
        if "error" in j or "input_order" not in j:
            record(tid, title, False, j.get("error", "no analysis: %s" % j.get("input_order"))); continue
        offs = j["layout"]["offsets_by_list_order"][BH]["in_first"]
        rows = {r["channel"]: r for r in j["input_order"]["rows"]}
        if all(r["level_db"] < -150 for r in rows.values()):
            silent_input(tid, title, j); continue
        found = {}
        for c, r in rows.items():
            if r["tone"] >= 0 and r["over_runner_up_db"] > 10:
                found[r["tone"]] = c
        good = all(found.get(t) == offs + t for t in range(n_bh_in))
        ks = {found[t] - t for t in found}
        record(tid, title, good, "K by list order = %d; tones found back at K = %s (%d/%d tones)" % (offs, sorted(ks), len(found), n_bh_in))
    outs = [
        ("O5", "output: Muse Share(master) + BlackHole", [MUSE[0], BH], MUSE[0], [BH]),
        ("O6", "output: BlackHole listed first, Muse master", [BH, MUSE[0]], MUSE[0], [BH]),
        ("O7", "output: Muse + Muse + BlackHole", [MUSE[0], MUSE[1], BH], MUSE[0], [MUSE[1], BH]),
    ]
    for tid, title, subs, master, drift in outs:
        j = run_probe(tid, subs, master, drift, reader=BH, aout="tones", secs=4)
        if "error" not in j and not served(j):
            not_served(tid, title, j); continue
        if "error" in j or "output_order" not in j:
            record(tid, title, False, j.get("error", "no analysis")); continue
        koff = j["layout"]["offsets_by_list_order"][BH]["out_first"]
        rows = {r["channel"]: r for r in j["output_order"]["rows"]}
        if all(r["level_db"] < -150 for r in rows.values()):
            silent_input(tid, title, j, "the loop of BlackHole"); continue
        ok_all = True; ks = set()
        for c in range(n_bh_in):
            r = rows.get(c)
            if r is None or r["tone"] < 0 or r["over_runner_up_db"] < 10:
                ok_all = False; continue
            ks.add(r["tone"] - c)
            if r["tone"] != koff + c:
                ok_all = False
        record(tid, title, ok_all, "out offset by list order = %d; BlackHole inputs show aggregate outputs at offset %s" % (koff, sorted(ks)))

    # ── D / T / K: rates, latency, destroy ────────────────────────────────────────────────────
    out("\n── D  different rates, T  latency by loop, K  destruction while serving as input")
    for tid, title, rates in [("D1", "speakers 48k(master) + BlackHole 176.4k, sine in", []),
                              ("D2", "speakers 44.1k(master) + BlackHole 176.4k, sine in", [SPK + "=44100"])]:
        j = run_probe(tid, [SPK, BH], SPK, [BH], writer=BH, wmode="sine", rates=rates, secs=8)
        if "error" not in j and not served(j):
            not_served(tid, title, j); continue
        if "error" in j or "run" not in j:
            record(tid, title, False, j.get("error", "no run")); continue
        r = j["run"]
        if r.get("watch_peak", 0) < 0.1:
            silent_input(tid, title, j); continue
        mv = rate_story(j)
        record(tid, title, r["sine_glitches"] == 0 and r["sine_frames_checked"] > 100000,
               "BlackHole %s -> %s; sine glitches=%d (max residual %.4f) over %d frames; overloads=%d; agg actual rate %.1f..%.1f" % (
                   st[BH]["rate"], j["rates_during_run"].get(BH), r["sine_glitches"], r["sine_max_residual"], r["sine_frames_checked"],
                   r["overload_notifications"], r["agg_actual_rate_min"], r["agg_actual_rate_max"]))
    for tid, title, subs, master in [("T1", "latency: speakers(master) + BlackHole", [SPK, BH], SPK),
                                     ("T2", "latency: Muse(master) + BlackHole", [MUSE[0], BH], MUSE[0])]:
        j = run_probe(tid, subs, master, [BH], writer=BH, wmode="impulse", secs=12)
        if "error" not in j and not served(j):
            not_served(tid, title, j); continue
        lat = j.get("run", {}).get("latency_loop_ms", {})
        a = j.get("layout", {}).get("aggregate", {})
        if lat.get("n", 0) == 0 and j.get("run", {}).get("watch_peak", 0) < 0.1:
            silent_input(tid, title, j); continue
        if lat.get("n", 0) < 8:
            record(tid, title, False, "too few impulses read back: %s" % lat); continue
        reported = (a.get("in_latency", 0) + a.get("in_safety", 0) + a.get("buffer", 0)) / a.get("rate", 48000) * 1000
        record(tid, title, (lat["max"] - lat["min"]) < 10.0,
               "median %.2f ms (min %.2f, max %.2f, n=%d); reported by CoreAudio for the aggregate's input: %.2f ms (latency %s + safety %s + buffer %s @ %s)" % (
                   lat["median"], lat["min"], lat["max"], lat["n"], reported, a.get("in_latency"), a.get("in_safety"), a.get("buffer"), a.get("rate")))
    j = run_probe("K1", [SPK, BH], SPK, [BH], writer=BH, wmode="sine", secs=6, extra=["--destroy-live"])
    ld = j.get("live_destroy", {})
    if not served(j) and j.get("live_destroy_status") == 0:
        record("K1", "aggregate destroyed while its IOProc runs (input = BlackHole)", "skip",
               "the destroy itself returned 0 and the process survived, but no IOProc was ever called, so nothing proves the IO side%s" % (" (console LOCKED)" if console_locked() else ""))
        ld = None
    ok = ld is not None and j.get("rc") == 0 and j.get("live_destroy_status") == 0 and ld.get("writer_calls_still_running", 0) > 10
    if ld is not None:
      record("K1", "aggregate destroyed while its IOProc runs (input = BlackHole)", ok,
           "status %s, aggregate callbacks after the destroy: %s, the card keeps running for its other client: %s calls; rates after %s" % (
               j.get("live_destroy_status"), ld.get("agg_calls_after_destroy_1s"), ld.get("writer_calls_still_running"), j.get("rates_after_destroy", {}).get(BH)))

    # ── S: the long sine ────────────────────────────────────────────────────────────────────
    secs = 30 if args.quick else int(args.minutes * 60)
    out("\n── S  sine for %d s (%.1f min) through the aggregate" % (secs, secs / 60.0))
    j = run_probe("S1", [SPK, BH], SPK, [BH], writer=BH, wmode="sine", secs=secs)
    r = j.get("run", {})
    if not r:
        record("S1", "sine: speakers(master) + BlackHole", False, j.get("error", "no run"))
    elif not served(j):
        not_served("S1", "sine: speakers(master) + BlackHole in", j)
    else:
        silent = r.get("watch_peak", 0) < 0.1
        good = (r["sine_glitches"] == 0 and r["overload_notifications"] == 0 and r["agg_in_time_discontinuities"] == 0
                and r["agg_out_time_discontinuities"] == 0)
        record("S1", "clocks over time: speakers(master) + BlackHole in" + (" (content: SILENT, no mic permission)" if silent else ""), good if not silent else good,
               "%.0f s, %d callbacks; sine glitches %d (max residual %.4f); overloads %d; time discontinuities in/out/writer %d/%d/%d; "
               "ActualSampleRate %.2f..%.2f (nominal %.0f..%.0f); frames/callback %d..%d" % (
                   r["seconds"], r["agg_callbacks"], r["sine_glitches"], r["sine_max_residual"], r["overload_notifications"],
                   r["agg_in_time_discontinuities"], r["agg_out_time_discontinuities"], r["writer_time_discontinuities"],
                   r["agg_actual_rate_min"], r["agg_actual_rate_max"], r["agg_nominal_rate_min"], r["agg_nominal_rate_max"],
                   r["frames_min"], r["frames_max"]))
        if r["sine_glitches"]:
            out("       glitch times (s): %s" % r["sine_glitch_times_s"])
    if not args.no_mic:
        short = 30 if args.quick else int(min(args.minutes, 5) * 60)
        j = run_probe("S2", [BH, MIC], BH, [MIC], writer=None, wmode="none", aout="sine", secs=short,
                      extra=["--aoutch", "0", "--watch", "0"])
        r = j.get("run", {})
        if "error" not in j and r and not served(j):
            not_served("S2", "sine: BlackHole(master) out, microphone in", j)
        elif "error" in j or not r:
            record("S2", "sine: BlackHole(master) out, microphone in", False, j.get("error", "no run"))
        else:
            record("S2", "sine out through BlackHole master, microphone drift-compensated", True if j.get("agg_start_status") == 0 else False,
                   "start status %s; %.0f s, %d callbacks; overloads %d; time discontinuities in/out %d/%d; rates %s -> %s" % (
                       j.get("agg_start_status"), r["seconds"], r["agg_callbacks"], r["overload_notifications"],
                       r["agg_in_time_discontinuities"], r["agg_out_time_discontinuities"], j["rates_before"], j.get("rates_during_run")))

    out("\n── summary: %d OK, %d FAIL, %d SKIP (no IO served), %d info" % (
        sum(1 for r in results if r[2] is True), sum(1 for r in results if r[2] is False),
        sum(1 for r in results if r[2] == "skip"), sum(1 for r in results if r[2] is None)))
    if args.json:
        with open(args.json, "w") as f:
            json.dump({"results": results, "raw": raw}, f, indent=1)
    return 1 if any(r[2] is False for r in results) else 0


if __name__ == "__main__":
    g = G.AudioStateGuard(strict=False)
    rc = 0
    with g:
        rc = main()
    if getattr(g, "failed", False):
        rc = 1
    sys.exit(rc)
