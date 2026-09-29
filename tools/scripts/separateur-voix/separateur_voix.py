#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Voice separator — orchestration + client (@see plan_separateur_voix.md, D2/D5/D6).

Reads the object(s) OBJEKAT hands it through OBJEKAT_OBJECT_IDS, detects voice / breaths /
SS-CH on each one's own audio (`detect.py`, pure and testable on its own), and calls
`object.explode` to lay the result out as a group of three sub-lanes on the object's own lane.
No sound is changed: the pieces stay jointive, and the fades of the original edges are left where
`object.explode` (hence `_splitInternal`) already puts them — on the FIRST and LAST piece only.

Run from OBJEKAT's own object context menu ("Scripts" submenu) via `run.sh`, or from the command
line for `--dry-run` / `--segments-json` testing.
"""

import json
import os
import socket
import sys

HERE = os.environ.get("OBJEKAT_PLUGIN_DIR") or os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import detect  # noqa: E402  (needs sys.path set first)
import transcribe as tr  # noqa: E402

SOCK = os.environ.get("OBJEKAT_SOCKET")


class Objekat:
    """A minimal JSON-lines client — copied out rather than imported (@see tools/example-script/
    report.py): a third-party script must depend only on the socket, never on the layout of
    OBJEKAT's own repository."""

    def __init__(self, path):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(120)
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
            raise RuntimeError(response.get("error"))
        return response["result"]


def read_portion(file_path, source_offset, duration, speed):
    """Reads `[source_offset, source_offset + duration * speed]` of `file_path` at its native
    sample rate, mono (channels averaged — for DETECTION only, the explode never touches audio).
    Mirrors the range the engine itself plays (@see CLAUDE.md, "the file range a clip consumes")."""
    import numpy as np
    import soundfile as sf

    info = sf.info(file_path)
    sr = info.samplerate
    i0 = max(0, int(round(source_offset * sr)))
    i1 = min(info.frames, int(round((source_offset + duration * speed) * sr)))
    if i1 <= i0:
        raise ValueError("empty source range")
    data, _ = sf.read(file_path, start=i0, stop=i1, always_2d=True)
    mono = data.mean(axis=1).astype("float64")
    return mono, sr


def transcribe(mono, sr, language):
    """The historical mode's words: Whisper, word-timestamped (@see transcribe.py, which also holds
    the other backends the evaluation can display)."""
    return tr.transcribe("whisper", mono, sr, language)


# MARK: - The caches

def cache_directory():
    """`~/Library/Caches/Objekat/separateur-voix/` (`OBJEKAT_SEPARATEUR_CACHE` overrides it, which is
    what lets a test use a folder of its own)."""
    return os.environ.get("OBJEKAT_SEPARATEUR_CACHE") or os.path.join(
        os.path.expanduser("~"), "Library", "Caches", "Objekat", "separateur-voix")


def _portion_fields(file_path, source_offset, duration, speed):
    st = os.stat(file_path)
    return [os.path.realpath(file_path), st.st_mtime_ns, st.st_size,
            round(float(source_offset), 6), round(float(duration), 6), round(float(speed), 6)]


def _digest(fields):
    import hashlib
    return hashlib.sha1(json.dumps(fields).encode("utf-8")).hexdigest()


def cache_key(file_path, source_offset, duration, speed):
    """What the FEATURES of an object depend on — the file (path, modification time, size), the
    portion of it that plays, and the version of the features. Nothing about a model: the detection
    never reads the words, so changing the transcription model never recomputes them."""
    return _digest(_portion_fields(file_path, source_offset, duration, speed)
                   + ["features", detect.EVAL_FEATURES_VERSION])


def words_cache_key(file_path, source_offset, duration, speed, language, model):
    """The transcription of the same portion by ONE model, in one language: its own entry, so that
    each model is transcribed once and switching between them afterwards is instant."""
    return _digest(_portion_fields(file_path, source_offset, duration, speed)
                   + ["words", model, language or "", tr.BACKEND_VERSION])


def save_features(path, feats):
    import numpy as np
    tmp = path + ".tmp.npz"
    np.savez(tmp, times=feats.times, voicing=feats.voicing, lp_db=feats.lp_db,
             cutoffs=feats.cutoffs, hop_s=np.array(feats.hop_s),
             hf_db=feats.hf_db, lf_db=feats.lf_db, zcr=feats.zcr)
    os.replace(tmp, path)


