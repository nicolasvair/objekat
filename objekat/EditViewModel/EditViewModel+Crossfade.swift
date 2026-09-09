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
        visibleCrossfadeZones(onDisplayLane: displayLane)
            .first { t >= $0.start && t <= $0.end }
    }

    /// The crossfades SHOWN, in canvas coordinates — the same reading as the hit test above, and
    /// deliberately the same function, so that what the eye is offered and what the hand can take
    /// hold of can never come apart. `lane` here is a DISPLAY lane, not the model's.
    /// `onDisplayLane: nil` = every row on screen.
    func visibleCrossfadeZones(onDisplayLane wanted: Int? = nil) -> [CrossfadeZone] {
        var zones: [CrossfadeZone] = []
        let lanes = wanted.map { [$0] } ?? Set(laneEntries.map(\.displayLane)).sorted()
        for lane in lanes {
            let row = laneEntries.filter { $0.displayLane == lane }
                                 .sorted { $0.absStart < $1.absStart }
            for (a, b) in zip(row, row.dropFirst()) where isCrossfadePair(a.item, b.item) {
                zones.append(CrossfadeZone(leftID: a.item.id, rightID: b.item.id,
                                           containerID: a.parentID, lane: lane,
                                           start: b.absStart, end: a.absStart + a.item.duration))
            }
        }
        return zones
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
        switch plannedCrossfade(leftID: leftID, rightID: rightID,
                                width: width, idealStart: idealStart) {
        case .failure(let reason):
            return .failure(reason)
        case .success(let plan):
            // The two edges travel, and nothing else does. `updateTrim` is the non-destructive move
            // the interface already uses: it carries the source offset (reverse mirrored), the
            // automation and the MIDI notes, and leaves the matter where it is on the timeline.
            updateTrim(id: plan.rightID, newStart: plan.start, newDuration: plan.rightEnd - plan.start)
            updateTrim(id: plan.leftID, newStart: plan.leftStart,
                       newDuration: (plan.start + plan.width) - plan.leftStart)

            // The fades LAST: `updateTrim` clamps them against the duration it is given, and the
            // durations only become big enough once both trims are through.
            updateFadeOut(id: plan.leftID, fadeOut: plan.width)
            updateFadeIn(id: plan.rightID, fadeIn: plan.width)

            isDirty = true
            return .success(plan.width > Self.seamEpsilon
                            ? crossfadeZone(leftID: plan.leftID, rightID: plan.rightID) : nil)
        }
    }

    /// What `openCrossfade` is ABOUT to lay down, worked out and clamped but not applied.
    ///
    /// It exists so that a gesture can DRAW the zone it is making before committing it — pulling a
    /// fade out onto a neighbour shows the X it is opening — and so that what is previewed and what
    /// is applied cannot be two different arithmetics. The refusals come out here too, which is
    /// what lets a hand be told that a seam gives nothing rather than see nothing happen.
    struct CrossfadePlan {
        let leftID:  UUID
        let rightID: UUID
        let leftStart: Double
        let rightEnd:  Double
        /// Where the zone begins, and how wide it is — after the clamp, so this is what one gets.
        let start: Double
        let width: Double
        let lane:  Int
        let containerID: UUID?
        var end: Double { start + width }
    }

    func plannedCrossfade(leftID: UUID, rightID: UUID, width: Double,
                          idealStart: Double? = nil) -> Result<CrossfadePlan, SeamRefusal> {
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

        return .success(CrossfadePlan(leftID: left.id, rightID: right.id,
                                      leftStart: left.startTime, rightEnd: rightEnd,
                                      start: s, width: w, lane: left.lane,
                                      containerID: parentGroup(for: left.id)?.id))
    }

    /// Shuts the zone back to a butt joint, both edges coming back onto its middle. The objects
    /// keep the matter the crossfade had re-exposed — it goes back behind their edges, where a
    /// trim always leaves it.
    @discardableResult
    func closeCrossfade(leftID: UUID, rightID: UUID) -> Result<CrossfadeZone?, SeamRefusal> {
        let r = openCrossfade(leftID: leftID, rightID: rightID, width: 0)
        if case .success = r, let a = find(id: leftID), let b = find(id: rightID) {
            // The SHAPE goes with the length, as it does on the double click that erases a fade:
            // a bend left behind a cleared fade lies in wait for the next time that edge is
            // pulled, and nothing in the gestures brings a curve back to the straight line.
            // Ordered here, since the caller may name the pair either way round.
            let (l, rr) = a.startTime <= b.startTime ? (a.id, b.id) : (b.id, a.id)
            updateFadeCurve(id: l,  fadeOut: .linear)
            updateFadeCurve(id: rr, fadeIn:  .linear)
        }
        return r
    }

    /// Re-forms the crossfade a MOVE has displaced, and says whether there is still one.
    ///
    /// Moving or CROPPING one of a crossfaded pair is not editing the crossfade — it is editing an
    /// object — and the zone is only ever the span the two have in common, so it has nothing to
    /// say about what one does to them. It simply follows: push the right-hand one 20 px to the
    /// right and the left one has not moved, so the common span loses 20 px OFF ITS LEFT and the
    /// two fades are that much shorter; crop that same edge instead and the span loses exactly as
    /// much, for exactly the same reason. Nothing is recentred, nothing is preserved — the
    /// geometry decides, as it always does here.
    ///
    /// Without this the pair stopped being one the instant it moved (the fades no longer matched
    /// the overlap), `resolveOverlaps` saw an ordinary superposition and OVERWROTE: the crossfade
    /// went and the left-hand object was cut back to the other's new start. A CROP was worse still,
    /// since it does not go through the overlap policy at all: the zone quietly stopped being one
    /// while both fades kept the length the zone had given them, so cropping an edge to the bone
    /// left a two-second fade standing inside an object that no longer overlapped anything — a
    /// fade that looked as though it had GROWN, the object's edge having come to meet it.
    ///
    /// Two ways out of being a crossfade, both of them the ordinary behaviour resuming:
    ///  • pushed apart until they no longer meet, they are simply two objects with a gap between
    ///    them — the fades go, and a move opens gaps everywhere else too;
    ///  • pushed together until one would swallow the other, this refuses and hands the pair back
    ///    to `resolveOverlaps`, whose overwrite policy is exactly what a drop onto an object means.
    ///    The fades go there as well: an overwrite leaves the survivor a clean edge.
    ///
    /// Returns true only when the pair is STILL a crossfade — in which case `resolveOverlaps` will
    /// leave it alone by itself (@see isCrossfadePair), so the caller has nothing else to do.
    @discardableResult
    func refitCrossfade(leftID: UUID, rightID: UUID) -> Bool {
        guard find(id: leftID) != nil, find(id: rightID) != nil else { return false }

        // The pair is taken AS NAMED, and that is deliberate: the two ids are not interchangeable,
        // they are a role each. Carried past its neighbour, an object does not arrive at the far
        // side still crossfaded with it — its outgoing edge would have to become an incoming one,
        // and a fade the hand never asked for would appear on each of their opposite ends. Crossing
        // over ENDS the crossfade; what happens next is `resolveOverlaps`', as after any drop.
        guard let zone = projectedCrossfade(leftID: leftID, rightID: rightID,
                                            placement: modelPlacement) else {
            updateFadeOut(id: leftID, fadeOut: 0)
            updateFadeCurve(id: leftID, fadeOut: .linear)
            updateFadeIn(id: rightID, fadeIn: 0)
            updateFadeCurve(id: rightID, fadeIn: .linear)
            return false
        }

        let overlap = zone.end - zone.start
        updateFadeOut(id: zone.leftID, fadeOut: overlap)
        updateFadeIn(id: zone.rightID, fadeIn: overlap)
        isDirty = true
        return true
    }

    /// Where each object of a pair actually SITS, as `projectedCrossfade` reads it: the container's
    /// own time, its length, and the model's lane.
    func modelPlacement(_ id: UUID) -> Placement? {
        guard let o = find(id: id) else { return nil }
        return (o.startTime, o.duration, o.lane, parentGroup(for: id)?.id)
    }

    /// Everything about an object a crossfade depends on: WHERE it is and HOW LONG it is. A move
    /// changes the first, a crop the second, and the zone — the span the two have in common —
    /// cannot tell the difference: both of them reshape it, and by the same arithmetic.
    typealias Placement = (start: Double, duration: Double, lane: Int, container: UUID?)

    /// What `refitCrossfade` WOULD leave of this pair, given where the two objects sit — worked
    /// out and not applied. `nil` = the placement has broken the pair, and the fades go.
    ///
    /// The placement is a PARAMETER, and that is the whole point: fed the model, it answers what
    /// the commit is about to write; fed the geometry a drag is SHOWING (a display row, an
    /// absolute time, the move's travel already added), it answers what the eye should be seeing
    /// while the hand is still down. One arithmetic, so the zone that follows the block during the
    /// gesture is the zone the release will lay down and not a resemblance of it.
    ///
    /// The lengths and the fades always come from the model: a move changes where an object is,
    /// never what it is.
    func projectedCrossfade(leftID: UUID, rightID: UUID, placement: (UUID) -> Placement?)
        -> (leftID: UUID, rightID: UUID, start: Double, end: Double, lane: Int)? {
        guard let a = find(id: leftID), let b = find(id: rightID),
              let pa = placement(leftID), let pb = placement(rightID) else { return nil }

        // A move that changes row, or that takes an object out of its container, separates them
        // as surely as a gap does. So does one that carries an object PAST its neighbour: the
        // `pb.start > pa.start` below is what says so, and it is why the pair is never re-ordered
        // here — left and right are roles, not a sort order.
        guard pa.lane == pb.lane, pa.container == pb.container else { return nil }

        let aEnd = pa.start + pa.duration
        let bEnd = pb.start + pb.duration
        let overlap = aEnd - pb.start
        guard overlap > Self.seamEpsilon else { return nil }

        // Side by side, each keeping something of its own outside the zone — the same floors the
        // opener uses, so a crossfade born of a move cannot be one the opener would have refused.
        // The FAR fade is the model's: a gesture on one edge says nothing about the other one.
        let minDur = Self.crossfadeMinDuration
        guard pb.start > pa.start, bEnd > aEnd,
              overlap <= pa.duration - max(a.fadeIn, minDur),
              overlap <= pb.duration - max(b.fadeOut, minDur)
        else { return nil }

        return (a.id, b.id, pb.start, aEnd, pa.lane)
    }

    /// The crossfades these objects are part of, read WHILE THEY STILL EXIST — a move destroys the
    /// evidence, since a displaced pair no longer satisfies `isCrossfadePair`. So a gesture that is
    /// about to move something notes its pairs first and refits them afterwards.
    func crossfadePairs(around ids: Set<UUID>) -> [(left: UUID, right: UUID)] {
        var pairs: [(left: UUID, right: UUID)] = []
        var seen = Set<String>()
        func note(_ l: UUID, _ r: UUID) {
            let key = l.uuidString + r.uuidString
            if seen.insert(key).inserted { pairs.append((l, r)) }
        }
        for id in ids {
            if let n = seamNeighbour(of: id, onRight: true),
               crossfadeZone(leftID: id, rightID: n) != nil { note(id, n) }
            if let n = seamNeighbour(of: id, onRight: false),
               crossfadeZone(leftID: n, rightID: id) != nil { note(n, id) }
        }
        return pairs
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
