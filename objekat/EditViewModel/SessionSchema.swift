import Foundation

// MARK: - Session format notice

/// What a project manifest (`<name>.json`) holds, written AT THE HEAD of the file (the
/// `_readme` key) and served
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
    static let formatVersion = 15

    /// One entry per line: JSON has no multi-line string, and an array stays readable in the raw
    /// file where one long string full of `\n` does not.
    static let note: [String] = [
        "OBJEKAT session — format \(formatVersion). Sound object editor (musique concrète).",
        "",
        "PROJECT FOLDER — this file lives at its root; several versions can live side by side and",
        "share: samples/ (imported sounds), samples/objects/ (baked consolidated objects plus their",
        "sidecars *_objectstate.json), waveforms/ (display caches, throwaway).",
        "File paths are RELATIVE to that folder when the file lives in it: the folder can be",
        "moved. A path outside the folder stays absolute.",
        "",
        "items — a TREE, not a flat list. A group carries its children in kind.children;",
        "  a child never appears at the top level.",
        "kind.type — clip (filePath, sourceOffset, fileDuration, speedRatio, isReversed),",
        "  group (children, isExpanded), aux (only receives sends, holds no file),",
        "  midiClip (notes, lengthBeats; the virtual instrument lives in `instruments`).",
        "fileSize — the source file's size in bytes, on a clip only, written when it is known.",
        "  It settles which of two files carrying the same name is the right one when a broken",
        "  link is repaired. Absent = unknown (a session written before format 14), and a repair",
        "  then falls back on the name alone.",
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
        "consolidateDefinitions — the registry of CONSOLIDATED OBJECTS: content baked once, laid down as N",
        "  instances. An item whose consolidateID points here is an instance: its content is the",
        "  definition's, but its position, its fades and its gain are its own.",
        "  revision is bumped on every re-bake; dependsOn is what detects stale definitions.",
        "  Changing a definition updates every one of its instances.",
        "",
        "viewport — timeline zoom and framing. Purely visual, with no effect on the sound.",
        "snapEnabled — whether the snap was on when the project was saved. It belongs to the",
        "  PROJECT and not to the app: a session built off the grid reopens off the grid. Absent =",
        "  on, which is where the app and a fresh project start.",
        "",
        "markerLanes — the rows of the marker band: { name, colorIndex, isVisible, markers }. A row",
        "  is a named layer one can show or hide; hiding it keeps everything on it, it is not a",
        "  deletion. Several rows let several readings of one project coexist.",
        "  A mark: { time, duration, name }. A REGION IS A MARKER THAT HAS AN END — duration 0 = a",
        "  point, > 0 = a span; there is no separate region type. Times in SECONDS, ABSOLUTE on the",
        "  timeline here.",
        "  An object can carry marks of its own (items[].markers, the same shape) — but THOSE times",
        "  are RELATIVE to the start of the object, exactly like its automation points, and they",
        "  follow its matter through a cut, a trim, a reverse, a varispeed and a ripple (a mark",
        "  pushed behind an edge keeps a NEGATIVE time and comes back if the edge is reopened).",
        "  Same type, two frames of reference: that is this section's trap.",
        "  colorIndex on a mark is an EXCEPTION, and it is written only when there is one: with no",
        "  key, a mark takes the colour of what carries it — its row here, white inside an object.",
        "comments — free texts laid over a span of the timeline: { startTime, duration, lane, text,",
        "  parentID }. The text is markdown (inline: bold, italic, code, links). They live BESIDE",
        "  items and not inside: a comment carries no sound. No colorIndex = WHITE, which is not a",
        "  hue of the object palette: a note must never read as one more object laid on the lane.",
        "  lane is a BASE row, like items[].lane and not the visual row index: what is unfolded",
        "  above it (an open group, a piano roll, an automation band) pushes it down on screen.",
        "  parentID — the GROUP the comment lives in, recursively; absent = the timeline itself",
        "  (which is every comment of a session written before format 15). WITH a parent, the two",
        "  coordinates change frame, exactly as a group's children do: startTime becomes RELATIVE",
        "  to that group's start, and lane a row of the group's own band (0 = the first row under",
        "  it). That is what makes the note follow its group when it is moved or copied, and why it",
        "  is not drawn at all while the group is folded. It is this section's second trap, the",
        "  first being the two frames of a marker just above.",
        "  Markers, regions and comments are purely visual — nothing here changes what is heard.",
        "",
        "TO ACT ON THIS PROJECT — prefer the app's command API (UNIX socket, JSON-lines, `help`",
        "  describes itself): it keeps the invariants this file does not state. Editing the JSON",
        "  by hand assumes the app is CLOSED on this project, otherwise the next save overwrites",
        "  it. See 'docs/command_api.md'.",
    ]
}