def load_features(path):
    """The `EvalFeatures`, or None for a file that is missing or unreadable — a corrupt cache is a
    recomputation, never an error."""
    import numpy as np
    try:
        with np.load(path) as z:
            return detect.EvalFeatures(times=z["times"], voicing=z["voicing"], lp_db=z["lp_db"],
                                       cutoffs=z["cutoffs"], hop_s=float(z["hop_s"]),
                                       hf_db=z["hf_db"], lf_db=z["lf_db"], zcr=z["zcr"])
    except Exception:
        return None


def cached_features(key, compute):
    """`compute()` → `EvalFeatures` runs only when nothing valid is cached under `key`."""
    folder = cache_directory()
    path = os.path.join(folder, key + ".npz")
    hit = load_features(path) if os.path.exists(path) else None
    if hit is not None:
        return hit
    feats = compute()
    try:
        os.makedirs(folder, exist_ok=True)
        save_features(path, feats)
    except OSError:
        pass   # a cache that cannot be written is a cache that is not there
    return feats


def cached_words(key, compute):
    """`compute()` → (words, seconds) runs only when nothing valid is cached under `key`. Returns
    `(words, seconds, from_cache)`."""
    folder = cache_directory()
    path = os.path.join(folder, key + ".words.json")
    try:
        with open(path, "r", encoding="utf-8") as f:
            data = json.load(f)
        return data["words"], float(data.get("seconds", 0.0)), True
    except Exception:
        pass
    words, seconds = compute()
    try:
        os.makedirs(folder, exist_ok=True)
        tmp = path + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump({"words": words, "seconds": seconds}, f)
        os.replace(tmp, path)
    except OSError:
        pass
    return words, seconds, False


def refuse(reason):
    sys.stderr.write(reason + "\n")
    sys.exit(3)


def check_object(obj, object_id):
    # D2 step 5 — the script's own refusal, clearer and earlier than a generic `bad_params` from
    # `object.explode` (which does not even check speed/reversed — @see plan's "Écarts"): none of
    # these change what `detect.py` would be measuring against.
    if obj.get("kind") != "clip":
        refuse("'%s' is not an audio clip." % obj.get("name", object_id))
    if obj.get("missing"):
        refuse("'%s' — source file not found." % obj.get("name", object_id))
    if obj.get("loop"):
        refuse("'%s' loops — separating a loop's window would ignore the pattern behind it."
               % obj.get("name", object_id))
    if abs(obj.get("speed", 1.0) - 1.0) > 1e-9:
        refuse("'%s' plays at a changed speed — its file positions would not line up "
               "with the seconds Whisper reports." % obj.get("name", object_id))
    if obj.get("reversed"):
        refuse("'%s' plays reversed." % obj.get("name", object_id))


def process_one(app, object_id, language, no_asr, segments_override, dry_run):
    obj = app.send("object.get", {"id": object_id})

    check_object(obj, object_id)

    start = obj["start"]
    duration = obj["duration"]
    file_path = obj["file"]
    source_offset = obj["source_offset"]
    speed = obj.get("speed", 1.0)

    if segments_override is not None:
        pieces = segments_override
    else:
        mono, sr = read_portion(file_path, source_offset, duration, speed)
        words = None if no_asr else transcribe(mono, sr, language)
        pieces = detect.segment(mono, sr, duration, words=words, language=language or "fr")

    cuts, lanes = detect.cuts_and_lanes(pieces)
    counts = {}
    for _lo, _hi, label in pieces:
        counts[label] = counts.get(label, 0) + 1

    if dry_run:
        print("DRY RUN — %s (%.2f s)" % (obj.get("name", object_id), duration))
        for lo, hi, label in pieces:
            print("  [%7.3f, %7.3f]  %s" % (lo, hi, label))
        return counts

    if not cuts:
        print("'%s' — nothing to separate (a single, uniform region)." % obj.get("name", object_id))
        return counts

    absolute_cuts = [start + c for c in cuts]
    lane_names = detect.LANE_NAMES.get(language, detect.LANE_NAMES["en"])
    names = lane_names[:max(lanes) + 1]

    result = app.send("object.explode", {
        "id": object_id,
        "cuts": absolute_cuts,
        "lanes": lanes,
        "names": names,
        "group_name": "%s — separated" % obj.get("name", object_id),
    })

    try:
        app.send("object.select", {"ids": [result["group"]]})
    except RuntimeError:
        pass  # no such command in this build — not fatal, the explode itself already happened

    return counts


