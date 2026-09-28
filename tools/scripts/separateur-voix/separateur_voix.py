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
    """16 kHz mono → mlx_whisper, word-timestamped. Returns Whisper's own word list (seconds
    relative to the portion handed in — the SAME reference `detect.segment` expects)."""
    import numpy as np
    from scipy.signal import resample_poly
    import mlx_whisper

    target_sr = 16000
    from math import gcd
    g = gcd(sr, target_sr)
    resampled = resample_poly(mono, target_sr // g, sr // g)
    audio = resampled.astype(np.float32)
    lang = None if language in (None, "", "auto") else language
    result = mlx_whisper.transcribe(
        audio,
        path_or_hf_repo=MODEL,
        word_timestamps=True,
        language=lang,
    )
    words = []
    for seg in result.get("segments", []):
        for w in seg.get("words", []):
            words.append({"word": w.get("word", "").strip(),
                          "start": float(w.get("start", 0.0)),
                          "end": float(w.get("end", 0.0))})
    return words


# MARK: - The analysis cache

MODEL = "mlx-community/whisper-large-v3-turbo"


def cache_directory():
    """`~/Library/Caches/Objekat/separateur-voix/` (`OBJEKAT_SEPARATEUR_CACHE` overrides it, which is
    what lets a test use a folder of its own)."""
    return os.environ.get("OBJEKAT_SEPARATEUR_CACHE") or os.path.join(
        os.path.expanduser("~"), "Library", "Caches", "Objekat", "separateur-voix")


def cache_key(file_path, source_offset, duration, speed, language, no_asr, model=MODEL):
    """What the analysis of an object depends on — the file (path, modification time, size), the
    portion of it that plays (offset, duration, speed), the language, whether Whisper ran, which
    model, and the version of the features. A different value anywhere is a different analysis."""
    import hashlib
    st = os.stat(file_path)
    fields = [os.path.realpath(file_path), st.st_mtime_ns, st.st_size,
              round(float(source_offset), 6), round(float(duration), 6), round(float(speed), 6),
              language or "", bool(no_asr), model, detect.FEATURES_VERSION]
    return hashlib.sha1(json.dumps(fields).encode("utf-8")).hexdigest()


_FEATURE_FIELDS = ("times", "energy_db", "hf_lf_ratio_db", "e_mid_db", "zcr", "flatness",
                   "voicing", "e_hf_db")


def save_analysis(path, words, feats, sr):
    import numpy as np
    arrays = {name: getattr(feats, name) for name in _FEATURE_FIELDS}
    arrays["hop_s"] = np.array(feats.hop_s)
    arrays["sr"] = np.array(float(sr))
    arrays["words"] = np.frombuffer(json.dumps(words).encode("utf-8"), dtype=np.uint8)
    tmp = path + ".tmp.npz"
    np.savez(tmp, **arrays)
    os.replace(tmp, path)


def load_analysis(path):
    """(words, feats, sr), or None for a file that is missing or unreadable — a corrupt cache is
    a recomputation, never an error."""
    import numpy as np
    try:
        with np.load(path) as z:
            words = json.loads(bytes(z["words"]).decode("utf-8"))
            feats = detect.Features(hop_s=float(z["hop_s"]), **{n: z[n] for n in _FEATURE_FIELDS})
            return words, feats, float(z["sr"])
    except Exception:
        return None


def cached_analysis(key, compute):
    """`compute()` → (words, feats, sr) runs only when nothing valid is cached under `key`."""
    folder = cache_directory()
    path = os.path.join(folder, key + ".npz")
    hit = load_analysis(path) if os.path.exists(path) else None
    if hit is not None:
        return hit
    words, feats, sr = compute()
    try:
        os.makedirs(folder, exist_ok=True)
        save_analysis(path, words, feats, sr)
    except OSError:
        pass   # a cache that cannot be written is a cache that is not there
    return words, feats, sr


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
           "count": lambda n, s: "%d respiration%s, %.1f s" % (n, "" if n <= 1 else "s", s)},
    "en": {"title": "Evaluate breaths", "analysing": "Analysing…",
           "none": "No breath found — nothing is cut.",
           "count": lambda n, s: "%d breath%s, %.1f s" % (n, "" if n == 1 else "es", s)},
    "es": {"title": "Evaluar respiraciones", "analysing": "Analizando…",
           "none": "Ninguna respiración — no se corta nada.",
           "count": lambda n, s: "%d respiraci%s, %.1f s" % (n, "ón" if n == 1 else "ones", s)},
}

