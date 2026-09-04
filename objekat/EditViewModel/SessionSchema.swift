import Foundation

// MARK: - Session format notice

/// What a `.objekat.json` holds, written AT THE HEAD of the file (the `_readme` key) and served
/// by the `project.schema` command.
///
/// WHY IN THE FILE. A project travels: you send it to someone, you hand it to a language model,
/// you read it again in two years. Without a notice you need the app's source at hand to know
/// that a MIDI time is in musical time and not in seconds. Cost: ~2 kB per file.
///
/// WHY A SINGLE SOURCE. `ProjectDocument.version` DERIVES from `formatVersion` below: changing
/// the format forces you to open this very file, and therefore to see the text you are making
/// obsolete. A wrong notice is worse than no notice — a reader believes it.
enum SessionSchema {

    /// Version of the session format. THIS is where it gets bumped, along with the text that
    /// describes it.
    static let formatVersion = 10

    /// One entry per line: JSON has no multi-line string, and an array stays readable in the raw
    /// file where one long string full of `\n` does not.
    static let note: [String] = [
        "OBJEKAT session — format \(formatVersion). Sound object editor (musique concrète).",
        "",
        "PROJECT FOLDER — this file lives at its root; several versions can live side by side and",
        "share: samples/ (imported sounds), samples/objects/ (baked sound objects plus their",
        "sidecars *_objectstate.json), waveforms/ (display caches, throwaway).",
        "File paths are RELATIVE to that folder when the file lives in it: the folder can be",
        "moved. A path outside the folder stays absolute.",
        "",
        "items — a TREE, not a flat list. A group carries its children in kind.children;",
        "  a child never appears at the top level.",
        "kind.type — clip (filePath, sourceOffset, fileDuration, speedRatio, isReversed),",
        "  group (children, isExpanded), aux (only receives sends, holds no file),",
        "  midiClip (notes, lengthBeats; the virtual instrument lives in `instruments`).",
        "",
        "TIME — startTime, duration, fadeIn, fadeOut are in SECONDS. MIDI notes, on the other",
        "  hand, are in MUSICAL TIME (startBeat, lengthBeats): converted at the current tempo.",
        "  Mixing the two up is this format's number one trap.",
        "lane — the model's row index. It is NOT the displayed row: an open group visually",
        "  shifts what follows without changing any `lane`.",
        "volume — in dB (0 = neutral). pan — -1 (left) to +1 (right). isMuted — bool.",
        "",
        "stems — the output buses. An object leaves through the bus named by its stemID; stemID",
        "  absent = the main bus.",
        "sends — sends towards an aux object: { auxID, levelDb, enabled }.",
        "plugins / instruments — the effect chain, and virtual instruments at the head for MIDI.",
        "  A plugin can be a rack (parallel branches) and hold other plugins.",
        "",
        "automation — an object's curves, one entry per parameter: { param, points }.",
        "  param names the target: {type:volume|pan|chainInGain|chainOutGain},",
        "  {type:send, auxID} or {type:plugin, pluginKey, paramID}.",
        "  points: { t, v, c }. t is in SECONDS RELATIVE TO THE START OF THE OBJECT (just as",
        "  MIDI notes are in relative beats) — moving or trimming the object leaves them alone.",
        "  v is in the parameter's own unit (dB for gains, -1..+1 for pan, 0..1 normalised for",
        "  a plugin parameter); c is the curvature of the outgoing segment, -1..+1, 0 = straight.",
        "  An entry with no point is never written: no point = no automation, and the field's",
        "  static value rules. As soon as there is one point, the curve is what counts WITHOUT",
        "  any offset: the static value stays written but is no longer heard (it becomes the",
        "  parameter's value again if the curve is removed). One exception only: an object that",
        "  is muted, or left out by a solo, stays silent — its volume curve is set aside for as",
        "  long as it is.",
        "",
        "objectDefinitions — the registry of SOUND OBJECTS: content baked once, laid down as N",
        "  instances. An item whose definitionID points here is an instance: its content is the",
        "  definition's, but its position, its fades and its gain are its own.",
        "  revision is bumped on every re-bake; dependsOn is what detects stale definitions.",
        "  Changing a definition updates every one of its instances.",
        "",
        "viewport — timeline zoom and framing. Purely visual, with no effect on the sound.",
        "",
        "TO ACT ON THIS PROJECT — prefer the app's command API (UNIX socket, JSON-lines, `help`",
        "  describes itself): it keeps the invariants this file does not state. Editing the JSON",
        "  by hand assumes the app is CLOSED on this project, otherwise the next save overwrites",
        "  it. See 'docs/command_api.md'.",
    ]
}
