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
//    own centre, RIGHT WIDENS AND LEFT NARROWS wherever one took hold, both curves bent at once,
//    cursor ✕; under ONE of them, that side alone — its edge
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

    /// The held object as the gesture found it, and whether the last frame cropped PAST the joint.
    /// A frame that did leaves the two objects with a gap between them, and a gap is not a seam:
    /// the next frame's `openCrossfade` would be refused, and the hand could leave a crossfade but
    /// never come back into it. So the object goes back where it was found before the seam is
    /// asked anything, and the frame is computed whole from the anchors like every other one.
    var heldAnchor: (start: Double, duration: Double)? = nil
    var didOverCrop = false

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
                return CrossfadeHit(zone: zone, part: .sideStart, viaEdgeBand: true)
            }
            if band > 0, lx > w - band {
                return CrossfadeHit(zone: zone, part: .sideEnd, viaEdgeBand: true)
            }
            return CrossfadeHit(zone: zone, part: .move, viaEdgeBand: false)
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
        return CrossfadeHit(zone: zone, part: part, viaEdgeBand: false)
    }

    /// The cursor a point inside a zone deserves. `nil` = not in a zone.
    func crossfadeCursor(at p: CGPoint) -> NSCursor? {
        guard let hit = crossfadeHit(at: p) else { return nil }
        switch hit.part {
        case .both:  return TimelineCursors.crossfade
        case .move:  return NSCursor.openHand
        case .sideStart, .sideEnd:
            if hit.viaEdgeBand {
                // A block's own edge cursor, brackets and all — and its arrows read off the OBJECT,
                // exactly as they are on that object's own handle. The zone is not what bounds this
                // edge: the edge belongs to one object, its travel is that object's file on one
                // side and its own length on the other, and the crossfade is merely what happens to
                // be under it. Read off the zone instead, the arrows went out the moment the zone
                // did, on a file that could still go both ways.
                return objectEdgeCursor(hit.part == .sideStart ? hit.zone.rightID : hit.zone.leftID,
                                        trimming: hit.part == .sideStart)
            }
            // The fade cursor of the side one is holding: ╱ climbs (the incoming curve, on the
            // left), ╲ comes down (the outgoing one, on the right).
            return hit.part == .sideStart ? TimelineCursors.fadeIn : TimelineCursors.fadeOut
        }
    }

    /// One object's edge cursor: the file on the outward side, the object's own length on the
    /// inward one — the SAME two questions a block's trim and resize handles ask, and deliberately
    /// the same answers. `trimming` = it is that object's LEFT edge.
    func objectEdgeCursor(_ id: UUID, trimming: Bool) -> NSCursor {
        guard let o = viewModel.find(id: id) else { return NSCursor.resizeLeftRight }
        let canShrink = o.duration > 0.01 + edgeEpsilon
        return trimming
            ? TimelineCursors.edge(open: true,
                                   canLeft: headroomBefore(o) > edgeEpsilon, canRight: canShrink)
            : TimelineCursors.edge(open: false,
                                   canLeft: canShrink, canRight: headroomAfter(o) > edgeEpsilon)
    }

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
            leftCurveAnchor:  viewModel.find(id: z.leftID)?.fadeOutCurve ?? .linear,
            rightCurveAnchor: viewModel.find(id: z.rightID)?.fadeInCurve ?? .linear)
        // Only the crop band can push an object out of its own zone, so only it needs the way back.
        if hit.viaEdgeBand,
           let held = viewModel.find(id: hit.part == .sideStart ? z.rightID : z.leftID) {
            crossfadeDrag?.heldAnchor = (held.startTime, held.duration)
        }
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
            //
            // RIGHT WIDENS, LEFT NARROWS — always, wherever inside the triangle the hand came down.
            // It used to push the NEARER EDGE outwards, so the sign flipped at the zone's midline:
            // the same travel widened or narrowed depending on which half one had grabbed, and a
            // crossfade is symmetric, so there is nothing on screen that says which half that was.
            // A gesture whose meaning one cannot SEE is a gesture one has to try. One direction,
            // one meaning: more to the right is more, as everywhere else on a timeline.
            rawWidth   = state.anchorWidth + 2 * dx
            idealStart = state.anchorCentre - max(0, rawWidth) / 2
        case .sideStart:
            rawWidth   = state.anchorEnd - viewModel.snapTime(state.anchorStart + dx, excluding: excl)
            idealStart = state.anchorEnd - max(0, rawWidth)
        case .sideEnd:
            rawWidth   = viewModel.snapTime(state.anchorEnd + dx, excluding: excl) - state.anchorStart
            idealStart = state.anchorStart
        }
        let width = max(0, rawWidth)
        // The OPPOSITE edge is PINNED, and the seam is TOLD so. Given only a width it gives what it
        // can and takes the rest out of whichever side still has it — right when one is opening a
        // seam, and quite wrong under a hand holding an edge: pushed past what the held side had
        // left, the zone went on growing BACKWARDS while the hand pulled forwards. Named, the pin
        // lowers the ceiling instead, and the gesture stops (@see ZonePin).
        let pin: EditViewModel.ZonePin?
        switch state.part {
        case .sideStart: pin = .end(state.anchorEnd)
        case .sideEnd:   pin = .start(state.anchorStart)
        case .move, .both: pin = nil
        }
        // Past the shut seam, the travel that is left is a PLAIN fade on the object whose edge the
        // hand holds. The two objects stay stuck together: a gesture that was making a crossfade
        // never opens a gap.
        //
        // Only from the FADE triangle. Taken by the crop band underneath, the same edge is being
        // CROPPED, and a crop grows no fade anywhere else in OBJEKAT — it goes on cropping, and it
        // opens the gap a crop opens (see `overCrop` below).
        let spill = (state.part == .move || state.viaEdgeBand) ? 0 : max(0, -rawWidth)
        let overCrop = state.viaEdgeBand ? max(0, -rawWidth) : 0

        let moved = abs(width - state.anchorWidth) > 1e-9 || spill > 0 || overCrop > 0
                 || (idealStart.map { abs($0 - state.anchorStart) > 1e-9 } ?? false)
        if (moved || state.overshootY != 0), !state.didChange {
            // The first frame that actually asks for something: one undo step for the whole drag.
            viewModel.pushUndo()
            state.didChange = true
        }

        if state.didChange {
            // Coming back INTO the zone after a frame that cropped past the joint: the gap that
            // frame opened has to be closed again first, or the seam has nothing to open.
            if state.didOverCrop, overCrop == 0, let ha = state.heldAnchor {
                let held = state.part == .sideStart ? state.rightID : state.leftID
                viewModel.updateTrim(id: held, newStart: ha.start, newDuration: ha.duration)
                state.didOverCrop = false
            }
            let result = viewModel.openCrossfade(leftID: state.leftID, rightID: state.rightID,
                                                 width: width, idealStart: idealStart, pin: pin)
            // The width the HAND asked for, not the one the pinned edge allowed: the HUD's job is
            // to say that the gesture stopped and why, and a pre-clamped figure would agree with
            // itself for ever.
            state.requestedWidth = max(0, rawWidth)
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

            // Past the shut seam, from the CROP band: the crop simply carries on, and a crop that
            // carries on opens a gap. Stopping the edge dead at the joint was the band claiming a
            // limit no crop has ever had — the zone had ended, and what was left under the hand was
            // an ordinary edge that had every right to keep travelling. Bounded only by the object
            // keeping a length, which is a trim's own floor.
            if overCrop > 0 {
                state.didOverCrop = true
                let floor = 0.01
                if state.part == .sideStart, let o = viewModel.find(id: state.rightID) {
                    let end = o.startTime + o.duration
                    let newStart = min(state.anchorEnd + overCrop, end - floor)
                    viewModel.updateTrim(id: o.id, newStart: newStart, newDuration: end - newStart)
                } else if state.part == .sideEnd, let o = viewModel.find(id: state.leftID) {
                    let newEnd = max(state.anchorStart - overCrop, o.startTime + floor)
                    viewModel.updateDuration(id: o.id, duration: newEnd - o.startTime)
                }
            }
        }

        // The arrows follow the drag, as they do on a block's own edge: once the button is down the
        // hover produces no more events, so it is here that an arrow goes out when the file — or
        // the joint — has nothing more to give.
        if state.viaEdgeBand {
            TimelineCursorKeeper.set(
                objectEdgeCursor(state.part == .sideStart ? state.rightID : state.leftID,
                                 trimming: state.part == .sideStart))
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
