#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""The diagnostic journal — a scenario that ASSERTS, against HEADLESS instances only.

    python3 tools/scenario_diag_log.py [path/to/objekat/binary] [T0 T4 …]

The app only WRITES the journal; reading it is `tools/diag_latest.py`'s job, and this scenario
tests both halves. Each test launches its own instances (`--headless --api --no-audio --no-recent`,
a short socket under /tmp, `--diag-dir=<temporary folder>` so ~/Library/Logs/Objekat is never
touched). No window is ever opened.

  T0  journal option off          → no file, no folder, `diag.status` says so
  T1  startup                     → header line, meta clean_exit:false, session file
  T2  tracing                     → API / EDIT / UNDO / TRANS / PROJ lines, in order, EDIT with
                                    function + file:line
  T3  normal exits                → SIGTERM and a plain `exit()` leave clean_exit true and
                                    diag_latest.py calls them ok
  T4  real crashes (Debug)        → ONE crash per debug.crash kind: the journal ends with the last
                                    API line then CRASH ; diag_latest.py flags the session CRASH
                                    and finds its .ips (macOS may not write one: reported, not failed)
  T5  kill -9                     → diag_latest.py: ABNORMAL, and it is the default pick
  T6  diag.mark                   → an ISSUE "note" line, found by diag_latest.py
  T7  rotation                    → --diag-max-mb=1 + diag_flood
  T8  two instances, one folder   → the killed one is ABNORMAL, the live one is alive
  T9  cost                        → median of one journal line < 10 µs
  T10 catalogue                   → the Diagnostic menu's keys exist in fr/en/es, none orphaned

