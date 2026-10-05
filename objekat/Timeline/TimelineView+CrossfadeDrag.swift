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
//  • the LOWER half is a block's, unchanged: a handle at each end — the same fixed 20 px capped at
//    a third of the zone's width (@see ClipEditZone.handleWidth) — and the whole middle to the
//    BODY. The handles take
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
// The model is NOT written while the hand is down. The frame is worked out on a private copy of the
// objects the gesture touches (`CrossfadeShadow`, @see EditViewModel+CrossfadeFrame) — by the very
// arithmetic the model would run — and the timeline draws that copy through the preview path every
// other edge gesture uses (`BlockPreviewGeometry`: a trim, a resize, the two fades and their shapes
// per object, and the zone's X from the copies' geometry). It used to be applied live, on the
// ground that a crossfade IS geometry and moving it redraws the blocks by itself; the price was six
// writes of `items` per frame, each rebuilding the lane entries and invalidating the whole Canvas —
// the lag read on screen on 2 October 2026. On release: ONE undo point, pushed before the first
// write, and ONE write of the model (@see EditViewModel.commitCrossfadeDrag).
//
// Every frame recomputes the target from the zone frozen at the gesture's start plus the TOTAL
// translation, never from the zone as it now stands: the model clamps, and feeding a clamped
// result back in would let the gesture drift away from the hand.
//
// ── Several objects selected ────────────────────────────────────────────────────────────────
//
// The gesture drives every crossfade of the selection, as the fade drag drives every selected
// object's fade (@see CrossfadeGrab.followers for which ones). The grabbed zone is the only one
// that SNAPS: it yields the travel of the held edge, and every other zone receives that same
// number — each keeps its own width and place, and none lands on a grid line of its own, which
// would no longer be one gesture. The bend is shared the same way (each zone adds it to its OWN
// starting curves). One undo point, pushed on the first frame that asks for anything.
//
// A fade handle that overhangs a zone is a grab of that zone too (@see fadeHandleOverhang).

/// What a gesture keeps about ONE zone: the pair as the hand found it, the zone as it stood then
/// (everything is computed from this, never from the zone as it now stands), and what the frames
/// have done to it since. A gesture holds one of these for the zone under the hand and one for
/// each crossfade that follows it (@see CrossfadeGrab.followers).
struct CrossfadePairTrack {
    var leftID:  UUID
    var rightID: UUID

    /// The zone as it stood when the hand came down. Everything is computed from this.
    let anchorStart: Double
    let anchorEnd:   Double
    var anchorWidth: Double { anchorEnd - anchorStart }
    var anchorCentre: Double { (anchorStart + anchorEnd) / 2 }

    /// The curves the two edges had at the start — the bend ADDS to them, so a crossfade already
    /// bent stays bent when one merely moves or widens it.
    var leftCurveAnchor:  FadeCurve = .linear
    var rightCurveAnchor: FadeCurve = .linear

    /// The held object as the gesture found it, and whether the last frame cropped PAST the joint.
    /// A frame that did leaves the two objects with a gap between them, and a gap is not a seam:
    /// the next frame's `openCrossfade` would be refused, and the hand could leave a crossfade but
    /// never come back into it. So the object goes back where it was found before the seam is
    /// asked anything, and the frame is computed whole from the anchors like every other one.
    var heldAnchor: (start: Double, duration: Double)? = nil
    var didOverCrop = false

    /// The width the hand asked for, and the one the seam gave. They part company as soon as the
    /// clamp bites.
    var requestedWidth: Double = 0
    var obtainedWidth:  Double = 0
    /// The plain fade the gesture has grown past the shut seam, on the object whose edge it holds.
    var spilloverFade: Double = 0
}

/// One drag on a crossfade zone — and, with several objects selected, on every crossfade of the
/// selection at once.
struct CrossfadeDragState {
    /// The parts a hand can take hold of — defined in `Shared/CrossfadeGrab.swift`, with the pure
    /// decisions that read them.
    typealias Part = CrossfadePart

    /// The zone under the hand AND the ones that follow it, in the order of their start on the
    /// timeline: a clip shared by two neighbouring zones is touched by both, and the order they are
    /// laid down in must not depend on a set's. `grabbedIndex` is the one the hand is on.
    var tracks: [CrossfadePairTrack]
    let grabbedIndex: Int

    let part: Part
    /// The gesture took hold through the LOWER half's handle — the crop band — rather than through
    /// the veil above it. The two drive the same edge, and they part company at the limit: a crop
    /// is a crop and grows nothing, while the fade triangle carries on into a plain fade.
    var viaEdgeBand: Bool = false

