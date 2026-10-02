import Foundation

// MARK: - One frame of a crossfade drag, laid down on the model
//
// It lived in `TimelineView+CrossfadeDrag.swift`. It sits here since the lag read on screen on
// 2 October 2026 ("it lags WHILE I drag a crossfade"): the frame is plain model work — the view
// only contributes the hand (`shift`, the bend) — and a headless door (`debug.crossfade_drag`) can
// now count what a frame costs and compare the batched laying with the one-write-at-a-time laying
// it replaced. The arithmetic is untouched.
//
// THE COST: a frame asks `openCrossfade` (two trims, two fades) and two `updateFadeCurve`s of EVERY
// zone of the gesture — the one under the hand and the ones that follow it — and each of those
// writes `items`, whose `didSet` rebuilds the lane entries in O(N) and drops five caches. Laid down
// one write at a time that was ~8 rebuilds per zone per frame; wrapped in `batchItemsMutation` it
// is ONE per frame. Safe because nothing in a frame reads `laneEntries` (every read is `find` /
// `parentGroup` / `isCrossfadePair` on `items`, which is written at once — only the lane entries
// are held back), which `tools/canvas_nested_cases/c13_crossfade_drag_batch_api.py` checks octet for
// octet against the unbatched laying on random layouts.

extension EditViewModel {

    /// What one frame asks of one zone. Worked out for EVERY zone of the gesture before any of them
    /// is applied, because whether the hand has asked for something at all — and so whether the
    /// undo point is due — is a question about all of them.
    struct CrossfadeFrame {
        let rawWidth: Double
        let width: Double
        let idealStart: Double
        let pin: EditViewModel.ZonePin?
        /// Past the shut seam from the fade triangle: a plain fade on the held side.
        let spill: Double
        /// Past the shut seam from the crop band: the crop goes on.
        let overCrop: Double
        let moved: Bool
    }

    func crossfadeFrame(for t: CrossfadePairTrack, part: CrossfadeDragState.Part,
                                viaEdgeBand: Bool, shift: Double) -> CrossfadeFrame {
        // `rawWidth` may go NEGATIVE — that is the gesture asking for more than the zone has to
        // give, and what is past zero becomes a plain fade.
        let target = CrossfadeGrab.target(part: part, anchorStart: t.anchorStart,
                                          anchorEnd: t.anchorEnd, shift: shift)
        let width = max(0, target.rawWidth)
        // The OPPOSITE edge is PINNED, and the seam is TOLD so. Given only a width it gives what it
        // can and takes the rest out of whichever side still has it — right when one is opening a
        // seam, and quite wrong under a hand holding an edge: pushed past what the held side had
        // left, the zone went on growing BACKWARDS while the hand pulled forwards. Named, the pin
        // lowers the ceiling instead, and the gesture stops (@see ZonePin).
        let pin: EditViewModel.ZonePin?
        switch part {
        case .sideStart: pin = .end(t.anchorEnd)
        case .sideEnd:   pin = .start(t.anchorStart)
        case .move, .both: pin = nil
        }
        // Past the shut seam, the travel that is left is a PLAIN fade on the object whose edge the
        // hand holds. The two objects stay stuck together: a gesture that was making a crossfade
        // never opens a gap.
        //
        // Only from the FADE triangle. Taken by the crop band underneath, the same edge is being
        // CROPPED, and a crop grows no fade anywhere else in OBJEKAT — it goes on cropping, and it
        // opens the gap a crop opens (see `overCrop` below).
        let spill = (part == .move || viaEdgeBand) ? 0 : max(0, -target.rawWidth)
        let overCrop = viaEdgeBand ? max(0, -target.rawWidth) : 0
        let moved = abs(width - t.anchorWidth) > 1e-9 || spill > 0 || overCrop > 0
                 || abs(target.idealStart - t.anchorStart) > 1e-9
        return CrossfadeFrame(rawWidth: target.rawWidth, width: width, idealStart: target.idealStart,
                              pin: pin, spill: spill, overCrop: overCrop, moved: moved)
    }

