import Foundation

// MARK: - Addressing an automatable parameter
//
// ParamRef names WHAT is automated, independently of the object carrying it: an automation is
// the pair (ParamRef, [AutomationPoint]). The addressing is uniform — the object's gain and
// pan, the chain trims, a send's level, a plugin's parameter — so that a single code path
// reads, draws and (later) pushes any curve to the engine. Every new target is added HERE,
// not in the views.

/// An automatable parameter of a `SoundObject`.
///
/// `Hashable`: it doubles as a row identity in the automation band (one row = one ParamRef)
/// and as a de-duplication key. `Codable` with an explicit discriminant (`type`), like
/// `SoundObject.Kind`: the session JSON stays readable and a case added later renumbers
/// nothing.
enum ParamRef: Codable, Equatable, Hashable {
    /// The object's fader, in dB.
    case volume
    /// The object's pan, -1 (left) … +1 (right).
    case pan
    /// The INPUT trim of the plugin chain, in dB.
    case chainInGain
    /// The OUTPUT trim of the plugin chain, in dB.
    case chainOutGain
    /// The level of a send towards an aux, in dB. `auxID` = the receiving aux (`AuxSend.auxID`).
    case send(auxID: UUID)
    /// A parameter of a plugin in the rack. `pluginKey` = `ObjectPlugin.id` (already the key the
    /// engine receives, see `getPluginParams:` / `setPluginParam:`), `paramID` = the parameter
    /// identifier the engine reports in that same call.
    case plugin(pluginKey: UUID, paramID: String)

    private enum CodingKeys: String, CodingKey { case type, auxID, pluginKey, paramID }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .volume:       try c.encode("volume", forKey: .type)
        case .pan:          try c.encode("pan", forKey: .type)
        case .chainInGain:  try c.encode("chainInGain", forKey: .type)
        case .chainOutGain: try c.encode("chainOutGain", forKey: .type)
        case .send(let auxID):
            try c.encode("send", forKey: .type)
            try c.encode(auxID, forKey: .auxID)
        case .plugin(let pluginKey, let paramID):
            try c.encode("plugin", forKey: .type)
            try c.encode(pluginKey, forKey: .pluginKey)
            try c.encode(paramID,   forKey: .paramID)
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "volume":       self = .volume
        case "pan":          self = .pan
        case "chainInGain":  self = .chainInGain
        case "chainOutGain": self = .chainOutGain
        case "send":
            self = .send(auxID: try c.decode(UUID.self, forKey: .auxID))
        case "plugin":
            self = .plugin(pluginKey: try c.decode(UUID.self, forKey: .pluginKey),
                           paramID:   try c.decode(String.self, forKey: .paramID))
        case let other:
            throw DecodingError.dataCorruptedError(forKey: .type, in: c,
                debugDescription: "unknown ParamRef: \(other)")
        }
    }

    /// The short name shown at the head of a row, WITHOUT resolving any external name: a send or
    /// a plugin parameter only has a readable name if you ask the project (the aux's name, the
    /// plugin's name). The full label is composed on the view-model's side
    /// (@see EditViewModel.automationLabel).
    var shortLabel: String {
        switch self {
        case .volume:       return "volume"
        case .pan:          return "pan"
        case .chainInGain:  return "trim in"
        case .chainOutGain: return "trim out"
        case .send:         return "envoi"
        case .plugin:       return "plugin"
        }
    }

    /// The parameter's value range — the VERTICAL axis of its automation row. The bounds are the
    /// ones the inspector already imposes (fader: -96…40 dB, send: `sendMinDb`…`sendMaxDb`), so
    /// that a curve and the static setting talk about the same scale.
    ///
    /// Plugin parameters are NORMALISED 0…1 — and that is OUR convention, not the engine's:
    /// Tracktion does normalise the parameters of an EXTERNAL plugin, but not those of a built-in,
    /// whose range is in real units (a frequency runs from 30 to 18000 Hz). Without that
    /// normalisation, the same curve would mean two different things depending on the plugin's
    /// family. Denormalisation happens when pushing, given the range the engine announces
    /// (@see EditViewModel.denormalizedPluginValue).
    var valueRange: ClosedRange<Float> {
        switch self {
        case .volume:                     return -96...40
        case .pan:                        return -1...1
        case .chainInGain, .chainOutGain: return -24...24
        case .send:                       return sendMinDb...sendMaxDb
        case .plugin:                     return 0...1
        }
    }

    /// The value's STEP under a gesture: a whole dB for everything counted in dB, 10 % for pan —
    /// exactly the steps of the inspector's boxes, so that a curve is set on the same numbers as a
    /// fader. nil for a plugin parameter: its normalised range has no unit, and a step there would
    /// be arbitrary.
    ///
    /// Driven by the timeline's SNAP, like time: ⌘ frees both at once
    /// (@see AutomationBandView).
    var valueStep: Float? {
        switch self {
        case .volume, .chainInGain, .chainOutGain, .send: return 1
        case .pan:                                        return 0.1
        case .plugin:                                     return nil
        }
    }

    /// The parameter's 'resting' value, drawn faintly on an empty row: it places the axis's zero
    /// (0 dB, the centre of the pan) without which an empty band has no scale.
    var neutralValue: Float {
        switch self {
        case .volume, .chainInGain, .chainOutGain, .send: return 0
        case .pan:                                        return 0
        case .plugin:                                     return 0.5
        }
    }

    /// Value → short text, in the parameter's unit. Shown during an editing gesture, where a low
    /// line says nothing precise to the eye: it is the only figure one has.
    func format(_ value: Float) -> String {
        switch self {
        case .volume, .chainInGain, .chainOutGain:
            return String(format: "%+.1f dB", value)
        case .send:
            return value <= sendMinDb ? "-∞" : String(format: "%+.1f dB", value)
        case .pan:
            if abs(value) < 0.005 { return "C" }
            return String(format: "%@%.0f", value < 0 ? "G" : "D", abs(value) * 100)
        case .plugin:
            return String(format: "%.2f", value)
        }
    }
}

