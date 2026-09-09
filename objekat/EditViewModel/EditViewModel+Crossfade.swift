import Foundation

// MARK: - Crossfades, which ARE the common zone
//
// A crossfade in OBJEKAT is not a thing laid between two objects. It is the zone the two of them
// SHARE: they overlap, the left one fades out across it, the right one fades in across it, and the
// invariant that makes it one is that the zone's width is exactly both fades' length. Nothing is
// stored saying "these two are crossfaded" — the geometry says it — which is why saving, reloading
// and undo carry it for free, and why there is no second truth to fall out of step with the first.
//
// Four decisions this rests on, none of them obvious:
//
//  • The overwrite policy does NOT move. Dropping an object onto another still overwrites it,
//    exactly as before. A crossfade is born from the SEAM and from nowhere else: one takes the
//    join between two adjacent objects and opens it. An overlap that is not a crossfade is still
//    the accident `resolveOverlaps` exists to settle.
//  • Opening is FREE because OBJEKAT's trim is non-destructive. A clip's window is a view on the
//    file (`sourceOffset` + `fileDuration`), so the matter an overwrite hid is still there:
//    opening re-exposes it, it does not fabricate it. Hence the whole notion of headroom below —
//    and hence a seam that will not open at all when both sides have run out of file.
//  • The zone is opened SYMMETRICALLY when it can be, and lopsidedly when it cannot. A side with
//    no file left simply gives nothing, and the other side gives the whole width. That falls out
//    of one clamp rather than out of a special case (@see `openCrossfade`).
//  • An edge engaged in a crossfade has no fade length of its own any more: the zone commands.
//    Setting the width sets both fades, and that is the only thing that keeps the definition
//    above true. The SHAPE stays each edge's own — two curves, one on each side, which is what
//    lets a crossfade be equal-gain or equal-power at the user's choice.
//
// Equal-gain is the default because linear fades sum to exactly constant AMPLITUDE. Worth knowing
// for later: exact equal-POWER is `convex` at a bend of 1/3 — the exponent is then 8^(1/3) = 2 and
// the gain √α, so α + (1−α) = 1 across the whole travel. It is not offered by default, and nothing
// here makes it hard to add.

extension EditViewModel {

    /// The common zone of two siblings on one lane: the crossfade itself. Derived, never stored.
    struct CrossfadeZone {
        let leftID:  UUID
        let rightID: UUID
        /// `nil` = the two live at the top level.
        let containerID: UUID?
        let lane:  Int
        let start: Double
        let end:   Double
        var width: Double { end - start }
    }

    /// A join closer than this counts as one. Positions come out of snapped drags, so the slack is
    /// only there to absorb the floating point, never a gap one could hear.
    static let seamEpsilon: Double = 1e-4

    /// The shortest object the overwrite policy will leave standing (@see EditViewModel+Overlaps).
    /// A crossfade uses the same floor: it must not produce what an overwrite would have deleted.
    private static let crossfadeMinDuration: Double = 0.05

    // MARK: - Reading the geometry

    /// The list an object belongs to: its group's children, or the top level.
    func crossfadeSiblings(of id: UUID) -> [SoundObject] {
        guard let parent = parentGroup(for: id), case .group(let children, _) = parent.kind else {
            return items
        }
        return children
    }

    /// How much further each edge could be pulled before the FILE runs out, in TIMELINE seconds.
    ///
    /// This is what makes opening a seam free rather than inventive: a trim hides matter, it does
    /// not destroy it, so the headroom is exactly what a previous trim (or an overwrite) put out
    /// of sight. Only a clip has a file and therefore a limit — a group's window is a porthole one
    /// may widen over its children, and a MIDI clip's notes are kept whole behind its edges, so
    /// both answer "unbounded". A group opened past its content will cross-fade into silence,
    /// which is a real answer and not an error: the seam was opened where it was asked for.
    func windowHeadroom(_ o: SoundObject) -> (left: Double, right: Double) {
        guard case .clip = o.kind, o.fileDuration > 0 else { return (.infinity, .infinity) }
        let speed = max(1e-6, o.speedRatio)
        let usedEnd = o.sourceOffset + o.duration * speed
        let beforeWindow = max(0, o.sourceOffset) / speed
        let afterWindow  = max(0, o.fileDuration - usedEnd) / speed
        // Reversed, `sourceOffset` is anchored to the RIGHT edge (@see retrimmedSourceOffset): the
        // file material sitting BEFORE the window is what lets the right edge travel, and the
        // material after it is what lets the left edge travel. An exact mirror, hence one swap.
        return o.isReversed ? (left: afterWindow, right: beforeWindow)
                            : (left: beforeWindow, right: afterWindow)
    }

