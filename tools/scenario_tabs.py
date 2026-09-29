#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Tabs (INC1) — several projects, ONE engine.

What it is out to prove, beyond the commands answering: that parking a document (leaving a
tab) and restoring it (coming back to it) loses NOTHING — not a moved object, not a plugin's
live parameter, not the undo stack, not the dirty flag — and that the workspace refuses a
switch exactly when the plan says it must (a load in flight, an export running) rather than
silently corrupting whatever is mid-gesture.

    # 1. launch the app with the API, on a SHORT socket (a system limit: 103 bytes).
    #    `--no-recent`: the throwaway projects below do not enter "Recent projects".
    objekat.app/Contents/MacOS/objekat --headless --api --no-audio --no-recent --socket=/tmp/o.sock

    # 2. replay (ROOT is a scratch folder for the tab fixtures; it need not exist yet)
    ./scenario_tabs.py /tmp/o.sock /tmp/trial_tabs

Exit: 0 if every assertion passes, 1 otherwise.
"""

import hashlib, json, os, re, subprocess, sys, time, wave

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from objekat_cli import ObjekatClient, ObjekatError

if len(sys.argv) != 3:
    print(__doc__)
    sys.exit(2)

SOCK, ROOT = sys.argv[1], sys.argv[2]
BIP = os.path.join(HERE, "fixtures", "bip.wav")

A_JSON = os.path.join(ROOT, "A", "A.objekat.json")
B_JSON = os.path.join(ROOT, "B", "B.objekat.json")
C_JSON = os.path.join(ROOT, "C", "C.objekat.json")
C2_JSON = os.path.join(ROOT, "C", "C_v2.objekat.json")
E_JSON = os.path.join(ROOT, "E", "E.objekat.json")
for p in (A_JSON, B_JSON, C_JSON, C2_JSON, E_JSON):
    os.makedirs(os.path.dirname(p), exist_ok=True)

fails = []
total = 0


def check(label, ok, detail=""):
    global total
    total += 1
    print(("ok    " if ok else "FAIL  ") + label + ("" if ok else "   " + str(detail)))
    if not ok:
        fails.append(label)


def approx(a, b, eps=1e-6):
    return abs(a - b) < eps


def wav_rms(path):
    """RMS of a 16/24-bit WAV, read in chunks (a 900 s stereo 24-bit file is 240 MB). Re-reading
    the FILE is what proves the render is a sound and not merely a file that exists — 24 bits is
    unpacked by hand (`wave` hands the bytes over as they are, @see the CLI's 24-bit caution)."""
    import numpy as np
    total, count = 0.0, 0
    with wave.open(path, "rb") as w:
        sw, ch = w.getsampwidth(), w.getnchannels()
        while True:
            raw = w.readframes(1 << 20)
            if not raw:
                break
            if sw == 2:
                a = np.frombuffer(raw, dtype="<i2").astype(np.float64) / 32768.0
            elif sw == 3:
                b = np.frombuffer(raw, dtype=np.uint8).reshape(-1, 3).astype(np.int32)
                v = b[:, 0] | (b[:, 1] << 8) | (b[:, 2] << 16)
                v = np.where(v >= 1 << 23, v - (1 << 24), v)
                a = v.astype(np.float64) / 8388608.0
            else:
                raise RuntimeError("unexpected sample width: %d" % sw)
            total += float(np.sum(a * a))
            count += a.size
    return (total / count) ** 0.5 if count else 0.0


def wav_digest(path):
    """A hash of the audio DATA only (the header carries nothing that can differ, but this reads
    the samples and nothing else)."""
    h = hashlib.sha256()
    with wave.open(path, "rb") as w:
        while True:
            raw = w.readframes(1 << 20)
            if not raw:
                break
            h.update(raw)
    return h.hexdigest()


def pid_for_socket(sock_path):
    try:
        out = subprocess.check_output(["lsof", "-t", sock_path], text=True,
                                      stderr=subprocess.DEVNULL)
        pids = [int(p) for p in out.split()]
        return pids[0] if pids else None
    except Exception:
        return None


def window_count_for_pid(pid):
    """Windows the process owns, off the WindowServer's own list (no permission needed). None if
    Quartz is not there to ask."""
    try:
        import Quartz
    except ImportError:
        return None
    info = Quartz.CGWindowListCopyWindowInfo(Quartz.kCGWindowListOptionAll, Quartz.kCGNullWindowID)
    return sum(1 for w in info if w.get("kCGWindowOwnerPID") == pid)


# `project.get_state` is re-serialised through `json.dumps` for the comparison, so the XML's
# quotes come back ESCAPED (`id=\"1038\"`) — the pattern matches that literal text, not raw XML.
_ENGINE_ID_RE = re.compile(r'(id=\\")\d+(\\")')


def normalized_state(state):
    """`project.get_state`, stripped of the ONE thing a round trip is allowed to change: a
    plugin's internal Tracktion `EditItemID` (the `id="…"` inside its `stateXML`), reassigned
    every time `applyProjectDocumentAsync` rebuilds the graph — restoring a parked tab goes
    through that same door. It is an ENGINE bookkeeping number, not part of the document a
    user would recognise: the API's own `plugin.id` (a stable UUID) is untouched by it, and so
    is every parameter value inside the very same `stateXML`."""
    text = json.dumps(state, sort_keys=True)
    return _ENGINE_ID_RE.sub(r"\g<1>0\g<2>", text)


with ObjekatClient(SOCK, timeout=180) as c:

    def cmd(name, **params):
        return c.send(name, params or None)

    def tabs():
        return cmd("tab.list")["tabs"]

    def tab_with_path(path):
        for t in tabs():
            if t["path"] == path:
                return t
        return None

    def settled_params(plugin, want=1, timeout=10.0):
        """The parameters of a live instance, waited for. Used to LOAD, never to assert."""
        deadline = time.time() + timeout
        while time.time() < deadline:
            try:
                ps = cmd("plugin.get_params", plugin=plugin)["params"]
            except ObjekatError:
                ps = []
            if len(ps) >= want:
                return ps
            time.sleep(0.1)
        return []

    # ── setup: app.info before any project touches anything ────────────────
    info = cmd("app.info")
    check("one tab at the start", info.get("tab_count") == 1, str(info.get("tab_count")))
    check("--no-recent honoured", info.get("records_recent_projects") is False)

    # ── build A in the (only, still untitled) tab ───────────────────────────
    cmd("project.new")
    oa = cmd("object.add", path=BIP, lane=0, start=0)["id"]
    cmd("project.save_as", path=A_JSON)
    check("save_as writes into the SAME tab, no tab created", cmd("tab.list")["count"] == 1)

    # ── tab.new: a second, blank tab, made active ───────────────────────────
    t2 = cmd("tab.new")
    check("tab.new answers with the new tab active", t2["active"] is True)
    check("tab.new: now two tabs", len(tabs()) == 2, str(len(tabs())))
    tab_a = tab_with_path(A_JSON)
    check("A is still there, and no longer active", tab_a is not None and tab_a["active"] is False)

    # ── build B in the new tab ───────────────────────────────────────────────
    ob = cmd("object.add", path=BIP, lane=1, start=5)["id"]
    cmd("project.save_as", path=B_JSON)
    tab_b_id = t2["id"]

    # ── tab.open on a file already open in THIS (active) tab: a no-op ───────
    reopened_self = cmd("tab.open", path=B_JSON)
    check("tab.open on the active tab's own file: already_open", reopened_self["already_open"] is True)
    check("tab.open on the active tab's own file: no new tab", cmd("tab.list")["count"] == 2)
    check("tab.open on the active tab's own file: stays there", reopened_self["id"] == tab_b_id)

    # ── tab.open on a file open in ANOTHER tab: switches, no duplicate ──────
    switched = cmd("tab.open", path=A_JSON)
    check("tab.open on another tab's file: already_open", switched["already_open"] is True)
    check("tab.open on another tab's file: switches to it", switched["active"] is True)
    check("tab.open on another tab's file: tab_count unchanged", cmd("tab.list")["count"] == 2)
    tab_a_id = switched["id"]

    # ── a file opened, closed, then reopened is NOT already_open ────────────
    t3 = cmd("tab.new")
    cmd("object.add", path=BIP, lane=0, start=0)
    cmd("project.save_as", path=C_JSON)
    check("building C: three tabs", cmd("tab.list")["count"] == 3)
    cmd("tab.close", id=t3["id"])
    cmd("wait_idle", timeout_ms=10000)
    check("closing C: back to two tabs", cmd("tab.list")["count"] == 2)

    reopened_c = cmd("tab.open", path=C_JSON)
    check("reopening a CLOSED file: not already_open", reopened_c["already_open"] is False)
    check("reopening a CLOSED file: a new tab", cmd("tab.list")["count"] == 3)

    # ── two versions of one folder (V1/V2): renaming the live tab (save_as) frees the
    #    OLD path, so opening it lands as a genuinely SEPARATE tab, side by side with V2 ──
    cmd("project.save_as", path=C2_JSON)
    check("save_as renames the SAME tab in place, still three", cmd("tab.list")["count"] == 3)
    reopened_c_v1 = cmd("tab.open", path=C_JSON)
    check("C.json is free again: not already_open", reopened_c_v1["already_open"] is False)
    check("V1 and V2 now open as two DISTINCT tabs (same folder)", cmd("tab.list")["count"] == 4)
    open_paths = {t["path"] for t in tabs()}
    check("both paths are open", C_JSON in open_paths and C2_JSON in open_paths)

    # tidy the two throwaway C tabs back up before what follows
    for path in (C_JSON, C2_JSON):
        t = tab_with_path(path)
        was_active = t["active"]
        cmd("tab.close", id=t["id"])
        if was_active:
            cmd("wait_idle", timeout_ms=10000)
    check("back to A and B alone", cmd("tab.list")["count"] == 2)

    # ── round trip without loss: move an object and adjust a plugin in A, ───
    #    hop to B and back, and find A byte-for-byte identical ───────────────
    cmd("tab.select", id=tab_a_id)
    check("A is active again", tab_with_path(A_JSON)["active"] is True)

    cmd("object.move", id=oa, lane=2, start=3)
    eq = cmd("plugin.add", host=oa, identifier="4bandEq")["plugin"]["id"]
    ps = settled_params(eq, want=1)
    check("the built-in answers before the round trip", len(ps) >= 1, str(len(ps)))
    if ps:
        p0 = ps[0]
        target = p0["min"] + (p0["max"] - p0["min"]) * 0.8
        cmd("plugin.set_param", plugin=eq, index=0, value=target)

    check("A is dirty after editing", tab_with_path(A_JSON)["dirty"] is True)
    state_before_hop = cmd("project.get_state")

    cmd("tab.select", id=tab_b_id)
    check("B is active, and clean", tab_with_path(B_JSON)["active"] is True
          and tab_with_path(B_JSON)["dirty"] is False)

    cmd("tab.select", id=tab_a_id)
    check("A active again", tab_with_path(A_JSON)["active"] is True)
    state_after_hop = cmd("project.get_state")
    check("round trip through B loses nothing: identical state (engine EditItemIDs excepted)",
          normalized_state(state_before_hop) == normalized_state(state_after_hop))
    check("A is still dirty after the round trip", tab_with_path(A_JSON)["dirty"] is True)
    moved = cmd("object.get", id=oa)
    check("the moved object kept its position through the round trip",
          moved["lane"] == 2 and approx(moved["start"], 3))
    if ps:
        back = cmd("plugin.get_params", plugin=eq)["params"][0]["value"]
        check("the plugin's live value survived the round trip", approx(back, target, eps=1e-3),
              "expected %s, got %s" % (target, back))

    # ── undo after the round trip: A's undo stack came back with it ─────────
    cmd("edit.undo")  # undoes plugin.add (the plugin itself, and its param with it)
    check("undo #1: the plugin is gone", len(cmd("object.get", id=oa).get("plugins", [])) == 0)
    moved_after_undo1 = cmd("object.get", id=oa)
    check("undo #1: the move is untouched", moved_after_undo1["lane"] == 2
          and approx(moved_after_undo1["start"], 3))
    cmd("edit.undo")  # undoes object.move
    restored = cmd("object.get", id=oa)
    check("undo #2: the object is back at its original position",
          restored["lane"] == 0 and approx(restored["start"], 0))

    # ── tab.select by 1-based index (tab.list order) ────────────────────────
    order = tabs()
    cmd("tab.select", index=1)
    check("tab.select {index:1} lands on the first tab in list order",
          tabs()[0]["id"] == order[0]["id"] and tabs()[0]["active"] is True)

    # ── tab.move: the ORDER changes, and nothing else ───────────────────────
    # A third tab so a move has neighbours to close up around it. It is created active (a
    # switch), then left in place while the other two are moved around it.
    t_move = cmd("tab.new")
    cmd("wait_idle", timeout_ms=10000)
    before = tabs()
    ids = [t["id"] for t in before]
    active_id = [t["id"] for t in before if t["active"]][0]
    dirty_before = {t["id"]: t["dirty"] for t in before}
    check("tab.move setup: three tabs, the new one last and active",
          len(ids) == 3 and ids[2] == t_move["id"] and active_id == t_move["id"])

    moved = cmd("tab.move", index=3, to=1)
    check("tab.move {index:3, to:1} answers with the tab at its new index",
          moved["id"] == ids[2] and moved["index"] == 1)
    check("tab.move: the others close up behind it",
          [t["id"] for t in tabs()] == [ids[2], ids[0], ids[1]])
    check("tab.move: the active tab is still the active one",
          [t["id"] for t in tabs() if t["active"]] == [active_id])
    check("tab.move: no dirty flag moved",
          {t["id"]: t["dirty"] for t in tabs()} == dirty_before)

    cmd("tab.move", id=ids[0], to=3)
    check("tab.move {id, to:3}: to the end",
          [t["id"] for t in tabs()] == [ids[2], ids[1], ids[0]])
    cmd("tab.move", id=ids[1], to=2)
    check("tab.move onto its own position: nothing changes",
          [t["id"] for t in tabs()] == [ids[2], ids[1], ids[0]])

    cmd("tab.select", index=3)
    cmd("wait_idle", timeout_ms=10000)
    check("tab.select {index:3} reads the NEW order",
          [t["id"] for t in tabs() if t["active"]] == [ids[0]])

    for bad in (0, 4):
        try:
            cmd("tab.move", id=ids[0], to=bad)
            check("tab.move to=%d: refused" % bad, False, "it went through")
        except ObjekatError as e:
            check("tab.move to=%d: refused" % bad, e.code == "bad_params", e.code)

    cmd("tab.close", id=t_move["id"], discard=True)   # inactive by now: closes synchronously
    cmd("tab.move", id=ids[0], to=1)
    check("tab.move teardown: the two tabs, back in their original order",
          [t["id"] for t in tabs()] == [ids[0], ids[1]])

    # ── playback stops on a switch ───────────────────────────────────────────
    cmd("tab.select", id=tab_a_id)
    cmd("transport.play")
    check("playing", cmd("transport.state")["playing"] is True)
    cmd("tab.select", id=tab_b_id)
    check("switching tabs stops playback", cmd("transport.state")["playing"] is False)

    # ── project.save_as onto another tab's path: already_open ──────────────
    cmd("tab.select", id=tab_a_id)
    try:
        cmd("project.save_as", path=B_JSON)
        check("save_as onto B's path from A: refused", False, "it went through")
    except ObjekatError as e:
        check("save_as onto B's path from A: refused", e.code == "invalid_state", e.code)

    # ── project.open on a path open elsewhere: switches (not tab.open) ─────
    cmd("tab.select", id=tab_a_id)
    opened_b = cmd("project.open", path=B_JSON)
    check("project.open on B's path from A: already_open", opened_b.get("already_open") is True)
    check("project.open on B's path from A: switches", tab_with_path(B_JSON)["active"] is True)
    check("project.open on B's path from A: no duplicate tab", cmd("tab.list")["count"] == 2)

    # ── blocking during an export ────────────────────────────────────────────
    cmd("tab.select", id=tab_a_id)
    job = cmd("export.run", format="wav")["job_id"]
    try:
        cmd("tab.select", id=tab_b_id)
        check("tab.select during export: refused", False, "it went through")
    except ObjekatError as e:
        check("tab.select during export: refused", e.code == "invalid_state", e.code)
    cmd("job.wait", id=job, timeout_ms=30000)
    cmd("wait_idle", timeout_ms=10000)
    cmd("tab.select", id=tab_b_id)
    check("tab.select after the export finishes: works", tab_with_path(B_JSON)["active"] is True)

    # ── a render on a COPY outlives a tab switch (L5) ────────────────────────
    #
    # A background export renders a CLONE of the Edit once it is under way: the hand can go and
    # work in another tab meanwhile, which is the whole point of rendering in the background. Only
    # a DIRECT render (it reads the live Edit) — and the clone being made, `.preparing` — pin the
    # document in front. The file is what says the engine followed and not merely the model: the
    # render taken across three tab switches must be the same SOUND as one taken without moving.
    RANGE = 900.0
    cmd("tab.select", id=tab_b_id)
    t_e = cmd("tab.new")
    tab_e_id = t_e["id"]
    for lane in range(4):
        for k in range(15):
            cmd("object.add", path=BIP, lane=lane, start=60.0 * k + 3.0 * lane)
    cmd("project.save_as", path=E_JSON)
    e_name = tab_with_path(E_JSON)["name"]
    e_objects = len(cmd("object.list")["objects"])
    REF = os.path.join(ROOT, "E", "ref.wav")
    TEST = os.path.join(ROOT, "E", "across_tabs.wav")
    DIRECT = os.path.join(ROOT, "E", "direct.wav")

    def export_args(path, background):
        return dict(format="wav", sample_rate=44100, dithering=False, background=background,
                    start=0.0, end=RANGE, path=path)

    def wait_past_preparing(limit=30.0):
        deadline = time.time() + limit
        while time.time() < deadline:
            st = cmd("export.status")
            if st.get("phase") != "preparing":
                return st
            time.sleep(0.02)
        return cmd("export.status")

    t0 = time.time()
    ref_job = cmd("export.run", **export_args(REF, True))["job_id"]
    cmd("job.wait", id=ref_job, timeout_ms=300000)
    ref_secs = time.time() - t0
    print("      (reference render: %.1f s for %.0f s of audio)" % (ref_secs, RANGE))
    check("reference export written", os.path.exists(REF), REF)
    cmd("export.panel", open=False)

    job = cmd("export.run", **export_args(TEST, True))["job_id"]
    st = cmd("export.status")
    check("export.status carries the project it was launched from",
          st.get("project_name") == e_name and st.get("background") is True, st)
    st = wait_past_preparing()
    check("the render is under way (past preparing)", st.get("running") is True, st)

    try:
        t_new = cmd("tab.new")
        check("tab.new during a background render: works", cmd("tab.list")["count"] >= 4)
    except ObjekatError as e:
        t_new = None
        check("tab.new during a background render: works", False, e.args[0])
    still = cmd("export.status")
    check("the render survived tab.new, project_name unchanged",
          still.get("running") is True and still.get("project_name") == e_name, still)

    for label, tid in (("E", tab_e_id), ("B", tab_b_id)):
        try:
            cmd("tab.select", id=tid)
            check("tab.select %s during a background render: works" % label,
                  [t for t in tabs() if t["id"] == tid][0]["active"] is True)
        except ObjekatError as e:
            check("tab.select %s during a background render: works" % label, False, e.args[0])
    still = cmd("export.status")
    check("the render is still running after tab.new + two switches",
          still.get("running") is True,
          "it ended too early to prove anything — lengthen RANGE: %s" % still)
    check("export.status.project_name is still the origin's, from another tab",
          still.get("project_name") == e_name, still)

    # The strip's Show button, through its API door: the panel comes back ONTO the running job.
    # No window may appear on a headless instance — the flag is state, the sheet is ContentView's.
    pid = pid_for_socket(SOCK)
    panel = cmd("export.panel", open=True)
    check("export.panel during a job: open", panel.get("open") is True, panel)
    check("export.status.panel_open", cmd("export.status").get("panel_open") is True)
    if pid is not None:
        wc = window_count_for_pid(pid)
        check("no window on the headless pid", wc in (0, None), wc)
    cmd("export.panel", open=False)

    cmd("job.wait", id=job, timeout_ms=300000)
    done = cmd("export.status")
    check("the render finished", done.get("phase") == "finished", done)
    check("export.status.project_name survives the end", done.get("project_name") == e_name, done)
    check("the final file exists", os.path.exists(TEST), TEST)
    if os.path.exists(TEST) and os.path.exists(REF):
        r_ref, r_test = wav_rms(REF), wav_rms(TEST)
        check("real signal in the render", r_ref > 0.001, r_ref)
        check("RMS equals the reference render's (no tab change)",
              abs(r_test - r_ref) <= 1e-9 + 1e-6 * r_ref, "%.9f vs %.9f" % (r_test, r_ref))
        check("and so do the samples", wav_digest(TEST) == wav_digest(REF))

    # DIRECT: the live Edit is being read, so everything that would replace or park it is refused.
    cmd("tab.select", id=tab_e_id)
    dj = cmd("export.run", **export_args(DIRECT, False))["job_id"]
    check("a direct render is running", cmd("export.status").get("running") is True)

    def refused(label, fn):
        try:
            fn()
            check(label + ": refused", False, "it went through")
        except ObjekatError as e:
            check(label + ": refused", e.code == "invalid_state", e.code)

    refused("tab.select during a DIRECT render", lambda: cmd("tab.select", id=tab_b_id))
    refused("tab.new during a DIRECT render", lambda: cmd("tab.new"))
    refused("project.new during a DIRECT render", lambda: cmd("project.new"))
    refused("project.open during a DIRECT render", lambda: cmd("project.open", path=A_JSON))
    refused("tab.open during a DIRECT render", lambda: cmd("tab.open", path=C_JSON))
    check("the project is untouched by the refusals",
          len(cmd("object.list")["objects"]) == e_objects
          and cmd("export.status").get("running") is True)
    cmd("job.wait", id=dj, timeout_ms=300000)
    check("the direct render finished", cmd("export.status").get("phase") == "finished")
    cmd("tab.select", id=tab_b_id)
    check("tab.select works again once it ends", [t for t in tabs() if t["id"] == tab_b_id][0]["active"])
    for t in list(tabs()):
        if t["id"] not in (tab_a_id, tab_b_id):
            cmd("tab.close", id=t["id"], discard=True)
    check("the L5 tabs are closed", cmd("tab.list")["count"] == 2, cmd("tab.list")["count"])
    cmd("export.panel", open=False)

    # ── closing: a dirty tab refuses, discard forces it, the last tab never closes ──
    cmd("tab.select", id=tab_a_id)
    t_scratch = cmd("tab.new")
    cmd("object.add", path=BIP, lane=0, start=0)
    dirty_scratch = [t for t in tabs() if t["id"] == t_scratch["id"]][0]
    check("the scratch tab (unsaved) is dirty", dirty_scratch["dirty"] is True)

    try:
        cmd("tab.close", id=t_scratch["id"])
        check("closing a dirty tab without discard: refused", False, "it went through")
    except ObjekatError as e:
        check("closing a dirty tab without discard: refused", e.code == "invalid_state", e.code)

    was_active = [t for t in tabs() if t["id"] == t_scratch["id"]][0]["active"]
    cmd("tab.close", id=t_scratch["id"], discard=True)
    if was_active:
        cmd("wait_idle", timeout_ms=10000)
    check("closing with discard: the tab is gone",
          all(t["id"] != t_scratch["id"] for t in tabs()))

    # close every remaining tab but one
    for t in list(tabs())[1:]:
        was_active = t["active"]
        try:
            cmd("tab.close", id=t["id"])
        except ObjekatError:
            cmd("tab.close", id=t["id"], discard=True)
        if was_active:
            cmd("wait_idle", timeout_ms=10000)
    check("down to a single tab", cmd("tab.list")["count"] == 1)

    try:
        cmd("tab.close", id=tabs()[0]["id"])
        check("the last tab cannot be closed: refused", False, "it went through")
    except ObjekatError as e:
        check("the last tab cannot be closed: refused", e.code == "invalid_state", e.code)

print("\n%d assertion(s), %s" % (total, "ALL PASS" if not fails else "%d FAILED: %s" % (len(fails), fails)))
sys.exit(1 if fails else 0)