extension ParamRef {
    /// The same target, with the AUX it names transposed into a copy of the subtree: a send that
    /// pointed at a copied aux now points at its copy. For a curve, the counterpart of what
    /// `EditViewModel.remappingSends` does to the send itself — without it, the curve and the send
    /// it drives would end up on two different auxes.
    ///
    /// The other cases are returned as they are. Remapping PLUGINS is another matter
    /// (@see SoundObject.remapping): a plugin's identity is never copied, and a curve whose plugin
    /// has no counterpart is dropped rather than left dangling.
    func remappingAux(using idMap: [UUID: UUID]) -> ParamRef {
        guard case .send(let auxID) = self, let mapped = idMap[auxID] else { return self }
        return .send(auxID: mapped)
    }
}

// MARK: - Point and curve

/// An automation point.
///
/// TIME RELATIVE to the start of the clip, in SECONDS — exactly as MIDI notes are in relative
/// beats (`MidiNote.startBeat`). An intended consequence: moving an object along the timeline,
/// changing its lane or trimming its RIGHT edge touches NO point.
///
/// The flip side is that any gesture which moves the ORIGIN of that reference without moving the
/// material (trimming the LEFT edge, the right half of a cut, a fragment of a time selection)
/// has to rebase the points itself, just as the same gesture already rebases a MIDI clip's notes
/// (@see EditViewModel.updateTrim). The transformations that take care of it are gathered below
/// (`shifted` / `split` / `mirrored` / `timeScaled`); a NEGATIVE time is legitimate there — it is
/// material hidden by the edge, not an error (@see AutomationLane.audiblePoints).
///
/// `c` is the CURVATURE of the segment leaving this point: 0 = straight, ±1 = extreme log/exp.
/// It is the engine's point model as it is: converting to a Tracktion curve will be the
/// identity, not a translation.
struct AutomationPoint: Codable, Equatable {
    var t: Double   // seconds from the start of the clip
    var v: Float    // the value, within `ParamRef.valueRange`
    var c: Float    // curvature of the outgoing segment, -1…+1