# MARK: - Voice separation evaluation (interactive)

# Panel wording. The LABELS are the script's own data (the app draws whatever it is told, and only
# its own three buttons / title go through its catalogue), so the script speaks the language it was
# launched in (OBJEKAT_LANGUAGE).
def _pick(language, fr, en, es):
    return {"fr": fr, "en": en, "es": es}.get(language, en)


def panel_text(language):
    def plural(n, fr, en, es):
        return _pick(language, fr[n > 1], en[n != 1], es[n != 1])
    return {
        "title": _pick(language, "Évaluer la séparation de la voix", "Evaluate voice separation",
                       "Evaluar la separación de la voz"),
        "analysing": _pick(language, "Analyse du signal…", "Analysing the signal…", "Analizando la señal…"),
        "analysed": _pick(language, "Analyse du signal terminée", "Signal analysed", "Señal analizada"),
        "transcribing": _pick(language, "Transcription", "Transcribing", "Transcribiendo"),
        "transcribed": _pick(language, "Transcription terminée", "Transcription done", "Transcripción terminada"),
        "none": _pick(language, "Aucune zone — rien n'est coupé.", "No zone found — nothing is cut.",
                      "Ninguna zona — no se corta nada."),
        "breaths": lambda n, s: "%d %s, %.1f s" % (n, plural(n, ("respiration", "respirations"),
                                                             ("breath", "breaths"),
                                                             ("respiración", "respiraciones")), s),
        "sibilants": lambda n, s: "%d %s, %.1f s" % (n, plural(n, ("consonne", "consonnes"),
                                                               ("consonant", "consonants"),
                                                               ("consonante", "consonantes")), s),
        "status_transcribing": _pick(language, "transcription…", "transcribing…", "transcribiendo…"),
        "missing": _pick(language, "non installé", "not installed", "no instalado"),
        "failed": _pick(language, "transcription échouée", "transcription failed", "transcripción fallida"),
        "words": lambda n, sec, cached: "%d %s%s" % (
            n, plural(n, ("mot", "mots"), ("word", "words"), ("palabra", "palabras")),
            "" if cached else " (%.1f s)" % sec),
        "not_installed": _pick(language, " — non installé", " — not installed", " — no instalado"),
        "models": {
            "none": _pick(language, "Aucun", "None", "Ninguno"),
            "whisper": "Whisper large-v3-turbo (mlx)",
            "parakeet": _pick(language, "Parakeet TDT v3 (mlx) — anglais", "Parakeet TDT v3 (mlx) — English",
                              "Parakeet TDT v3 (mlx) — inglés"),
            "align": _pick(language, "Whisper + alignement wav2vec2", "Whisper + wav2vec2 alignment",
                           "Whisper + alineación wav2vec2"),
        },
    }


# Backwards-compatible name for the tests / callers that read the wording table.
PANEL_TEXT = {lang: panel_text(lang) for lang in ("fr", "en", "es")}


