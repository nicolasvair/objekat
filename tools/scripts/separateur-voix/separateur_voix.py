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
             cutoffs=feats.cutoffs, hop_s=np.array(feats.hop_s))
    os.replace(tmp, path)


def load_features(path):
    """The `EvalFeatures`, or None for a file that is missing or unreadable — a corrupt cache is a
    recomputation, never an error."""
    import numpy as np
    try:
        with np.load(path) as z:
            return detect.EvalFeatures(times=z["times"], voicing=z["voicing"], lp_db=z["lp_db"],
                                       cutoffs=z["cutoffs"], hop_s=float(z["hop_s"]))
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


# MARK: - Breath evaluation (interactive)

# Panel wording. The LABELS are the script's own data (the app draws whatever it is told, and only
# its own three buttons / title go through its catalogue), so the script speaks the language it was
# launched in (OBJEKAT_LANGUAGE).
PANEL_TEXT = {
    "fr": {"title": "Évaluer les respirations", "analysing": "Analyse…",
           "none": "Aucune respiration — rien n'est coupé.",
           "count": lambda n, s: "%d zone%s, %.1f s" % (n, "" if n <= 1 else "s", s),
           "transcribing": "transcription…", "missing": "non installé", "failed": "transcription échouée",
           "words": lambda n, sec, cached: "%d mot%s%s" % (n, "" if n <= 1 else "s",
                                                           "" if cached else " (%.1f s)" % sec),
           "model": "Texte affiché", "not_installed": " — non installé",
           "models": {"none": "Aucun", "whisper": "Whisper large-v3-turbo (mlx)",
                      "parakeet": "Parakeet TDT v3 (mlx)", "align": "Whisper + alignement wav2vec2"}},
    "en": {"title": "Evaluate breaths", "analysing": "Analysing…",
           "none": "No breath found — nothing is cut.",
           "count": lambda n, s: "%d zone%s, %.1f s" % (n, "" if n == 1 else "s", s),
           "transcribing": "transcribing…", "missing": "not installed", "failed": "transcription failed",
           "words": lambda n, sec, cached: "%d word%s%s" % (n, "" if n == 1 else "s",
                                                           "" if cached else " (%.1f s)" % sec),
           "model": "Text shown", "not_installed": " — not installed",
           "models": {"none": "None", "whisper": "Whisper large-v3-turbo (mlx)",
                      "parakeet": "Parakeet TDT v3 (mlx)", "align": "Whisper + wav2vec2 alignment"}},
    "es": {"title": "Evaluar respiraciones", "analysing": "Analizando…",
           "none": "Ninguna respiración — no se corta nada.",
           "count": lambda n, s: "%d zona%s, %.1f s" % (n, "" if n == 1 else "s", s),
           "transcribing": "transcribiendo…", "missing": "no instalado", "failed": "transcripción fallida",
           "words": lambda n, sec, cached: "%d palabra%s%s" % (n, "" if n == 1 else "s",
                                                              "" if cached else " (%.1f s)" % sec),
           "model": "Texto mostrado", "not_installed": " — no instalado",
           "models": {"none": "Ninguno", "whisper": "Whisper large-v3-turbo (mlx)",
                      "parakeet": "Parakeet TDT v3 (mlx)", "align": "Whisper + alineación wav2vec2"}},
}

# The four criteria. (id, label per language, unit, min, max, step) of each one's SLIDER; the box is
# `<id>_on`. The energy criterion carries a second slider, the low-pass cutoff, gated by the same box.
CRITERIA = [
    ("unvoiced", {"fr": "Voisement <", "en": "Voicing <", "es": "Sonoridad <"}, "", 0.1, 0.9, 0.01),
    ("below_speech", {"fr": "Énergie < parole − (passe-bas)", "en": "Energy < speech − (low-passed)",
                      "es": "Energía < habla − (paso bajo)"}, "dB", 0, 40, 1),
    ("min_len", {"fr": "Durée minimale", "en": "Minimum length", "es": "Duración mínima"}, "ms", 0, 400, 10),
    ("end_margin", {"fr": "Marge avant la voix", "en": "Margin before voice",
                    "es": "Margen antes de la voz"}, "ms", 0, 60, 1),
]
CUTOFF_LABEL = {"fr": "Coupure passe-bas", "en": "Low-pass cutoff", "es": "Corte paso bajo"}


def panel_controls(language, model_labels):
    """The model choice, then one checkbox + one slider per criterion (the slider greys while its box
    is unchecked — `enabled_by`, the whole 'box and threshold' idea)."""
    defaults = detect.EvalParams()
    text = PANEL_TEXT.get(language, PANEL_TEXT["en"])
    controls = [{"id": "model", "kind": "choice", "label": text["model"], "value": "none",
                 "options": [{"id": m, "label": model_labels[m]} for m in tr.MODEL_IDS]}]
    for cid, labels, unit, lo, hi, step in CRITERIA:
        label = labels.get(language, labels["en"])
        controls.append({"id": cid + "_on", "kind": "bool", "label": label, "value": True})
        controls.append({"id": cid, "kind": "number", "label": label, "value": getattr(defaults, cid),
                         "min": lo, "max": hi, "step": step, "unit": unit, "enabled_by": cid + "_on"})
        if cid == "below_speech":
            controls.append({"id": "cutoff", "kind": "number", "label": CUTOFF_LABEL.get(language, CUTOFF_LABEL["en"]),
                             "value": defaults.cutoff, "min": float(detect.EVAL_CUTOFFS[0]),
                             "max": float(detect.EVAL_CUTOFFS[-1]),
                             "step": float(detect.EVAL_CUTOFFS[1] - detect.EVAL_CUTOFFS[0]),
                             "unit": "Hz", "enabled_by": "below_speech_on"})
    return controls


