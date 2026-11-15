#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""The diagnostic journal — a scenario that ASSERTS, against HEADLESS instances only.

    python3 tools/scenario_diag_log.py [path/to/objekat/binary]

Each test launches its own instances (`--headless --api --no-audio --no-recent`, a short socket
under /tmp, `--diag-dir=<temporary folder>` so ~/Library/Logs/Objekat is never touched). No window
is ever opened; T4 checks it on the crashing pids.

  T0  journal option off          → no file, no folder, `diag.status` says so
  T1  startup                     → header line, meta clean_exit:false, session file
  T2  tracing                     → API / EDIT / UNDO / TRANS / PROJ lines, in order, EDIT with
                                    function + file:line
  T3  normal exits                → SIGTERM and a plain `exit()` (`--exec`) leave NO crash folder
  T4  real crashes (Debug)        → segv, abort, objc_exception, swift_fatal, stack_overflow: the
                                    journal ends with the last API line then CRASH ; the relaunch
                                    prepares a complete crashes/… folder (summary, journal, .ips of
                                    the right pid, oslog, LATEST.md, diag.status.last_crash)
  T5  kill -9                     → « arrêt anormal sans rapport »
  T6  diag.mark                   → a complete issues/… folder
  T7  rotation                    → --diag-max-mb=1 + diag_flood
  T8  two instances, one folder   → only the instance that crashed is reported
  T9  cost                        → median of one journal line < 10 µs
  T10 catalogue                   → the Diagnostic menu's keys exist in fr/en/es

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


def crash_folders(diag_dir):
    return sorted(glob.glob(os.path.join(diag_dir, "crashes", "*")))


def wait_reports(sock, timeout=240):
    """The crash folders are prepared in the BACKGROUND after startup (the .ips of a fresh crash can
    take up to 60 s to appear): waits until `diag.status` says none is pending."""
    deadline = time.time() + timeout
    with client(sock) as c:
        while time.time() < deadline:
            if c.send("diag.status")["reports_pending"] == 0:
                return True
            time.sleep(1.0)
    return False


def folder_meta(folder):
    try:
        return json.load(open(os.path.join(folder, "meta.json")))
    except Exception:
        return {}


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
    stop(proc, sock)
    check("no sessions file", not glob.glob(os.path.join(d, "sessions", "*")))
    check("no crash / issue folder", not crash_folders(d) and not glob.glob(os.path.join(d, "issues", "*")))


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
    # Relaunch: neither session may produce a crash folder.
    proc3, sock3 = launch(d, extra=["--diag-ips-wait=2"])
    wait_reports(sock3, 60)
    with client(sock3) as c:
        st = c.send("diag.status")
        check("relaunch: no last_crash", st["last_crash"] is None, str(st["last_crash"]))
    stop(proc3, sock3)
    check("relaunch: no crash folder", not crash_folders(d))
    check("no LATEST.md", not os.path.exists(os.path.join(d, "LATEST.md")))


KINDS = {  # kind → acceptable signals
    "segv": {"SIGSEGV", "SIGBUS"},
    "abort": {"SIGABRT"},
    "objc_exception": {"SIGABRT"},
    "swift_fatal": {"SIGTRAP", "SIGILL"},
    "stack_overflow": {"SIGSEGV", "SIGBUS"},
}


def t4_crashes():
    section("T4  real crashes (Debug)")
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

    print("   … relaunching: the folders are prepared before the engine (up to ~60 s per .ips)")
    t0 = time.time()
    proc, sock = launch(d, extra=["--diag-ips-wait=60"], wait_socket=420)
    check("reports finished", wait_reports(sock, 300))
    print("   … relaunch + reports took %.0f s" % (time.time() - t0))
    folders = crash_folders(d)
    check("one crash folder per crash", len(folders) == len(KINDS), str(folders))
    by_pid = {folder_meta(f).get("pid"): f for f in folders}
    with client(sock) as c:
        st = c.send("diag.status")
    last = st.get("last_crash")
    for kind, pid in crashed.items():
        f = by_pid.get(pid)
        if not check("%s: folder for pid %d" % (kind, pid), f is not None, str(list(by_pid))):
            continue
        meta = folder_meta(f)
        check("%s: meta complete, signal %s" % (kind, meta.get("signal")),
              meta.get("complete") is True and meta.get("signal") in KINDS[kind], str(meta))
        check("%s: name ends with the signal" % kind, os.path.basename(f).endswith(meta.get("signal", "?"))
              or re.search(r"_%s-\d+$" % meta.get("signal", "?"), os.path.basename(f)) is not None, f)
        summary = open(os.path.join(f, "summary.md"), encoding="utf-8").read()
        check("%s: summary.md names the signal" % kind, meta.get("signal", "?") in summary)
        frames = [l for l in summary.split("## Pile du thread fautif", 1)[-1].split("##", 1)[0].splitlines()
                  if re.match(r"^#\d+\s+\S+", l)]
        check("%s: summary.md has a non-empty stack (%d frames)" % (kind, len(frames)),
              len(frames) >= 3, summary[:600])
        check("%s: journal.log ends on the crash" % kind,
              "CRASH" in open(os.path.join(f, "journal.log"), encoding="utf-8").read().splitlines()[-1]
              or any("CRASH" in l for l in open(os.path.join(f, "journal.log"), encoding="utf-8").read().splitlines()[-30:]))
        ips = glob.glob(os.path.join(f, "*.ips"))
        ips_pid = None
        if ips:
            try:
                body = open(ips[0], encoding="utf-8").read().split("\n", 1)[1]
                ips_pid = json.loads(body).get("pid")
            except Exception as e:
                ips_pid = str(e)
        check("%s: .ips of the right pid" % kind, ips_pid == pid, "ips=%s pid=%s" % (ips, ips_pid))
        oslog = os.path.join(f, "oslog.txt")
        check("%s: oslog.txt non-empty" % kind, os.path.exists(oslog) and os.path.getsize(oslog) > 80,
              "%s bytes" % (os.path.getsize(oslog) if os.path.exists(oslog) else "missing"))
    latest = open(os.path.join(d, "LATEST.md"), encoding="utf-8").read() if os.path.exists(
        os.path.join(d, "LATEST.md")) else ""
    check("LATEST.md names the newest folder", last is not None and last.get("dir", "?") in latest, latest[:300])
    check("diag.status.last_crash filled", last is not None and last.get("complete") is True, str(last))
    stop(proc, sock)