    /// True when these two overlap AS a crossfade: laid side by side (neither swallowing the
    /// other) and each fading right across the common zone. The whole definition, and it is what
    /// `resolveOverlaps` consults before overwriting — a drop that merely LANDS on another object
    /// has no such fades, so it still overwrites.
    func isCrossfadePair(_ a: SoundObject, _ b: SoundObject) -> Bool {
        guard a.lane == b.lane else { return false }
        let (left, right) = a.startTime <= b.startTime ? (a, b) : (b, a)
        let leftEnd = left.startTime + left.duration
        let rightEnd = right.startTime + right.duration
        // Side by side: the right one starts later AND ends later. One inside the other is an
        // overwrite whatever its fades say.
        guard right.startTime > left.startTime, rightEnd > leftEnd else { return false }
        let overlap = leftEnd - right.startTime
        guard overlap > Self.seamEpsilon else { return false }
        return abs(left.fadeOut - overlap) <= Self.seamEpsilon
            && abs(right.fadeIn - overlap) <= Self.seamEpsilon
    }

    /// Every crossfade among one list of siblings, lane by lane.
    private func crossfadeZones(among siblings: [SoundObject], containerID: UUID?) -> [CrossfadeZone] {
        var zones: [CrossfadeZone] = []
        for lane in Set(siblings.map(\.lane)).sorted() {
            let row = siblings.filter { $0.lane == lane }.sorted { $0.startTime < $1.startTime }
            for (a, b) in zip(row, row.dropFirst()) where isCrossfadePair(a, b) {
                zones.append(CrossfadeZone(leftID: a.id, rightID: b.id, containerID: containerID,
                                           lane: lane,
                                           start: b.startTime, end: a.startTime + a.duration))
            }
        }
        return zones
    }

    /// Every crossfade in the project, at every depth.
    func allCrossfadeZones() -> [CrossfadeZone] {
        var zones: [CrossfadeZone] = []
        func walk(_ list: [SoundObject], containerID: UUID?) {
            zones += crossfadeZones(among: list, containerID: containerID)
            for item in list {
                if case .group(let children, _) = item.kind { walk(children, containerID: item.id) }
            }
        }
        walk(items, containerID: nil)
        return zones
    }

    /// The crossfade under a point of the TIMELINE, addressed the way the canvas addresses things:
    /// a display lane and an absolute time. `crossfadeZones(among:)` works on the model's lanes,
    /// which is what the API wants; hit-testing wants the rows actually on screen, so it reads
    /// `laneEntries` — and a folded group's children, having no row, are rightly invisible to it.
    func crossfadeZone(atTime t: Double, displayLane: Int) -> CrossfadeZone? {
        let row = laneEntries.filter { $0.displayLane == displayLane }
                             .sorted { $0.absStart < $1.absStart }
        for (a, b) in zip(row, row.dropFirst()) where isCrossfadePair(a.item, b.item) {
            let start = b.absStart, end = a.absStart + a.item.duration
            if t >= start && t <= end {
                return CrossfadeZone(leftID: a.item.id, rightID: b.item.id,
                                     containerID: a.parentID, lane: displayLane,
                                     start: start, end: end)
            }
        }
        return nil
    }

    /// The widest zone a seam can hold — the `w` at which the four bounds on the zone's start meet
    /// (@see `openCrossfade`, where they are named). Shared so that a GESTURE can know the limit
    /// before it reaches it: pulling a fade out onto its neighbour is bounded by this and not by
    /// the object's own file, otherwise a side with nothing left would forbid a crossfade the
    /// OTHER side could perfectly well have given.
    static func crossfadeCeiling(leftStart: Double, leftEnd: Double,
                                 rightStart: Double, rightEnd: Double,
                                 headLRight: Double, headRLeft: Double,
                                 keepLeft: Double, keepRight: Double) -> Double {
        let currentOverlap = max(0, leftEnd - rightStart)
        return min(currentOverlap + headLRight + headRLeft,
                   (rightEnd - rightStart) - keepRight + headRLeft,
                   (leftEnd - leftStart) - keepLeft + headLRight,
                   rightEnd - keepRight - leftStart - keepLeft)
    }

