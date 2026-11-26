import Foundation

// MARK: - From a timeline instant to the pictures to show (plan-video §4.3)
//
// A PURE function: no view, no engine, no model type. It answers one question — "at timeline time
// `t`, which pictures are visible, and which instant of its file does each one show?" — from an
// index of the picture objects that carries, for each one, the windows of the groups it sits in.
// Being pure it is asserted alone (`tools/test_video_time_map.swift`) and called from three places
// that must agree: the preview's display link, `video.layers`, and `video.render_frame`.
//
// The rules, in the order they are applied to ONE picture:
//
//   for each ancestor group, from the root down to the direct parent:
//     - an INFINITE group has no window (the picture keeps its own extent);
//     - otherwise `t` must lie in [start, start + duration[ — whatever the group's content does
//       beyond it is cut by the container, on the engine side as here;
//     - a LOOPING group (IN/OUT range, local to the group) folds `t` back onto its slice. The fold
//       is the engine's: the container's offset is `max(0, start − IN)`, so the grid of repeats
//       starts at `min(start, start + IN)` and the material at IN lands at the start of each period
//       (`refreshContainerSpanForKey:`, `ContainerClipNode.cpp:224`) — written the same way in
//       `GroupWaveformView.expand` (`origin = min(0, r.start)`), so the picture, the drawn composite
//       and the sound are one definition seen three times.
//   then the picture's own window [start, start + duration[ — negative starts included: `t − start`
//   stays valid, there is no clamp at zero here (a picture may begin before 0, @see the negative
//   start convention) — then its own loop, then speed / offset (`WaveformShaping.sourceTime`).
//
// Fades (Q6): the fades of the picture and of every group above it multiply into its OPACITY, by the
// sound's own curve. A group's fade runs over the group's window at the time the group sees (before
// its loop fold: no new fade-in at each turn), the picture's over its own window before its own loop
// fold. Nothing below 1/255 is drawn or counted in the cap of two.
//
// Silence (Q7): a picture is HIDDEN exactly when a sound at its place would be reduced to silence —
// its own mute, its stem's mute, a solo elsewhere — or when a group above it would be. The resolver
// reads none of those rules: the index builder has already folded them into `isMuted` (@see
// `VideoObjectIndex.init(items:audibility:)`), and `VideoResolver.Presence` is the one place that acts
// on it. Fades (Q6) act at the same place.
//
// Two layers at most, the FRONT-most ones (§2.7), chosen AFTER the window and opacity filtering: after
// `windowOnly` cuts many picture objects overlap in time without being visible.

/// One group between the root and a picture: only what the resolver reads of it.
nonisolated struct VideoGroupWindow: Equatable, Sendable {
    var lane: Int
    var start: Double
    var duration: Double
    /// An infinite bus has no window.
    var isInfinite: Bool
    /// The loop's IN/OUT, in seconds LOCAL to the group (0 = its start); nil when the loop is off.
    var loop: VideoLoopRange?
    /// The group is reduced to silence by the listening composition (its mute, its stem's, a solo
    /// that filters it out): the pictures below it are hidden (@see `VideoResolver.Presence`). The
    /// index builder fills it from `AudibilitySnapshot.isSilenced`, never from the object's flag alone.
    var isMuted: Bool = false
    /// The group's own fades, over ITS window (lengths in seconds, with their shapes): they multiply the
    /// opacity of every picture below it, as `ObjWindowFade` multiplies the sound. An infinite group has
    /// no window, hence no fade.
    var fadeIn: Double = 0
    var fadeOut: Double = 0
    var fadeInCurve: FadeCurve = .linear
    var fadeOutCurve: FadeCurve = .linear

    init(lane: Int, start: Double, duration: Double, isInfinite: Bool = false,
         loop: VideoLoopRange? = nil, isMuted: Bool = false,
         fadeIn: Double = 0, fadeOut: Double = 0,
         fadeInCurve: FadeCurve = .linear, fadeOutCurve: FadeCurve = .linear) {
        self.lane = lane; self.start = start; self.duration = duration
        self.isInfinite = isInfinite; self.loop = loop; self.isMuted = isMuted
        self.fadeIn = fadeIn; self.fadeOut = fadeOut
        self.fadeInCurve = fadeInCurve; self.fadeOutCurve = fadeOutCurve
    }
}

nonisolated struct VideoLoopRange: Equatable, Sendable {
    var start: Double
    var end: Double
    var length: Double { end - start }
}

