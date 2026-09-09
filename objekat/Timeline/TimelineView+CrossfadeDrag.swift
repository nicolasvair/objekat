import SwiftUI
import AppKit

// MARK: - The gesture on a crossfade zone
//
// The zone is the only NEW hit target crossfades needed. Everywhere else the timeline's twelve
// geometric hit tests go on assuming "one lane, one object at a given instant", and they stay
// right: two objects are never freely superposed (`resolveOverlaps` sees to that), so a shared
// span is ALWAYS a crossfade and there is no general tie-break to spread through the code. One
// case, tested in one place, before the per-block carve-up (@see ClipEditZone.resolve).
//
// This handles an EXISTING zone only. A crossfade is CREATED by pulling a fade out past its
// object's edge onto the neighbour — the fade overflows the join and the overlap it makes is the
// crossfade (@see the fade branch of `handleCanvasDrag`). The join itself is not a target: it is a
// line with no surface, and it is exactly where the two blocks' own trim and resize handles already
// meet, so grabbing it meant a 5 px target competing with two others.
//
// ── The carve-up, and why it is the one the X already draws ─────────────────────────────────
//
// The HALF decides first, as it does on every block (@see ClipEditZone.resolve): the lower half
// belongs to the object — its edges and its body — and the upper half is where the fades live.
// That rule is what keeps a long fade from confiscating the trimming under it, and a crossfade IS
// two long fades, so it applies here with more reason than anywhere.
//
//  • the LOWER half is a block's, unchanged: a handle at each end — the same quarter-of-the-width
//    capped at 50 px, none at all below 60 px — and the whole middle to the BODY. The handles take
//    the same edges as the sides above them, under the cursor a block's own edge wears: the zone
//    covers both blocks' trim and resize handles entirely, and a hand reaching for an edge must
//    find an edge. The body slides the seam, the two going on meeting for just as long somewhere
//    else, and taking hold of it SELECTS the crossfade — which is what lets ⌫ mean "this zone"
//    (@see selectCrossfade).
//
//  • the UPPER half is carved by the two veils, which already draw the regions: under BOTH of them
//    (the top triangle) the crossfade AS a thing — widened and narrowed symmetrically about its
//    own centre, both curves bent at once, cursor ✕; under ONE of them, that side alone — its edge
//    travels and the opposite one stays put, cursor ╱ or ╲; under neither, the body again, since
//    two bulged curves cross high and carry the bare region up with them.
//
// So the hand is given exactly what the eye is shown, and a crossfade is grabbed with the reflexes
// a block has already taught.
//
// What the edges do at their limit is the one rule that is not geometry: pushed past the opposite
// edge the zone shuts, the two objects stay STUCK TOGETHER (no gap ever opens under a hand that
// was making a crossfade), and the travel that is left grows a PLAIN fade on the object whose edge
// is being held. One continuous gesture from "a crossfade this wide" to "no crossfade, a fade this
// long" — which is the same road the fade took to become a crossfade, walked backwards.
//
// The model is applied LIVE rather than previewed. A crossfade IS geometry — the two windows and
// their fades — so moving it redraws the blocks by itself, with no preview layer to write and,
// more to the point, no second definition of the zone that could disagree with the first. Undo is
// pushed ONCE at the start of the gesture, so the whole drag is one step.
//
// Every frame recomputes the target from the zone frozen at the gesture's start plus the TOTAL
// translation, never from the zone as it now stands: the model clamps, and feeding a clamped
// result back in would let the gesture drift away from the hand.

/// One drag on a crossfade zone.
struct CrossfadeDragState {
    enum Part {
        /// The bottom triangle: slide the seam, width unchanged.
        case move
        /// The top triangle: widen/narrow symmetrically about the centre, and bend both curves.
        case both
        /// A side: that edge of the zone travels, the opposite one is pinned.
        case sideStart, sideEnd
    }

    var leftID:  UUID
    var rightID: UUID
    let part: Part
    /// The gesture took hold through the LOWER half's handle — the crop band — rather than through
    /// the veil above it. The two drive the same edge, and they part company at the limit: a crop
    /// is a crop and grows nothing, while the fade triangle carries on into a plain fade.
    var viaEdgeBand: Bool = false