def panel_controls(language, model_labels, model="align"):
    """The panel: a small GLOBAL part (the text model, the progress bar — neither is a detection
    setting), then TWO fully independent blocks, Breaths and Consonants (SS/CH and the others), each
    owning everything it detects with — its criteria (a box and a value: an unchecked box drops the
    criterion and greys its value, `enabled_by`), its hole filling, its minimum length, its text
    criterion and tolerance. Ids: `b_` breaths, `s_` consonants (the historical prefix)."""
    L = lambda fr, en, es: _pick(language, fr, en, es)      # noqa: E731
    text = panel_text(language)
    b, s = detect.BreathEval(), detect.SibilantEval()
    out = []

    def section(cid, label):
        out.append({"id": cid, "kind": "section", "label": label})

    def flag(cid, label, value):
        out.append({"id": cid, "kind": "bool", "label": label, "value": value})

    def pair(prefix, obj, name, label, unit, lo, hi, step, gate_label=None, gated=True):
        """`<prefix><name>_on` (when the criterion has a box) + the value control. The box's label is
        what the window draws next to it (a box and its only value share a row)."""
        if gated:
            flag(prefix + name + "_on", gate_label or label, getattr(obj, name + "_on"))
        out.append({"id": prefix + name, "kind": "number", "label": label, "value": getattr(obj, name),
                    "min": lo, "max": hi, "step": step, "unit": unit,
                    **({"enabled_by": prefix + name + "_on"} if gated else {})})

    def shared_tail(prefix, obj):
        """What both blocks have, each its own: the hole filling and the text + tolerance."""
        pair(prefix, obj, "fill", L("Bouche-trou", "Hole filling", "Rellena huecos"), "ms", 0, 100, 1)
        flag(prefix + "text_on", L("Utiliser le texte, tolérance", "Use the text, tolerance",
                                   "Usar el texto, tolerancia"), obj.text_on)
        out.append({"id": prefix + "tolerance", "kind": "number", "label": L("Tolérance", "Tolerance", "Tolerancia"),
                    "value": obj.tolerance, "min": 50, "max": 800, "step": 10, "unit": "ms",
                    "enabled_by": prefix + "text_on"})

    # ── global ──
    out.append({"id": "model", "kind": "choice", "label": L("Texte (modèle)", "Text (model)", "Texto (modelo)"),
                "value": model, "options": [{"id": m, "label": model_labels[m]} for m in tr.MODEL_IDS]})
    out.append({"id": "progress", "kind": "progress", "label": text["analysing"], "value": None})

    # ── breaths ──
    section("sec_breath", L("Respirations", "Breaths", "Respiraciones"))
    flag("b_on", L("Détecter les respirations", "Detect breaths", "Detectar respiraciones"), b.on)
    pair("b_", b, "unvoiced", L("Voisement <", "Voicing <", "Sonoridad <"), "", 0.2, 0.6, 0.01)
    flag("b_below_speech_on", L("Énergie sous la parole", "Energy under speech", "Energía bajo el habla"),
         b.below_speech_on)
    out.append({"id": "b_below_speech", "kind": "number", "label": L("   écart", "   gap", "   diferencia"),
                "value": b.below_speech, "min": 3, "max": 15, "step": 1, "unit": "dB",
                "enabled_by": "b_below_speech_on"})
    out.append({"id": "b_cutoff", "kind": "number", "label": L("   passe-bas", "   low-pass", "   paso bajo"),
                "value": b.cutoff, "min": 100, "max": 1000, "step": 100, "unit": "Hz",
                "enabled_by": "b_below_speech_on"})
    pair("b_", b, "min_len", L("Durée minimale", "Minimum length", "Duración mínima"), "ms", 80, 200, 5)
    shared_tail("b_", b)

    # ── consonants ──
    section("sec_sib", L("Consonnes (SS/CH et autres)", "Consonants (SS/CH and others)",
                         "Consonantes (SS/CH y otras)"))
    flag("s_on", L("Détecter les consonnes", "Detect consonants", "Detectar consonantes"), s.on)
    pair("s_", s, "unvoiced", L("Non voisé (voisement <)", "Not voiced (voicing <)", "No sonoro (sonoridad <)"),
         "", 0.3, 0.9, 0.01)
    pair("s_", s, "hf_ratio", L("Aigus / graves >", "High / low >", "Agudos / graves >"), "dB", -20, 20, 1)
    pair("s_", s, "zcr", L("Passages par zéro >", "Zero crossings >", "Cruces por cero >"), "", 0.05, 0.4, 0.01)
    pair("s_", s, "hf_energy", L("Énergie HF > plancher +", "HF energy > floor +", "Energía HF > suelo +"),
         "dB", 0, 30, 1)
    pair("s_", s, "min_len", L("Durée minimale", "Minimum length", "Duración mínima"), "ms", 10, 150, 5)
    pair("s_", s, "refine", L("Affiner sur le pic HF (−)", "Refine on the HF peak (−)",
                              "Afinar sobre el pico HF (−)"), "dB", 3, 30, 1)
    shared_tail("s_", s)
    return out


