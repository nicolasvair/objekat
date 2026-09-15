import Foundation

extension EditViewModel {

    // MARK: - Pan

    // Pan lives on a DETENT: a TENTH, and it is the only value a hand may lay down. 0 %, 10 %,
    // 20 % — the centre and the two edges are what one aims at, and the values in between are not
    // wanted (asked for again on 15 September 2026, after the detent came back tied to the grid
    // snap: a session built off the grid had no detent at all, and a control the snap did not reach
    // — the synoptic's box, which writes an ABSOLUTE value — had none in any case).
    //
    // So the detent is UNCONDITIONAL and it belongs to the GESTURE layer, at the two doors a hand
    // comes in by: `applyPanDelta` (the Pan tool, the inspector's box, the ±0.1 arrows, the wheel)
    // and `setPanFromHand` (the synoptic's box, which sets rather than adds). It does NOT answer to
    // `effectiveSnapEnabled` — the grid is about TIME, and a pan has nothing to place itself
    // against — and ⌘ no longer lifts it: a modifier that leaves 13 % behind in the file is the
    // intermediate value under another name.
    //
    // `updatePan` stays EXACT, because it is the machine's door (`object.set_pan`) and the
    // automation's: a script setting 0.37 gets 0.37, and a curve plays what it draws.
    //
    // WHY THE QUANTUM MAY NOT GO BACK INTO THE MODEL, where it lived until 12 September 2026: it
    // COMPOUNDED. A delta gesture handed over ~0.0125 at a time, each one added to the STORED value
    // and rounded straight back onto the tenth it came from, so the travel was thrown away on every
    // frame and a multiple drag moved nothing at all, for ever. A gesture works from ANCHORS and
    // hands over its TOTAL travel since: the rounding lands on the result and never feeds the next
    // frame, so a slow drag simply waits until the total crosses the half-step — which is what a
    // detent IS. Its accepted cost, on a multiple selection: an object whose pan was not on a tenth
    // is brought onto one, so the spread between the objects can shift by up to half a step.

    /// A pan brought onto its detent — the tenth. The ONE definition: every gesture goes through it,
    /// so no two controls can disagree about where the pan clicks.
    static func detentedPan(_ v: Float) -> Float {
        ((v * 10).rounded() / 10).clamped(to: -1...1)
    }

    func updatePan(id: UUID, pan: Float) {
        update(id: id) { $0.pan = pan.clamped(to: -1...1) }
        recordAutomationTouch(id, .pan)
        pushMix(id)
        propagateLinkedAttr(.pan, from: id)
    }

    /// The door a HAND comes in by when it SETS a pan rather than adding to it (the synoptic's box,
    /// a knob, a direct entry): the value lands on the detent.
    func setPanFromHand(id: UUID, pan: Float) {
        updatePan(id: id, pan: Self.detentedPan(pan))
    }

    /// The selection's pans, as they stand. The ORIGIN a continuous gesture works from: see
    /// `applyPanDelta`.
    func panSnapshot() -> [UUID: Float] {
        Dictionary(uniqueKeysWithValues:
            selectedIDs.compactMap { find(id: $0) }.map { ($0.id, $0.pan) })
    }

    /// A one-shot relative step (the arrow keys, a menu): read the current value, add, write.
    func adjustPanSelected(_ delta: Float) {
        applyPanDelta(delta, from: panSnapshot())
    }

    /// Applies to every anchored object the TOTAL travel since `anchors` was taken. A continuous
    /// gesture snapshots once (`panSnapshot`) at its start and passes its whole delta each time,
    /// rather than compounding small deltas on the stored value: the range being ±1, an object
    /// reaches the edge in one flick, and a compounded delta would leave it there with its offset
    /// LOST — coming back would collapse the selection onto the edge instead of restoring the
    /// spread it started with.
    func applyPanDelta(_ delta: Float, from anchors: [UUID: Float]) {
        guard !anchors.isEmpty else { return }
        // Two passes (see adjustVolumeDB): apply the delta everywhere BEFORE propagating, otherwise a
        // linked instance still to come in the loop would see its delta doubled.
        for (id, anchor) in anchors {
            let raw = (anchor + delta).clamped(to: -1...1)
            update(id: id) { $0.pan = Self.detentedPan(raw) }
            recordAutomationTouch(id, .pan)
            pushMix(id)
        }
        for id in anchors.keys { propagateLinkedAttr(.pan, from: id) }
        isDirty = true
    }

    func resetPanSelected() {
        for id in selectedIDs { updatePan(id: id, pan: 0.0) }
        isDirty = true
    }
}