    /// The zone as it stood when the hand came down. Everything is computed from this.
    let anchorStart: Double
    let anchorEnd:   Double
    var anchorWidth: Double { anchorEnd - anchorStart }
    var anchorCentre: Double { (anchorStart + anchorEnd) / 2 }

    /// The display lane the zone sits on: the origin of the vertical travel.
    let lane: Int

    /// Which way the top triangle's horizontal reads. Grabbed left of the centre, pulling LEFT
    /// widens; grabbed right of it, pulling RIGHT does. The hand pushes the nearer edge outwards
    /// in both cases, which is what "symmetric" feels like from wherever one took hold.
    var widenSign: Double = 1

    /// The curves the two edges had at the start — the bend ADDS to them, so a crossfade already
    /// bent stays bent when one merely moves or widens it.
    var leftCurveAnchor:  FadeCurve = .linear
    var rightCurveAnchor: FadeCurve = .linear

    /// The vertical travel outside the row (px). 0 while the hand is on the block.
    var overshootY: Double = 0
    /// One block-height of travel from straight to full bend, as on a fade.
    var bendTravelPx: Double = 60
    var sCurve: Bool = false

    /// True once the hand has actually asked for something, so a click that merely twitches on a
    /// zone does not push an undo step for a gesture that changed nothing.
    var didChange = false

    /// The width the hand asked for, and the one the seam gave. They part company as soon as the
    /// clamp bites, and the HUD says so — a gesture that stops must say why it stopped, otherwise
    /// the limit reads as the app having lost the drag.
    var requestedWidth: Double = 0
    var obtainedWidth:  Double = 0
    /// The plain fade the gesture has grown past the shut seam, on the object whose edge it holds.
    var spilloverFade: Double = 0
    /// The seam has given everything it has: the hand may go on travelling, the zone will not.
    var atCeiling: Bool { requestedWidth - obtainedWidth > EditViewModel.seamEpsilon }

    var bendDelta: Double { -overshootY / max(1, bendTravelPx) }

    /// The two curves the gesture asks for. Both sides get the SAME bend: a crossfade is one
    /// object as far as the hand is concerned, and bending only one half of it is what
    /// `object.set_fade_curve` is for.
    func curves() -> (left: FadeCurve, right: FadeCurve) {
        guard overshootY != 0 else { return (leftCurveAnchor, rightCurveAnchor) }
        return (.signed(leftCurveAnchor.signedAmount + bendDelta,
                        sCurve: leftCurveAnchor.isS != sCurve),
                .signed(rightCurveAnchor.signedAmount + bendDelta,
                        sCurve: rightCurveAnchor.isS != sCurve))
    }
}

/// What the hand is on, inside a zone: the part it will drive, and whether it took hold through
/// the lower half's handle — which changes nothing but the cursor, and that matters.
struct CrossfadeHit {
    let zone: EditViewModel.CrossfadeZone
    let part: CrossfadeDragState.Part
    let viaEdgeBand: Bool
    /// Where the hand came down inside the zone, 0…1 across its width. The top triangle reads it
    /// to know which way widening goes.
    let alpha: Double
}

extension TimelineView {