/// One picture object, with its ancestors.
nonisolated struct VideoPictureEntry: Equatable, Sendable {
    var id: UUID
    var filePath: String
    var lane: Int
    var start: Double
    var duration: Double
    /// Seconds of the SOURCE, invariant to speed (@see the offset convention).
    var sourceOffset: Double
    var speedRatio: Double
    var isReversed: Bool
    var fileDuration: Double
    /// The object's own loop (a slice of itself, local to the object); nil when off.
    var loop: VideoLoopRange?
    var nominalFPS: Double
    /// The picture object is reduced to silence by the listening composition, as a sound at its place
    /// would be: hidden (@see `VideoGroupWindow.isMuted`).
    var isMuted: Bool = false
    /// The picture's own fades over its window: its OPACITY goes with them (Q6), by the same curve as
    /// the sound's gain (`WaveformShaping.fadeEnvelope`).
    var fadeIn: Double = 0
    var fadeOut: Double = 0
    var fadeInCurve: FadeCurve = .linear
    var fadeOutCurve: FadeCurve = .linear
    /// Root → direct parent. Empty for a picture at the root.
    var ancestors: [VideoGroupWindow]

    /// The lanes from the root down to this picture: the order key of §2.7. Compared on THIS path and
    /// not on a display lane, otherwise opening a group above would change which picture is in front.
    var lanePath: [Int] { ancestors.map(\.lane) + [lane] }

    init(id: UUID, filePath: String, lane: Int, start: Double, duration: Double,
         sourceOffset: Double = 0, speedRatio: Double = 1, isReversed: Bool = false,
         fileDuration: Double = 0, loop: VideoLoopRange? = nil, nominalFPS: Double = 0,
         isMuted: Bool = false, fadeIn: Double = 0, fadeOut: Double = 0,
         fadeInCurve: FadeCurve = .linear, fadeOutCurve: FadeCurve = .linear,
         ancestors: [VideoGroupWindow] = []) {
        self.id = id; self.filePath = filePath; self.lane = lane; self.start = start
        self.duration = duration; self.sourceOffset = sourceOffset; self.speedRatio = speedRatio
        self.isReversed = isReversed; self.fileDuration = fileDuration; self.loop = loop
        self.nominalFPS = nominalFPS; self.isMuted = isMuted; self.ancestors = ancestors
        self.fadeIn = fadeIn; self.fadeOut = fadeOut
        self.fadeInCurve = fadeInCurve; self.fadeOutCurve = fadeOutCurve
    }
}

/// Only the picture objects of the document, so that it stays light at 60 Hz. Rebuilt when `items`
/// changes (@see `EditViewModel.videoObjectIndex`).
nonisolated struct VideoObjectIndex: Equatable, Sendable {
    var entries: [VideoPictureEntry] = []
    var isEmpty: Bool { entries.isEmpty }
}

/// What the display draws for ONE picture.
nonisolated struct VideoLayer: Equatable, Sendable {
    var objectID: UUID
    var filePath: String
    /// The instant of the FILE (seconds on the movie's timeline) to show.
    var sourceTime: Double
    /// The rate the file advances at while the timeline plays (the object's speed).
    var rate: Double
    var nominalFPS: Double
    /// The product of the fades from the root to the picture (@see `Presence`); 1 without any.
    var opacity: Double
    /// The file is read backwards (the object is reversed): the player cannot run it, so the display
    /// seeks to every instant instead of following a rate.
    var isReversed: Bool = false
}

