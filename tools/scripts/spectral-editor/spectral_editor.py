#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Spectral editor — a spectrogram of ONE object, edited by hand with gain only (attenuate, or boost).

The script renders the object (exactly as `retouche-externe` does), computes its STFT, opens a canvas
(`script.canvas.*`, @see docs/plan_spectral_editor.md, section 9) with the spectrogram and the rectangle /
brush tools, and keeps three things up to date for the app: the SPECTROGRAM ITSELF (recomputed from the
result of the committed steps, so what is applied is SEEN in the picture, with no overlay), the
SELECTION layer (the pending selection, in amber) and the audio preview (result and delta) that the
ear compares. The preview opens on the result; the controls, the mode and the tool are remembered. The canvas has two modes (`modes: true`): Instant, where each gesture is a step,
and Selection, where gestures build a weighted selection that the hand tunes live (gain, feathers)
before the app's Apply seals it into ONE step. A live tweak never touches the history: only the
selection layer (a feather) and the audio are recomputed. Validate writes what is HEARD — the committed
steps and the pending selection at the current values — as a wav and lays it back like
`retouche-externe`: a new row at the same instant (inside the same group if any), named
"<name> (spectral)", the original MUTED, all in one `batch` (ONE undo). Cancel leaves the session
untouched.

Contract with the app: a separate process that talks to the socket (@see docs/command_api.md,
"Third-party scripts"). Human messages go to stderr with exit != 0 — the app surfaces them.

All the gain mathematics lives in `mask.py`; the app knows gestures, never gain. One connection, one
loop (a connection serves its requests one after another): wait, compute, update.

Format of the file laid back (spec 2): same sample rate and bit depth class as the source file
(16-bit -> 16, 24-bit -> 24, 32-bit float -> float, anything else -> 24), MONO when the two channels
of the render are identical sample for sample, stereo otherwise. Over 120 s the script warns (the
resolution degrades), over 600 s it refuses.

Testing hooks: `--object ID` (instead of OBJEKAT_OBJECT_IDS), OBJEKAT_SPECTRAL_CACHE (the work folder),
OBJEKAT_SPECTRAL_REMEMBER (the key under which the app remembers the controls: a test gives its own, so
that it neither reads nor writes what the user left).
"""

import json
import os
import shutil
import signal
import socket
import sys
import uuid

HERE = os.path.dirname(os.path.realpath(__file__))
sys.path.insert(0, HERE)

import numpy as np  # noqa: E402

import decide  # noqa: E402
import dsp  # noqa: E402
import image  # noqa: E402
import mask  # noqa: E402
import reassign  # noqa: E402
import selection  # noqa: E402
import wavio  # noqa: E402

SOCK = os.environ.get("OBJEKAT_SOCKET")
LANG = (os.environ.get("OBJEKAT_LANGUAGE") or "en")[:2]
LANG = LANG if LANG in ("fr", "en", "es") else "en"
FALLBACK_RATE = 48000  # an object with no audio file (MIDI...)
FFT_SIZES = (1024, 2048, 4096, 8192, 16384, 32768)
DEFAULT_FFT = 2048
DEFAULT_OVERLAP = 4
F_MIN = image.F_MIN


def tr(fr, en, es):
    return {"fr": fr, "en": en, "es": es}[LANG]


class ApiError(RuntimeError):
    """The app answered an error: `code` is its stable code."""

    def __init__(self, payload):
        payload = payload if isinstance(payload, dict) else {"message": str(payload)}
        self.code = payload.get("code", "unknown")
        self.message = payload.get("message", "")
        super().__init__("%s: %s" % (self.code, self.message))


class Objekat:
    """Minimal JSON-lines client, copied out on purpose (@see tools/example-script/report.py)."""

    def __init__(self, path):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(900)
        self.sock.connect(path)
        self.buffer = b""
        self.next_id = 0

    def send(self, cmd, params=None):
        self.next_id += 1
        request = {"id": self.next_id, "cmd": cmd}
        if params:
            request["params"] = params
        self.sock.sendall(json.dumps(request).encode("utf-8") + b"\n")
        while b"\n" not in self.buffer:
            chunk = self.sock.recv(65536)
            if not chunk:
                raise ConnectionError("connection closed by the application")
            self.buffer += chunk
        line, self.buffer = self.buffer.split(b"\n", 1)
        response = json.loads(line)
        if not response.get("ok"):
            raise ApiError(response.get("error"))
        return response["result"]


class Failure(Exception):
    """A message meant for the user (stderr, exit 1)."""


# --- the object ------------------------------------------------------------------------------

def descendants(app, obj):
    """The object and everything below it (whatever the depth), from `object.list`."""
    objects = app.send("object.list").get("objects", [])
    below = {obj["id"]}
    grew = True
    while grew:
        grew = False
        for o in objects:
            if o.get("parent") in below and o["id"] not in below:
                below.add(o["id"])
                grew = True
    return [o for o in objects if o["id"] in below]


def source_formats(app, obj):
    """[(sample_rate, bit_depth, format)] — one per audio file read by the object (its own file, or the
    files of every clip below a group), from `object.get`'s `source_*` fields. A file is asked once."""
    seen = {}
    for o in descendants(app, obj):
        path = o.get("file")
        if o.get("kind") != "clip" or not path or path in seen:
            continue
        g = app.send("object.get", {"id": o["id"]})
        seen[path] = (g.get("source_sample_rate"), g.get("source_bit_depth"), g.get("source_format"))
    return list(seen.values())