class Transcriber:
    """Transcribes on a BACKGROUND thread, one model at a time, so the panel stays reactive: the
    socket is only ever used by the main thread, the worker just computes and hands the result back
    through `results` (and its progress through `progress`, read by the main loop). Each model's
    words are cached on disk under their own key."""

    def __init__(self, obj, language, mono_loader):
        import queue
        import threading
        self.obj, self.language, self.load = obj, language, mono_loader
        self.results = queue.Queue()
        self.done = {}          # model → (words, seconds, from_cache) | RuntimeError
        self.running = None
        self.progress = {"model": None, "f": None}     # the running model's fraction (None = unknown)
        self._threading = threading

    def key(self, model):
        o = self.obj
        return words_cache_key(o["file"], o["source_offset"], o["duration"], o.get("speed", 1.0),
                               self.language, model)

    def request(self, model):
        """Starts `model` unless it is done or already running. Returns True when something is (now)
        in flight or ready to be collected."""
        if model in self.done or self.running == model:
            return True
        if self.running is not None:
            return True          # one at a time; `collect` starts the wanted one when this ends
        self.running = model
        self.progress = {"model": model, "f": None}

        def report(f):
            self.progress = {"model": model, "f": f}

        def work():
            import time
            try:
                def compute():
                    mono, sr = self.load()
                    t0 = time.time()
                    return tr.transcribe(model, mono, sr, self.language, progress=report), time.time() - t0
                self.results.put((model, cached_words(self.key(model), compute)))
            except Exception as e:  # noqa: BLE001 — a backend failing is a label, not a crash
                self.results.put((model, RuntimeError(str(e))))

        self._threading.Thread(target=work, daemon=True).start()
        return True

    def collect(self):
        """Moves finished work into `done`. Returns the models that finished."""
        import queue
        finished = []
        while True:
            try:
                model, outcome = self.results.get_nowait()
            except queue.Empty:
                return finished
            self.done[model] = outcome
            if self.running == model:
                self.running = None
            finished.append(model)


class ProgressBar:
    """The panel's `progress` control, written back at most every 100 ms (a value that did not move
    is not sent again): what the script says it is doing (`label`) and how far (`fraction`, or None
    for "no idea")."""

    def __init__(self, app, panel_id, control_id="progress"):
        self.app, self.pid, self.cid = app, panel_id, control_id
        self.sent = None
        self.last = 0.0

    def set(self, label, fraction, force=False):
        import time
        state = (label, None if fraction is None else round(fraction, 3))
        now = time.time()
        if state == self.sent or (not force and now - self.last < 0.1):
            return
        self.sent, self.last = state, now
        self.app.send("script.panel.update", {"panel_id": self.pid, "labels": {self.cid: label},
                                              "values": {self.cid: fraction}})


def eval_lanes(settings):
    """label → sub-lane, for the categories that are ON: Voice is always lane 0, then Breaths, then
    SS/CH — a category that is switched off has no lane at all."""
    lanes = {"voice": 0}
    if settings.breath.on:
        lanes["breath"] = len(lanes)
    if settings.sibilant.on:
        lanes["sibilant"] = len(lanes)
    return lanes


