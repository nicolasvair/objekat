#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Reads OBJEKAT's diagnostic journal after the fact — stdlib only, run by hand (by Claude).

The app only WRITES: one file per session in ~/Library/Logs/Objekat/sessions/ (journal + meta).
Everything that interprets it lives here: which sessions died, the system crash report (.ips), the
system log.

    diag_latest.py                     the newest abnormal session OR session with a reported
                                       problem (ISSUE line), in full
    diag_latest.py list [-n 15]        recent sessions, one line each (status: ok / alive / CRASH /
                                       ABNORMAL, + ISSUE count)
    diag_latest.py show <session>      one session in full. <session> = its name, its pid, a part of
                                       its name, or `latest` (the newest, whatever it is)

Options (show and default): --lines N  journal tail length (default 40)
                            --minutes M  journal window instead: the last M minutes of the session
                            --oslog    add `log show` for the session's pid and time window
                            --dir PATH logs folder (default ~/Library/Logs/Objekat)
                            --json     the summary as JSON (list / show)

What "abnormal" means: the session's meta says clean_exit false, its pid no longer runs (or is
another process now) and no EXIT line closes the journal. A session with a CRASH line crashed.
The .ips is looked for in ~/Library/Logs/DiagnosticReports by pid; macOS may write it up to a
minute after the crash (re-run), and a kill -9 leaves none.
"""
import argparse, glob, json, os, re, subprocess, sys, time

DEFAULT_DIR = "~/Library/Logs/Objekat"
REPORTS_DIR = os.path.expanduser("~/Library/Logs/DiagnosticReports")
LINE_RX = re.compile(r"^\d\d:\d\d:\d\d\.\d{3} \+(\d+\.\d+) (\S+)")


# ── reading sessions ──────────────────────────────────────────────────────────────────────────
def read_text(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            return f.read()
    except OSError:
        return ""


def process_alive(pid, start_epoch):
    """Is `pid` still the process that wrote the session (not a zombie, not a reused pid)?"""
    if not pid or pid <= 0:
        return False
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        pass
    out = subprocess.run(["ps", "-p", str(pid), "-o", "stat=,lstart="], capture_output=True, text=True).stdout.split(None, 1)
    if len(out) < 2 or out[0].startswith("Z"):
        return False
    try:
        launched = time.mktime(time.strptime(out[1].strip(), "%a %b %d %H:%M:%S %Y"))
    except ValueError:
        return True
    return launched <= (start_epoch or 0) + 5


class Session:
    def __init__(self, root, base):
        self.base = base
        d = os.path.join(root, "sessions")
        self.log = os.path.join(d, base + ".log")
        self.rotated = os.path.join(d, base + ".log.1")
        try:
            self.meta = json.load(open(os.path.join(d, base + ".meta.json"), encoding="utf-8"))
        except (OSError, ValueError):
            self.meta = {}
        files = [p for p in (self.log, self.rotated) if os.path.exists(p)]
        self.end = max((os.path.getmtime(p) for p in files), default=0.0)
        self.pid = self.meta.get("pid") or int((re.search(r"_pid(\d+)", base) or [0, 0])[1])
        self.start = self.meta.get("start_epoch") or 0
        self._lines = None

    @property
    def lines(self):
        """All the journal's lines, the rotated file first."""
        if self._lines is None:
            text = read_text(self.rotated) + read_text(self.log)
            self._lines = [l for l in text.split("\n") if l.strip()]
        return self._lines

    def category(self, cat):
        return [l for l in self.lines if re.match(r"^\S+ \+\S+ %s\b" % cat, l)]

    @property
    def crash_lines(self):
        return self.category("CRASH")

    @property
    def issues(self):
        return self.category("ISSUE")

    @property
    def exited(self):
        return bool(self.category("EXIT"))

    @property
    def status(self):
        if self.crash_lines:
            return "CRASH"
        if self.meta.get("clean_exit") is True or self.exited:
            return "ok"
        if self.meta and process_alive(self.pid, self.start):
            return "alive"
        return "ABNORMAL"

    @property
    def anomalous(self):
        return self.status in ("CRASH", "ABNORMAL")

    def signal(self):
        for l in self.crash_lines:
            m = re.search(r"signal (SIG\w+)", l)
            if m:
                return m.group(1)
        return None

    def brief(self):
        sig = self.signal()
        return {"session": self.base, "pid": self.pid, "status": self.status, "signal": sig,
                "issues": len(self.issues), "version": self.meta.get("version"),
                "project": self.meta.get("project"), "start": self.meta.get("start"),
                "end": time.strftime("%Y-%m-%dT%H:%M:%S", time.localtime(self.end)) if self.end else None,
                "log": self.log}


