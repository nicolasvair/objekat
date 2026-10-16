import Foundation

// Writing a curve LIVE, while the transport plays — the arithmetic of the automation "pencil",
// with no view, no model and no engine behind it (@see EditViewModel+AutomationWrite for the
// session that feeds it, AutomationBandView for the pencil itself).
//
// It is a TOUCH write, the mode a mixing desk calls "touch": what the hand writes REPLACES the
// curve between the instant it started writing and the instant it is at, and the rest of the
// curve is left exactly as it was. Concretely, each PASS (one stretch of uninterrupted playback
// under the hand) becomes:
//
//     the original curve up to the pass's start  →  a 1 ms entry ramp  →  the written samples,
//     thinned  →  a 50 ms return glide  →  the original curve again
//
// The two boundaries cut the original curve EXACTLY (the shape family is closed under
// restriction, @see AutomationCurveShape.subCurvature), so a bent segment that straddles one keeps
// its shape on the side that survives.
//
// While the hand is still writing, a HOLD sample is added `holdAhead` after the last one, at the
// same value: the engine renders ahead of the playhead, and without it it would play, between two
// writes, the return glide towards the old curve — the hand would hear its own value wobble.
// The hold is not kept: the curve laid down at release ends on the last real sample.
//
// A pass ends when the playhead goes BACKWARDS (a loop wrapping round, a seek) or jumps forward
// by more than `jumpGap` (a seek): the next sample opens a new pass, applied on top of the curve
// the previous ones produced — so writing over a loop several times keeps the last word.
//
// Times are the object's RELATIVE seconds, like every `AutomationPoint`; values are clamped to the
// parameter's range here, and every sample outside `bounds` (the object's window) is refused.
struct AutomationTouchWrite {

    /// One written sample.
    struct Sample: Equatable {
        var t: Double
        var v: Float
    }

    /// One stretch of uninterrupted writing.
    struct Pass: Equatable {
        var samples: [Sample]
        var start: Double { samples.first?.t ?? 0 }
        var end: Double { samples.last?.t ?? 0 }
    }

    /// The span before a pass's first sample where the original curve hands over to the hand.
    static let entryRamp: Double = 0.001
    /// The span after a pass's last sample where the curve glides back onto the original one.
    static let returnGlide: Double = 0.05
    /// How far ahead of the last sample the provisional hold sits while the hand is writing.
    static let holdAhead: Double = 0.2
    /// Samples closer than this (s) to the last one KEPT are merged into it (its value updated).
    static let mergeWindow: Double = 0.005
    /// The thinning tolerance, as a fraction of the parameter's range: a sample whose value lies
    /// within this of the straight line between its kept neighbours is dropped.
    static let valueTolerance: Double = 0.001
    /// A forward jump of the playhead longer than this (s) opens a new pass (a seek, not playback).
    static let jumpGap: Double = 0.5

    /// The curve as it was when the writing started (any order — it is sorted here).
    let original: [AutomationPoint]
    /// The parameter's value range (clamp, and the scale of the thinning tolerance).
    let range: ClosedRange<Float>
    /// The relative instants where writing is allowed — the object's window.
    let bounds: ClosedRange<Double>
    /// The value the parameter holds where the original curve says nothing (it has no point):
    /// the static value, which rules when there is no curve.
    let defaultValue: Float

    private(set) var passes: [Pass] = []

    init(original: [AutomationPoint], range: ClosedRange<Float>,
         bounds: ClosedRange<Double>, defaultValue: Float) {
        self.original = original.sorted { $0.t < $1.t }
        self.range = range
        self.bounds = bounds
        self.defaultValue = defaultValue
    }

    /// True once at least one sample has been written.
    var hasWritten: Bool { passes.contains { !$0.samples.isEmpty } }

    /// Records the hand's value `v` at the relative instant `t`. Returns false (and records
    /// nothing) outside `bounds`.
    @discardableResult
    mutating func write(t: Double, v: Float) -> Bool {
        guard t.isFinite, v.isFinite, bounds.contains(t) else { return false }
        let s = Sample(t: t, v: min(max(v, range.lowerBound), range.upperBound))
        guard let last = passes.last?.samples.last else {
            passes.append(Pass(samples: [s]))
            return true
        }
        if t < last.t - 1e-9 || t > last.t + Self.jumpGap {
            passes.append(Pass(samples: [s]))       // a loop wrapped round, or a seek
        } else if t - last.t < Self.mergeWindow {
            // Too close to the last sample to say anything new about TIME: its value is updated,
            // its instant kept (the merge never drifts later than the first of the cluster).
            passes[passes.count - 1].samples[passes[passes.count - 1].samples.count - 1].v = s.v
        } else {
            passes[passes.count - 1].samples.append(s)
        }
        return true
    }