    /// Lays one frame down on one zone. Every zone gets the SAME travel (@see CrossfadeGrab.target)
    /// and the same bend, and keeps its own width, place and curves.
    func applyCrossfadeFrame(_ f: CrossfadeFrame, to t: inout CrossfadePairTrack,
                                     state: CrossfadeDragState) {
        // Coming back INTO the zone after a frame that cropped past the joint: the gap that
        // frame opened has to be closed again first, or the seam has nothing to open.
        if t.didOverCrop, f.overCrop == 0, let ha = t.heldAnchor {
            let held = state.part == .sideStart ? t.rightID : t.leftID
            updateTrim(id: held, newStart: ha.start, newDuration: ha.duration)
            t.didOverCrop = false
        }
        let result = openCrossfade(leftID: t.leftID, rightID: t.rightID,
                                             width: f.width, idealStart: f.idealStart, pin: f.pin)
        // The width the HAND asked for, not the one the pinned edge allowed: the HUD's job is
        // to say that the gesture stopped and why, and a pre-clamped figure would agree with
        // itself for ever.
        t.requestedWidth = max(0, f.rawWidth)
        // A zone shut to nothing stops being a crossfade, so the ids would no longer resolve
        // to one: the gesture keeps its own two ids and can reopen the seam on the way back.
        if case .success(let zone) = result {
            t.obtainedWidth = zone?.width ?? 0
            if let zone {
                t.leftID = zone.leftID
                t.rightID = zone.rightID
            }
        }
        let curves = state.curves(for: t)
        updateFadeCurve(id: t.leftID,  fadeOut: curves.left)
        updateFadeCurve(id: t.rightID, fadeIn:  curves.right)

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
        t.spilloverFade = f.spill
        if f.spill > 0 {
            if state.part == .sideStart, let o = find(id: t.rightID) {
                updateFadeIn(id: o.id, fadeIn: min(f.spill, o.duration))
            } else if state.part == .sideEnd, let o = find(id: t.leftID) {
                updateFadeOut(id: o.id, fadeOut: min(f.spill, o.duration))
            }
        }

        // Past the shut seam, from the CROP band: the crop simply carries on, and a crop that
        // carries on opens a gap. Stopping the edge dead at the joint was the band claiming a
        // limit no crop has ever had — the zone had ended, and what was left under the hand was
        // an ordinary edge that had every right to keep travelling. Bounded only by the object
        // keeping a length, which is a trim's own floor.
        if f.overCrop > 0 {
            t.didOverCrop = true
            let floor = 0.01
            if state.part == .sideStart, let o = find(id: t.rightID) {
                let end = o.startTime + o.duration
                let newStart = min(t.anchorEnd + f.overCrop, end - floor)
                updateTrim(id: o.id, newStart: newStart, newDuration: end - newStart)
            } else if state.part == .sideEnd, let o = find(id: t.leftID) {
                let newEnd = max(t.anchorStart - f.overCrop, o.startTime + floor)
                updateDuration(id: o.id, duration: newEnd - o.startTime)
            }
        }
    }

    /// One frame of the gesture, every zone: worked out for ALL of them first, the undo point
    /// pushed on the first frame that asks for anything (one step for the whole drag, every zone of
    /// it), then laid down — in ONE batch of model writes, unless `batched` is false (the way it was
    /// laid before, kept so the two can be compared).
    func driveCrossfadeFrame(_ state: inout CrossfadeDragState, shift: Double, batched: Bool = true) {
        let frames = state.tracks.map {
            crossfadeFrame(for: $0, part: state.part, viaEdgeBand: state.viaEdgeBand, shift: shift)
        }
        if (frames.contains { $0.moved } || state.overshootY != 0), !state.didChange {
            // The first frame that actually asks for something: one undo step for the whole drag,
            // every zone of it.
            pushUndo()
            state.didChange = true
        }
        guard state.didChange else { return }

        func layDown() {
            for i in state.tracks.indices {
                var t = state.tracks[i]
                applyCrossfadeFrame(frames[i], to: &t, state: state)
                state.tracks[i] = t
            }
        }
        if batched { batchItemsMutation { layDown() } } else { layDown() }
    }
}
