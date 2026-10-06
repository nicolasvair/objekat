#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Spectral gain — a spectrogram of ONE object, edited by hand with gain only (attenuate, or boost).

The script renders the object (exactly as `retouche-externe` does), computes its STFT, opens a canvas
(`script.canvas.*`, @see docs/plan_spectral_gain.md) with the spectrogram and the rectangle / eraser
tools, and on every change of the operation history recomputes the veil (the picture of the mask)
and the audio preview (result and delta) that the app lets the ear compare. Validate writes the
result as a wav and lays it back like `retouche-externe`: a new row at the same instant (inside the
same group if any), named "<name> (spectral)", the original MUTED, all in one `batch` (ONE undo).
Cancel leaves the session untouched.

Contract with the app: a separate process that talks to the socket (@see docs/command_api.md,
"Third-party scripts"). Human messages go to stderr with exit != 0 — the app surfaces them.

All the gain mathematics lives in `mask.py`; the app knows gestures, never gain. One connection, one
loop (a connection serves its requests one after another): wait, compute, update.

Format of the file laid back (spec 2): same sample rate and bit depth class as the source file
(16-bit -> 16, 24-bit -> 24, 32-bit float -> float, anything else -> 24), MONO when the two channels
of the render are identical sample for sample, stereo otherwise. Over 120 s the script warns (the
resolution degrades), over 600 s it refuses.

Testing hooks: `--object ID` (instead of OBJEKAT_OBJECT_IDS), OBJEKAT_SPECTRAL_CACHE (the work folder).
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
import veil  # noqa: E402
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
        "title": tr("Gain spectral", "Spectral gain", "Ganancia espectral"),
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
        {"id": "sec_rect", "kind": "section", "label": tr("Rectangle", "Rectangle", "Rectángulo")},
        num("gain", tr("Gain", "Gain", "Ganancia"), -60, 12, 0.5, -12, "dB"),
        num("feather_ms", tr("Fondu en temps", "Time feather", "Suavizado en tiempo"), 0, 200, 1, 10, "ms"),
        num("feather_st", tr("Fondu en fréquence", "Frequency feather", "Suavizado en frecuencia"), 0, 12, 0.1, 1, "st"),
        {"id": "sec_eraser", "kind": "section", "label": tr("Gomme", "Eraser", "Borrador")},
        num("size_px", tr("Taille", "Size", "Tamaño"), 4, 200, 1, 32, "px"),
        num("amount", tr("Atténuation par passage", "Attenuation per pass", "Atenuación por pasada"), -24, -0.5, 0.5, -3, "dB"),
        num("hardness", tr("Dureté", "Hardness", "Dureza"), 0, 100, 1, 50, "%"),
        {"id": "sec_analysis", "kind": "section", "label": tr("Analyse", "Analysis", "Análisis"), "advanced": True},
        {"id": "fft_size", "kind": "choice", "label": tr("Taille de FFT", "FFT size", "Tamaño de FFT"),
         "value": str(DEFAULT_FFT), "options": [{"id": str(n), "label": str(n)} for n in FFT_SIZES], "advanced": True},
        num("overlap", tr("Recouvrement", "Overlap", "Solapamiento"), 2, 10, 1, DEFAULT_OVERLAP, "", advanced=True),
    ]