    init(t: Double, v: Float, c: Float = 0) {
        self.t = t; self.v = v; self.c = c
    }
}

/// The curve of ONE parameter on ONE object.
///
/// The invariant 'no point = no automation': a row with no point does not exist in
/// `SoundObject.automation`, and the model's static value (volume, pan, send level…) goes on
/// ruling alone. So the views must never create an empty entry to 'reserve' a row — the
/// pending row is computed, not stored
/// (@see SoundObject.automationRows).
struct AutomationLane: Codable, Equatable, Identifiable {
    var param: ParamRef
    var points: [AutomationPoint]
    var id: ParamRef { param }

    init(param: ParamRef, points: [AutomationPoint] = []) {
        self.param = param
        self.points = points
    }

    /// Points sorted by increasing time — the order in which a polyline is drawn. Storage is not
    /// assumed sorted: the editing gestures (the next step) move points around, and demanding that
    /// they keep the order would be one more invariant to hold.
    var sortedPoints: [AutomationPoint] { points.sorted { $0.t < $1.t } }
}

// MARK: - Transformations of a curve under the editing gestures
//
// Storing time RELATIVE to the start of the object (@see AutomationPoint) makes moving, changing
// lane and trimming the RIGHT edge free: nothing moves in the points' frame of reference. It does
// NOT make free the gestures that move the ORIGIN of that frame without moving the material
// (trimming the left edge, the right half of a cut, a fragment of a time selection), nor those
// that transform the material itself (reverse, varispeed).
//
// All of them come down to the four primitives below. They live in the MODEL, with no
// view-model and no engine, because they have a dozen callers scattered about (cut, overlaps,
// time selection, clipboard) and a single one of them rewritten wrongly would make the curves
// slide on that one path alone — the kind of divergence one only hears, long afterwards.
extension AutomationLane {

    /// Points shifted by `dt` seconds in the object's frame. `dt < 0` = the origin moves forward
    /// (trimming the left edge, the right half of a cut): the curve stays stuck to the MATERIAL
    /// and not to the edge.
    ///
    /// Non-destructive, exactly like the MIDI notes of a trimmed clip: points that have gone past
    /// the start keep a NEGATIVE time and come back if the edge is reopened. They are neither drawn
    /// nor grabbable (the band starts at x = 0), but they really are PUSHED to the engine: a curve
    /// lives in EDIT time, where `start + t` stays positive, and that is what gives the parameter
    /// the RIGHT value from the clip's very first frame — the one the curve reaches on the way,
    /// not the one of the first point still visible. @see engineCurvePoints, which only bounds at
    /// the TIMELINE's zero.
    func shifted(by dt: Double) -> AutomationLane {
        guard dt != 0 else { return self }
        var l = self
        for i in l.points.indices { l.points[i].t += dt }
        return l
    }

    /// Time scaled (varispeed). `k` = the timeline's STRETCH factor, hence
    /// `oldSpeed / newSpeed`: speeding a clip up shortens it, and its curve tightens by as much so
    /// as to stay opposite the same material.
    ///
    /// CURVATURE is invariant: `c` reads off the segment's proportions (@see
    /// AutomationCurveMath.bezierPoint, whose control point is a fraction of `run`), which a
    /// scaling of time leaves unchanged.
    func timeScaled(by k: Double) -> AutomationLane {
        guard k > 0, k != 1 else { return self }
        var l = self
        for i in l.points.indices { l.points[i].t *= k }
        return l
    }

