#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""The audio state guard: what a test of the audio code must give back exactly as it found it.

Anything that opens a real sound card can leave traces on the MACHINE, not only in the project:

  * the nominal sample rate and the buffer size of every card (an aggregate makes the system change a
    card's rate; so does the app's own "Sample rate" menu, which is also the only way a test of it
    would ever ask);
  * the three system defaults (default input, default output, default system output);
  * `org.labelpeche.objekat` in `defaults` (the app's preferences, `pref.outputDevice`,
    `pref.inputDevice`, the window frames ...);
  * `~/Library/objekat/Settings.xml`, which the engine rewrites at every exit.

The guard takes all of it before, puts it back after, then reads everything again and FAILS if one
value is still different. The snapshot is also kept on disk, so `--restore` works after a crash, a
Ctrl-C or a session that was lost half-way.

  audio_state_guard.py run [--strict] -- CMD ARG...    snapshot, run CMD, restore, verify
  audio_state_guard.py snapshot                        take and keep a snapshot
  audio_state_guard.py check                           compare the machine to the kept snapshot
  audio_state_guard.py --restore                       put the machine back to the kept snapshot

From Python:  `with AudioStateGuard(): ...`  (a nested guard does nothing: `run` sets
OBJEKAT_AUDIO_GUARD in the environment of its child).

What is NOT a failure. A card that appears or disappears while the guard is active (reported, but it
is the world moving: nothing to put back). `Settings.xml` differs after nearly every exit of the app (the engine rewrites
it, its hash is not stable): that is reported as "changed by the run" and restored, never counted
against the run, even with `--strict`. `--strict` makes any other drift (a card's rate, a default,
a preference) a failure EVEN WHEN it was restored, because a test that changes the hardware must say so.

Exit codes: 0 clean; 1 something could not be put back (or `--strict` drift); 2 usage;
otherwise the child's own code.