# (id, min, max, step, unit, {language: label}) — the defaults are BreathParams's own.
BREATH_CRITERIA = [
    ("gap", 40, 400, 10, "ms", {"fr": "Trou entre mots ≥", "en": "Gap between words ≥", "es": "Hueco entre palabras ≥"}),
    ("unvoiced", 0.1, 0.9, 0.01, "", {"fr": "Voisement <", "en": "Voicing <", "es": "Sonoridad <"}),
    ("above_floor", 0, 30, 1, "dB", {"fr": "Énergie > plancher +", "en": "Energy > floor +", "es": "Energía > suelo +"}),
    ("below_speech", 0, 40, 1, "dB", {"fr": "Énergie < parole −", "en": "Energy < speech −", "es": "Energía < habla −"}),
    ("flatness", 0, 0.5, 0.01, "", {"fr": "Platitude >", "en": "Flatness >", "es": "Planitud >"}),
    ("hf_lf", -20, 20, 1, "dB", {"fr": "Aigus/graves <", "en": "Highs/lows <", "es": "Agudos/graves <"}),
    ("min_len", 0, 400, 10, "ms", {"fr": "Durée ≥", "en": "Length ≥", "es": "Duración ≥"}),
    ("fill", 0, 100, 5, "ms", {"fr": "Bouchage des trous", "en": "Fill holes", "es": "Rellenar huecos"}),
    ("end_margin", 0, 60, 5, "ms", {"fr": "Marge de fin", "en": "End margin", "es": "Margen final"}),
]


def panel_controls(language):
    """One checkbox + one slider per criterion; the slider is greyed while its box is unchecked
    (`enabled_by`), which is the whole 'box and threshold' idea."""
    defaults = detect.BreathParams()
    controls = []
    for cid, lo, hi, step, unit, labels in BREATH_CRITERIA:
        label = labels.get(language, labels["en"])
        controls.append({"id": cid + "_on", "kind": "bool", "label": label, "value": True})
        controls.append({"id": cid, "kind": "number", "label": label, "value": getattr(defaults, cid),
                         "min": lo, "max": hi, "step": step, "unit": unit, "enabled_by": cid + "_on"})
    return controls


def breaths_eval(app, object_id, language, no_asr):
    """Shows the breaths the detector finds on ONE object, as zones over it, and lets the hand move
    the nine criteria until they are right; Validate then cuts exactly what is shown. Nothing is
    changed before that: the zones are an overlay (never in the project), and Cancel — or the
    window closing, or this process dying — leaves the project untouched."""
    obj = app.send("object.get", {"id": object_id})
    check_object(obj, object_id)
    text = PANEL_TEXT.get(language, PANEL_TEXT["en"])
    start, duration = obj["start"], obj["duration"]

    panel = app.send("script.panel.open", {
        "title": text["title"], "controls": panel_controls(language), "object": object_id,
        "status": text["analysing"], "busy": True})
    pid = panel["panel_id"]

    def status(message, busy=False):
        app.send("script.panel.update", {"panel_id": pid, "status": message, "busy": busy})

    try:
        key = cache_key(obj["file"], obj["source_offset"], duration, obj.get("speed", 1.0),
                        language, no_asr)

        def analyse():
            mono, sr = read_portion(obj["file"], obj["source_offset"], duration, obj.get("speed", 1.0))
            words = None if no_asr else transcribe(mono, sr, language)
            return words, detect.compute_features(mono, sr), sr

        words, feats, _sr = cached_analysis(key, analyse)
        if words:
            app.send("overlay.set", {"id": object_id, "texts": [
                {"start": w["start"], "end": w["end"], "text": w["word"]} for w in words]})

        stats_by_voicing, gaps_by_gap = {}, {}

        def regions_for(values):
            p = detect.BreathParams.from_values(values)
            if p.unvoiced not in stats_by_voicing:
                stats_by_voicing[p.unvoiced] = detect.breath_stats(feats, p.unvoiced)
            if p.gap not in gaps_by_gap:
                gaps_by_gap[p.gap] = detect.word_gaps(words, duration, p.gap)
            return detect.breath_mask(feats, stats_by_voicing[p.unvoiced], gaps_by_gap[p.gap], p)

        def show(values):
            regions = regions_for(values)
            app.send("overlay.set", {"id": object_id, "replace": ["zones"],
                                     "zones": [{"start": lo, "end": hi, "color": "white"}
                                               for lo, hi in regions]})
            status(text["count"](len(regions), sum(hi - lo for lo, hi in regions)))
            return regions

        current = app.send("script.panel.get", {"panel_id": pid})
        regions = show(current["values"])
        rev = current["rev"]

        while True:
            current = app.send("script.panel.wait",
                               {"panel_id": pid, "since_rev": rev, "timeout_ms": 1000})
            if current["state"] != "open":
                break
            if current["rev"] != rev:
                rev = current["rev"]
                regions = show(current["values"])

        if current["state"] == "validated":
            regions = regions_for(current["values"])
            if not regions:
                status(text["none"])
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
        breaths_eval(app, target, language, no_asr)
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