def t5_kill9():
    section("T5  kill -9 → abnormal stop, no report")
    d = tmpdir()
    proc, sock = launch(d)
    pid = proc.pid
    with client(sock) as c:
        c.send("project.new")
    proc.kill()
    proc.wait()
    proc2, sock2 = launch(d, extra=["--diag-ips-wait=3"])
    check("reports finished", wait_reports(sock2))
    folders = crash_folders(d)
    check("one folder", len(folders) == 1, str(folders))
    if folders:
        meta = folder_meta(folders[0])
        check("meta: abnormal, no ips", meta.get("abnormal") is True and meta.get("ips_found") is False, str(meta))
        check("name ends with ABNORMAL", folders[0].endswith("ABNORMAL"), folders[0])
        s = open(os.path.join(folders[0], "summary.md"), encoding="utf-8").read()
        check("summary: « arrêt anormal sans rapport »", "arrêt anormal sans rapport" in s, s[:400])
    stop(proc2, sock2)


def t6_mark():
    section("T6  diag.mark → issues/ folder")
    d = tmpdir()
    proc, sock = launch(d)
    with client(sock) as c:
        c.send("project.new")
        c.send("object.add", {"path": BIP, "lane": 0, "start": 0})
        r = c.send("diag.mark", {"note": "le son craque après le split"})
    folder = r["folder"]
    check("folder under issues/", os.path.dirname(folder) == os.path.join(d, "issues"), folder)
    check("note.txt", open(os.path.join(folder, "note.txt"), encoding="utf-8").read().strip()
          == "le son craque après le split")
    try:
        state = json.load(open(os.path.join(folder, "state.json"), encoding="utf-8"))
    except Exception as e:
        state = {"err": str(e)}
    check("state.json: project, selection, transport, undo depth",
          all(k in state for k in ("project.get_state", "selection.get", "transport.state", "annulation")),
          str(list(state)))
    j = open(os.path.join(folder, "journal.log"), encoding="utf-8").read()
    check("journal.log holds the ISSUE line and the API lines",
          " ISSUE " in j and "object.add" in j)
    check("oslog.txt present", os.path.exists(os.path.join(folder, "oslog.txt")))
    latest = open(os.path.join(d, "LATEST.md"), encoding="utf-8").read()
    check("LATEST.md points at it", folder in latest and "problème signalé" in latest, latest[:200])
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
        try:
            c.send("debug.crash", {"kind": "segv"})
        except (ConnectionError, OSError, ValueError):
            pass
    pa.wait(timeout=60)
    with client(sb) as c:
        c.send("project.new")
        check("B survives and answers", c.send("diag.status")["enabled"] is True)
    pc, sc = launch(d, extra=["--diag-ips-wait=40"], wait_socket=240)
    check("reports finished", wait_reports(sc, 200))
    folders = crash_folders(d)
    check("exactly one crash folder", len(folders) == 1, str(folders))
    if folders:
        check("it is A's", folder_meta(folders[0]).get("pid") == pa.pid, str(folder_meta(folders[0])))
    check("B's session left alone (clean_exit false, alive)",
          session_meta(d, pb.pid)["clean_exit"] is False and pb.poll() is None)
    stop(pb, sb)
    stop(pc, sc)


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
            "diag.issue.title", "diag.issue.info", "diag.issue.send", "diag.issue.placeholder",
            "diag.issue.done.title", "diag.issue.done.info"]
    missing = [k for k in keys for l in ("fr", "en", "es")
               if not cat["strings"].get(k, {}).get("localizations", {}).get(l, {}).get("stringUnit", {}).get("value")]
    check("the 10 diag keys exist in fr/en/es", not missing, str(missing))
    r = subprocess.run([sys.executable, os.path.join(HERE, "i18n/xcstrings.py"), "check"], cwd=ROOT,
                       capture_output=True, text=True)
    check("xcstrings check: no diag.* key reported", "diag." not in r.stdout, r.stdout[-300:])


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