    /// The display lane the zone under the hand sits on: the origin of the vertical travel.
    let lane: Int

    /// The vertical travel outside the row (px). 0 while the hand is on the block.
    var overshootY: Double = 0
    /// One block-height of travel from straight to full bend, as on a fade.
    var bendTravelPx: Double = 60
    var sCurve: Bool = false

    /// True once the hand has actually asked for something, so a click that merely twitches on a
    /// zone does not push an undo step for a gesture that changed nothing.
    var didChange = false

    /// The objects as the frames have left them (taken from the model on the first frame that asks
    /// for something). The model holds the objects as the hand found them until the release; the
    /// timeline draws THESE, through the preview path (@see EditViewModel+CrossfadeFrame).
    var shadow: CrossfadeShadow? = nil

    /// What a snap reads, frozen when the hand comes down: the model does not move under the
    /// gesture, so the marks it can land on cannot either.
    var snap: EditViewModel.SnapFrame? = nil

    // The zone under the hand is what the HUD, the cursor and the first frame read.
    var grabbed: CrossfadePairTrack { tracks[grabbedIndex] }
    var leftID:  UUID { grabbed.leftID }
    var rightID: UUID { grabbed.rightID }
    var anchorStart: Double { grabbed.anchorStart }
    var anchorEnd:   Double { grabbed.anchorEnd }

    var bendDelta: Double { -overshootY / max(1, bendTravelPx) }

    /// The two curves the gesture asks for, for the zone under the hand (what the HUD names). Both
    /// sides get the SAME bend: a crossfade is one object as far as the hand is concerned, and
    /// bending only one half of it is what `object.set_fade_curve` is for.
    func curves() -> (left: FadeCurve, right: FadeCurve) { curves(for: grabbed) }

    /// The same for any zone of the gesture: its OWN starting curves, moved by the one bend the
    /// hand has travelled — what the fade drag does for each object of a selection.
    func curves(for t: CrossfadePairTrack) -> (left: FadeCurve, right: FadeCurve) {
        guard overshootY != 0 else { return (t.leftCurveAnchor, t.rightCurveAnchor) }
        return (.signed(t.leftCurveAnchor.signedAmount + bendDelta,
                        sCurve: t.leftCurveAnchor.isS != sCurve),
                .signed(t.rightCurveAnchor.signedAmount + bendDelta,
                        sCurve: t.rightCurveAnchor.isS != sCurve))
    }
}

/// What the hand is on, inside a zone: the part it will drive, and whether it took hold through
/// the lower half's handle — which changes nothing but the cursor, and that matters.
struct CrossfadeHit {
    let zone: EditViewModel.CrossfadeZone
    let part: CrossfadeDragState.Part
    let viaEdgeBand: Bool
    /// Set when the zone was taken through an object's fade handle OUTSIDE it (@see
    /// fadeHandleOverhang): which fade the hand holds, which is what decides who owns the grab and
    /// which crossfades of the selection follow (@see CrossfadeGrab.followers).
    var heldFade: CrossfadeGrab.FadeEdge? = nil
}

extension TimelineView {

    /// The crossfade under a canvas point, and which part of it the hand is on. `nil` when the
    /// point is not in a zone — the ordinary per-block carve-up then applies, untouched — except
    /// for one case that is the zone's all the same: a fade handle of an object engaged in a
    /// crossfade, grabbed where it overhangs the zone (@see fadeHandleOverhang).
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
        guard let zone = viewModel.crossfadeZone(atTime: t, displayLane: lane) else {
            return fadeHandleOverhang(at: p, displayLane: lane, laneTop: laneTop)
        }

        let x0 = zone.start * pixelsPerSecond
        let x1 = zone.end * pixelsPerSecond
        let w  = x1 - x0
        guard w > 0 else { return nil }
        let lx = min(max(p.x - x0, 0), w)
        let ly = min(max(p.y - laneTop, 0), blockHeight)
        let a  = lx / w

        // ── The LOWER half: the objects' own, and nothing else ──────────────────────────────
        // The same handle as a block's, measured on the ZONE's width by the same function: a
        // fixed 20 px, capped at a third of the zone so that a narrow one keeps a body.
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

