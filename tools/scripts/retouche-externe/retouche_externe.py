#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""External edit — bounce an object to a NEW FILE, retouch it in another audio editor, bring it back.

"Consolidate" in the classic DAW sense (not OBJEKAT's consolidated object): the object is
RENDERED into a new wav — its chain, its fades and its window included — the file is handed to the
editor the user chose (asked once, at the first launch, remembered in `config.json`), and when the
user says "done" the retouched file is laid back into the session.

Contract with the app: a separate process that talks to the socket (@see docs/command_api.md,
"Third-party scripts"). Human messages go to stderr with exit != 0 — the app surfaces them.

What it does NOT do, on purpose:
  • it never touches the original object beyond MUTING it: the retouched clip is laid on a NEW row
    (inside the same group if the original is a group's child), so one ⌘Z, a click on the speaker, or deleting one of the two is enough to go back;
  • it writes no preference of the app, only its own `config.json`.

What to know: the render is "just the object" (`object.render_isolated`): it carries everything that
belongs to the object — its own plugins, gain and pan, fades, window and speed (its content, for a
group) — and NOTHING around it: no parent group's chain, no master, no aux or sends. The retouched
file laid back at the same start is therefore iso with the object as it sounded alone (same level,
same position), and the new clip has no plugin, gain or fade of its own to apply them a second time.
The render keeps the sample rate of the original's source file (for a group: the files below it; if they
disagree, a small panel asks which one — Cancel stops everything before any render); BIT_DEPTH stays 24,
and SAMPLE_RATE (48 kHz) is only the fallback for an object with no audio file (MIDI).
The object is put in direct solo for the render (so a mute or another solo cannot silence it), then
the previous solo is restored.
"""

import json
import os
import re
import struct
import subprocess
import sys

import socket

SOCK = os.environ.get("OBJEKAT_SOCKET")
HERE = os.environ.get("OBJEKAT_PLUGIN_DIR") or os.path.dirname(os.path.abspath(__file__))
LANG = (os.environ.get("OBJEKAT_LANGUAGE") or "en")[:2]
LANG = LANG if LANG in ("fr", "en", "es") else "en"
CONFIG = os.path.join(HERE, "config.json")
SAMPLE_RATE = 48000  # fallback only: used when the object has no audio file to read a rate from (MIDI…)
BIT_DEPTH = 24


def tr(fr, en, es):
    return {"fr": fr, "en": en, "es": es}[LANG]


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
            raise RuntimeError(response.get("error"))
        return response["result"]


class Failure(Exception):
    """A message meant for the user (stderr, exit 1)."""


# --- the editor ------------------------------------------------------------------------------

def load_config():
    try:
        with open(CONFIG, "r", encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return {}


def save_config(config):
    os.makedirs(HERE, exist_ok=True)
    tmp = CONFIG + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(config, f, indent=2, ensure_ascii=False)
    os.replace(tmp, CONFIG)


def q(text):
    """An AppleScript string literal: only \\ and " need escaping (UTF-8 accents are fine as they are)."""
    return '"' + text.replace("\\", "\\\\").replace('"', '\\"') + '"'


def choose_editor(app=None):
    """A Finder file dialog opened on /Applications. Returns the .app path, or None if cancelled."""
    prompt = tr("Choisissez l'éditeur audio pour les retouches", "Choose the audio editor for retouching",
                "Elija el editor de audio para los retoques")
    folder = "/Applications" if os.path.isdir("/Applications") else os.path.expanduser("~")
    script = ("tell current application to activate\n"
              "POSIX path of (choose file of type {\"com.apple.application-bundle\"} "
              "default location (POSIX file %s as alias) with prompt %s)") % (q(folder), q(prompt))
    result = subprocess.run(["osascript", "-e", script], capture_output=True, text=True)
    if result.returncode != 0:
        err = result.stderr.strip()
        if "-128" in err:
            return None  # the user cancelled
        raise Failure(tr("Le sélecteur de fichiers a échoué : %s", "The file chooser failed: %s",
                         "El selector de archivos falló: %s") % err)
    return result.stdout.strip().rstrip("/") or None


def editor_path(app, force_choice=False):
    config = load_config()
    path = config.get("editor")
    if force_choice or not path or not os.path.isdir(path):
        chosen = choose_editor(app)
        if not chosen:
            if force_choice and path and os.path.isdir(path):
                return path  # cancelled: keep what there was
            raise Failure(tr("Aucun éditeur audio choisi — rien n'a été fait.",
                             "No audio editor chosen — nothing was done.",
                             "No se eligió ningún editor de audio — no se hizo nada."))
        config["editor"] = chosen
        save_config(config)
        path = chosen
    return path


def open_in_editor(editor, file_path):
    result = subprocess.run(["open", "-a", editor, file_path], capture_output=True, text=True)
    if result.returncode != 0:
        raise Failure(tr("Impossible d'ouvrir l'éditeur « %s » : %s",
                         "Could not open the editor “%s”: %s",
                         "No se pudo abrir el editor «%s»: %s") % (editor, result.stderr.strip()))


# --- the object ------------------------------------------------------------------------------

def safe_name(name):
    name = re.sub(r"[\\/:*?\"<>|\x00-\x1f]", "_", name).strip(" .") or "object"
    return name[:60]


def work_folder(app):
    info = app.send("app.info")
    project_path = info.get("project_path")
    if project_path:
        base = os.path.join(os.path.dirname(project_path), "samples", "retouches")
    else:
        base = os.path.join(os.path.expanduser("~/Library/Application Support/Objekat"), "Retouches")
    os.makedirs(base, exist_ok=True)
    return base


def unique_path(folder, stem, suffix):
    path = os.path.join(folder, "%s%s.wav" % (stem, suffix))
    n = 2
    while os.path.exists(path):
        path = os.path.join(folder, "%s%s %d.wav" % (stem, suffix, n))
        n += 1
    return path


def file_sample_rate(path):
    """The sample rate of an audio file, or None. WAV/RF64 header read by hand (stdlib `wave` refuses
    extensible and float formats); anything else (AIFF, FLAC, MP3, CAF…) through macOS `afinfo`."""
    try:
        with open(path, "rb") as f:
            if f.read(4) in (b"RIFF", b"RF64"):
                f.read(4)
                if f.read(4) == b"WAVE":
                    while True:
                        head = f.read(8)
                        if len(head) < 8:
                            break
                        chunk_id, size = head[:4], struct.unpack("<I", head[4:])[0]
                        if chunk_id == b"fmt ":
                            fmt = f.read(8)
                            if len(fmt) == 8:
                                return struct.unpack("<I", fmt[4:8])[0] or None
                            break
                        f.seek(size + (size & 1), 1)
    except OSError:
        return None
    try:
        out = subprocess.run(["afinfo", path], capture_output=True, text=True).stdout
        m = re.search(r"(\d+(?:\.\d+)?)\s*Hz", out)
        return int(round(float(m.group(1)))) if m else None
    except OSError:
        return None


def source_sample_rates(app, obj):
    """{rate: number of audio files read at that rate} for the object: its own file, or, for a group,
    the files of every clip below it. Empty when there is no readable audio file (MIDI…)."""
    objects = app.send("object.list").get("objects", [])
    below = {obj["id"]}
    grew = True
    while grew:  # the descendants, whatever the depth
        grew = False
        for o in objects:
            if o.get("parent") in below and o["id"] not in below:
                below.add(o["id"])
                grew = True
    rates = {}
    for o in objects:
        if o["id"] in below and o.get("kind") == "clip" and o.get("file"):
            rate = file_sample_rate(o["file"])
            if rate:
                rates[rate] = rates.get(rate, 0) + 1
    return rates


def choose_rate(app, rates):
    """The object's sources do not agree on a rate: ask. Returns the chosen rate, or None if cancelled."""
    ordered = sorted(rates, key=lambda r: (-rates[r], r))  # the most used first = the default
    panel = app.send("script.panel.open", {
        "title": tr("Retouche externe", "External edit", "Edición externa"),
        "controls": [{"id": "rate", "kind": "choice",
                      "label": tr("Fréquence d'échantillonnage", "Sample rate", "Frecuencia de muestreo"),
                      "value": str(ordered[0]),
                      "options": [{"id": str(r), "label": "%d Hz  (%d)" % (r, rates[r])} for r in ordered]}],
        "status": tr("Les fichiers de ce groupe n'ont pas tous la même fréquence : laquelle utiliser pour la retouche ?",
                     "The files in this group do not share one sample rate: which one for the edit?",
                     "Los archivos de este grupo no comparten frecuencia: ¿cuál usar para el retoque?"),
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
        except Exception:
            pass


def render_object(app, obj, out_path, sample_rate):
    """Renders `obj` ALONE (the object and what belongs to it, nothing of its surroundings — a direct
    solo only guarantees it is audible, restored afterwards) over its own span into out_path."""
    before = app.send("solo.get")
    previous = before.get("confirmed") or []
    app.send("solo.clear")
    app.send("solo.set", {"ids": [obj["id"]]})
    try:
        job = app.send("object.render_isolated", {
            "id": obj["id"], "path": out_path,
            "sample_rate": sample_rate, "bit_depth": BIT_DEPTH,
            "start": obj["start"], "end": obj["start"] + obj["duration"],
        })
        while True:
            try:
                state = app.send("job.wait", {"id": job["job_id"], "timeout_ms": 5000})
            except RuntimeError as e:
                if "timeout" in str(e).lower() or "still running" in str(e).lower():
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
    objects = app.send("object.list").get("objects", [])
    return max([o.get("display_lane", 0) for o in objects] + [-1]) + 1


# --- waiting for the user --------------------------------------------------------------------

def wait_for_user(app, editor_name, file_name):
    """A small panel: Validate = bring the file back, Cancel = leave everything as it is.
    Returns True on Validate."""
    panel = app.send("script.panel.open", {
        "title": tr("Retouche externe", "External edit", "Edición externa"),
        "controls": [],
        "status": tr("« %s » est ouvert dans %s. Validez quand vous avez enregistré.",
                     "“%s” is open in %s. Validate once you have saved it.",
                     "«%s» está abierto en %s. Valide cuando lo haya guardado.") % (file_name, editor_name),
    })
    pid, rev = panel["panel_id"], panel.get("rev", 0)
    try:
        while True:
            state = app.send("script.panel.wait", {"panel_id": pid, "since_rev": rev, "timeout_ms": 2000})
            rev = state.get("rev", rev)
            if state.get("state") == "validated":
                return True
            if state.get("state") in ("cancelled", "closed"):
                return False
    finally:
        try:
            app.send("script.panel.close", {"panel_id": pid})
        except Exception:
            pass


# --- main ------------------------------------------------------------------------------------

def run():
    if not SOCK:
        raise Failure("OBJEKAT_SOCKET missing: run this script from OBJEKAT's Scripts menu.")

    app = Objekat(SOCK)
    if "--choose-editor" in sys.argv:
        path = editor_path(app, force_choice=True)
        print("Editor: %s" % path)
        return 0

    ids = [i for i in (os.environ.get("OBJEKAT_OBJECT_IDS") or "").split(",") if i]
    if len(ids) != 1:
        raise Failure(tr("Sélectionnez un seul objet à retoucher.", "Select a single object to retouch.",
                         "Seleccione un solo objeto para retocar."))

    editor = editor_path(app)  # first launch: asks, then remembers
    obj = app.send("object.get", {"id": ids[0]})

    if obj.get("kind") == "aux" or obj.get("infinite"):
        raise Failure(tr("Un bus ne peut pas être retouché ainsi.", "A bus cannot be retouched this way.",
                         "Un bus no se puede retocar así."))
    if obj.get("missing"):
        raise Failure(tr("Le fichier de cet objet est introuvable.", "This object's file is missing.",
                         "No se encuentra el archivo de este objeto."))
    if not obj.get("duration", 0) > 0:
        raise Failure(tr("Objet vide.", "Empty object.", "Objeto vacío."))

    # The rate of the original's source file(s) — the file sent to the editor and the one that comes
    # back keep it. A group whose files disagree: the user decides (nothing is rendered if cancelled).
    rates = source_sample_rates(app, obj)
    if len(rates) > 1:
        sample_rate = choose_rate(app, rates)
        if sample_rate is None:
            return 0
    else:
        sample_rate = next(iter(rates), SAMPLE_RATE)

    name = obj.get("name") or "object"
    stem = safe_name(name)
    folder = work_folder(app)
    out_path = unique_path(folder, stem, " (retouche)")
    render_object(app, obj, out_path, sample_rate)

    before = os.stat(out_path).st_mtime_ns
    open_in_editor(editor, out_path)
    editor_name = os.path.splitext(os.path.basename(editor))[0]
    if not wait_for_user(app, editor_name, os.path.basename(out_path)):
        return 0  # cancelled: nothing touched in the session
    if os.stat(out_path).st_mtime_ns == before:
        print("Note: the file was not modified by the editor; it is brought back as it is.", file=sys.stderr)

    # The retouched file lands where the source lives: inside the SAME group when the source is a
    # child (a new sub-lane at the end of that group), on a new root row otherwise.
    params = {"path": out_path, "start": obj["start"]}
    if obj.get("parent"):
        params["group"] = obj["parent"]
    else:
        params["lane"] = next_free_lane(app)
    added = app.send("object.add", params)
    app.send("object.rename", {"id": added["id"], "name": "%s (%s)" % (name, tr("retouche", "retouched", "retocado"))})
    app.send("object.set_mute", {"ids": [obj["id"]], "muted": True})
    return 0


if __name__ == "__main__":
    try:
        sys.exit(run())
    except Failure as e:
        sys.stderr.write(str(e) + "\n")
        sys.exit(1)
    except Exception as e:  # noqa: BLE001 — anything else is reported, not swallowed
        sys.stderr.write("%s: %s\n" % (type(e).__name__, e))
        sys.exit(1)