    /// The widest crossfade these two neighbours could hold, 0 when the seam cannot open at all.
    /// What a gesture asks before it starts, so it can stop at the limit — and so it can SHOW that
    /// there is no room rather than silently doing nothing.
    func maxCrossfadeWidth(leftID: UUID, rightID: UUID) -> Double {
        guard var left = find(id: leftID), var right = find(id: rightID),
              left.lane == right.lane,
              parentGroup(for: leftID)?.id == parentGroup(for: rightID)?.id else { return 0 }
        if left.startTime > right.startTime { swap(&left, &right) }
        if isLoopedGroupPorthole(left) || isLoopedGroupPorthole(right) { return 0 }
        let leftEnd = left.startTime + left.duration
        let rightEnd = right.startTime + right.duration
        guard leftEnd >= right.startTime - Self.seamEpsilon else { return 0 }
        let headL = windowHeadroom(left), headR = windowHeadroom(right)
        return max(0, Self.crossfadeCeiling(
            leftStart: left.startTime, leftEnd: leftEnd,
            rightStart: right.startTime, rightEnd: rightEnd,
            headLRight: headL.right, headRLeft: headR.left,
            keepLeft: max(left.fadeIn, Self.crossfadeMinDuration),
            keepRight: max(right.fadeOut, Self.crossfadeMinDuration)))
    }

    /// The sibling this object BUTTS against on one side — the one a fade pulled out past that
    /// edge would spill onto, which is how a crossfade is created. An already-crossfaded
    /// neighbour counts: pulling further simply widens the zone that is there.
    func seamNeighbour(of id: UUID, onRight: Bool) -> UUID? {
        guard let me = find(id: id) else { return nil }
        let myEnd = me.startTime + me.duration
        for other in crossfadeSiblings(of: id) where other.id != id && other.lane == me.lane {
            let otherEnd = other.startTime + other.duration
            if onRight {
                // It starts where I finish (a butt joint), or we already share a zone.
                guard other.startTime > me.startTime, otherEnd > myEnd else { continue }
                if abs(other.startTime - myEnd) <= Self.seamEpsilon || isCrossfadePair(me, other) {
                    return other.id
                }
            } else {
                guard other.startTime < me.startTime, otherEnd < myEnd else { continue }
                if abs(me.startTime - otherEnd) <= Self.seamEpsilon || isCrossfadePair(other, me) {
                    return other.id
                }
            }
        }
        return nil
    }

    /// The crossfade these two form, if they form one.
    func crossfadeZone(leftID: UUID, rightID: UUID) -> CrossfadeZone? {
        guard let a = find(id: leftID), let b = find(id: rightID), isCrossfadePair(a, b) else {
            return nil
        }
        let (left, right) = a.startTime <= b.startTime ? (a, b) : (b, a)
        return CrossfadeZone(leftID: left.id, rightID: right.id,
                             containerID: parentGroup(for: left.id)?.id, lane: left.lane,
                             start: right.startTime, end: left.startTime + left.duration)
    }

    // MARK: - Finding the seam

    /// Why a seam refuses to open. A gesture has to be able to SHOW this, not merely do nothing.
    enum SeamRefusal: String, Error {
        /// The two objects are not on the same lane, or not in the same container.
        case notSiblings
        /// A gap separates them: there is no join to take hold of.
        case gap
        /// One of the two is a looping container — its window is a porthole onto a pattern, and
        /// widening it would change every repeat at once (the same rule as the ripple's).
        case porthole
        /// Neither side has any file left to re-expose: the seam cannot open at all.
        case noMaterial
        /// The width asked for is more than the two objects can give without one of them falling
        /// below the floor the overwrite policy itself uses.
        case tooWide
    }

    /// The two objects meeting at a seam on `lane`, nearest to `time`, among `container`'s
    /// children. Already-crossfaded pairs count: their zone is a seam one can go on widening.
    func seamPair(nearTime time: Double, lane: Int, container: UUID?) -> (left: UUID, right: UUID)? {
        let siblings: [SoundObject] = {
            guard let container, let g = find(id: container), case .group(let ch, _) = g.kind else {
                return items
            }
            return ch
        }()
        let row = siblings.filter { $0.lane == lane }.sorted { $0.startTime < $1.startTime }
        var best: (pair: (UUID, UUID), distance: Double)?
        for (a, b) in zip(row, row.dropFirst()) {
            let aEnd = a.startTime + a.duration
            // A gap disqualifies; a butt joint and an open zone are both seams.
            guard aEnd >= b.startTime - Self.seamEpsilon else { continue }
            // The distance to the seam is measured to the zone, which is a point when it is shut.
            let distance = time < b.startTime ? b.startTime - time
                         : time > aEnd        ? time - aEnd
                         : 0
            if best == nil || distance < best!.distance { best = ((a.id, b.id), distance) }
        }
        return best.map { (left: $0.pair.0, right: $0.pair.1) }
    }