def choose_rate(app, rates):
    """The object's sources do not agree on a rate: ask. Returns the chosen rate, or None if cancelled."""
    ordered = sorted(rates, key=lambda r: (-rates[r], r))  # the most used first = the default
    panel = app.send("script.panel.open", {
        "title": tr("Éditeur spectral", "Spectral editor", "Editor espectral"),
        "controls": [{"id": "rate", "kind": "choice",
                      "label": tr("Fréquence d'échantillonnage", "Sample rate", "Frecuencia de muestreo"),
                      "value": str(ordered[0]),
                      "options": [{"id": str(r), "label": "%d Hz  (%d)" % (r, rates[r])} for r in ordered]}],
        "status": tr("Les fichiers de ce groupe n'ont pas tous la même fréquence : laquelle utiliser ?",
                     "The files in this group do not share one sample rate: which one to use?",
                     "Los archivos de este grupo no comparten frecuencia: ¿cuál usar?"),
    })
    pid, rev = panel["panel_id"], panel.get("rev", 0)
    try:
        while True:
            state = app.send("script.panel.wait", {"panel_id": pid, "since_rev": rev, "timeout_ms": 2000})
            rev = state.get("rev", rev)
            if state.get("state") == "validated":
                return int((state.get("values") or {}).get("rate") or ordered[0])
            if state.get("state") in ("cancelled", "closed"):
                return None
    finally:
        try:
            app.send("script.panel.close", {"panel_id": pid})
        except Exception:  # noqa: BLE001
            pass


def render_object(app, obj, out_path, sample_rate, bit_depth):
    """Renders `obj` ALONE (the object and what belongs to it, nothing of its surroundings — a direct
    solo only guarantees it is audible, restored afterwards) over its own span into out_path."""
    before = app.send("solo.get")
    previous = before.get("confirmed") or []
    app.send("solo.clear")
    app.send("solo.set", {"ids": [obj["id"]]})
    try:
        job = app.send("object.render_isolated", {
            "id": obj["id"], "path": out_path,
            "sample_rate": sample_rate, "bit_depth": bit_depth,
            "start": obj["start"], "end": obj["start"] + obj["duration"],
        })
        while True:
            try:
                state = app.send("job.wait", {"id": job["job_id"], "timeout_ms": 5000})
            except ApiError as e:
                if e.code == "timeout" or "timeout" in str(e).lower() or "still running" in str(e).lower():
                    continue  # job.wait answers a timeout as an error: ask again
                raise
            break
        if state.get("state") != "done":
            raise Failure(tr("Le rendu a échoué (%s).", "The render failed (%s).",
                             "El renderizado falló (%s).") % (state.get("error") or state.get("state")))
    finally:
        app.send("solo.clear")
        if previous:
            app.send("solo.set", {"ids": previous})
    if not os.path.exists(out_path):
        raise Failure(tr("Le rendu n'a produit aucun fichier.", "The render produced no file.",
                         "El renderizado no produjo ningún archivo."))


def next_free_lane(app):
    roots = [o for o in app.send("object.list").get("objects", []) if not o.get("parent")]
    return max([o.get("display_lane", 0) + o.get("expanded_span", 0) for o in roots] + [-1]) + 1


def output_folder(app):
    info = app.send("app.info")
    project_path = info.get("project_path")
    if project_path:
        base = os.path.join(os.path.dirname(project_path), "samples", "spectral")
    else:
        base = os.path.join(os.path.expanduser("~/Library/Application Support/Objekat"), "Spectral")
    os.makedirs(base, exist_ok=True)
    return base


# --- the canvas ------------------------------------------------------------------------------

