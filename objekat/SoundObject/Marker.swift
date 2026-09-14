import Foundation

// MARK: - Markers, regions

/// A named point in time — or a named SPAN, when `duration > 0`.
///
/// ONE type for the marker and the region, because a region IS a marker that has an end: the
/// name, the selection, the deletion, the renaming, the persistence and the command API are the
/// same thing twice otherwise. Only the DRAWING branches on `isRegion` (a flag against a bar), and
/// that is one `if` rather than a second implementation.
///
/// TWO FRAMES OF REFERENCE, and this is the trap to keep in mind — the same trap the session
/// format already carries between seconds and beats:
///   - in `MarkerLane.markers`, `time` is ABSOLUTE on the timeline;
///   - in `SoundObject.markers`, `time` is RELATIVE to the start of the object, exactly like an
///     automation point (@see AutomationPoint) and for the same reason: moving the object, changing
///     its lane or trimming its right edge then costs nothing.
/// Nothing in the type distinguishes the two — a marker does not know where it lives. The
/// transformations below are written for the RELATIVE frame (they are what an editing gesture
/// applies to an object's markers); a lane's markers only ever get `shiftedInTime`, and only when
/// the whole timeline slides.
struct Marker: Codable, Equatable, Identifiable {
    var id: UUID = UUID()
    var time: Double
    /// 0 = a point (a marker). > 0 = a span (a region).
    var duration: Double = 0
    var name: String = ""
    /// Its own hue, an index into `ObjectColorPalette`. nil = it takes the colour of whatever
    /// carries it — the ROW for a mark of the band, white for one carried by an object.
    ///
    /// Inheritance is the default on purpose: a colour is laid on a mark to say what KIND of mark
    /// it is (a cue, a question, a thing to redo), and a row recoloured must recolour everything on
    /// it that has not asked for otherwise. A hue set here is a deliberate exception, and it
    /// outlives a recolouring of the row.
    var colorIndex: Int? = nil

    init(id: UUID = UUID(), time: Double, duration: Double = 0, name: String = "",
         colorIndex: Int? = nil) {
        self.id = id
        self.time = time
        self.duration = duration
        self.name = name
        self.colorIndex = colorIndex
    }

    /// A tolerance rather than `> 0`: a region dragged down to nothing by a splice, or one whose
    /// bounds were computed, must read as a point rather than as a bar 3 nanoseconds wide.
    var isRegion: Bool { duration > 1e-9 }
    var endTime: Double { time + duration }

    enum CodingKeys: String, CodingKey { case id, time, duration, name, colorIndex }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id         = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        time       = try c.decode(Double.self, forKey: .time)
        duration   = try c.decodeIfPresent(Double.self, forKey: .duration) ?? 0
        name       = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        colorIndex = try c.decodeIfPresent(Int.self, forKey: .colorIndex)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(time, forKey: .time)
        if duration != 0 { try c.encode(duration, forKey: .duration) }
        if !name.isEmpty { try c.encode(name, forKey: .name) }
        // Written only when it IS an exception: an absent key reads as 'the colour of what carries
        // me', which is what nearly every mark wants.
        if let colorIndex { try c.encode(colorIndex, forKey: .colorIndex) }
    }
}

/// One ROW of the marker band: a named, colour-coded, showable/hideable layer holding markers and
/// regions together.
///
/// WHY SEVERAL ROWS rather than the single lane a DAW usually offers. A project passes through
/// several hands, and each pass wants to leave its own marks without erasing the previous ones —
/// the mixing notes, the editing points, someone else's questions. A row one can hide is what
/// makes those readings coexist; one row shared by everybody would make them fight for the same
/// 16 pixels.
///
/// A row is PURELY VISUAL: it names moments, it changes nothing that is heard. Nothing in the
/// engine knows it exists.
struct MarkerLane: Codable, Equatable, Identifiable {
    var id: UUID = UUID()
    var name: String
    var colorIndex: Int
    /// Hidden = the row keeps its content and gives its 16 px back. It is not a deletion.
    var isVisible: Bool = true
    var markers: [Marker] = []