    // MARK: - Opening, resizing and closing

    /// Opens (or resizes) the crossfade at the seam between two adjacent siblings, to `width`
    /// seconds. `width == 0` closes it back to a butt joint.
    ///
    /// The whole arithmetic is one clamp on a single unknown — where the right-hand object now
    /// STARTS — and every rule falls out of it rather than out of a chain of special cases:
    ///
    ///   • the ideal is symmetric, each side giving half the width;
    ///   • a side with no file left pulls the clamp against itself, and the other side then gives
    ///     the whole width — "if the matter is missing on one side, open on the other";
    ///   • when the two bounds cross, no split of the width works at all and the seam refuses.
    ///
    /// It also keeps each object clear of its OWN other fade, which is what stops two crossfades
    /// on the same object from eating into one another.
    ///
    /// `idealStart` is where the caller would LIKE the zone to begin; `nil` means "centred on the
    /// join", which is what opening a shut seam wants. It is what makes one primitive serve all
    /// three gestures — opening centres, widening from an edge pins the OTHER edge, and moving
    /// keeps the width and slides the start — instead of three near-copies of this arithmetic.
    /// It is a wish, not an order: the clamp below has the last word.
    ///
    /// Returns the refusal rather than a bare `false`: the gesture has to be able to show why.
    @discardableResult
    func openCrossfade(leftID: UUID, rightID: UUID, width: Double,
                       idealStart: Double? = nil) -> Result<CrossfadeZone?, SeamRefusal> {
        guard var left = find(id: leftID), var right = find(id: rightID),
              left.lane == right.lane,
              parentGroup(for: leftID)?.id == parentGroup(for: rightID)?.id
        else { return .failure(.notSiblings) }

        // Put them the right way round: the caller may name them either way.
        if left.startTime > right.startTime { swap(&left, &right) }

        // A looping container's window is a porthole onto a repeating pattern, not an edge:
        // widening it would change every repeat at once, including those the gesture never
        // touched. The same refusal as the ripple's, for the same reason.
        if isLoopedGroupPorthole(left) || isLoopedGroupPorthole(right) { return .failure(.porthole) }

        let leftEnd  = left.startTime + left.duration
        let rightEnd = right.startTime + right.duration
        guard leftEnd >= right.startTime - Self.seamEpsilon else { return .failure(.gap) }

        let minDur = Self.crossfadeMinDuration
        let headL = windowHeadroom(left)
        let headR = windowHeadroom(right)
        let currentOverlap = max(0, leftEnd - right.startTime)

        // What each object must keep for ITSELF, outside the zone: its own other fade, and never
        // less than the floor. A zone that swallowed a whole object would not be a crossfade any
        // more — it would be one object lying hidden under another, with no side left to speak of.
        // Asking for an enormous width used to produce exactly that, the two ending up on the very
        // same span (measured).
        let keepLeft  = max(left.fadeIn,   minDur)
        let keepRight = max(right.fadeOut, minDur)

        // The zone's start `s` is hemmed in by four bounds — two floors, two ceilings — and the
        // widest zone this seam can hold is simply the `w` at which they meet. Pairing each floor
        // with each ceiling gives the four ceilings on `w` below; which one bites decides what the
        // gesture is told, the FILE one being a seam that cannot open at all and the others a seam
        // that merely cannot go this far.
        let byMaterial = currentOverlap + headL.right + headR.left
        let maxWidth = Self.crossfadeCeiling(leftStart: left.startTime, leftEnd: leftEnd,
                                             rightStart: right.startTime, rightEnd: rightEnd,
                                             headLRight: headL.right, headRLeft: headR.left,
                                             keepLeft: keepLeft, keepRight: keepRight)
        guard maxWidth > Self.seamEpsilon || width <= Self.seamEpsilon else {
            return .failure(byMaterial <= Self.seamEpsilon ? .noMaterial : .tooWide)
        }

        // CLAMPED, not refused. A width is what a hand pulls, and a hand pulls past the end: the
        // gesture must stop at the limit rather than die on it, and the caller is told the width it
        // GOT beside the one it asked for. Only a seam that can hold nothing at all refuses above.
        let w = min(max(0, width), max(0, maxWidth))

        // The unknown: `s`, the right-hand object's new start. The left one then ends at `s + w`,
        // which is what makes the zone exactly `w` wide.
        //
        // Its floor: the file left under the right object's left edge, and the left object's own
        // fade-in, which the zone must not reach (its duration has to hold fadeIn + w).
        // Its ceiling: the file left past the left object's right edge, and the right object's own
        // fade-out, symmetrically. Plus the floor on both durations.
        let sMin = max(right.startTime - headR.left,     // the right object's file
                       left.startTime + keepLeft)        // what the left object keeps for itself
        let sMax = min(leftEnd + headL.right - w,         // the left object's file
                       rightEnd - w - keepRight)         // what the right object keeps for itself
        // `maxWidth` above is exactly the width at which these two meet, so the clamp has already
        // made this feasible. It stays as a guard rather than a `!`: the arithmetic is the whole
        // feature, and a floating-point surprise must refuse rather than lay down a wrong zone.
        guard sMin <= sMax + 1e-9 else {
            return .failure(byMaterial <= Self.seamEpsilon ? .noMaterial : .tooWide)
        }

        let centre = (leftEnd + right.startTime) / 2
        let s = min(max(idealStart ?? (centre - w / 2), sMin), sMax)

        // The two edges travel, and nothing else does. `updateTrim` is the non-destructive move
        // the interface already uses: it carries the source offset (reverse mirrored), the
        // automation and the MIDI notes, and leaves the matter where it is on the timeline.
        updateTrim(id: right.id, newStart: s, newDuration: rightEnd - s)
        updateTrim(id: left.id, newStart: left.startTime, newDuration: (s + w) - left.startTime)

        // The fades LAST: `updateTrim` clamps them against the duration it is given, and the
        // durations only become big enough once both trims are through.
        updateFadeOut(id: left.id, fadeOut: w)
        updateFadeIn(id: right.id, fadeIn: w)

        isDirty = true
        return .success(w > Self.seamEpsilon ? crossfadeZone(leftID: left.id, rightID: right.id) : nil)
    }