def canvas_controls():
    def num(cid, label, lo, hi, step, value, unit, **extra):
        c = {"id": cid, "kind": "number", "label": label, "min": lo, "max": hi, "step": step,
             "value": value, "unit": unit}
        c.update(extra)
        return c

    return [
        # ONE gain serves both tools; with the feathers it is what a pending selection tunes live. It is a
        # row of buttons (revision 6b: `presets`, one selected at a time), not a slider; the app snaps every
        # value to the nearest preset, so the script only ever reads one of them back.
        {"id": "sec_gain", "kind": "section", "label": tr("Gain", "Gain", "Ganancia")},
        num("gain", tr("Gain", "Gain", "Ganancia"), min(decide.GAIN_PRESETS), max(decide.GAIN_PRESETS), 1,
            decide.GAIN_DEFAULT, "dB", presets=list(decide.GAIN_PRESETS)),
        num("feather_ms", tr("Fondu en temps", "Time feather", "Suavizado en tiempo"), 0, 1000, 1, 10, "ms"),
        num("feather_st", tr("Fondu en fréquence", "Frequency feather", "Suavizado en frecuencia"), 0, 12, 0.1, 1, "st"),
        {"id": "sec_brush", "kind": "section", "label": tr("Pinceau", "Brush", "Pincel")},
        num("size_px", tr("Taille", "Size", "Tamaño"), 4, 200, 1, 32, "px"),
        # A pass deposits this share of selection; with the default gain (-12 dB) 25 % = -3 dB.
        num("quantity", tr("Quantité par passage", "Amount per pass", "Cantidad por pasada"), 1, 100, 1, 25, "%"),
        num("hardness", tr("Dureté", "Hardness", "Dureza"), 0, 100, 1, 50, "%"),
        {"id": "sec_analysis", "kind": "section", "label": tr("Analyse", "Analysis", "Análisis"), "advanced": True},
        {"id": "fft_size", "kind": "choice", "label": tr("Taille de FFT", "FFT size", "Tamaño de FFT"),
         "value": str(DEFAULT_FFT), "options": [{"id": str(n), "label": str(n)} for n in FFT_SIZES], "advanced": True},
        num("overlap", tr("Recouvrement", "Overlap", "Solapamiento"), 2, 10, 1, DEFAULT_OVERLAP, "", advanced=True),
        # Display only (revision 6): the range of levels the pictures span. It is a view setting, not a
        # gesture parameter, so it sits with the other settings that a step does not own (`advanced`).
        {"id": "sec_display", "kind": "section", "label": tr("Affichage", "Display", "Visualización"), "advanced": True},
        num("db_floor", tr("Plancher du spectrogramme", "Spectrogram floor", "Suelo del espectrograma"),
            decide.DB_FLOOR[0], decide.DB_FLOOR[1], 1, decide.DB_FLOOR[2], "dB", advanced=True),
        num("db_ceiling", tr("Plafond du spectrogramme", "Spectrogram ceiling", "Techo del espectrograma"),
            decide.DB_CEIL[0], decide.DB_CEIL[1], 1, decide.DB_CEIL[2], "dB", advanced=True),
        # Revision 7, for testing — DISPLAY ONLY: the pictures drawn as a reassigned ("focused") spectrogram. The mask and
        # the STFT / ISTFT that make the sound stay the plain FFT of "FFT size" / "Overlap" above, whatever is chosen here.
        {"id": "sec_focus", "kind": "section", "advanced": True,
         "label": tr("Concentré (affichage seul)", "Focused (display only)", "Concentrado (solo visualización)")},
        {"id": "display_mode", "kind": "choice", "advanced": True,
         "label": tr("Mode d'affichage", "Display mode", "Modo de visualización"), "value": decide.DISPLAY_NORMAL,
         "options": [{"id": decide.DISPLAY_NORMAL, "label": tr("Normal", "Normal", "Normal")},
                     {"id": decide.DISPLAY_FOCUSED, "label": tr("Concentré", "Focused", "Concentrado")}]},
        {"id": "focus_window", "kind": "choice", "advanced": True,
         "label": tr("Fenêtre d'analyse (Concentré)", "Analysis window (Focused)", "Ventana de análisis (Concentrado)"),
         "value": str(decide.FOCUS_WINDOW_DEFAULT), "options": [{"id": str(n), "label": str(n)} for n in decide.FOCUS_WINDOWS]},
        {"id": "focus_pad", "kind": "choice", "advanced": True,
         "label": tr("Taille de calcul (Concentré)", "Compute size (Focused)", "Tamaño de cálculo (Concentrado)"),
         "value": str(decide.FOCUS_PAD_DEFAULT), "options": [{"id": str(n), "label": str(n)} for n in decide.FOCUS_PADS]},
        num("focus_overlap", tr("Recouvrement d'affichage (Concentré)", "Display overlap (Focused)",
                                "Solapamiento de visualización (Concentrado)"),
            decide.FOCUS_OVERLAP[0], decide.FOCUS_OVERLAP[1], 1, decide.FOCUS_OVERLAP[2], "", advanced=True),
        num("focus_threshold", tr("Seuil (Concentré)", "Threshold (Focused)", "Umbral (Concentrado)"),
            decide.FOCUS_THRESHOLD[0], decide.FOCUS_THRESHOLD[1], 1, decide.FOCUS_THRESHOLD[2], "dB", advanced=True),
    ]