def all_sessions(root):
    bases = set()
    for p in glob.glob(os.path.join(root, "sessions", "*")):
        m = re.match(r"(.+_pid\d+)\.(?:log|log\.1|meta\.json)$", os.path.basename(p))
        if m:
            bases.add(m.group(1))
    return sorted((Session(root, b) for b in bases), key=lambda s: (s.end, s.base), reverse=True)


def find_session(sessions, ref):
    if ref == "latest":
        return sessions[0] if sessions else None
    exact = [s for s in sessions if s.base == ref or str(s.pid) == ref or "pid" + ref == s.base.split("_")[-1]]
    part = [s for s in sessions if ref in s.base]
    return (exact or part or [None])[0]


# ── the system crash report ───────────────────────────────────────────────────────────────────
def find_ips(session):
    """The .ips of the session's pid, or None."""
    names = glob.glob(os.path.join(REPORTS_DIR, "*.ips"))
    names = [p for p in names if os.path.getmtime(p) >= (session.start or 0) - 5]
    for path in sorted(names, key=os.path.getmtime, reverse=True):
        try:
            head, body = read_text(path).split("\n", 1)
            data = json.loads(body)
        except ValueError:
            continue
        if data.get("pid") == session.pid and os.path.basename(path).lower().startswith(
                (json.loads(head).get("name") or "objekat").lower()[:4]):
            return path, data
    return None


def frames_of(ips, frames, limit):
    images = ips.get("usedImages") or []
    out = []
    for i, f in enumerate(frames[:limit]):
        idx = f.get("imageIndex", -1)
        image = images[idx].get("name", "?") if 0 <= idx < len(images) else "?"
        if f.get("symbol"):
            what = "%s + %s" % (f["symbol"], f.get("symbolLocation", 0))
            if f.get("sourceFile"):
                what += " (%s:%s)" % (f["sourceFile"], f.get("sourceLine", "?"))
        else:
            what = hex(f.get("imageOffset", 0))
        out.append("#%-2d %-26s %s" % (i, image[:26], what))
    return out


def describe_ips(path, ips, limit=20):
    out = ["Rapport système : %s" % path]
    exc = ips.get("exception") or {}
    out.append("  exception : %s / %s%s" % (exc.get("type", "?"), exc.get("signal", "?"),
                                            " — " + exc["subtype"] if exc.get("subtype") else ""))
    term = ips.get("termination") or {}
    if term:
        out.append("  terminaison : %s %s" % (term.get("namespace", "?"), term.get("indicator", "")))
    for key, value in sorted((ips.get("asi") or {}).items()):
        if isinstance(value, list):
            out += ["  %s : %s" % (key, v) for v in value[:6]]
    threads = ips.get("threads") or []
    idx = ips.get("faultingThread", 0)
    if 0 <= idx < len(threads):
        t = threads[idx]
        out.append("Thread fautif (#%d%s), %d premières frames :" % (
            idx, " " + t["name"] if t.get("name") else "", limit))
        out += ["  " + l for l in frames_of(ips, t.get("frames") or [], limit)]
    last = ips.get("lastExceptionBacktrace")
    if last:
        out.append("Pile de l'exception Objective-C :")
        out += ["  " + l for l in frames_of(ips, last, limit)]
    return out


# ── the system log ────────────────────────────────────────────────────────────────────────────
def oslog_lines(session, keep=150):
    fmt = "%Y-%m-%d %H:%M:%S"
    start = time.strftime(fmt, time.localtime(session.start or session.end - 600))
    end = time.strftime(fmt, time.localtime(session.end + 30))
    cmd = ["/usr/bin/log", "show", "--predicate", "processIdentifier == %d" % session.pid,
           "--start", start, "--end", end, "--style", "compact"]
    head = "$ log show --predicate 'processIdentifier == %d' --start '%s' --end '%s'" % (session.pid, start, end)
    try:
        out = subprocess.run(cmd, capture_output=True, text=True, timeout=90).stdout.splitlines()
    except subprocess.TimeoutExpired:
        return [head, "(interrompu : délai de 90 s dépassé)"]
    shown = out[-keep:]
    return [head, "(%d lignes, les %d dernières)" % (len(out), len(shown))] + shown


# ── the journal's tail ────────────────────────────────────────────────────────────────────────
def tail(session, lines, minutes):
    all_lines = session.lines
    if minutes:
        last = next((float(m.group(1)) for l in reversed(all_lines) if (m := LINE_RX.match(l))), None)
        if last is not None:
            return [l for l in all_lines if (m := LINE_RX.match(l)) is None or float(m.group(1)) >= last - minutes * 60]
    return all_lines[-lines:]