    /// The crossfade under a canvas point, and which part of it the hand is on. `nil` when the
    /// point is not in a zone — the ordinary per-block carve-up then applies, untouched.
    ///
    /// The HALF decides first, exactly as it does on a block (@see ClipEditZone.resolve): the
    /// lower half is the object's — edges and body — and the upper half is where the fades live.
    /// Nothing else keeps a long fade from confiscating the rognage under it, and a crossfade IS
    /// two long fades. Read the other way round, the side triangles reached down into the corners
    /// and the bottom of the zone answered as a curve where every block answers as a body.
    ///
    /// Inside the upper half the regions are read off the CURVES themselves and not off the
    /// diagonals of the box: a strongly bent crossfade draws an X well away from its diagonals,
    /// and the hand has to find the region it can SEE rather than the one the maths would have
    /// drawn if nothing were bent.
    func crossfadeHit(at p: CGPoint) -> CrossfadeHit? {
        guard p.y > rulerHeight else { return nil }
        let lane = Int((p.y - rulerHeight) / laneStep)
        let laneTop = rulerHeight + Double(lane) * laneStep
        guard p.y <= laneTop + blockHeight else { return nil }
        let t = p.x / pixelsPerSecond
        guard let zone = viewModel.crossfadeZone(atTime: t, displayLane: lane) else { return nil }

        let x0 = zone.start * pixelsPerSecond
        let x1 = zone.end * pixelsPerSecond
        let w  = x1 - x0
        guard w > 0 else { return nil }
        let lx = min(max(p.x - x0, 0), w)
        let ly = min(max(p.y - laneTop, 0), blockHeight)
        let a  = lx / w

        // ── The LOWER half: the objects' own, and nothing else ──────────────────────────────
        // The same handle as a block's, measured on the ZONE's width by the same function: a
        // quarter of it capped at 50 px, and none at all below 60 px — where a block gives up its
        // handles too and leaves its whole lower half to the body.
        if ly > blockHeight / 2 {
            let band = handleWidth(blockWidth: w)
            if band > 0, lx < band {
                return CrossfadeHit(zone: zone, part: .sideStart, viaEdgeBand: true, alpha: a)
            }
            if band > 0, lx > w - band {
                return CrossfadeHit(zone: zone, part: .sideEnd, viaEdgeBand: true, alpha: a)
            }
            return CrossfadeHit(zone: zone, part: .move, viaEdgeBand: false, alpha: a)
        }

        // ── The UPPER half: the two curves ──────────────────────────────────────────────────
        // In the zone's own coordinates, the same reading as the veil's (@see CrossfadeCurvePath):
        // `alpha` is the fade's PROGRESS, so the outgoing one is read right to left.
        let outCurve = viewModel.find(id: zone.leftID)?.fadeOutCurve ?? .linear
        let inCurve  = viewModel.find(id: zone.rightID)?.fadeInCurve ?? .linear
        let yOut = blockHeight * (1 - outCurve.gain(1 - a))
        let yIn  = blockHeight * (1 - inCurve.gain(a))

        let part: CrossfadeDragState.Part
        if ly < min(yIn, yOut)      { part = .both }        // under BOTH veils
        // Under NEITHER, up here: two bulged curves cross high, and the bare region rises above
        // the middle with them. It is still the body — the bare part of the zone is the body
        // wherever it happens to be.
        else if ly > max(yIn, yOut) { part = .move }
        else if yOut < yIn          { part = .sideStart }   // left of the crossing
        else                        { part = .sideEnd }
        return CrossfadeHit(zone: zone, part: part, viaEdgeBand: false, alpha: a)
    }

    /// The cursor a point inside a zone deserves. `nil` = not in a zone.
    func crossfadeCursor(at p: CGPoint) -> NSCursor? {
        guard let hit = crossfadeHit(at: p) else { return nil }
        switch hit.part {
        case .both:  return TimelineCursors.crossfade
        case .move:  return NSCursor.openHand
        case .sideStart, .sideEnd:
            if hit.viaEdgeBand {
                // A block's own edge cursor, brackets and all — small arrows included: the band is
                // there so that a hand reaching for an edge finds an edge, and a block's edge says
                // which way it can still go. Two arrows drawn regardless would promise travel that
                // the file no longer has.
                let r = edgeBandRoom(hit.zone, part: hit.part)
                return TimelineCursors.edge(open: hit.part == .sideStart,
                                            canLeft:  r.left  > edgeBandEpsilon,
                                            canRight: r.right > edgeBandEpsilon)
            }
            // The fade cursor of the side one is holding: ╱ climbs (the incoming curve, on the
            // left), ╲ comes down (the outgoing one, on the right).
            return hit.part == .sideStart ? TimelineCursors.fadeIn : TimelineCursors.fadeOut
        }
    }

    /// The travel a crop band still has, in seconds, to the left and to the right of the edge it
    /// holds. OUTWARDS the zone widens, and the stop is the seam's own ceiling — which already
    /// counts what each file has left beyond its edge and what each object must keep of its own
    /// (@see maxCrossfadeWidth). INWARDS it narrows, and the stop is the joint: nothing is left to
    /// give once the zone is shut.
    func edgeBandRoom(_ zone: EditViewModel.CrossfadeZone,
                      part: CrossfadeDragState.Part) -> (left: Double, right: Double) {
        let ceiling = viewModel.maxCrossfadeWidth(leftID: zone.leftID, rightID: zone.rightID)
        let outward = max(0, ceiling - zone.width)
        let inward  = max(0, zone.width)
        return part == .sideStart ? (outward, inward) : (inward, outward)
    }