    /// A curve flipped inside a window of length `duration` — the counterpart of a clip played
    /// backwards: what was heard at `t` is now heard at `duration - t`, and the curve has to
    /// follow.
    ///
    /// Curvature takes more than mirroring the times: `c` belongs to the OUTGOING segment of a
    /// point (the engine's convention, @see AutomationCurveMath). After the flip, the point that
    /// OPENS a segment is the one that used to close it — so the curvature moves back one place —
    /// and it changes SIGN, because the bézier's control point is measured from the left of the
    /// segment: mirroring its abscissa amounts to negating `c` (the computation comes out the same
    /// for a rising as for a falling segment, and the PLATEAUX of |c| > 0.5, which hold the value
    /// at the start for c > 0 and at the end for c < 0, flip to the right side).
    func mirrored(over duration: Double) -> AutomationLane {
        let s = sortedPoints
        guard !s.isEmpty else { return self }
        var out: [AutomationPoint] = []
        out.reserveCapacity(s.count)
        for i in stride(from: s.count - 1, through: 0, by: -1) {
            out.append(AutomationPoint(t: duration - s[i].t, v: s[i].v,
                                       c: i > 0 ? -s[i - 1].c : 0))
        }
        return AutomationLane(param: param, points: out)
    }

    /// Cuts the curve at the relative time `s`: the left half keeps its frame, the right half is
    /// rebased on the cut. Both receive an INTERPOLATED point at the cut, at the value the curve
    /// takes there — without it, each half would set off from its surviving neighbour and the cut
    /// would be heard as a jump.
    ///
    /// A half is always returned non-empty when the curve was: the engine holds its FIRST value
    /// before the first point and its LAST after the last (@see AutomationCurveMath.value). A half
    /// with no point would therefore fall back on the static setting — the parameter would change
    /// value for the sole reason that we cut.
    ///
    /// An accepted limit: the segment that STRADDLES the cut is carried over on both sides with the
    /// SAME curvature over a shorter span, for want of being able to subdivide a bézier exactly in
    /// this single-parameter model. The values at the three bounds (start, cut, end) are exact;
    /// only the inside of that one segment is redrawn. A straight segment (`c == 0`), which is to
    /// say the common case, cuts exactly.
    func split(at s: Double) -> (left: AutomationLane, right: AutomationLane) {
        let sorted = sortedPoints
        guard !sorted.isEmpty else { return (self, self) }
        let vCut = AutomationCurveMath.value(at: s, in: sorted, default: param.neutralValue)
        let cCut = sorted.last(where: { $0.t < s })?.c ?? 0

        var left = sorted.filter { $0.t < s }
        if left.isEmpty {
            left = [AutomationPoint(t: 0, v: vCut)]          // the plateau before the first point
        } else if sorted.contains(where: { $0.t >= s }) {
            left.append(AutomationPoint(t: s, v: vCut))
        }

        var right = sorted.filter { $0.t >= s }.map { p -> AutomationPoint in
            var q = p; q.t -= s; return q
        }
        if right.first.map({ $0.t > 1e-9 }) ?? true {
            right.insert(AutomationPoint(t: 0, v: vCut, c: cCut), at: 0)
        }
        return (AutomationLane(param: param, points: left),
                AutomationLane(param: param, points: right))
    }

}

// MARK: - The same transformations on ALL of an object's curves
//
// The form the editing sites actually call: they handle the whole `SoundObject.automation`
// array, never a single row.
extension Array where Element == AutomationLane {

    func shiftedInTime(by dt: Double) -> [AutomationLane] { map { $0.shifted(by: dt) } }

    func timeScaled(by k: Double) -> [AutomationLane] { map { $0.timeScaled(by: k) } }

    func mirroredInTime(over duration: Double) -> [AutomationLane] {
        map { $0.mirrored(over: duration) }
    }

    /// Cuts every curve at `s`. Empty rows are dropped on both sides:
    /// 'no point = no automation' (@see AutomationLane).
    func splitInTime(at s: Double) -> (left: [AutomationLane], right: [AutomationLane]) {
        var l: [AutomationLane] = [], r: [AutomationLane] = []
        for lane in self where !lane.points.isEmpty {
            let (a, b) = lane.split(at: s)
            if !a.points.isEmpty { l.append(a) }
            if !b.points.isEmpty { r.append(b) }
        }
        return (l, r)
    }
}