    init(id: UUID = UUID(), name: String, colorIndex: Int, isVisible: Bool = true,
         markers: [Marker] = []) {
        self.id = id
        self.name = name
        self.colorIndex = colorIndex
        self.isVisible = isVisible
        self.markers = markers
    }

    /// Markers in reading order. Storage is not assumed sorted — creating one in the middle of a
    /// row would otherwise have to hold that invariant, and nothing needs it but the drawing.
    var sortedMarkers: [Marker] { markers.sorted { $0.time < $1.time } }

    enum CodingKeys: String, CodingKey { case id, name, colorIndex, isVisible, markers }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id         = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name       = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        colorIndex = try c.decodeIfPresent(Int.self, forKey: .colorIndex) ?? 0
        isVisible  = try c.decodeIfPresent(Bool.self, forKey: .isVisible) ?? true
        markers    = try c.decodeIfPresent([Marker].self, forKey: .markers) ?? []
    }
}

// MARK: - A comment laid on the timeline

/// A free text laid over a span of the timeline: a note to oneself or to the next person, in the
/// place it talks about.
///
/// It is NOT a `SoundObject`, and that is a decision rather than a shortcut. The closest precedent
/// in the model is the `aux` — an object that holds no file — and it reaches 22 files and 62 sites,
/// while still creating an object on the engine's side. A comment would be the first item with NO
/// engine object at all: a new special case in the one place of the project it is least safe to add
/// one (the engine sync). Living beside `items` instead, it touches neither the engine, nor the
/// bake, nor the export, nor the stems.
///
/// The accepted cost: it inherits nothing for free. It does not move with a ripple, a cut or a
/// dragged object — those gestures have to name it explicitly, and until they do, a comment stays
/// where it was put.
struct TimelineComment: Codable, Equatable, Identifiable {
    var id: UUID = UUID()
    var startTime: Double
    var duration: Double
    /// The DISPLAY row it is laid on, in the same frame as `SoundObject.lane`. A comment has no
    /// content to nest, so it never belongs to a container: it is always read at the top level.
    var lane: Int
    /// The text, in markdown. Inline only (bold, italic, code, links) — that is what SwiftUI's
    /// `AttributedString(markdown:)` renders in a `Text`, and it is what a note needs.
    var text: String = ""
    /// A hue from `ObjectColorPalette`, or nil — and nil is WHITE rather than a hue of the palette.
    /// A comment is not matter: it must not read as one more object laid on the lane, and white is
    /// the one value the object palette does not hold. A hue is then something one CHOOSES, to sort
    /// the notes among themselves.
    var colorIndex: Int? = nil

    init(id: UUID = UUID(), startTime: Double, duration: Double, lane: Int,
         text: String = "", colorIndex: Int? = nil) {
        self.id = id
        self.startTime = startTime
        self.duration = duration
        self.lane = lane
        self.text = text
        self.colorIndex = colorIndex
    }

    var endTime: Double { startTime + duration }

    enum CodingKeys: String, CodingKey { case id, startTime, duration, lane, text, colorIndex }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id         = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        startTime  = try c.decode(Double.self, forKey: .startTime)
        duration   = try c.decode(Double.self, forKey: .duration)
        lane       = try c.decodeIfPresent(Int.self, forKey: .lane) ?? 0
        text       = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        colorIndex = try c.decodeIfPresent(Int.self, forKey: .colorIndex)
    }
}

// MARK: - Transformations of an object's markers under the editing gestures
//
// The strict counterpart of `Array where Element == AutomationLane` (@see Automation.swift), with
// the SAME five names and the same semantics — because these two payloads are transformed at the
// same ~30 call sites, one line each. Two identical names side by side is what keeps a gesture from
// remembering the curves and forgetting the markers.
//
// The one place they part company is the empty case. An empty curve must never be created (the
// 'no point = no automation' invariant, where an absent row hands the parameter back to its static
// value); an empty marker list is simply a list with nothing in it, and a marker whose material
// has gone is DELETED rather than interpolated — a name for a passage that no longer exists would
// be a lie, where a curve's value is still needed.
extension Array where Element == Marker {