    /// Half a pixel at the current scale, with a floor in seconds: the same 'this edge cannot move
    /// any more' tolerance a block's own handles use.
    var edgeBandEpsilon: Double { max(0.001, 0.5 / max(pixelsPerSecond, 1)) }

    /// Starts the gesture if the hand came down on a zone. Called BEFORE the per-block carve-up,
    /// the way the loop markers are: a narrow target tested before the surfaces that cover the
    /// same pixels — here the two fade triangles the zone is made of, which would otherwise
    /// confiscate it and bend one side alone.
    func beginCrossfadeDragIfHit(at p: CGPoint) -> Bool {
        guard let hit = crossfadeHit(at: p) else { return false }
        let z = hit.zone
        // The bottom triangle is the zone taken AS an object: taking hold of it selects it, which
        // is what gives ⌫ something to delete. The two objects leave the selection — a crossfade
        // is not them, it is what they share.
        if hit.part == .move { viewModel.selectCrossfade(left: z.leftID, right: z.rightID) }
        crossfadeDrag = CrossfadeDragState(
            leftID: z.leftID, rightID: z.rightID, part: hit.part,
            viaEdgeBand: hit.viaEdgeBand,
            anchorStart: z.start, anchorEnd: z.end,
            lane: Int((p.y - rulerHeight) / laneStep),
            widenSign: hit.alpha < 0.5 ? -1 : 1,
            leftCurveAnchor:  viewModel.find(id: z.leftID)?.fadeOutCurve ?? .linear,
            rightCurveAnchor: viewModel.find(id: z.rightID)?.fadeInCurve ?? .linear)
        return true
    }

    /// A double click inside a zone resets it: the pair comes back onto the middle and each loses
    /// its fade, shape included. The same bargain as the double click on a fade — you pull to make
    /// one, you double-click to take it away — and the same thing ⌫ does to a selected zone.
    /// Returns true when it consumed the click.
    func handleCrossfadeDoubleTap(at p: CGPoint) -> Bool {
        guard let hit = crossfadeHit(at: p) else { return false }
        viewModel.edit {
            viewModel.closeCrossfade(leftID: hit.zone.leftID, rightID: hit.zone.rightID)
        }
        viewModel.selectedCrossfade = nil
        return true
    }