def breaths_eval(app, object_id, language, no_asr, model_arg=None):
    """Shows the zones the detector finds on ONE object — breaths in white, SS/CH in yellow — and
    lets the hand move the criteria until they are right; Validate then cuts exactly what is shown.
    Nothing is changed before that: the zones are an overlay (never in the project), and Cancel — or
    the window closing, or this process dying — leaves the project untouched. The words come from a
    model chosen in the panel (transcribed in the background) and are both DISPLAYED and, when 'use
    the text' is checked, a criterion (@see detect.eval_zones)."""
    obj = app.send("object.get", {"id": object_id})
    check_object(obj, object_id)
    text = panel_text(language)
    start, duration = obj["start"], obj["duration"]
    speed = obj.get("speed", 1.0)

    model_labels = {m: text["models"][m] + ("" if tr.installed(m, language) else text["not_installed"])
                    for m in tr.MODEL_IDS}
    if no_asr:
        initial = "none"
    elif model_arg:
        initial = model_arg
    else:   # the default is Whisper + alignment; an install that lacks it falls back rather than
            # opening on a model that says "not installed"
        initial = next((m for m in ("align", "whisper") if tr.installed(m, language)), "none")
    if initial not in tr.MODEL_IDS:
        initial = "none"
    controls = panel_controls(language, model_labels, initial)

    panel = app.send("script.panel.open", {
        "title": text["title"], "controls": controls, "object": object_id,
        "remember": "separateur-voix.eval",     # the app keeps what was last validated
        "status": text["analysing"], "busy": True})
    pid = panel["panel_id"]
    bar = ProgressBar(app, pid)

    def load_portion():
        return read_portion(obj["file"], obj["source_offset"], duration, speed)

    try:
        bar.set(text["analysing"], None, force=True)
        feats = cached_features(
            cache_key(obj["file"], obj["source_offset"], duration, speed),
            lambda: detect.compute_eval_features(
                *load_portion(), progress=lambda f: bar.set(text["analysing"], f)))
        bar.set(text["analysed"], 1.0, force=True)

        speech_levels = {}
        transcriber = Transcriber(obj, language, load_portion)
        shown_model = {"id": None}        # the model whose words are on the overlay
        words_note = {"text": ""}         # the transcription half of the status line
        zone_note = {"text": ""}

        def words_for(values):
            """The words the DETECTION may read: the wanted model's, once it has them."""
            m = values.get("model", "none")
            outcome = transcriber.done.get(m) if m != "none" else None
            if outcome is None or isinstance(outcome, Exception):
                return None
            return outcome[0]

        def zones_for(values):
            settings = detect.EvalSettings.from_values(values)
            k = (settings.breath.unvoiced, settings.breath.cutoff)
            if k not in speech_levels:
                speech_levels[k] = detect.eval_speech_level(feats, *k)
            return settings, detect.eval_zones(feats, settings, duration, words_for(values),
                                               language or "fr", speech_levels[k])

        def push_status(busy=False):
            parts = [x for x in (zone_note["text"], words_note["text"]) if x]
            app.send("script.panel.update", {"panel_id": pid, "status": " · ".join(parts), "busy": busy})

        def show_zones(values):
            settings, zones = zones_for(values)
            overlay = ([{"start": lo, "end": hi, "color": "white"} for lo, hi in zones["breath"]]
                       + [{"start": lo, "end": hi, "color": "yellow"} for lo, hi in zones["sibilant"]])
            app.send("overlay.set", {"id": object_id, "replace": ["zones"], "zones": overlay})
            notes = []
            if settings.breath.on:
                notes.append(text["breaths"](len(zones["breath"]), sum(h - l for l, h in zones["breath"])))
            if settings.sibilant.on:
                notes.append(text["sibilants"](len(zones["sibilant"]), sum(h - l for l, h in zones["sibilant"])))
            zone_note["text"] = " · ".join(notes)
            push_status()
            return settings, zones

        def show_words(model):
            """Puts `model`'s words on the overlay, or says why it cannot."""
            if model == "none":
                app.send("overlay.set", {"id": object_id, "replace": ["texts"], "texts": []})
                shown_model["id"] = "none"
                words_note["text"] = ""
                return
            if not tr.installed(model, language):
                words_note["text"] = text["missing"]
                return
            transcriber.request(model)
            outcome = transcriber.done.get(model)
            if outcome is None:
                words_note["text"] = text["status_transcribing"]
            elif isinstance(outcome, Exception):
                words_note["text"] = text["failed"]
                sys.stderr.write("transcription (%s) failed: %s\n" % (model, outcome))
            else:
                words, seconds, from_cache = outcome
                app.send("overlay.set", {"id": object_id, "replace": ["texts"], "texts": [
                    {"start": w["start"], "end": w["end"], "text": w["word"]} for w in words]})
                shown_model["id"] = model
                words_note["text"] = text["words"](len(words), seconds, from_cache)

        def show_progress(model, force=False):
            """The bar follows the model being transcribed; when nothing is, it rests on 'done'."""
            if transcriber.running is not None:
                name = model_labels[transcriber.running].replace(text["not_installed"], "")
                bar.set("%s — %s" % (text["transcribing"], name), transcriber.progress["f"], force)
            else:
                bar.set(text["transcribed"] if model != "none" and isinstance(
                    transcriber.done.get(model), tuple) else text["analysed"], 1.0, force)

        current = app.send("script.panel.get", {"panel_id": pid})
        values = current["values"]
        show_words(values.get("model", "none"))
        settings, zones = show_zones(values)
        last_wanted = values.get("model", "none")
        show_progress(last_wanted, force=True)
        push_status(busy=False)
        rev = current["rev"]

        while True:
            current = app.send("script.panel.wait",
                               {"panel_id": pid, "since_rev": rev, "timeout_ms": 250})
            if current["state"] != "open":
                break
            changed = current["rev"] != rev
            rev = current["rev"]
            values = current["values"]
            finished = transcriber.collect()
            wanted = values.get("model", "none")
            if wanted != last_wanted or finished:
                last_wanted = wanted
                show_words(wanted)     # also starts `wanted` when a finished model freed the worker
            if changed or finished:
                settings, zones = show_zones(values)
            elif wanted != shown_model["id"]:
                push_status()
            show_progress(wanted, force=bool(finished))

        if current["state"] == "validated":
            settings, zones = zones_for(current["values"])
            lanes = eval_lanes(settings)
            if not (zones["breath"] or zones["sibilant"]):
                app.send("script.panel.update", {"panel_id": pid, "status": text["none"]})
            else:
                pieces = detect.segment_zones(duration, zones)
                cuts, piece_lanes = detect.cuts_and_lanes(pieces, lanes)
                if cuts:
                    lane_names = detect.LANE_NAMES.get(language, detect.LANE_NAMES["en"])
                    by_lane = sorted(lanes.items(), key=lambda kv: kv[1])
                    names = [lane_names[detect.LANE_FOR_LABEL[label]] for label, _ in by_lane]
                    names = names[:max(piece_lanes) + 1]
                    result = app.send("object.explode", {
                        "id": object_id, "cuts": [start + c for c in cuts], "lanes": piece_lanes,
                        "names": names,
                        "group_name": "%s — separated" % obj.get("name", object_id)})
                    try:
                        app.send("object.select", {"ids": [result["group"]]})
                    except RuntimeError:
                        pass
    finally:
        # Even without this, the connection closing would clear both (the app owns that rule) — but
        # a script that ends cleanly leaves cleanly.
        for cmd, params in (("overlay.clear", {"id": object_id}),
                            ("script.panel.close", {"panel_id": pid})):
            try:
                app.send(cmd, params)
            except (RuntimeError, OSError):
                pass