The five debug.crash calls leave real .ips files in ~/Library/Logs/DiagnosticReports (expected).
Exit: 0 if every assertion passes, 1 otherwise.
"""

import glob, json, os, re, shutil, signal, subprocess, sys, tempfile, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from objekat_cli import ObjekatClient, ObjekatError

ROOT = os.path.dirname(HERE)
BIN = sys.argv[1] if len(sys.argv) > 1 and sys.argv[1] else os.path.join(
    ROOT, "DerivedData/Build/Products/Debug/objekat.app/Contents/MacOS/objekat")
BIP = os.path.join(HERE, "fixtures", "bip.wav")

ok = ko = 0
procs = []
tmpdirs = []


def check(label, cond, detail=""):
    global ok, ko
    if cond:
        ok += 1
        print("  OK   %s" % label)
    else:
        ko += 1
        print("  FAIL %s  %s" % (label, detail))
    return cond


def section(title):
    print("\n── %s " % title + "─" * max(4, 74 - len(title)))


def tmpdir(prefix="objdiag-"):
    d = tempfile.mkdtemp(prefix=prefix)
    tmpdirs.append(d)
    return d


_sock_n = [0]


def new_sock():
    _sock_n[0] += 1
    return "/tmp/odg%d_%d.sock" % (os.getpid() % 10000, _sock_n[0])


def launch(diag_dir, diag_log=True, extra=None, wait_socket=180):
    """Starts a headless instance, waits for its socket. Returns (proc, sock)."""
    sock = new_sock()
    if os.path.exists(sock):
        os.remove(sock)
    args = [BIN, "--headless", "--api", "--no-audio", "--no-recent", "--language=en",
            "--socket=" + sock, "--diag-dir=" + diag_dir]
    if diag_log:
        args.append("--diag-log")
    args += extra or []
    proc = subprocess.Popen(args, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    procs.append(proc)
    deadline = time.time() + wait_socket
    while time.time() < deadline:
        if os.path.exists(sock):
            time.sleep(0.2)
            return proc, sock
        if proc.poll() is not None:
            raise RuntimeError("the app exited before opening its socket (rc=%s)" % proc.returncode)
        time.sleep(0.25)
    proc.kill()
    raise RuntimeError("the app did not open its socket: " + sock)


def stop(proc, sock=None, sig=signal.SIGTERM):
    if proc.poll() is None:
        try:
            proc.send_signal(sig)
            proc.wait(timeout=20)
        except Exception:
            proc.kill()
    if sock and os.path.exists(sock):
        try:
            os.remove(sock)
        except OSError:
            pass


def client(sock):
    return ObjekatClient(sock, timeout=60).connect()


def session_log(diag_dir, pid):
    hits = glob.glob(os.path.join(diag_dir, "sessions", "*_pid%d.log" % pid))
    return hits[0] if hits else None


def session_meta(diag_dir, pid):
    hits = glob.glob(os.path.join(diag_dir, "sessions", "*_pid%d.meta.json" % pid))
    return json.load(open(hits[0])) if hits else None


def read_lines(path):
    with open(path, encoding="utf-8", errors="replace") as f:
        return [l.rstrip("\n") for l in f if l.strip()]


def window_count(pid):
    import Quartz
    info = Quartz.CGWindowListCopyWindowInfo(Quartz.kCGWindowListOptionAll, Quartz.kCGNullWindowID)
    return sum(1 for w in info if w.get("kCGWindowOwnerPID") == pid)


def index_of(lines, pattern, start=0):
    rx = re.compile(pattern)
    for i in range(start, len(lines)):
        if rx.search(lines[i]):
            return i
    return -1


LATEST = os.path.join(HERE, "diag_latest.py")


def diag_latest(d, *args):
    """Runs tools/diag_latest.py on a logs folder. Returns (returncode, stdout)."""
    r = subprocess.run([sys.executable, LATEST, "--dir", d] + list(args), capture_output=True, text=True,
                       timeout=180)
    return r.returncode, r.stdout


def sessions_json(d):
    rc, out = diag_latest(d, "list", "--json", "-n", "50")
    return {s["pid"]: s for s in json.loads(out)} if rc == 0 and out.strip() else {}


def show_json(d, pid, *extra):
    rc, out = diag_latest(d, "show", str(pid), "--json", *extra)
    return json.loads(out) if rc == 0 and out.strip() else {}


# ─────────────────────────────────────────────────────────────────────────────
def t0_off():
    section("T0  option off → nothing written")
    d = tmpdir()
    proc, sock = launch(d, diag_log=False)
    with client(sock) as c:
        st = c.send("diag.status")
        check("diag.status: enabled false", st["enabled"] is False, str(st))
        check("diag.status: no log", st["log"] is None)
        c.send("app.info")
        try:
            c.send("diag.tail")
            check("diag.tail refused while off", False)
        except ObjekatError as e:
            check("diag.tail refused while off", e.code == "invalid_state", str(e))
        try:
            c.send("diag.mark", {"note": "x"})
            check("diag.mark refused while off", False)
        except ObjekatError as e:
            check("diag.mark refused while off", e.code == "invalid_state", str(e))
    stop(proc, sock)
    check("no sessions file", not glob.glob(os.path.join(d, "sessions", "*")))
    check("no crash / issue folder", not glob.glob(os.path.join(d, "crashes")) and not glob.glob(os.path.join(d, "issues")))


def t1_startup():
    section("T1  startup")
    d = tmpdir()
    proc, sock = launch(d)
    with client(sock) as c:
        st = c.send("diag.status")
        check("diag.status: enabled", st["enabled"] is True, str(st))
        log = session_log(d, proc.pid)
        check("session file named after the pid", log is not None)
        lines = read_lines(log)
        check("header line", re.match(
            r"# OBJEKAT \S+ \(\S+\) pid=%d start=\S+ macOS .* device=\".*\" headless=1" % proc.pid,
            lines[0]) is not None, lines[0][:200])
        meta = session_meta(d, proc.pid)
        check("meta: clean_exit false while alive", meta and meta["clean_exit"] is False, str(meta))
        check("meta: pid and headless", meta and meta["pid"] == proc.pid and meta["headless"] is True)
        check("README.md written", os.path.exists(os.path.join(d, "README.md")))
        check("window count 0", window_count(proc.pid) == 0)
    stop(proc, sock)


def t2_tracing():
    section("T2  tracing")
    d = tmpdir()
    proc, sock = launch(d)
    proj = os.path.join(d, "proj", "t.objekat")
    with client(sock) as c:
        c.send("project.new")
        a = c.send("object.add", {"path": BIP, "lane": 0, "start": 0})["id"]
        c.send("wait_idle", {"timeout_ms": 10000})
        c.send("object.move", {"id": a, "start": 1.0})
        c.send("object.set_gain", {"ids": [a], "db": -6})
        c.send("object.split_at", {"seconds": 1.5, "ids": [a]})
        c.send("transport.play")
        c.send("transport.stop")
        c.send("edit.undo")
        c.send("project.save_as", {"path": proj})
        c.send("batch", {"commands": [{"cmd": "object.set_gain", "params": {"ids": [a], "db": -3}}]})
        try:
            c.send("object.move", {"id": "00000000-0000-0000-0000-000000000000", "start": 1})
        except ObjekatError:
            pass
        lines = read_lines(session_log(d, proc.pid))
        check("window count 0 (no window ever)", window_count(proc.pid) == 0)
    stop(proc, sock)
    text = "\n".join(lines)
    check("line format HH:MM:SS.mmm +secs CAT", all(
        re.match(r"^\d\d:\d\d:\d\d\.\d{3} \+\d+\.\d{3} \S+", l) or l.startswith("#") for l in lines),
        next((l for l in lines if not (re.match(r"^\d\d:\d\d:\d\d\.\d{3} \+\d+\.\d{3} \S+", l)
                                       or l.startswith("#"))), ""))
    seq = ["API +project.new", "PROJ +nouveau projet", "API +object.add .*→ ok", "API +object.move",
           "EDIT ", "API +object.set_gain", "API +object.split_at", "API +transport.play",
           "TRANS +play", "API +transport.stop", "TRANS +stop", "API +edit.undo", "UNDO +undo",
           "API +project.save_as", "PROJ +enregistrement", "PROJ +enregistré", "API +batch"]
    pos, in_order = 0, True
    for pat in seq:
        i = index_of(lines, pat, pos)
        if i < 0:
            in_order = False
            check("in order: %s" % pat, False, "not found after line %d" % pos)
            break
        pos = i + 1
    if in_order:
        check("API / EDIT / TRANS / UNDO / PROJ lines, in order", True)
    edits = [l for l in lines if re.search(r" EDIT +", l)]
    check("EDIT lines carry function and file:line",
          bool(edits) and all(re.search(r"EDIT +\S+ \S+\.swift:\d+$", l) for l in edits), str(edits[:3]))
    check("EDIT names a real function (not only the bus)",
          any(not re.search(r"EDIT +executeCommand", l) for l in edits), str(edits[:6]))
    mine = [l for l in lines if re.search(r" (API|EDIT|UNDO|PROJ|TRANS) ", l)]
    check("API params shown and UUIDs shortened",
          not any(re.search(r"[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}", l) for l in mine)
          and '"start":1' in text and '\\/' not in text)
    check("API outcome with duration", re.search(r"object\.add → ok \d+\.\d ms", text) is not None)
    check("API error outcome journaled",
          re.search(r"object\.move → erreur not_found", text) is not None)


def t3_normal_exits():
    section("T3  normal exits are not crashes")
    d = tmpdir()
    proc, sock = launch(d)
    pid1 = proc.pid
    stop(proc, sock, signal.SIGTERM)
    meta = session_meta(d, pid1)
    lines = read_lines(session_log(d, pid1))
    check("SIGTERM: EXIT line", index_of(lines, r" EXIT +external signal SIGTERM") >= 0, lines[-1])
    check("SIGTERM: meta clean_exit true", meta and meta["clean_exit"] is True, str(meta))
    # A plain exit(): `--exec` without --api runs the script then exit(code).
    script = os.path.join(d, "exit.jsonl")
    open(script, "w").write('{"cmd":"app.info"}\n')
    sock2 = new_sock()
    p2 = subprocess.Popen([BIN, "--headless", "--no-audio", "--no-recent", "--exec=" + script,
                           "--diag-dir=" + d, "--diag-log", "-pref.apiEnabled", "NO"],
                          stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    procs.append(p2)
    try:
        rc = p2.wait(timeout=90)
    except subprocess.TimeoutExpired:
        p2.kill()
        rc = None
    check("--exec exits by itself", rc == 0, "rc=%s" % rc)
    meta2 = session_meta(d, p2.pid)
    check("exit(): meta clean_exit true", meta2 and meta2["clean_exit"] is True, str(meta2))
    sess = sessions_json(d)
    check("diag_latest: both sessions ok", sess.get(pid1, {}).get("status") == "ok"
          and sess.get(p2.pid, {}).get("status") == "ok", str({k: v["status"] for k, v in sess.items()}))
    rc, out = diag_latest(d)
    check("diag_latest default: nothing abnormal", rc == 0 and "Aucune session anormale" in out, out[:200])
    check("no crashes/, issues/ or LATEST.md written by the app",
          not any(os.path.exists(os.path.join(d, n)) for n in ("crashes", "issues", "LATEST.md")))


KINDS = {  # kind → acceptable signals
    "segv": {"SIGSEGV", "SIGBUS"},
    "abort": {"SIGABRT"},
    "objc_exception": {"SIGABRT"},
    "swift_fatal": {"SIGTRAP", "SIGILL"},
    "stack_overflow": {"SIGSEGV", "SIGBUS"},
}


def t4_crashes():
    section("T4  real crashes (Debug) — one per kind")
    d = tmpdir()
    crashed = {}
    for kind in KINDS:
        proc, sock = launch(d)
        pid = proc.pid
        with client(sock) as c:
            c.send("project.new")
            c.send("object.add", {"path": BIP, "lane": 0, "start": 0})
            wins = window_count(pid)
            try:
                c.send("debug.crash", {"kind": kind})
                check("%s: the connection drops" % kind, False, "got an answer")
            except (ConnectionError, OSError, ValueError):
                pass
        try:
            proc.wait(timeout=60)
        except subprocess.TimeoutExpired:
            proc.kill()
            check("%s: process died" % kind, False)
        check("%s: no window at any time" % kind, wins == 0)
        crashed[kind] = pid
        lines = read_lines(session_log(d, pid))
        last_api = max((i for i, l in enumerate(lines) if re.search(r" API +\S", l)), default=-1)
        check("%s: last API line is debug.crash" % kind,
              last_api >= 0 and "debug.crash" in lines[last_api] and "→" not in lines[last_api],
              lines[last_api] if last_api >= 0 else "none")
        crash_idx = index_of(lines, r" CRASH +", last_api + 1)
        check("%s: CRASH lines follow it" % kind, crash_idx > last_api, "\n".join(lines[-4:]))
        sig_lines = [l for l in lines if re.search(r"CRASH +signal SIG\w+", l)]
        got = re.search(r"signal (SIG\w+)", sig_lines[-1]).group(1) if sig_lines else None
        check("%s: signal line (%s)" % (kind, got), got in KINDS[kind], str(sig_lines[-1:]))
        if kind == "objc_exception":
            check("objc_exception: name + reason recorded",
                  index_of(lines, r"CRASH +objc_exception name=OBJDiagTestException reason=debug\.crash") >= 0)
        meta = session_meta(d, pid)
        check("%s: meta still clean_exit false" % kind, meta and meta["clean_exit"] is False)
        time.sleep(1.0)

    # diag_latest.py reads the dead sessions.
    sess = sessions_json(d)
    for kind, pid in crashed.items():
        s_ = sess.get(pid, {})
        check("%s: diag_latest says CRASH/%s" % (kind, s_.get("signal")),
              s_.get("status") == "CRASH" and s_.get("signal") in KINDS[kind], str(s_))
    rc, out = diag_latest(d)
    last_pid = crashed[list(KINDS)[-1]]
    check("diag_latest default: the newest crash, in full", rc == 0 and "pid %d" % last_pid in out
          and "── CRASH ──" in out and "Fin du journal" in out, out[:400])
    data = show_json(d, last_pid, "--lines", "5")
    check("show --lines 5: 5 journal lines, ending on the CRASH", len(data.get("tail", [])) == 5
          and " CRASH " in data["tail"][-1], str(data.get("tail", [])[-2:]))
    data = show_json(d, last_pid, "--minutes", "0.01")
    check("show --minutes: a window, not the whole journal", 0 < len(data.get("tail", [])) < 40,
          str(len(data.get("tail", []))))

    # The system report: macOS writes it asynchronously, up to a minute later, and sometimes not at
    # all — absent is REPORTED, never a failure.
    print("   … waiting for the .ips files (up to 60 s)")
    deadline = time.time() + 60
    found = {}
    while time.time() < deadline:
        for kind, pid in crashed.items():
            if kind not in found:
                data = show_json(d, pid)
                if data.get("ips"):
                    found[kind] = data
        if len(found) == len(crashed):
            break
        time.sleep(3.0)
    for kind, pid in crashed.items():
        data = found.get(kind)
        if not data:
            print("  NOTE %s: no .ips found for pid %d (macOS did not write one, or not yet)" % (kind, pid))
            continue
        exc = data.get("ips_exception") or {}
        check("%s: .ips of pid %d, signal %s" % (kind, pid, exc.get("signal")),
              exc.get("signal") in KINDS[kind], str(exc))
        rc, out = diag_latest(d, "show", str(pid))
        frames = re.findall(r"^\s+#\d+\s+\S+", out.split("Thread fautif", 1)[-1], re.M)
        check("%s: show prints the faulting thread (%d frames)" % (kind, len(frames)),
              "Thread fautif" in out and len(frames) >= 3, out[-500:])


def t5_kill9():
    section("T5  kill -9 → ABNORMAL for diag_latest.py")
    d = tmpdir()
    proc, sock = launch(d)
    pid = proc.pid
    with client(sock) as c:
        c.send("project.new")
    proc.kill()
    proc.wait()
    s_ = sessions_json(d).get(pid, {})
    check("list: ABNORMAL", s_.get("status") == "ABNORMAL", str(s_))
    rc, out = diag_latest(d)
    check("default pick: the killed session, « Arrêt anormal »", rc == 0 and "ABNORMAL" in out
          and "Arrêt anormal" in out and "pid %d" % pid in out, out[:400])
    data = show_json(d, pid)
    check("no CRASH line, no .ips", not data.get("crash_lines") and not data.get("ips"), str(data.get("ips")))


def t6_mark():
    section("T6  diag.mark → ISSUE line")
    d = tmpdir()
    proc, sock = launch(d)
    with client(sock) as c:
        c.send("project.new")
        c.send("object.add", {"path": BIP, "lane": 0, "start": 0})
        c.send("diag.mark", {"note": 'le son craque après le "split"'})
        lines = read_lines(session_log(d, proc.pid))
        check("session stays alive", c.send("diag.status")["enabled"] is True)
    issue = [l for l in lines if re.search(r" ISSUE +", l)]
    check("one ISSUE line, note quoted", len(issue) == 1 and re.search(
        r'ISSUE +"le son craque après le \\"split\\""$', issue[0]) is not None, str(issue))
    check("after the object.add line", index_of(lines, r"ISSUE") > index_of(lines, r"API +object\.add"))
    check("nothing else written: no issues/ folder, no LATEST.md",
          not os.path.exists(os.path.join(d, "issues")) and not os.path.exists(os.path.join(d, "LATEST.md")))
    rc, out = diag_latest(d)
    check("diag_latest default finds the ISSUE of the live session",
          rc == 0 and "Problèmes signalés" in out and "craque" in out and "alive" in out, out[:500])
    s_ = sessions_json(d).get(proc.pid, {})
    check("list: alive, 1 issue", s_.get("status") == "alive" and s_.get("issues") == 1, str(s_))
    stop(proc, sock)


def t7_rotation():
    section("T7  rotation")
    d = tmpdir()
    proc, sock = launch(d, extra=["--diag-max-mb=1"])
    with client(sock) as c:
        r = c.send("debug.diag_flood", {"lines": 30000, "width": 60})
        st = c.send("diag.status")
    check("rotations >= 1 (%s)" % r["rotations"], r["rotations"] >= 1, str(r))
    log = session_log(d, proc.pid)
    check(".log.1 exists", os.path.exists(log + ".1"))
    check("current file under ~1.1 MB", os.path.getsize(log) < 1.1 * 1024 * 1024, str(os.path.getsize(log)))
    first = open(log, encoding="utf-8").readline()
    check("new file starts with the header", first.startswith("# (suite apres rotation) # OBJEKAT")
          or first.startswith("# "), first[:120])
    stop(proc, sock)


def t8_two_instances():
    section("T8  two instances, one folder")
    d = tmpdir()
    pa, sa = launch(d)
    pb, sb = launch(d)
    with client(sa) as c:
        c.send("project.new")
    pa.kill()                      # no real crash needed: an abrupt death is what is being told apart
    pa.wait(timeout=60)
    with client(sb) as c:
        c.send("project.new")
        check("B survives and answers", c.send("diag.status")["enabled"] is True)
    sess = sessions_json(d)
    check("A is ABNORMAL, B is alive", sess.get(pa.pid, {}).get("status") == "ABNORMAL"
          and sess.get(pb.pid, {}).get("status") == "alive", str({k: v["status"] for k, v in sess.items()}))
    rc, out = diag_latest(d)
    check("default pick is A, never B", "pid %d" % pa.pid in out and "pid %d" % pb.pid not in out, out[:300])
    check("B's meta untouched (clean_exit false, process alive)",
          session_meta(d, pb.pid)["clean_exit"] is False and pb.poll() is None)
    stop(pb, sb)
    check("B, stopped, is ok", sessions_json(d).get(pb.pid, {}).get("status") == "ok")


def t9_cost():
    section("T9  cost")
    d = tmpdir()
    proc, sock = launch(d)
    with client(sock) as c:
        r = c.send("debug.diag_flood", {"lines": 10000, "width": 60})
    check("median %.2f µs < 10 µs (p95 %.2f)" % (r["median_us"], r["p95_us"]), r["median_us"] < 10.0, str(r))
    stop(proc, sock)


def t10_catalogue():
    section("T10 catalogue")
    cat = json.load(open(os.path.join(ROOT, "objekat/Resources/Localizable.xcstrings"), encoding="utf-8"))
    keys = ["diag.menu.title", "diag.menu.log", "diag.menu.report", "diag.menu.openFolder",
            "diag.issue.title", "diag.issue.info", "diag.issue.send", "diag.issue.placeholder"]
    missing = [k for k in keys for l in ("fr", "en", "es")
               if not cat["strings"].get(k, {}).get("localizations", {}).get(l, {}).get("stringUnit", {}).get("value")]
    check("the 8 diag keys exist in fr/en/es", not missing, str(missing))
    r = subprocess.run([sys.executable, os.path.join(HERE, "i18n/xcstrings.py"), "check"], cwd=ROOT,
                       capture_output=True, text=True)
    check("xcstrings check: no diag.* key reported", "diag." not in r.stdout, r.stdout[-300:])
    r = subprocess.run([sys.executable, os.path.join(HERE, "i18n/xcstrings.py"), "orphans"], cwd=ROOT,
                       capture_output=True, text=True)
    check("xcstrings orphans: no diag.* key", "diag." not in r.stdout, r.stdout[-300:])


TESTS = [t0_off, t1_startup, t2_tracing, t3_normal_exits, t4_crashes, t5_kill9, t6_mark, t7_rotation,
         t8_two_instances, t9_cost, t10_catalogue]

if __name__ == "__main__":
    only = [a for a in sys.argv[2:]]
    try:
        for t in TESTS:
            if only and t.__name__.split("_")[0].upper() not in [o.upper() for o in only]:
                continue
            try:
                t()
            except Exception as e:  # a broken test must not hide the others
                import traceback
                traceback.print_exc()
                check("%s raised %r" % (t.__name__, e), False)
    finally:
        for p in procs:
            if p.poll() is None:
                p.kill()
        for d in tmpdirs:
            if os.environ.get("KEEP_DIAG_TMP"):
                print("kept:", d)
            else:
                shutil.rmtree(d, ignore_errors=True)
    print("\n%d ok, %d failed" % (ok, ko))
    sys.exit(0 if ko == 0 else 1)