    /// One frame of the gesture. Returns false when no crossfade drag is running.
    @discardableResult
    func handleCrossfadeDrag(_ value: DragGesture.Value, phase: DragPhase) -> Bool {
        guard var state = crossfadeDrag else { return false }

        // The vertical, measured against the ROW and not in pixels — the same origin as a fade's,
        // so the two gestures answer to the hand in the same way. Reading the bend inside the top
        // triangle instead would give a tenth of a fade's travel for the same curve, and would
        // take the bend's limit away from something one can SEE.
        // Only the top triangle bends at all: the sides and the body are edge gestures, and a hand
        // that strays out of the row while sliding a seam has not asked for a shape.
        if state.part == .both {
            let laneTop = rulerHeight + Double(state.lane) * laneStep
            let y = value.location.y
            state.overshootY = y < laneTop ? y - laneTop
                             : (y > laneTop + blockHeight ? y - (laneTop + blockHeight) : 0)
            state.bendTravelPx = blockHeight
            state.sCurve = NSEvent.modifierFlags.contains(.option)
        }

        let dx = Double(value.translation.width) / pixelsPerSecond

        // Absolute targets from the FROZEN zone: the clamp never feeds back into the hand.
        // `rawWidth` may go NEGATIVE — that is the gesture asking for more than the zone has to
        // give, and what is past zero becomes a plain fade below.
        let rawWidth: Double
        let idealStart: Double?
        // The pair is EXCLUDED from the snap targets, exactly as a trim excludes the objects it
        // moves: the zone's two boundaries ARE these two objects' edges, so leaving them in would
        // have the travelling edge snap onto the very edge it is moving away from — the zone
        // sticking shut, or leaping to the neighbour's far end.
        let excl: Set<UUID> = [state.leftID, state.rightID]
        switch state.part {
        case .move:
            rawWidth   = state.anchorWidth
            idealStart = viewModel.snapTime(state.anchorStart + dx, excluding: excl)
        case .both:
            // Symmetric about the centre the zone had when the hand came down, so widening and
            // narrowing are the same travel seen from either side of it.
            rawWidth   = state.anchorWidth + 2 * state.widenSign * dx
            idealStart = state.anchorCentre - max(0, rawWidth) / 2
        case .sideStart:
            rawWidth   = state.anchorEnd - viewModel.snapTime(state.anchorStart + dx, excluding: excl)
            idealStart = state.anchorEnd - max(0, rawWidth)
        case .sideEnd:
            rawWidth   = viewModel.snapTime(state.anchorEnd + dx, excluding: excl) - state.anchorStart
            idealStart = state.anchorStart
        }
        let width = max(0, rawWidth)
        // Past the shut seam, the travel that is left is a PLAIN fade on the object whose edge the
        // hand holds. The two objects stay stuck together: a gesture that was making a crossfade
        // never opens a gap.
        //
        // Only from the FADE triangle. Taken by the crop band underneath, the same edge is being
        // CROPPED, and cropping has never produced a fade anywhere else in OBJEKAT — the band is
        // there precisely so that a hand reaching for an edge gets an edge and nothing more. It
        // stops at the joint, where the crossfade ends.
        let spill = (state.part == .move || state.viaEdgeBand) ? 0 : max(0, -rawWidth)

        let moved = abs(width - state.anchorWidth) > 1e-9 || spill > 0
                 || (idealStart.map { abs($0 - state.anchorStart) > 1e-9 } ?? false)
        if (moved || state.overshootY != 0), !state.didChange {
            // The first frame that actually asks for something: one undo step for the whole drag.
            viewModel.pushUndo()
            state.didChange = true
        }

        if state.didChange {
            let result = viewModel.openCrossfade(leftID: state.leftID, rightID: state.rightID,
                                                 width: width, idealStart: idealStart)
            state.requestedWidth = width
            // A zone shut to nothing stops being a crossfade, so the ids would no longer resolve
            // to one: the gesture keeps its own two ids and can reopen the seam on the way back.
            if case .success(let zone) = result {
                state.obtainedWidth = zone?.width ?? 0
                if let zone {
                    state.leftID = zone.leftID
                    state.rightID = zone.rightID
                }
            }
            let curves = state.curves()
            viewModel.updateFadeCurve(id: state.leftID,  fadeOut: curves.left)
            viewModel.updateFadeCurve(id: state.rightID, fadeIn:  curves.right)

            // The plain fade past the joint, on the held side only. Bounded by that object's own
            // length, which is the only stop a fade has ever had.
            //
            // ONLY once there IS something past the joint, and that guard is the whole of it: run
            // unconditionally, this wrote a fade of 0 over the one `openCrossfade` had just set
            // three lines above, and a crossfade IS the two fades being equal to the overlap
            // (@see isCrossfadePair) — so one side at 0 dissolved the pair on the first frame and
            // the two side gestures looked as though they turned the crossfade off. Nothing else
            // is needed on the way back either: `openCrossfade` sets both fades every frame, so
            // returning inside the zone restores them by itself.
            state.spilloverFade = spill
            if spill > 0 {
                if state.part == .sideStart, let o = viewModel.find(id: state.rightID) {
                    viewModel.updateFadeIn(id: o.id, fadeIn: min(spill, o.duration))
                } else if state.part == .sideEnd, let o = viewModel.find(id: state.leftID) {
                    viewModel.updateFadeOut(id: o.id, fadeOut: min(spill, o.duration))
                }
            }
        }

        // The arrows follow the drag, as they do on a block's own edge: once the button is down the
        // hover produces no more events, so it is here that an arrow goes out when the file — or
        // the joint — has nothing more to give.
        if state.viaEdgeBand {
            let zone = viewModel.crossfadeZone(leftID: state.leftID, rightID: state.rightID)
                    ?? EditViewModel.CrossfadeZone(leftID: state.leftID, rightID: state.rightID,
                                                   containerID: nil, lane: state.lane,
                                                   start: 0, end: 0)
            setEdgeCursor(open: state.part == .sideStart,
                          room: edgeBandRoom(zone, part: state.part))
        }

        if phase == .ended {
            // A gesture that asked for nothing leaves no trace, not even an empty undo step.
            if !state.didChange { crossfadeDrag = nil; return true }
            viewModel.isDirty = true
            crossfadeDrag = nil
        } else {
            crossfadeDrag = state
        }
        return true
    }
}