def remember_key():
    """The key under which the app remembers the controls, the mode and the tool between sessions."""
    return os.environ.get("OBJEKAT_SPECTRAL_REMEMBER") or "spectral-editor"


def canvas_tools():
    # The rectangle's feathers come from the step's `params` (so they can be tuned live on a selection),
    # not from the op: it declares no params of its own.
    return [
        {"id": "rect", "kind": "rect", "label": tr("Rectangle", "Rectangle", "Rectángulo"), "params": []},
        {"id": "brush", "kind": "stroke", "label": tr("Pinceau", "Brush", "Pincel"), "icon": "paintbrush.pointed",
         "params": ["quantity", "hardness"], "size_control": "size_px"},
    ]


def analysis_settings(values):
    """(fft size, overlap) from the side bar's values, clamped to what is allowed."""
    try:
        n = int(float(values.get("fft_size")))
    except (TypeError, ValueError):
        n = DEFAULT_FFT
    if n not in FFT_SIZES:
        n = DEFAULT_FFT
    try:
        k = int(round(float(values.get("overlap"))))
    except (TypeError, ValueError):
        k = DEFAULT_OVERLAP
    return n, min(10, max(2, k))


def live_values(values):
    """The three tunable values of a pending selection, as the mask reads them (`mask.step_values`)."""
    return {k: (values or {}).get(k) for k in decide.LIVE_KEYS}