def canvas_tools():
    return [
        {"id": "rect", "kind": "rect", "label": tr("Rectangle", "Rectangle", "Rectángulo"),
         "params": ["gain", "feather_ms", "feather_st"]},
        {"id": "eraser", "kind": "stroke", "label": tr("Gomme", "Eraser", "Borrador"), "icon": "eraser",
         "params": ["amount", "hardness"], "size_control": "size_px"},
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
        self.veil = veil.VeilCache()
        self.mask_cache = {}
        self.fft = None            # (n, k) of the base image and of the result
        self.ops = []              # every op of the history, as last read
        self.ops_rev = None        # the history rev `ops` was read at (the `known_history_rev`)
        self.veil_rev = 0          # the history rev the veil layer reflects
        self.audio_rev = 0         # the history rev the audio preview reflects
        self.result = x            # the result in memory (float32); the original until the first op
        self.result_key = None     # (history rev, n, k) the result was computed for
        self.files = {}            # kind -> [(seq, path)]

    # -- the app ---------------------------------------------------------------------------

    def update(self, **kw):
        kw["canvas_id"] = self.cid
        self.app.send("script.canvas.update", kw)

    def status(self, hist):
        count = hist["cursor"]
        text = tr("%d opération(s)", "%d operation(s)", "%d operación(es)") % count
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

    def set_base(self, n, k):
        self.seq += 1
        path = os.path.join(self.work, "base-%d.objkcnv" % self.seq)
        image.write_base_image(path, self.x, self.sr, n, k)
        self.app.send("script.canvas.set_image", {
            "canvas_id": self.cid, "path": path, "x": self.world["x"], "y": self.world["y"],
            "value_unit": "dB"})
        self.remember_file("base", path)
        self.fft = (n, k)

    # -- the veil and the audio ------------------------------------------------------------

    def active_ops(self, hist):
        return self.ops[:hist["cursor"]]

    def send_veil(self, hist):
        g = self.veil.update(self.active_ops(hist), self.world)
        self.seq += 1
        path = os.path.join(self.work, "veil-%d.objkrgb" % self.seq)
        veil.write_veil(path, g)
        self.app.send("script.canvas.set_layer", {
            "canvas_id": self.cid, "layer": "veil", "path": path, "z": 1, "history_rev": hist["rev"]})
        self.remember_file("veil", path)
        self.veil_rev = hist["rev"]

    def compute_result(self, hist, n, k):
        """The audio through the mask of the active ops (float32, like x). Cached per (history rev, n, k)."""
        key = (hist["rev"], n, k)
        if self.result_key != key:
            fn = mask.stft_gain_block_fn(self.active_ops(hist), self.world, self.sr, n, k, self.mask_cache)
            self.result = dsp.process(self.x, self.sr, n, k, fn, np.float32)
            self.result_key = key
        return self.result

    def send_audio(self, hist, n, k):
        y = self.compute_result(hist, n, k)
        self.seq += 1
        rpath = os.path.join(self.work, "result-%d.wav" % self.seq)
        dpath = os.path.join(self.work, "delta-%d.wav" % self.seq)
        wavio.write_wav(rpath, y, self.sr, "f32")
        wavio.write_wav(dpath, self.x - y, self.sr, "f32")
        self.app.send("script.canvas.set_audio", {
            "canvas_id": self.cid, "result": rpath, "delta": dpath, "history_rev": hist["rev"]})
        self.remember_file("result", rpath)
        self.remember_file("delta", dpath)
        self.audio_rev = hist["rev"]

    def read_history(self, st):
        """The history of an answer; the ops are cached while the rev does not move."""
        hist = st["history"]
        if "ops" in hist:
            self.ops = hist["ops"]
            self.ops_rev = hist["rev"]
        return hist

    # -- the loop ----------------------------------------------------------------------------

    def sync(self, st):
        """Brings the app up to date with an answer: a new base image when the analysis settings moved,
        then, when the history moved, the veil (before the audio, it is the faster one), then the audio."""
        hist = self.read_history(st)
        n, k = analysis_settings(st.get("values") or {})
        analysis_changed = (n, k) != self.fft
        veil_stale = hist["rev"] != self.veil_rev
        audio_stale = analysis_changed or hist["rev"] != self.audio_rev
        if not (analysis_changed or veil_stale or audio_stale):
            return
        self.update(busy=True, status=tr("Calcul…", "Computing…", "Calculando…"))
        if analysis_changed:
            self.set_base(n, k)
        if veil_stale:
            self.send_veil(hist)
        if audio_stale:
            self.send_audio(hist, n, k)
        self.update(busy=False, status=self.status(hist))

    def run(self, original_path):
        """First display, then waits for the hand. Returns the last answer, whose state says how it ended."""
        st = self.app.send("script.canvas.get", {"canvas_id": self.cid})
        n, k = analysis_settings(st.get("values") or {})
        self.set_base(n, k)
        self.result = self.x
        self.result_key = (0, n, k)  # no op yet: the result IS the original
        self.app.send("script.canvas.set_audio", {
            "canvas_id": self.cid, "original": original_path, "result": original_path, "history_rev": 0})
        self.veil_rev = 0   # no layer at history rev 0: nothing to show
        self.audio_rev = 0
        self.update(busy=False, status=self.status({"cursor": 0}))
        while True:
            if st.get("state") != "open":
                return st
            since = st["rev"]
            self.sync(st)  # ops drawn while the render was under way are handled here
            st = self.app.send("script.canvas.wait", {
                "canvas_id": self.cid, "since_rev": since, "timeout_ms": 2000,
                **({"known_history_rev": self.ops_rev} if self.ops_rev is not None else {})})

    def final_result(self, st):
        """The result for the history at Validate (recomputed if the preview is not current)."""
        hist = self.read_history(st)
        n, k = analysis_settings(st.get("values") or {})
        return self.compute_result(hist, n, k)


# --- main ------------------------------------------------------------------------------------

def arg_object_ids():
    argv = sys.argv[1:]
    if "--object" in argv:
        i = argv.index("--object")
        if i + 1 < len(argv):
            return [argv[i + 1]]
    return [i for i in (os.environ.get("OBJEKAT_OBJECT_IDS") or "").split(",") if i]


def work_folder():
    base = os.environ.get("OBJEKAT_SPECTRAL_CACHE") or os.path.expanduser("~/Library/Caches/Objekat/spectral-gain")
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
            "title": tr("Gain spectral — %s", "Spectral gain — %s", "Ganancia espectral — %s") % (obj.get("name") or ""),
            "object": obj["id"], "controls": canvas_controls(), "tools": canvas_tools(),
            "remember": "spectral-gain", "busy": True,
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