def main():
    args = sys.argv[1:]
    language = os.environ.get("OBJEKAT_LANGUAGE", "en")
    no_asr = "--no-asr" in args
    dry_run = "--dry-run" in args
    segments_json = None
    if "--lang" in args:
        language = args[args.index("--lang") + 1]
    if "--segments-json" in args:
        segments_json = args[args.index("--segments-json") + 1]

    if not SOCK:
        sys.stderr.write("OBJEKAT_SOCKET missing: run this script from OBJEKAT.\n")
        return 2

    ids_env = os.environ.get("OBJEKAT_OBJECT_IDS", "")
    ids = [x for x in ids_env.split(",") if x]
    if "--object" in args:
        ids = [args[args.index("--object") + 1]]
    if not ids:
        sys.stderr.write("No object selected.\n")
        return 3

    segments_override = None
    if segments_json:
        with open(segments_json, "r", encoding="utf-8") as f:
            raw = json.load(f)
        segments_override = [(p["start"], p["start"] + p["duration"], p["label"]) for p in raw]

    app = Objekat(SOCK)
    if "--breaths-eval" in args or "--eval-separation" in args:
        target = args[args.index("--object") + 1] if "--object" in args else ids[0]
        model_arg = args[args.index("--model") + 1] if "--model" in args else None
        breaths_eval(app, target, language, no_asr, model_arg)
        return 0
    total = {}
    for object_id in ids:
        counts = process_one(app, object_id, language, no_asr, segments_override, dry_run)
        for k, v in counts.items():
            total[k] = total.get(k, 0) + v

    if not dry_run:
        print("%d breath(s), %d SS/CH" % (total.get("breath", 0), total.get("sibilant", 0)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