class Editor:
    """The state of one editing session: the signal, the canvas, what has been sent to the app."""

    def __init__(self, app, canvas_id, work, x, sr, warn_text):
        self.app = app
        self.cid = canvas_id
        self.work = work
        self.x = x  # float32 (frames, channels)
        self.sr = sr
        self.warn_text = warn_text
        self.seq = 0
        self.world = {"x": {"min": 0.0, "max": x.shape[0] / float(sr), "unit": "s", "mapping": "lin"},
                      "y": {"min": F_MIN, "max": sr / 2.0, "unit": "Hz", "mapping": "log"}}
        self.selection = selection.SelectionCache()
        self.mask_cache = {}
        self.fft = None            # (n, k) of the base image and of the result
        self.original_fft = None   # (n, k) the Original's picture (the `original` slot's) was drawn for
        self.delta_key = None      # (committed steps, n, k) the Difference's picture was drawn for
        self.hist = None           # the last history WITH entries (the app omits them while the rev holds)
        self.prev_values = None    # the side bar's values at the last sync (None = not seen yet)
        self.image_steps = None    # the committed steps the base image shows (None = not drawn yet)
        self.committed = None      # (steps, n, k, y): the audio through the committed steps only
        self.sel_key = None        # (history rev, feathers) of the selection layer on screen (None = none)
        self.audio_key = None      # (history rev, n, k, live) the app's audio preview was computed for
        self.result = x            # the result in memory (float32); the original until the first op
        self.result_key = None     # the key `result` was computed for
        self.files = {}            # kind -> [(seq, path)]
        # Revision 6: the display range (dB floor, ceiling) and the levels the three pictures were drawn
        # from, kept as dB so that a new range only re-quantises them (no transform). `shown` is the range
        # each picture on screen was written for; `pic_rev` the history rev its set_image carried.
        self.range = decide.display_range({})
        self.db = {"base": None, "original": None, "delta": None}
        self.shown = {"base": None, "original": None, "delta": None}
        self.pic_rev = {"base": 0, "delta": 0}
        # Revision 7: the FOCUSED display (None = Normal, else the reassignment's (window, pad, overlap, threshold)) the pictures
        # are to be drawn with, and the one they were drawn with. DISPLAY ONLY: the audio never reads it.
        self.focus = None
        self.focus_drawn = None

    # -- the app ---------------------------------------------------------------------------

    def update(self, **kw):
        kw["canvas_id"] = self.cid
        self.app.send("script.canvas.update", kw)

    def status(self, steps, pending):
        text = tr("%d étape(s)", "%d step(s)", "%d paso(s)") % len(steps)
        if pending:
            text += tr(" — sélection : %d geste(s)", " — selection: %d gesture(s)",
                       " — selección: %d gesto(s)") % pending
        if self.focus is not None:   # the picture is not the transform that makes the sound: say so
            text += " — " + tr("Concentré (affichage seul)", "Focused (display only)", "Concentrado (solo visualización)")
        return "%s — %s" % (self.warn_text, text) if self.warn_text else text

    def remember_file(self, kind, path):
        """Keeps the last two files of a kind (the previous one may still be playing), removes older."""
        lst = self.files.setdefault(kind, [])
        lst.append((self.seq, path))
        while len(lst) > 2:
            _, old = lst.pop(0)
            try:
                os.remove(old)
            except OSError:
                pass

    # -- the base image -------------------------------------------------------------------

    def focus_tag(self):
        """What the pictures' cache keys add to (n, k): nothing in Normal (the keys keep their old shape), the focus otherwise."""
        return () if self.focus is None else (self.focus,)

    def picture_db(self, signal, n, k):
        """The levels of a picture of `signal`: the plain STFT of (n, k), or the focused (reassigned) display. Same grid."""
        if self.focus is None:
            return image.build_db(signal, self.sr, n, k)
        window, pad, overlap, threshold = self.focus
        return reassign.build_db(signal, self.sr, window, pad, overlap, threshold)

    def blank_picture_db(self, length, n, k):
        """The levels of silence, shaped like `picture_db`'s."""
        if self.focus is None:
            return image.blank_db(length, n, k)
        return reassign.blank_db(length, self.focus[0], self.focus[2])

    def send_base(self, y, n, k, steps, rev):
        """The spectrogram of `y` (the result of the COMMITTED steps; the original when there are none)
        as the base image — the RESULT's picture — stamped with the history rev so the app lets the raw
        traces of the gestures go: what is applied is seen in the picture itself, not under an overlay.

        The ORIGINAL's picture goes with it as the `original` slot's (the app draws the picture of the slot
        being heard): it never changes, so it is made once per (n, k) — and, with no step, it IS the base
        image, which is sent twice (the second time as a copy: the retention of base pictures must not take it)."""
        self.seq += 1
        path = os.path.join(self.work, "base-%d.objkcnv" % self.seq)
        floor, ceil = self.range
        base_db = self.picture_db(y, n, k).astype(np.float32)
        image.write_db_image(path, base_db, floor, ceil)
        self.app.send("script.canvas.set_image", {
            "canvas_id": self.cid, "path": path, "x": self.world["x"], "y": self.world["y"],
            "value_unit": "dB", "history_rev": rev})
        self.remember_file("base", path)
        self.db["base"], self.shown["base"], self.pic_rev["base"] = base_db, self.range, rev
        if self.original_fft != (n, k) + self.focus_tag():
            self.seq += 1
            opath = os.path.join(self.work, "original-%d.objkcnv" % self.seq)
            if steps:
                orig_db = self.picture_db(self.x, n, k).astype(np.float32)
                image.write_db_image(opath, orig_db, floor, ceil)
            else:
                orig_db = base_db
                shutil.copyfile(path, opath)   # the base image IS the original's: a file of its own, though
            self.app.send("script.canvas.set_image", {"canvas_id": self.cid, "slot": "original", "path": opath})
            self.remember_file("original", opath)
            self.db["original"], self.shown["original"] = orig_db, self.range
            self.original_fft = (n, k) + self.focus_tag()
        self.fft = (n, k)
        self.focus_drawn = self.focus
        self.image_steps = steps
        # The world is constant for a session, so the app keeps the layers (the selection layer stays).

    def send_delta_image(self, steps, n, k, rev):
        """The picture of the DIFFERENCE (original - committed result) as the `delta` slot's, so that the
        spectrogram follows the ear when it listens to what the operations take away. Sent AFTER the
        picture and the audio have settled (it is the one the hand needs last), and only when the
        committed steps or the analysis changed: a live tweak of a pending selection never redraws it.
        With no step it is silence, a blank picture that costs no transform."""
        key = (steps, n, k) + self.focus_tag()
        if self.delta_key == key:
            return
        self.seq += 1
        path = os.path.join(self.work, "delta-%d.objkcnv" % self.seq)
        if steps:
            delta_db = self.picture_db(self.x - self.committed_result(steps, n, k), n, k).astype(np.float32)
        else:
            delta_db = self.blank_picture_db(self.x.shape[0], n, k)
        image.write_db_image(path, delta_db, *self.range)
        self.app.send("script.canvas.set_image", {"canvas_id": self.cid, "slot": "delta", "path": path,
                                                  "history_rev": rev})
        self.remember_file("delta-image", path)
        self.db["delta"], self.shown["delta"], self.pic_rev["delta"] = delta_db, self.range, rev
        self.delta_key = key

    def recolour(self):
        """The pictures on screen whose display range is not the hand's any more are written again from the
        levels kept in memory (a quantisation, no transform) and sent as they were — same slot, same history
        rev, so what the app does with traces and layers does not move. Display only: no audio, no history."""
        floor, ceil = self.range
        for slot in ("base", "original", "delta"):
            db = self.db[slot]
            if db is None or self.shown[slot] == self.range:
                continue
            self.seq += 1
            path = os.path.join(self.work, "%s-%d.objkcnv" % (slot, self.seq))
            image.write_db_image(path, db, floor, ceil)
            params = {"canvas_id": self.cid, "path": path}
            if slot == "base":
                params.update({"x": self.world["x"], "y": self.world["y"], "value_unit": "dB",
                               "history_rev": self.pic_rev["base"]})
            else:
                params["slot"] = slot
                if slot == "delta":
                    params["history_rev"] = self.pic_rev["delta"]
            self.app.send("script.canvas.set_image", params)
            self.remember_file({"base": "base", "original": "original", "delta": "delta-image"}[slot], path)
            self.shown[slot] = self.range

    # -- the selection, the committed result and the audio -----------------------------------------------

    def read_history(self, st):
        """The history of an answer. Its entries are cached while the rev does not move (the app omits
        them when `known_history_rev` is the current rev). Returns (hist, steps, drafts, pending)."""
        hist = st["history"]
        if "entries" in hist:
            self.hist = hist
        hist = self.hist
        steps, drafts = mask.split_history(hist)
        return hist, steps, drafts, hist["pending"]

    def send_selection(self, hist, drafts, values):
        """The pending selection as an amber layer over the spectrogram, or no layer when nothing is pending.
        Stamped with the history rev, so the app lets the raw traces of the drafts go."""
        if not drafts:
            self.app.send("script.canvas.set_layer", {"canvas_id": self.cid, "layer": "selection", "path": None})
            self.sel_key = None
            return
        fms, fst = mask.step_values(live_values(values))[1:]
        s = self.selection.update(drafts, self.world, fms, fst)
        self.seq += 1
        path = os.path.join(self.work, "selection-%d.objkrgb" % self.seq)
        selection.write_selection(path, s)
        self.app.send("script.canvas.set_layer", {
            "canvas_id": self.cid, "layer": "selection", "path": path, "z": 2, "history_rev": hist["rev"]})
        self.remember_file("selection", path)
        self.sel_key = (hist["rev"], fms, fst)

    def audio_key_for(self, hist, pending, n, k, values):
        live = tuple(live_values(values)[key] for key in decide.LIVE_KEYS) if pending else None
        return (hist["rev"], n, k, live)

    def committed_result(self, steps, n, k):
        """The audio through the COMMITTED steps only (what the picture shows); the original when there
        are none. Cached: an Apply, an undo or a redo computes it once for the picture AND the ear."""
        if not steps:
            return self.x
        if self.committed is None or self.committed[:3] != (steps, n, k):
            fn = mask.stft_gain_block_fn(steps, [], None, self.world, self.sr, n, k, self.mask_cache)
            self.committed = (steps, n, k, dsp.process(self.x, self.sr, n, k, fn, np.float32))
        return self.committed[3]

    def compute_result(self, steps, drafts, values, n, k, key):
        """The audio through the mask of the committed steps and, when something is pending, of the
        pending selection at the CURRENT values. Cached per key; with nothing pending it IS the
        committed result (shared with the picture)."""
        if self.result_key != key:
            if drafts:
                fn = mask.stft_gain_block_fn(steps, drafts, live_values(values), self.world, self.sr, n, k,
                                             self.mask_cache)
                self.result = dsp.process(self.x, self.sr, n, k, fn, np.float32)
            else:
                self.result = self.committed_result(steps, n, k)
            self.result_key = key
        return self.result

    def send_audio(self, hist, steps, drafts, values, n, k, key):
        y = self.compute_result(steps, drafts, values, n, k, key)
        self.seq += 1
        rpath = os.path.join(self.work, "result-%d.wav" % self.seq)
        dpath = os.path.join(self.work, "delta-%d.wav" % self.seq)
        wavio.write_wav(rpath, y, self.sr, "f32")
        wavio.write_wav(dpath, self.x - y, self.sr, "f32")
        self.app.send("script.canvas.set_audio", {
            "canvas_id": self.cid, "result": rpath, "delta": dpath, "history_rev": hist["rev"]})
        self.remember_file("result", rpath)
        self.remember_file("delta", dpath)
        self.audio_key = key

    # -- the loop ----------------------------------------------------------------------------

    def sync(self, st):
        """Brings the app up to date with an answer, in this order: `busy`, the selection layer, the
        spectrogram (only when the COMMITTED steps changed), the audio, `busy` off. A live tweak (the gain, a
        feather) never touches the history: it moves the audio, and the selection layer for a feather."""
        hist, steps, drafts, pending = self.read_history(st)
        values = st.get("values") or {}
        n, k = analysis_settings(values)
        analysis_changed = (n, k) != self.fft
        self.range = decide.display_range(values)   # the pictures written from here on use it; `recolour` catches up the others
        self.focus = decide.focus_settings(values)   # likewise for the display mode (the audio does not read it)
        # What a change of the side bar's values makes stale while a selection is pending.
        dirty = decide.preview_dirty(self.prev_values, values, pending)
        if "selection" in dirty:
            self.sel_key = None
        if "audio" in dirty:
            self.audio_key = None
        fms, fst = mask.step_values(live_values(values))[1:] if pending else (None, None)
        sel_stale = (self.sel_key != (hist["rev"], fms, fst)) if drafts else (self.sel_key is not None)
        image_stale = (analysis_changed or self.focus != self.focus_drawn or self.image_steps is None
                       or steps != self.image_steps)
        key = self.audio_key_for(hist, pending, n, k, values)
        audio_stale = analysis_changed or key != self.audio_key
        self.prev_values = values
        delta_stale = self.delta_key != (steps, n, k) + self.focus_tag()
        if not (sel_stale or image_stale or audio_stale):
            if delta_stale:
                self.send_delta_image(steps, n, k, hist["rev"])
            self.recolour()
            return
        self.update(busy=True, status=tr("Calcul…", "Computing…", "Calculando…"))
        # A trace is never hidden before what replaces it is there: a selection that appears goes first
        # (cheap), one that goes away (Apply, undo) goes after the picture that now shows its effect.
        if sel_stale and drafts:
            self.send_selection(hist, drafts, values)
        if image_stale:
            self.send_base(self.committed_result(steps, n, k), n, k, steps, hist["rev"])
        if sel_stale and not drafts:
            self.send_selection(hist, drafts, values)
        if audio_stale:
            self.send_audio(hist, steps, drafts, values, n, k, key)
        self.update(busy=False, status=self.status(steps, pending))
        if delta_stale:
            self.send_delta_image(steps, n, k, hist["rev"])
        self.recolour()

    def run(self, original_path):
        """First display, then waits for the hand. Returns the last answer, whose state says how it ended."""
        st = self.app.send("script.canvas.get", {"canvas_id": self.cid})
        n, k = analysis_settings(st.get("values") or {})
        self.range = decide.display_range(st.get("values"))   # the remembered range, from the first picture
        self.focus = decide.focus_settings(st.get("values"))   # and the remembered display mode
        self.send_base(self.x, n, k, [], 0)
        self.result = self.x
        # The preview opens on the RESULT (`listen`), the slot the hand is here to judge. No gesture
        # yet: the result IS the original (history rev 0). The first sync sees the history as it is (the
        # hand may have drawn while the render was under way).
        self.app.send("script.canvas.set_audio", {
            "canvas_id": self.cid, "original": original_path, "result": original_path, "history_rev": 0,
            "listen": "result"})
        self.result_key = self.audio_key = (0, n, k, None)
        self.update(busy=False, status=self.status([], 0))
        self.send_delta_image([], n, k, 0)
        while True:
            if st.get("state") != "open":
                return st
            since = st["rev"]
            self.sync(st)
            known = self.hist["rev"] if self.hist else None
            st = self.app.send("script.canvas.wait", {
                "canvas_id": self.cid, "since_rev": since, "timeout_ms": 2000,
                **({"known_history_rev": known} if known is not None else {})})

    def final_result(self, st):
        """The result for what is HEARD at Validate: the committed steps and the pending selection (if
        any) at the current values. Recomputed unless the preview is already that."""
        hist, steps, drafts, pending = self.read_history(st)
        values = st.get("values") or {}
        n, k = analysis_settings(values)
        return self.compute_result(steps, drafts, values, n, k, self.audio_key_for(hist, pending, n, k, values))


