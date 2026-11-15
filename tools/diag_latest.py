#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Reads the diagnostic journal's last report (crash or reported problem) — stdlib only.

    python3 tools/diag_latest.py               # LATEST.md + the folder it names (summary/note, journal tail)
    python3 tools/diag_latest.py --list 10     # the 10 newest crash / issue folders, one line each
    python3 tools/diag_latest.py --dir PATH    # another logs folder (default ~/Library/Logs/Objekat)
    python3 tools/diag_latest.py --lines 80     # how much of the journal's tail to show (default 40)

The folders are written by OBJEKAT itself (OBJEKAT ▸ Diagnostic ▸ Journal de diagnostic); see the
README.md it leaves in the logs folder, and docs/command_api.md ("Diagnostic journal").
"""
import argparse, glob, json, os, sys


def default_dir():
    return os.path.expanduser("~/Library/Logs/Objekat")


def read(path, limit=None):
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            text = f.read()
    except OSError:
        return None
    return text if limit is None else text[:limit]


def folder_line(folder):
    kind = "crash" if os.sep + "crashes" + os.sep in folder else "issue"
    meta = {}
    try:
        meta = json.load(open(os.path.join(folder, "meta.json"), encoding="utf-8"))
    except Exception:
        pass
    summary = meta.get("summary")
    if summary is None:
        note = read(os.path.join(folder, "note.txt"), 200)
        summary = (note or "").strip().replace("\n", " ")
    complete = "" if meta.get("complete", True) else "  [incomplete]"
    return "%-6s %s  %s%s" % (kind, os.path.basename(folder), summary, complete)


def all_folders(root):
    out = []
    for sub in ("crashes", "issues"):
        out += [p for p in glob.glob(os.path.join(root, sub, "*")) if os.path.isdir(p)]
    return sorted(out, key=os.path.basename, reverse=True)


def show_latest(root, lines):
    latest = read(os.path.join(root, "LATEST.md"))
    if latest is None:
        print("No LATEST.md in %s — no crash or reported problem recorded." % root)
        return 1
    print(latest.rstrip())
    folder = None
    for l in latest.splitlines():
        if l.startswith("- Dossier :"):
            folder = l.split(":", 1)[1].strip()
    if not folder or not os.path.isdir(folder):
        return 0
    for name in ("summary.md", "note.txt"):
        text = read(os.path.join(folder, name))
        if text:
            print("\n══ %s ══\n%s" % (name, text.rstrip()))
    journal = read(os.path.join(folder, "journal.log"))
    if journal:
        tail = journal.rstrip().splitlines()[-lines:]
        print("\n══ journal.log (last %d lines) ══\n%s" % (len(tail), "\n".join(tail)))
    print("\nFolder: %s" % folder)
    return 0


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--dir", default=default_dir())
    ap.add_argument("--list", type=int, metavar="N")
    ap.add_argument("--lines", type=int, default=40)
    args = ap.parse_args()
    if args.list:
        folders = all_folders(args.dir)[:args.list]
        if not folders:
            print("Nothing in %s." % args.dir)
            return 1
        for f in folders:
            print(folder_line(f))
        return 0
    return show_latest(args.dir, args.lines)


if __name__ == "__main__":
    sys.exit(main())