class Transcriber:
    """Transcribes on a BACKGROUND thread, one model at a time, so the panel stays reactive: the
    socket is only ever used by the main thread, the worker just computes and hands the result back
    through `results`. Each model's words are cached on disk under their own key."""

    def __init__(self, obj, language, mono_loader):
        import queue
        import threading
        self.obj, self.language, self.load = obj, language, mono_loader
        self.results = queue.Queue()
        self.done = {}          # model → (words, seconds, from_cache) | RuntimeError
        self.running = None
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

        def work():
            import time
            try:
                def compute():
                    mono, sr = self.load()
                    t0 = time.time()
                    return tr.transcribe(model, mono, sr, self.language), time.time() - t0
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


def breaths_eval(app, object_id, language, no_asr, model_arg=None):
    """Shows the zones the detector finds on ONE object, as white zones over it, and lets the hand
    move the four criteria until they are right; Validate then cuts exactly what is shown. Nothing is
    changed before that: the zones are an overlay (never in the project), and Cancel — or the
    window closing, or this process dying — leaves the project untouched. The words are a DISPLAY
    (a model chosen in the panel, transcribed in the background); the detection never reads them."""
    obj = app.send("object.get", {"id": object_id})
    check_object(obj, object_id)
    text = PANEL_TEXT.get(language, PANEL_TEXT["en"])
    start, duration = obj["start"], obj["duration"]
    speed = obj.get("speed", 1.0)

    model_labels = {m: text["models"][m] + ("" if tr.installed(m, language) else text["not_installed"])
                    for m in tr.MODEL_IDS}
    controls = panel_controls(language, model_labels)
    initial = "none" if no_asr else (model_arg or "none")
    for c in controls:
        if c["id"] == "model":
            c["value"] = initial if initial in tr.MODEL_IDS else "none"

    panel = app.send("script.panel.open", {
        "title": text["title"], "controls": controls, "object": object_id,
        "status": text["analysing"], "busy": True})
    pid = panel["panel_id"]

    def load_portion():
        return read_portion(obj["file"], obj["source_offset"], duration, speed)

    try:
        feats = cached_features(
            cache_key(obj["file"], obj["source_offset"], duration, speed),
            lambda: detect.compute_eval_features(*load_portion()))

        speech_levels = {}
        transcriber = Transcriber(obj, language, load_portion)
        shown_model = {"id": None}        # the model whose words are on the overlay
        words_note = {"text": ""}         # the transcription half of the status line
        zone_note = {"text": ""}

        def regions_for(values):
            p = detect.EvalParams.from_values(values)
            k = (p.unvoiced, p.cutoff)
            if k not in speech_levels:
                speech_levels[k] = detect.eval_speech_level(feats, p.unvoiced, p.cutoff)
            return detect.eval_mask(feats, speech_levels[k], p, duration)

        def push_status(busy=False):
            parts = [x for x in (zone_note["text"], words_note["text"]) if x]
            app.send("script.panel.update", {"panel_id": pid, "status": " · ".join(parts), "busy": busy})

        def show_zones(values):
            regions = regions_for(values)
            app.send("overlay.set", {"id": object_id, "replace": ["zones"],
                                     "zones": [{"start": lo, "end": hi, "color": "white"}
                                               for lo, hi in regions]})
            zone_note["text"] = text["count"](len(regions), sum(hi - lo for lo, hi in regions))
            push_status()
            return regions

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
                words_note["text"] = text["transcribing"]
            elif isinstance(outcome, Exception):
                words_note["text"] = text["failed"]
                sys.stderr.write("transcription (%s) failed: %s\n" % (model, outcome))
            else:
                words, seconds, from_cache = outcome
                app.send("overlay.set", {"id": object_id, "replace": ["texts"], "texts": [
                    {"start": w["start"], "end": w["end"], "text": w["word"]} for w in words]})
                shown_model["id"] = model
                words_note["text"] = text["words"](len(words), seconds, from_cache)

        current = app.send("script.panel.get", {"panel_id": pid})
        values = current["values"]
        regions = show_zones(values)
        last_wanted = values.get("model", "none")
        show_words(last_wanted)
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
            if changed:
                regions = show_zones(values)
            wanted = values.get("model", "none")
            if wanted != last_wanted or finished:
                last_wanted = wanted
                show_words(wanted)     # also starts `wanted` when a finished model freed the worker
                push_status()

        if current["state"] == "validated":
            regions = regions_for(current["values"])
            if not regions:
                app.send("script.panel.update", {"panel_id": pid, "status": text["none"]})
            else:
                pieces = detect.segment_breaths(duration, regions)
                cuts, lanes = detect.cuts_and_lanes(pieces)
                if cuts:
                    lane_names = detect.LANE_NAMES.get(language, detect.LANE_NAMES["en"])
                    result = app.send("object.explode", {
                        "id": object_id, "cuts": [start + c for c in cuts], "lanes": lanes,
                        "names": lane_names[:2],
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
    if "--breaths-eval" in args:
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