# --- main ------------------------------------------------------------------------------------

def arg_object_ids():
    argv = sys.argv[1:]
    if "--object" in argv:
        i = argv.index("--object")
        if i + 1 < len(argv):
            return [argv[i + 1]]
    return [i for i in (os.environ.get("OBJEKAT_OBJECT_IDS") or "").split(",") if i]


def work_folder():
    base = os.environ.get("OBJEKAT_SPECTRAL_CACHE") or os.path.expanduser("~/Library/Caches/Objekat/spectral-editor")
    path = os.path.join(base, uuid.uuid4().hex)
    os.makedirs(path, exist_ok=True)
    return path


def run():
    if not SOCK:
        raise Failure("OBJEKAT_SOCKET missing: run this script from OBJEKAT's Scripts menu.")
    app = Objekat(SOCK)

    # 1. Check the object.
    ids = arg_object_ids()
    if len(ids) != 1:
        raise Failure(tr("Sélectionnez un seul objet à éditer.", "Select a single object to edit.",
                         "Seleccione un solo objeto para editar."))
    obj = app.send("object.get", {"id": ids[0]})
    if obj.get("kind") == "aux" or obj.get("infinite"):
        raise Failure(tr("Un bus ne peut pas être édité ainsi.", "A bus cannot be edited this way.",
                         "Un bus no se puede editar así."))
    if obj.get("missing"):
        raise Failure(tr("Le fichier de cet objet est introuvable.", "This object's file is missing.",
                         "No se encuentra el archivo de este objeto."))
    if not obj.get("duration", 0) > 0:
        raise Failure(tr("Objet vide.", "Empty object.", "Objeto vacío."))
    verdict = decide.duration_verdict(obj["duration"])
    if verdict == "refuse":
        raise Failure(tr("Objet trop long (%.0f s) : le maximum est de %.0f s.",
                         "Object too long (%.0f s): the maximum is %.0f s.",
                         "Objeto demasiado largo (%.0f s): el máximo es %.0f s.")
                      % (obj["duration"], decide.REFUSE_SECONDS))
    warn_text = ""
    if verdict == "warn":
        warn_text = tr("Objet long (%.0f s) : résolution réduite, calculs plus lents",
                       "Long object (%.0f s): reduced resolution, slower",
                       "Objeto largo (%.0f s): resolución reducida, más lento") % obj["duration"]

    # 2. The source formats: rate, and the depth class the file comes back in.
    formats = source_formats(app, obj)
    rates = decide.rate_counts([f[0] for f in formats])
    if len(rates) > 1:
        sample_rate = choose_rate(app, rates)
        if sample_rate is None:
            return 0  # cancelled before any render
    else:
        sample_rate = next(iter(rates), FALLBACK_RATE)
    depth_cls = decide.decide_depth([decide.depth_class(f[2], f[1]) for f in formats])

    work = work_folder()
    canvas_id = None
    try:
        # 3. Open the canvas (busy until the render is read).
        opened = app.send("script.canvas.open", {
            "title": tr("Éditeur spectral — %s", "Spectral editor — %s", "Editor espectral — %s") % (obj.get("name") or ""),
            "object": obj["id"], "controls": canvas_controls(), "tools": canvas_tools(),
            "modes": True, "remember": remember_key(), "busy": True,
            "status": tr("Rendu…", "Rendering…", "Renderizando…")})
        canvas_id = opened["canvas_id"]

        # 4. Render, read back.
        original = os.path.join(work, "original.wav")
        render_object(app, obj, original, sample_rate, decide.render_depth(depth_cls))
        samples, info = wavio.read_wav(original)
        if info.frames < 1:
            raise Failure(tr("Le rendu est vide.", "The render is empty.", "El renderizado está vacío."))
        if decide.is_mono(samples):
            samples = samples[:, :1]
        x = np.ascontiguousarray(samples, dtype=np.float32)
        del samples

        # 5-6. First display, then the loop.
        editor = Editor(app, canvas_id, work, x, info.sample_rate, warn_text)
        last = editor.run(original)
        if last.get("state") != "validated":
            return 0  # cancelled / closed: nothing touched

        # 7. Validate.
        y = editor.final_result(last)
        out_dir = output_folder(app)
        name = obj.get("name") or "object"
        path = decide.unique_path(out_dir, decide.safe_name(name), decide.OUTPUT_SUFFIX)
        clipped = wavio.write_wav(path, y, info.sample_rate, decide.write_kind(depth_cls))
        if clipped:
            print("Clipped samples: %d" % clipped)
        try:
            obj = app.send("object.get", {"id": obj["id"]})
        except ApiError:
            raise Failure(tr("L'objet n'existe plus : rien n'a été posé.", "The object no longer exists: nothing was laid down.",
                             "El objeto ya no existe: no se colocó nada."))
        params = {"path": path, "start": obj["start"], "name": decide.output_name(name)}
        if obj.get("parent"):
            params["group"] = obj["parent"]
        else:
            params["lane"] = next_free_lane(app)
        app.send("batch", {"commands": [
            {"cmd": "object.add", "params": params},
            {"cmd": "object.set_mute", "params": {"ids": [obj["id"]], "muted": True}},
        ]})
        return 0
    finally:
        if canvas_id:
            try:
                app.send("script.canvas.close", {"canvas_id": canvas_id})
            except Exception:  # noqa: BLE001
                pass
        shutil.rmtree(work, ignore_errors=True)


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(1))  # so that `finally` runs and the work folder goes
    try:
        sys.exit(run())
    except Failure as e:
        sys.stderr.write(str(e) + "\n")
        sys.exit(1)
    except Exception as e:  # noqa: BLE001 — anything else is reported, not swallowed
        sys.stderr.write("%s: %s\n" % (type(e).__name__, e))
        sys.exit(1)