    /// Shuts the zone back to a butt joint, both edges coming back onto its middle. The objects
    /// keep the matter the crossfade had re-exposed — it goes back behind their edges, where a
    /// trim always leaves it.
    @discardableResult
    func closeCrossfade(leftID: UUID, rightID: UUID) -> Result<CrossfadeZone?, SeamRefusal> {
        openCrossfade(leftID: leftID, rightID: rightID, width: 0)
    }

    /// Slides the zone earlier or later WITHOUT changing its width: the two objects go on meeting
    /// for just as long, but they meet somewhere else. This is the body of the gesture — moving the
    /// seam — and it is a trim of both edges at once, so the matter stays where it is on the
    /// timeline and only the window that shows it travels.
    @discardableResult
    func moveCrossfade(leftID: UUID, rightID: UUID, by delta: Double) -> Result<CrossfadeZone?, SeamRefusal> {
        guard let zone = crossfadeZone(leftID: leftID, rightID: rightID) else {
            // Nothing open yet: a butt joint has a seam but no zone to slide.
            return .failure(.gap)
        }
        return openCrossfade(leftID: zone.leftID, rightID: zone.rightID,
                             width: zone.width, idealStart: zone.start + delta)
    }

    /// Widens or narrows the zone by pulling ONE of its edges, the other staying put. `fromStart`
    /// is the left edge: pulling it left widens, so the zone's END is what gets pinned.
    @discardableResult
    func resizeCrossfade(leftID: UUID, rightID: UUID, edge fromStart: Bool,
                         to time: Double) -> Result<CrossfadeZone?, SeamRefusal> {
        guard let zone = crossfadeZone(leftID: leftID, rightID: rightID) else { return .failure(.gap) }
        let width = fromStart ? zone.end - time : time - zone.start
        return openCrossfade(leftID: zone.leftID, rightID: zone.rightID,
                             width: max(0, width),
                             idealStart: fromStart ? zone.end - max(0, width) : zone.start)
    }
}
