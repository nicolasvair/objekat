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
// What the hand does inside it, and why that split:
//
//  • the BODY moves the seam — the two go on meeting for just as long, but somewhere else. It is
//    the gesture one wants most often, so it gets the largest target;
//  • the EDGES widen and narrow it, the opposite edge staying put;
//  • the VERTICAL bends both curves at once, exactly as on a fade: the origin is the object's own
//    ROW, so while the hand stays on the block the curves are left alone, and leaving the row
//    upwards bulges, downwards hollows. ⌥ flips them to the S. A gesture whose limit one can SEE
//    beats one calibrated in pixels.
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
        /// The middle: slide the seam, width unchanged.
        case body
        /// An edge: widen or narrow, the opposite edge pinned.
        case edgeStart, edgeEnd
        /// A seam still SHUT: the drag opens it, symmetrically about the join. This is the only
        /// way a crossfade is created, and it is why the join is a target of its own — with no
        /// zone yet there is no surface to grab, just the line where the two objects meet.
        case openFromSeam
    }

    var leftID:  UUID
    var rightID: UUID
    let part: Part

    /// The zone as it stood when the hand came down. Everything is computed from this.
    let anchorStart: Double
    let anchorEnd:   Double
    var anchorWidth: Double { anchorEnd - anchorStart }

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

extension TimelineView {

    /// How close to an edge of the zone counts as grabbing that edge, in px. Never more than a
    /// third of the zone, so the body stays reachable on a narrow crossfade.
    static let crossfadeEdgeGrabPx: Double = 7

    /// How close to a SHUT seam counts as grabbing it. Wider than an edge of an open zone: there
    /// is no surface to aim at, only a line, and the join is also where two blocks' own trim and
    /// resize handles meet — so it has to be findable without being greedy.
    static let seamGrabPx: Double = 5

    /// The crossfade under a canvas point, and which part of it the hand is on. `nil` when the
    /// point is not in a zone — the ordinary per-block carve-up then applies, untouched.
    func crossfadeHit(at p: CGPoint) -> (zone: EditViewModel.CrossfadeZone, part: CrossfadeDragState.Part)? {
        guard p.y > rulerHeight else { return nil }
        let lane = Int((p.y - rulerHeight) / laneStep)
        let laneTop = rulerHeight + Double(lane) * laneStep
        guard p.y <= laneTop + blockHeight else { return nil }
        let t = p.x / pixelsPerSecond
        guard let zone = viewModel.crossfadeZone(atTime: t, displayLane: lane) else {
            // No zone here: perhaps a seam still shut, which is what one grabs to make one.
            guard let seam = viewModel.buttSeam(nearTime: t, displayLane: lane,
                                                tolerance: Self.seamGrabPx / pixelsPerSecond)
            else { return nil }
            let shut = EditViewModel.CrossfadeZone(leftID: seam.left, rightID: seam.right,
                                                   containerID: nil, lane: lane,
                                                   start: seam.at, end: seam.at)
            return (shut, .openFromSeam)
        }

        let x0 = zone.start * pixelsPerSecond
        let x1 = zone.end * pixelsPerSecond
        let grab = min(Self.crossfadeEdgeGrabPx, (x1 - x0) / 3)
        if p.x - x0 <= grab { return (zone, .edgeStart) }
        if x1 - p.x <= grab { return (zone, .edgeEnd) }
        return (zone, .body)
    }

    /// Starts the gesture if the hand came down on a zone. Called BEFORE the per-block carve-up,
    /// the way the loop markers are: a narrow target tested before the surfaces that cover the
    /// same pixels — here the two fade triangles the zone is made of, which would otherwise
    /// confiscate it and bend one side alone.
    func beginCrossfadeDragIfHit(at p: CGPoint) -> Bool {
        guard let hit = crossfadeHit(at: p) else { return false }
        let z = hit.zone
        crossfadeDrag = CrossfadeDragState(
            leftID: z.leftID, rightID: z.rightID, part: hit.part,
            anchorStart: z.start, anchorEnd: z.end,
            lane: Int((p.y - rulerHeight) / laneStep),
            leftCurveAnchor:  viewModel.find(id: z.leftID)?.fadeOutCurve ?? .linear,
            rightCurveAnchor: viewModel.find(id: z.rightID)?.fadeInCurve ?? .linear)
        return true
    }

    /// One frame of the gesture. Returns false when no crossfade drag is running.
    @discardableResult
    func handleCrossfadeDrag(_ value: DragGesture.Value, phase: DragPhase) -> Bool {
        guard var state = crossfadeDrag else { return false }

        // The vertical, measured against the ROW and not in pixels — the same origin as a fade's,
        // so the two gestures answer to the hand in the same way.
        let laneTop = rulerHeight + Double(state.lane) * laneStep
        let y = value.location.y
        state.overshootY = y < laneTop ? y - laneTop
                         : (y > laneTop + blockHeight ? y - (laneTop + blockHeight) : 0)
        state.bendTravelPx = blockHeight
        state.sCurve = NSEvent.modifierFlags.contains(.option)

        let dx = Double(value.translation.width) / pixelsPerSecond

        // Absolute targets from the FROZEN zone: the clamp never feeds back into the hand.
        let width: Double
        let idealStart: Double
        switch state.part {
        case .body:
            width      = state.anchorWidth
            idealStart = viewModel.snapTime(state.anchorStart + dx)
        case .edgeStart:
            let newStart = viewModel.snapTime(state.anchorStart + dx)
            width      = max(0, state.anchorEnd - newStart)
            idealStart = state.anchorEnd - width
        case .edgeEnd:
            let newEnd = viewModel.snapTime(state.anchorEnd + dx)
            width      = max(0, newEnd - state.anchorStart)
            idealStart = state.anchorStart
        case .openFromSeam:
            // Pulling either way opens it, and it opens ABOUT the join — hence `nil`, the centred
            // default. Which way the hand went says how far, not which side gives: that is settled
            // by the material each side has left.
            width      = abs(dx)
            idealStart = .nan   // stands for "centred"; see the call below
        }

        let moved = (!idealStart.isNaN && abs(idealStart - state.anchorStart) > 1e-9)
                 || abs(width - state.anchorWidth) > 1e-9
        if (moved || state.overshootY != 0), !state.didChange {
            // The first frame that actually asks for something: one undo step for the whole drag.
            viewModel.pushUndo()
            state.didChange = true
        }

        if state.didChange {
            let result = viewModel.openCrossfade(leftID: state.leftID, rightID: state.rightID,
                                                 width: width,
                                                 idealStart: idealStart.isNaN ? nil : idealStart)
            // A zone shut to nothing stops being a crossfade, so the ids would no longer resolve
            // to one: the gesture keeps its own two ids and can reopen the seam on the way back.
            if case .success(let zone) = result, let zone {
                state.leftID = zone.leftID
                state.rightID = zone.rightID
            }
            let curves = state.curves()
            viewModel.updateFadeCurve(id: state.leftID,  fadeOut: curves.left)
            viewModel.updateFadeCurve(id: state.rightID, fadeIn:  curves.right)
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