    /// Markers shifted by `dt` in the object's frame. `dt < 0` = the origin moves forward
    /// (trimming the left edge, the right half of a cut): the marker stays stuck to the MATERIAL
    /// and not to the edge.
    ///
    /// Non-destructive, exactly like an automation point and a trimmed clip's MIDI notes: a marker
    /// pushed past the start keeps a NEGATIVE time and comes back if the edge is reopened. It is
    /// simply not drawn.
    func shiftedInTime(by dt: Double) -> [Marker] {
        guard dt != 0 else { return self }
        return map { var m = $0; m.time += dt; return m }
    }

    /// Time scaled (varispeed). `k` = the timeline's stretch factor, `oldSpeed / newSpeed`: a
    /// region has to tighten with the material it names, hence its `duration` scaling too.
    func timeScaled(by k: Double) -> [Marker] {
        guard k > 0, k != 1 else { return self }
        return map { var m = $0; m.time *= k; m.duration *= k; return m }
    }

    /// Flipped inside a window of length `duration` — the counterpart of a clip played backwards.
    /// A point at `t` lands on `duration - t`; a region [t, t+d] lands on
    /// [duration - t - d, duration - t], since it is the SPAN that mirrors and not its left edge.
    func mirroredInTime(over duration: Double) -> [Marker] {
        map { var m = $0; m.time = duration - m.endTime; return m }
    }

    /// Cuts at the relative time `s`: what is before stays in the left frame, what is after is
    /// rebased on the cut.
    ///
    /// A REGION that straddles the cut is divided in two, each half keeping the name — the same
    /// thing that happens to the object itself, whose two halves both keep their label. A region
    /// names a passage; cutting the passage cuts the region.
    func splitInTime(at s: Double) -> (left: [Marker], right: [Marker]) {
        var l: [Marker] = [], r: [Marker] = []
        for m in self {
            // A point, or a region entirely on one side.
            if m.endTime <= s || !m.isRegion {
                if m.time < s { l.append(m) }
                else { var q = m; q.time -= s; r.append(q) }
                continue
            }
            if m.time >= s {
                var q = m; q.time -= s; r.append(q)
                continue
            }
            // A region straddling the cut: one half each, the name on both.
            var left = m
            left.duration = s - m.time
            l.append(left)
            var right = m
            right.id = UUID()          // two halves cannot share an identity
            right.time = 0
            right.duration = m.endTime - s
            r.append(right)
        }
        return (l, r)
    }

    /// Takes the span [from, to] out and closes the gap behind it (the ripple's counterpart of
    /// `splitInTime`, for an object that keeps ONE identity).
    ///
    /// A marker inside the hole DISAPPEARS: it named material that has gone. A region overlapping
    /// the hole loses the overlapping part and keeps the rest; one entirely inside disappears with
    /// it. Times local to the object, as everywhere here.
    func splicedInTime(removing from: Double, to: Double) -> [Marker] {
        let hole = to - from
        guard hole > 1e-9 else { return self }
        var out: [Marker] = []
        for m in self {
            guard m.isRegion else {
                if m.time < from { out.append(m) }
                else if m.time >= to { var q = m; q.time -= hole; out.append(q) }
                continue                                  // inside the hole: it goes
            }
            let lo = Swift.max(m.time, from), hi = Swift.min(m.endTime, to)
            let overlap = Swift.max(0, hi - lo)
            guard overlap > 1e-9 else {                   // wholly outside the hole
                var q = m
                if m.time >= to { q.time -= hole }
                out.append(q)
                continue
            }
            let newDuration = m.duration - overlap
            guard newDuration > 1e-9 else { continue }    // wholly swallowed
            var q = m
            q.time = Swift.min(m.time, from)
            q.duration = newDuration
            out.append(q)
        }
        return out
    }
}