    /// A fade handle of an object ENGAGED in a crossfade, grabbed where it sticks out of the zone.
    ///
    /// The handle band is 20 px wide (@see handleWidth), the zone
    /// is often narrower, and the part of the band beyond the zone used to fall through to the
    /// per-block fade — which changes one fade and leaves the other at the old overlap. The pair
    /// then stopped being a crossfade (@see isCrossfadePair) and the two clips stayed superposed.
    /// That band is the crossfade's own side, and the side is the one NEAREST the hand: a fade-in
    /// handle overhangs the zone on its RIGHT (past the zone's end, inside the right-hand object),
    /// so it drives the zone's END; a fade-out handle overhangs on the LEFT and drives its START.
    /// The same side the zone's own upper half gives just across the boundary, so going in and out
    /// of the zone never swaps the edge under the hand (@see
    /// CrossfadeGrab.pair(forFade:of:partnerLeft:partnerRight:)).
    ///
    /// The zone is looked up among the SHOWN ones (`visibleCrossfadeZones`) and not through
    /// `crossfadeZone(leftID:rightID:)`: the drag works in the canvas' absolute time, and the
    /// second answers in the container's — they differ for the child of an open group.
    ///
    /// The block's own carve-up decides what is under the hand (`selectionZoneHover`, the one the
    /// drag falls back on), so this and the plain fade can never disagree about where the handle
    /// is. Only the two fade zones count — a trim or a resize handle is the object's, whatever sits
    /// beside it — and an object with no crossfade on that side keeps the plain fade, untouched.
    private func fadeHandleOverhang(at p: CGPoint, displayLane lane: Int, laneTop: Double) -> CrossfadeHit? {
        // Fades live in the UPPER half of a block (@see ClipEditZone.resolve): ruling the lower half
        // out first keeps this off the hover's path for most of the pointer's travel.
        // And a row with no shown crossfade at all cannot hold one of these handles — the zone is
        // looked up on that very row below, so the answer would be `nil` anyway. That keeps the
        // block carve-up (`selectionZoneHover`, which walks the row's objects) off every mouse
        // move over a row that has none.
        guard p.y - laneTop < blockHeight / 2,
              !viewModel.visibleCrossfadeZones(onDisplayLane: lane).isEmpty,
              let (hover, item) = selectionZoneHover(at: p) else { return nil }
        let edge: CrossfadeGrab.FadeEdge
        switch hover.zone {
        case .fadeIn:  edge = .fadeIn
        case .fadeOut: edge = .fadeOut
        default:       return nil
        }
        let partners = viewModel.crossfadePartners(of: item.id)
        guard let found = CrossfadeGrab.pair(forFade: edge, of: item.id,
                                             partnerLeft: partners?.left,
                                             partnerRight: partners?.right),
              let zone = viewModel.visibleCrossfadeZones(onDisplayLane: lane).first(where: {
                  $0.leftID == found.pair.left && $0.rightID == found.pair.right
              }) else { return nil }
        return CrossfadeHit(zone: zone, part: found.part, viaEdgeBand: false, heldFade: edge)
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
        // A crossfade drag holds its objects in copies: the arrows follow THEM.
        guard let o = crossfadeDrag?.shadow?.objects[id] ?? viewModel.find(id: id)
        else { return NSCursor.resizeLeftRight }
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
    ///
    /// With several objects selected the gesture takes the selection's OTHER crossfades along
    /// (@see CrossfadeGrab.followers for which, and why). It is decided HERE, on the selection as
    /// the hand found it: taking hold of a zone's body selects the zone, which empties the
    /// selection of objects — and that is read after.
    func beginCrossfadeDragIfHit(at p: CGPoint) -> Bool {
        guard let hit = crossfadeHit(at: p) else { return false }
        let z = hit.zone
        let grabbedPair = CrossfadeGrab.Pair(left: z.leftID, right: z.rightID)

        func track(_ zone: EditViewModel.CrossfadeZone) -> CrossfadePairTrack {
            var t = CrossfadePairTrack(
                leftID: zone.leftID, rightID: zone.rightID,
                anchorStart: zone.start, anchorEnd: zone.end,
                leftCurveAnchor:  viewModel.find(id: zone.leftID)?.fadeOutCurve ?? .linear,
                rightCurveAnchor: viewModel.find(id: zone.rightID)?.fadeInCurve ?? .linear)
            // Only the crop band can push an object out of its own zone, so only it needs the way back.
            if hit.viaEdgeBand,
               let held = viewModel.find(id: hit.part == .sideStart ? zone.rightID : zone.leftID) {
                t.heldAnchor = (held.startTime, held.duration)
            }
            return t
        }

        var tracks = [track(z)]
        let others = CrossfadeGrab.followers(
            part: hit.part, grabbed: grabbedPair, selected: viewModel.selectedIDs,
            heldFade: hit.heldFade,
            partners: { id in
                let c = viewModel.crossfadePartners(of: id)
                return (c?.left, c?.right)
            })
        if !others.isEmpty {
            // The zones as the canvas SHOWS them — the same absolute time the zone under the hand
            // was read in. One that is not on a row (inside a folded group) has nothing to follow.
            var shown: [CrossfadeGrab.Pair: EditViewModel.CrossfadeZone] = [:]
            for zone in viewModel.visibleCrossfadeZones() {
                shown[CrossfadeGrab.Pair(left: zone.leftID, right: zone.rightID)] = zone
            }
            for pair in others { if let zone = shown[pair] { tracks.append(track(zone)) } }
        }
        // By start, the grabbed one wherever that puts it (the id breaks a tie, so the order is the
        // same from one frame to the next).
        tracks.sort { ($0.anchorStart, $0.leftID.uuidString) < ($1.anchorStart, $1.leftID.uuidString) }
        let grabbedIndex = tracks.firstIndex { $0.leftID == z.leftID && $0.rightID == z.rightID } ?? 0

        // The bottom triangle is the zone taken AS an object: taking hold of it selects it, which
        // is what gives ⌫ something to delete. The two objects leave the selection — a crossfade
        // is not them, it is what they share.
        if hit.part == .move { viewModel.selectCrossfade(left: z.leftID, right: z.rightID) }
        var state = CrossfadeDragState(
            tracks: tracks, grabbedIndex: grabbedIndex, part: hit.part,
            viaEdgeBand: hit.viaEdgeBand,
            lane: Int((p.y - rulerHeight) / laneStep))
        // The pairs are EXCLUDED from the snap targets (@see handleCrossfadeDrag), and the targets
        // are read ONCE: nothing under the hand writes the model, so they cannot change.
        state.snap = viewModel.snapFrame(excluding: Set(tracks.flatMap { [$0.leftID, $0.rightID] }))
        crossfadeDrag = state
        return true
    }

    /// A double click inside a zone resets it: the pair comes back onto the middle and each loses
    /// its fade, shape included. The same bargain as the double click on a fade — you pull to make
    /// one, you double-click to take it away — and the same thing ⌫ does to a selected zone.
    /// A fade handle of the pair that overhangs the zone answers the same (@see crossfadeHit): it
    /// closes the crossfade, both fades, and never erases ONE fade of a pair that would then no
    /// longer be one.
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
    func handleCrossfadeDrag(_ value: CanvasDrag, phase: DragPhase) -> Bool {
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

        // The travel of the held edge — or, for the whole zone, of the hand — from the zone under
        // the hand as it stood when the hand came down: absolute targets from the FROZEN zone, the
        // clamp never feeds back into the hand. It is the ONE number every zone of the gesture is
        // laid down from (@see CrossfadeGrab.target): the others follow by the same travel and
        // never snap on their own, two zones each landing on a grid line of their own being no
        // longer one gesture.
        //
        // The pairs are EXCLUDED from the snap targets, exactly as a trim excludes the objects it
        // moves: a zone's two boundaries ARE its two objects' edges, so leaving them in would have
        // the travelling edge snap onto the very edge it is moving away from — the zone sticking
        // shut, or leaping to the neighbour's far end. All the zones that move, not only the one
        // under the hand.
        let snap = state.snap ?? viewModel.snapFrame(
            excluding: Set(state.tracks.flatMap { [$0.leftID, $0.rightID] }))
        state.snap = snap
        let g = state.grabbed
        let shift: Double
        switch state.part {
        case .move, .sideStart:
            shift = viewModel.snapTime(g.anchorStart + dx, in: snap) - g.anchorStart
        case .sideEnd:
            shift = viewModel.snapTime(g.anchorEnd + dx, in: snap) - g.anchorEnd
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
            shift = dx
        }

        // One frame, every zone: worked out first, then laid down on the gesture's copies of the
        // objects — the model is not written (@see EditViewModel.driveCrossfadeFrame).
        viewModel.driveCrossfadeFrame(&state, shift: shift)

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
            // ONE undo point, ONE write of the model — and the engine told, once.
            viewModel.commitCrossfadeDrag(state)
            crossfadeDrag = nil
        } else {
            crossfadeDrag = state
        }
        return true
    }
}