nonisolated enum VideoResolver {

    /// Never more than this many pictures are decoded and composed (§2.7). The FRONT-most win.
    static let maxLayers = 2

    /// A group whose loop slice is shorter than this is not a loop (the same floor as
    /// `GroupWaveformView.expand`).
    static let minimumLoopLength = 0.02

    // MARK: Q6 / Q7 — the one place

    /// Where a mute (Q7) and a fade (Q6) act on a picture. `nil` hides the picture; the number is a
    /// factor (an OPACITY) multiplied along the way down. The curve is the sound's: the fade's gain IS
    /// the opacity (`WaveformShaping.fadeEnvelope`, `FadeCurve`), so what is drawn, what is heard and
    /// what is seen come from one definition.
    enum Presence {
        /// `time` is the timeline time as seen BY the group (before its own fold, the way the plan's
        /// pseudo-code orders it): a looping group does not replay its fade-in at every turn. An
        /// infinite group has no window, hence no fade.
        static func group(_ g: VideoGroupWindow, at time: Double) -> Double? {
            guard !g.isMuted else { return nil }
            guard !g.isInfinite else { return 1 }
            return WaveformShaping.fadeEnvelope(localTime: time - g.start, duration: g.duration,
                                                fadeIn: g.fadeIn, fadeOut: g.fadeOut,
                                                curveIn: g.fadeInCurve, curveOut: g.fadeOutCurve)
        }
        /// `localTime` is the time inside the picture's window (0 = its start), before its own loop
        /// fold and whatever its direction: a reversed picture still fades in at the entry of its window.
        static func picture(_ p: VideoPictureEntry, at localTime: Double) -> Double? {
            guard !p.isMuted else { return nil }
            return WaveformShaping.fadeEnvelope(localTime: localTime, duration: p.duration,
                                                fadeIn: p.fadeIn, fadeOut: p.fadeOut,
                                                curveIn: p.fadeInCurve, curveOut: p.fadeOutCurve)
        }
    }

    /// Below this opacity (1/255: the least step of an 8-bit alpha) a picture is not drawn, and does
    /// not count among the `maxLayers` — otherwise a picture beginning its fade-in would hide a visible one.
    static let invisibleOpacity = 1.0 / 255.0

    // MARK: The fold of a looping group

    /// The group's folded time: `t` is inside its window, the result lies in `[IN, OUT[` (absolute).
    /// Mirrors `GroupWaveformView.expand` and the engine (@see the header); nil range → unchanged.
    static func foldGroup(_ t: Double, group g: VideoGroupWindow) -> Double {
        guard let r = g.loop, r.length > minimumLoopLength else { return t }
        let inAbs = g.start + r.start
        let origin = min(g.start, inAbs)
        return inAbs + max(0, t - origin).truncatingRemainder(dividingBy: r.length)
    }

    /// The picture's own loop: the local time `u` (0 = its start) read at `IN + (u mod period)`.
    /// Mirrors `WaveformDrawing.LoopFold`.
    static func foldPicture(localTime u: Double, loop: VideoLoopRange?, isReversed: Bool) -> Double {
        guard !isReversed, let r = loop, r.length > 0.0001 else { return u }
        return r.start + max(0, u).truncatingRemainder(dividingBy: r.length)
    }

    // MARK: One picture

    /// The layer a picture shows at `t`, or nil if it shows nothing.
    static func layer(of p: VideoPictureEntry, at t: Double) -> VideoLayer? {
        var T = t
        var opacity = 1.0
        for g in p.ancestors {
            guard let o = Presence.group(g, at: T) else { return nil }
            if !g.isInfinite {
                guard T >= g.start, T < g.start + g.duration else { return nil }
            }
            opacity *= o
            if !g.isInfinite { T = foldGroup(T, group: g) }
        }
        guard T >= p.start, T < p.start + p.duration else { return nil }
        guard let o = Presence.picture(p, at: T - p.start) else { return nil }
        opacity *= o
        let folded = foldPicture(localTime: T - p.start, loop: p.loop, isReversed: p.isReversed)
        let s = WaveformShaping.sourceTime(localTime: folded, sourceOffset: p.sourceOffset,
                                           duration: p.duration, speedRatio: p.speedRatio,
                                           isReversed: p.isReversed)
        // Past the end of the file there is no picture (a sound would be silent): never the last
        // frame frozen.
        guard s >= 0, p.fileDuration <= 0 || s < p.fileDuration else { return nil }
        return VideoLayer(objectID: p.id, filePath: p.filePath, sourceTime: s,
                          rate: p.speedRatio, nominalFPS: p.nominalFPS, opacity: opacity,
                          isReversed: p.isReversed)
    }

    // MARK: The answer

    /// The pictures visible at `t`, BOTTOM first (the order they are composed in), at most
    /// `maxLayers`. The front-most is the one on the HIGHEST lane — the smallest lane number, the
    /// path compared from the root down (§2.7).
    static func layers(at t: Double, in index: VideoObjectIndex) -> [VideoLayer] {
        var visible: [(entry: VideoPictureEntry, layer: VideoLayer, order: Int)] = []
        for (i, e) in index.entries.enumerated() {
            if let l = layer(of: e, at: t), l.opacity > invisibleOpacity { visible.append((e, l, i)) }
        }
        guard !visible.isEmpty else { return [] }
        // Front first: lane path ascending; a prefix before its extension; then the index order, so
        // that the answer is a function of the document and never of an unstable sort.
        visible.sort { a, b in
            let pa = a.entry.lanePath, pb = b.entry.lanePath
            for (x, y) in zip(pa, pb) where x != y { return x < y }
            if pa.count != pb.count { return pa.count < pb.count }
            return a.order < b.order
        }
        return visible.prefix(maxLayers).reversed().map(\.layer)
    }
}