    /// The curve as it stands: every pass applied, in order, on top of the original. `holding`
    /// = the hand is still writing (the last pass gets its provisional hold sample).
    func points(holding: Bool) -> [AutomationPoint] {
        var base = original
        for (i, pass) in passes.enumerated() where !pass.samples.isEmpty {
            base = Self.apply(pass, onto: base, holding: holding && i == passes.count - 1,
                              range: range, defaultValue: defaultValue)
        }
        return base
    }

    // MARK: - Pure pieces

    /// One pass laid onto `base` (sorted): `base` up to the pass's start, the entry ramp, the
    /// thinned samples, then the glide back onto `base`.
    static func apply(_ pass: Pass, onto base: [AutomationPoint], holding: Bool,
                      range: ClosedRange<Float>, defaultValue: Float) -> [AutomationPoint] {
        var samples = pass.samples
        if holding, let last = samples.last {
            samples.append(Sample(t: last.t + holdAhead, v: last.v))
        }
        let span = Double(range.upperBound - range.lowerBound)
        let kept = thinned(samples, tolerance: valueTolerance * max(span, 1e-9))
        let a = pass.start - entryRamp
        let b = (kept.last?.t ?? pass.end) + returnGlide
        return prefix(of: base, upTo: a, defaultValue: defaultValue)
            + kept.map { AutomationPoint(t: $0.t, v: $0.v, c: 0) }
            + suffix(of: base, from: b, defaultValue: defaultValue)
    }

    /// `base` (sorted) strictly before `x`, closed by a point AT `x` on the curve's value there. The
    /// segment that straddles `x` keeps its shape exactly (its left point takes the curvature of
    /// the part that survives); the closing point is straight (what follows it is the hand's).
    static func prefix(of base: [AutomationPoint], upTo x: Double,
                       defaultValue: Float) -> [AutomationPoint] {
        let vx = AutomationCurveMath.value(at: x, in: base, default: defaultValue)
        var pts = base
        if let cut = AutomationCurveMath.cutCurvatures(at: x, in: pts) { pts[cut.leftIndex].c = cut.left }
        return pts.filter { $0.t < x } + [AutomationPoint(t: x, v: vx, c: 0)]
    }

    /// `base` (sorted) strictly after `y`, opened by a point AT `y` on the curve's value there,
    /// carrying the curvature of the remaining part of the segment that straddles `y`.
    static func suffix(of base: [AutomationPoint], from y: Double,
                       defaultValue: Float) -> [AutomationPoint] {
        let vy = AutomationCurveMath.value(at: y, in: base, default: defaultValue)
        let after = base.filter { $0.t > y }
        let c: Float
        if after.isEmpty {
            c = 0
        } else if let cut = AutomationCurveMath.cutCurvatures(at: y, in: base) {
            c = cut.right
        } else {
            // A point exactly AT y (it is replaced by the one laid here), or nothing before y:
            // the segment leaving y is that point's own, or the plateau's (straight).
            c = base.last(where: { $0.t <= y })?.c ?? 0
        }
        return [AutomationPoint(t: y, v: vy, c: c)] + after
    }

    /// The samples thinned: every sample whose value lies within `tolerance` of the straight line
    /// between its kept neighbours is dropped (a vertical Ramer–Douglas–Peucker — the error that
    /// matters is the value heard at an instant, not a distance on screen). The first and last
    /// samples are always kept.
    static func thinned(_ s: [Sample], tolerance: Double) -> [Sample] {
        guard s.count > 2 else { return s }
        var keep = [Bool](repeating: false, count: s.count)
        keep[0] = true; keep[s.count - 1] = true
        var stack: [(Int, Int)] = [(0, s.count - 1)]
        while let (i, j) = stack.popLast() {
            guard j > i + 1 else { continue }
            let a = s[i], b = s[j]
            let dt = b.t - a.t
            var worst = -1.0, at = -1
            for k in (i + 1)..<j {
                let u = dt > 0 ? (s[k].t - a.t) / dt : 0
                let line = Double(a.v) + Double(b.v - a.v) * u
                let err = abs(Double(s[k].v) - line)
                if err > worst { worst = err; at = k }
            }
            if worst > tolerance, at > 0 {
                keep[at] = true
                stack.append((i, at)); stack.append((at, j))
            }
        }
        return s.indices.filter { keep[$0] }.map { s[$0] }
    }
}
