"""The small decisions of the spectral-editor script, kept PURE (no socket, no app) so they can be
tested on their own (plan 5, `decide.py`).

- Which depth the result is written at, which depth the render is made at.
- Which sample rates the sources use.
- Whether an object is too long to edit.
- Whether a render is mono.
- Naming and not overwriting.
"""
import os
import re

import numpy as np

# Depth classes: 16 (16-bit integer), 24 (24-bit integer), "f32" (32-bit float), in increasing order.
CLASS_RANK = {16: 0, 24: 1, "f32": 2}
DEFAULT_CLASS = 24

WARN_SECONDS = 120.0
REFUSE_SECONDS = 600.0

OUTPUT_SUFFIX = " (spectral)"

# The controls that can be tuned while a selection is pending, and are heard / seen at once without
# touching the history (plan 9.3): the gain, and the two feathers.
LIVE_KEYS = ("gain", "feather_ms", "feather_st")
FEATHER_KEYS = ("feather_ms", "feather_st")


def depth_class(source_format, bit_depth):
    """The class of one source file: pcm_int 16 -> 16, pcm_int 24 -> 24, pcm_float 32 -> "f32",
    anything else (compressed, 32-bit integer, 64-bit float, unknown) -> 24."""
    if source_format == "pcm_int" and bit_depth == 16:
        return 16
    if source_format == "pcm_int" and bit_depth == 24:
        return 24
    if source_format == "pcm_float" and bit_depth == 32:
        return "f32"
    return DEFAULT_CLASS


def decide_depth(classes):
    """The highest class among `classes` (a group mixing 16-bit and 24-bit sources is written at 24).
    No class at all (no audio file: MIDI) -> 24."""
    classes = list(classes)
    if not classes:
        return DEFAULT_CLASS
    return max(classes, key=lambda c: CLASS_RANK[c])


def render_depth(cls):
    """The bit depth the app renders at: 16 for the 16 class, 24 for the others (the render is
    integer PCM; a float class is written as float from the 24-bit render)."""
    return 16 if cls == 16 else 24


def write_kind(cls):
    """The `wavio.write_wav` kind that stores a class."""
    return {16: "pcm16", 24: "pcm24", "f32": "f32"}[cls]


def rate_counts(rates):
    """{rate: number of files at that rate}; a None (unreadable file) is ignored."""
    counts = {}
    for r in rates:
        if r:
            counts[int(r)] = counts.get(int(r), 0) + 1
    return counts


def duration_verdict(seconds):
    """"ok" up to 120 s included, "warn" above, "refuse" above 600 s."""
    if seconds > REFUSE_SECONDS:
        return "refuse"
    if seconds > WARN_SECONDS:
        return "warn"
    return "ok"


def is_mono(x):
    """True when the render has one channel, or two that are identical sample for sample."""
    x = np.asarray(x)
    if x.ndim == 1 or x.shape[1] == 1:
        return True
    return all(np.array_equal(x[:, 0], x[:, c]) for c in range(1, x.shape[1]))


def output_name(name):
    """The label of the object laid back: "<name> (spectral)"."""
    return "%s%s" % (name, OUTPUT_SUFFIX)


def safe_name(name):
    """A file-system safe stem (same rule as the external-edit script)."""
    name = re.sub(r"[\\/:*?\"<>|\x00-\x1f]", "_", name).strip(" .") or "object"
    return name[:60]


def unique_path(folder, stem, suffix):
    """folder/<stem><suffix>.wav, or ... <suffix> 2.wav, 3 ... as long as the file exists."""
    path = os.path.join(folder, "%s%s.wav" % (stem, suffix))
    n = 2
    while os.path.exists(path):
        path = os.path.join(folder, "%s%s %d.wav" % (stem, suffix, n))
        n += 1
    return path


def preview_dirty(prev_values, values, pending):
    """What a change of the side bar's values makes stale while `pending` selection gestures exist:
    a subset of {"selection", "audio"}.

    - nothing pending: the empty set (the values only matter to the NEXT gesture; a step carries its own);
    - a feather moved: both (the selection's edges moved, so the overlay AND the sound change);
    - only the gain moved: the audio alone (the overlay's opacity is the intensity, not the gain);
    - any other value (the brush, the analysis settings...): nothing here — the analysis settings are
      the loop's own business (a new base image), not a live preview.
    `prev_values` None means "not seen yet": every live key counts as changed."""
    if pending <= 0:
        return set()
    prev = prev_values or {}
    changed = {k for k in LIVE_KEYS if prev_values is None or prev.get(k) != (values or {}).get(k)}
    if changed & set(FEATHER_KEYS):
        return {"selection", "audio"}
    if "gain" in changed:
        return {"audio"}
    return set()


# --- the spectrogram's display range (revision 6) -------------------------------------------------
# DISPLAY ONLY: the hand's floor (the level drawn black) and ceiling (drawn white) of the pictures.
# Nothing here reaches the audio or the history.
DB_FLOOR = (-120.0, -20.0, -100.0)   # (min, max, default)
DB_CEIL = (-60.0, 0.0, 0.0)
DB_MIN_GAP = 6.0                     # the ceiling is kept at least this far above the floor


def display_range(values):
    """(floor, ceiling) in dB from the side bar's `db_floor` / `db_ceiling`: each clamped to its control's
    range (an unreadable value falls back to the default), then the ceiling lifted to floor + DB_MIN_GAP
    when the hand crossed them — the floor never moves, so dragging the floor up carries the ceiling."""
    def read(key, spec):
        lo, hi, default = spec
        try:
            v = float((values or {}).get(key))
        except (TypeError, ValueError):
            v = default
        if v != v:
            v = default
        return min(hi, max(lo, v))

    floor = read("db_floor", DB_FLOOR)
    ceil = read("db_ceiling", DB_CEIL)
    return floor, max(ceil, floor + DB_MIN_GAP)