def issue_context(session, count=3, before=12):
    """The `before` lines that precede each of the last `count` ISSUE lines."""
    out = []
    lines = session.lines
    idxs = [i for i, l in enumerate(lines) if re.match(r"^\S+ \+\S+ ISSUE\b", l)][-count:]
    for i in idxs:
        out.append("— avant la ligne ISSUE (%s) —" % lines[i].split(" ", 1)[0])
        out += lines[max(0, i - before):i + 1]
    return out


# ── output ────────────────────────────────────────────────────────────────────────────────────
def show(session, args):
    b = session.brief()
    ips = find_ips(session) if session.status in ("CRASH", "ABNORMAL") or session.crash_lines else None
    if args.json:
        data = dict(b, crash_lines=session.crash_lines, issue_lines=session.issues,
                    ips=ips[0] if ips else None,
                    ips_exception=(ips[1].get("exception") if ips else None),
                    tail=tail(session, args.lines, args.minutes))
        print(json.dumps(data, ensure_ascii=False, indent=2))
        return
    dur = ""
    if session.start and session.end:
        d = max(0, int(session.end - session.start))
        dur = ", %d min %d s" % (d // 60, d % 60)
    print("══ Session %s — %s%s ══" % (b["session"], b["status"], " (" + b["signal"] + ")" if b["signal"] else ""))
    print("OBJEKAT %s, pid %s, démarrée %s, dernière écriture %s%s" % (
        b["version"], b["pid"], b["start"], b["end"], dur))
    print("Projet : %s" % (session.meta.get("project") or "(aucun)"))
    print("macOS : %s   Journal : %s" % (session.meta.get("macos", "?"), session.log))
    if b["status"] == "ABNORMAL":
        print("\nArrêt anormal : ni CRASH ni EXIT en fin de journal, le pid ne tourne plus "
              "(kill -9, « forcer à quitter », coupure…).")
    if session.crash_lines:
        print("\n── CRASH ──")
        print("\n".join(session.crash_lines))
    if session.issues:
        print("\n── Problèmes signalés (%d) ──" % len(session.issues))
        print("\n".join(session.issues))
    if ips:
        print("\n── Rapport système ──")
        print("\n".join(describe_ips(*ips)))
    elif session.status in ("CRASH", "ABNORMAL"):
        print("\n── Rapport système ──\nAucun .ips pour le pid %s dans %s (macOS l'écrit parfois jusqu'à une "
              "minute après le crash : relancer ; un kill -9 n'en laisse pas)." % (session.pid, REPORTS_DIR))
    if session.issues and not session.anomalous:
        print("\n── Contexte des problèmes signalés ──")
        print("\n".join(issue_context(session)))
    t = tail(session, args.lines, args.minutes)
    print("\n── Fin du journal (%d lignes) ──" % len(t))
    print("\n".join(t))
    if args.oslog:
        print("\n── Logs système ──")
        print("\n".join(oslog_lines(session)))


def cmd_list(sessions, args):
    rows = sessions[:args.n]
    if args.json:
        print(json.dumps([s.brief() for s in rows], ensure_ascii=False, indent=2))
        return 0
    if not rows:
        print("Aucune session dans %s." % args.dir)
        return 0
    for s in rows:
        b = s.brief()
        flag = b["status"] + ("/" + b["signal"] if b["signal"] else "")
        extra = "  ISSUE×%d" % b["issues"] if b["issues"] else ""
        print("%-40s %-14s %s%s" % (b["session"], flag, b["project"] or "-", extra))
    return 0


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("command", nargs="?", choices=["list", "show"], help="default: the newest anomaly or ISSUE")
    ap.add_argument("session", nargs="?", help="show: name, pid, part of the name, or `latest`")
    ap.add_argument("-n", type=int, default=15, help="list: how many sessions")
    ap.add_argument("--lines", type=int, default=40)
    ap.add_argument("--minutes", type=float)
    ap.add_argument("--oslog", action="store_true")
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--dir", default=DEFAULT_DIR)
    args = ap.parse_args()
    args.dir = os.path.expanduser(args.dir)
    sessions = all_sessions(args.dir)
    if args.command == "list":
        return cmd_list(sessions, args)
    if args.command == "show":
        s = find_session(sessions, args.session or "latest")
        if not s:
            print("Session introuvable : %s (voir `list`)." % args.session, file=sys.stderr)
            return 1
    else:
        s = next((x for x in sessions if x.anomalous or x.issues), None)
        if not s:
            print("Aucune session anormale ni problème signalé dans %s." % args.dir)
            if sessions:
                print("Dernières sessions :")
                cmd_list(sessions, argparse.Namespace(n=3, json=False, dir=args.dir))
            return 0
    show(s, args)
    return 0


if __name__ == "__main__":
    sys.exit(main())