The card access goes through tools/audio_aggregate_probe.m (property queries only: no card is opened,
so no microphone prompt and no Bluetooth profile switch), compiled on first use.
"""

import argparse
import base64
import datetime
import json
import os
import plistlib
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
DOMAIN = "org.labelpeche.objekat"
SETTINGS = os.path.expanduser("~/Library/objekat/Settings.xml")
CACHE = os.path.expanduser("~/Library/Caches/objekat-audio-guard")
SNAPSHOT_FILE = os.path.join(CACHE, "snapshot.json")
PROBE_SRC = os.path.join(HERE, "audio_aggregate_probe.m")
PROBE_BIN = os.path.join(CACHE, "audio_aggregate_probe")
ENV_FLAG = "OBJEKAT_AUDIO_GUARD"
PREF_INPUT = "pref.inputDevice"


def ensure_probe():
    """Compile the CoreAudio helper if it is missing or older than its source."""
    os.makedirs(CACHE, exist_ok=True)
    if (not os.path.exists(PROBE_BIN)
            or os.path.getmtime(PROBE_BIN) < os.path.getmtime(PROBE_SRC)):
        subprocess.check_call(["clang", "-fobjc-arc", "-O2", "-framework", "Foundation",
                               "-framework", "CoreAudio", PROBE_SRC, "-o", PROBE_BIN])
    return PROBE_BIN


def probe(*args, timeout=60):
    out = subprocess.run([ensure_probe()] + [str(a) for a in args], stdout=subprocess.PIPE,
                         stderr=subprocess.PIPE, timeout=timeout)
    return out.returncode, out.stdout.decode("utf-8", "replace").strip()


def read_cards():
    rc, text = probe("state")
    if rc != 0:
        raise RuntimeError("the CoreAudio helper failed: " + text)
    st = json.loads(text)
    cards = {}
    for d in st["devices"]:
        cards[d["uid"]] = {"name": d["name"], "rate": d["rate"], "buffer": d["buffer"],
                           "in": d["in_channels"], "out": d["out_channels"], "transport": d["transport"]}
    return {"cards": cards, "defaults": st["defaults"]}


def read_defaults_domain():
    r = subprocess.run(["defaults", "export", DOMAIN, "-"], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if r.returncode != 0 or not r.stdout.strip():
        return {}
    try:
        return plistlib.loads(r.stdout)
    except Exception:
        return {}


def read_settings_bytes():
    try:
        with open(SETTINGS, "rb") as f:
            return f.read()
    except FileNotFoundError:
        return None


def take():
    dom = read_defaults_domain()
    sx = read_settings_bytes()
    return {
        "taken_at": datetime.datetime.now().isoformat(timespec="seconds"),
        "audio": read_cards(),
        "defaults_domain_plist": base64.b64encode(plistlib.dumps(dom)).decode("ascii"),
        "pref_input_device": dom.get(PREF_INPUT),
        "pref_input_device_present": PREF_INPUT in dom,
        "settings_xml_b64": None if sx is None else base64.b64encode(sx).decode("ascii"),
    }


def _norm(v):
    # plist values that json cannot hold (bytes, datetime) compare by repr
    if isinstance(v, (bytes, bytearray)):
        return "bytes:" + base64.b64encode(bytes(v)).decode("ascii")
    if isinstance(v, datetime.datetime):
        return "date:" + v.isoformat()
    if isinstance(v, dict):
        return {k: _norm(x) for k, x in v.items()}
    if isinstance(v, list):
        return [_norm(x) for x in v]
    return v


def diff(snap, now):
    """Every difference between a snapshot and a later reading, as (kind, subject, before, after)."""
    out = []
    a, b = snap["audio"], now["audio"]
    for uid, c in a["cards"].items():
        n = b["cards"].get(uid)
        if n is None:
            out.append(("card_missing", c["name"], "present", "absent"))
            continue
        if c["rate"] != n["rate"]:
            out.append(("rate", c["name"], c["rate"], n["rate"], uid))
        if c["buffer"] != n["buffer"]:
            out.append(("buffer", c["name"], c["buffer"], n["buffer"], uid))
    for uid, c in b["cards"].items():
        if uid not in a["cards"]:
            out.append(("card_appeared", c["name"], "absent", "present"))
    for k in ("input", "output", "system"):
        if a["defaults"].get(k) != b["defaults"].get(k):
            out.append(("default_" + k, k, a["defaults"].get(k), b["defaults"].get(k)))
    before = _norm(plistlib.loads(base64.b64decode(snap["defaults_domain_plist"])))
    after = _norm(plistlib.loads(base64.b64decode(now["defaults_domain_plist"])))
    if before != after:
        keys = sorted(set(before) | set(after))
        for k in keys:
            if before.get(k) != after.get(k):
                out.append(("defaults", k, before.get(k, "<absent>"), after.get(k, "<absent>")))
    if snap["pref_input_device"] != now["pref_input_device"] or \
            snap["pref_input_device_present"] != now["pref_input_device_present"]:
        out.append(("pref_inputDevice", PREF_INPUT, snap["pref_input_device"], now["pref_input_device"]))
    if snap["settings_xml_b64"] != now["settings_xml_b64"]:
        out.append(("settings_xml", SETTINGS,
                    "absent" if snap["settings_xml_b64"] is None else "%d bytes" % len(base64.b64decode(snap["settings_xml_b64"])),
                    "absent" if now["settings_xml_b64"] is None else "%d bytes" % len(base64.b64decode(now["settings_xml_b64"]))))
    return out


def restore(snap, log=print):
    """Put back what the snapshot holds. Returns the list of things that could not be put back."""
    failures = []
    now = take()
    for kind, subject, before, after, *extra in diff(snap, now):
        if kind == "rate":
            uid = extra[0]
            if before and before > 0:
                rc, out = probe("set-rate", uid, before)
                log("  restore rate   %-28s %s -> %s : %s" % (subject, after, before, out or rc))
                if rc != 0:
                    failures.append((kind, subject))
        elif kind == "buffer":
            uid = extra[0]
            if before and before > 0:
                rc, out = probe("set-buffer", uid, before)
                log("  restore buffer %-28s %s -> %s : %s" % (subject, after, before, out or rc))
                if rc != 0:
                    failures.append((kind, subject))
        elif kind.startswith("default_"):
            if before:
                rc, out = probe("set-default", subject, before)
                log("  restore default %-27s %s -> %s : %s" % (subject, after, before, out or rc))
                if rc != 0:
                    failures.append((kind, subject))
        elif kind == "settings_xml":
            if snap["settings_xml_b64"] is None:
                try:
                    os.remove(SETTINGS)
                except FileNotFoundError:
                    pass
            else:
                os.makedirs(os.path.dirname(SETTINGS), exist_ok=True)
                tmp = SETTINGS + ".guard-tmp"
                with open(tmp, "wb") as f:
                    f.write(base64.b64decode(snap["settings_xml_b64"]))
                os.replace(tmp, SETTINGS)
            log("  restore Settings.xml (%s -> %s)" % (after, before))
        elif kind in ("defaults", "pref_inputDevice"):
            pass   # restored as one block below
    if any(k in ("defaults", "pref_inputDevice") for k, *_ in diff(snap, take())):
        with tempfile.NamedTemporaryFile(suffix=".plist", delete=False) as f:
            f.write(base64.b64decode(snap["defaults_domain_plist"]))
            path = f.name
        r = subprocess.run(["defaults", "import", DOMAIN, path], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        os.remove(path)
        log("  restore defaults of %s : %s" % (DOMAIN, "ok" if r.returncode == 0 else r.stderr.decode().strip()))
        if r.returncode != 0:
            failures.append(("defaults", DOMAIN))
    return failures


def save(snap):
    os.makedirs(CACHE, exist_ok=True)
    tmp = SNAPSHOT_FILE + ".tmp"
    with open(tmp, "w") as f:
        json.dump(snap, f)
    os.replace(tmp, SNAPSHOT_FILE)


def load():
    try:
        with open(SNAPSHOT_FILE) as f:
            return json.load(f)
    except FileNotFoundError:
        return None


# A card that appears or vanishes (a phone's microphone, a Bluetooth device) is the world moving, not
# something a test left behind and not something the guard can put back: reported, never a failure.
INFORMATIONAL = ("settings_xml", "card_missing", "card_appeared")


def describe(d):
    return "%-16s %-28s %s -> %s" % tuple(d[:4])


class AudioStateGuard(object):
    """`with AudioStateGuard(strict=False) as g: ...` ; `g.drift` lists what the body changed."""

    def __init__(self, strict=False, log=print):
        self.strict, self.log = strict, log
        self.nested = bool(os.environ.get(ENV_FLAG))
        self.drift = []
        self.unrestored = []

    def __enter__(self):
        if self.nested:
            return self
        self.snap = take()
        save(self.snap)
        os.environ[ENV_FLAG] = "1"
        return self

    def __exit__(self, *exc):
        if self.nested:
            return False
        os.environ.pop(ENV_FLAG, None)
        self.drift = diff(self.snap, take())
        if self.drift:
            self.log("audio_state_guard: the run changed the machine:")
            for d in self.drift:
                self.log("  " + describe(d))
            self.log("audio_state_guard: restoring")
            self.unrestored = restore(self.snap, self.log)
        residual = diff(self.snap, take())
        residual = [d for d in residual if d[0] not in INFORMATIONAL]
        self.residual = residual
        if residual:
            self.log("audio_state_guard: FAILED, still different after the restore:")
            for d in residual:
                self.log("  " + describe(d))
        else:
            self.log("audio_state_guard: everything is back as it was (%d card(s), 3 defaults, defaults domain, "
                     "pref.inputDevice, Settings.xml)" % len(self.snap["audio"]["cards"]))
        self.failed = bool(residual) or bool(self.unrestored) or (
            self.strict and any(d[0] not in INFORMATIONAL for d in self.drift))
        return False


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("command", nargs="?", choices=["run", "snapshot", "check", "restore"])
    ap.add_argument("--restore", action="store_true", help="put the machine back to the kept snapshot")
    ap.add_argument("--strict", action="store_true", help="drift other than Settings.xml fails even if restored")
    argv = sys.argv[1:]
    rest = []
    if "--" in argv:                        # everything after the first -- is the command to run
        i = argv.index("--")
        argv, rest = argv[:i], argv[i + 1:]
    args = ap.parse_args(argv)
    cmd = "restore" if args.restore else args.command
    if cmd is None:
        ap.print_usage()
        return 2

    if cmd == "snapshot":
        snap = take()
        save(snap)
        print("snapshot kept: %d card(s), defaults %s" % (len(snap["audio"]["cards"]), snap["audio"]["defaults"]))
        return 0
    if cmd in ("check", "restore"):
        snap = load()
        if snap is None:
            print("no snapshot kept (run `snapshot` first)")
            return 2
        d = diff(snap, take())
        for x in d:
            print("  " + describe(x))
        if cmd == "check":
            print("different: %d" % len(d) if d else "identical to the snapshot of " + snap["taken_at"])
            return 1 if [x for x in d if x[0] not in INFORMATIONAL] else 0
        un = restore(snap)
        res = [x for x in diff(snap, take()) if x[0] not in INFORMATIONAL]
        if res or un:
            print("FAILED, still different:")
            for x in res:
                print("  " + describe(x))
            return 1
        print("everything is back as it was (snapshot of %s)" % snap["taken_at"])
        return 0

    # run
    if not rest:
        print("run: nothing to run")
        return 2
    g = AudioStateGuard(strict=args.strict)
    rc = 0
    with g:
        try:
            rc = subprocess.call(rest)
        except KeyboardInterrupt:
            rc = 130
    if g.failed:
        return 1
    return rc


if __name__ == "__main__":
    sys.exit(main())
