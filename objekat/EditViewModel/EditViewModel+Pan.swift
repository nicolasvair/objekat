import Foundation

extension EditViewModel {

    // MARK: - Pan

    // Pan is CONTINUOUS over −1…+1. It was quantised to a tenth for as long as the only way to
    // move it was the ±0.1 arrow keys; every control added since is continuous (the inspector's
    // box, the timeline's Pan tool, the synoptic's knob, an automation's static value), and the
    // quantum silently ate them. Worst of all on a multiple selection, where the box works by
    // DELTAS: a drag hands over ~0.0125 at a time, each object landed back on its own tenth, and
    // the whole gesture moved nothing at all. The steps that ARE wanted are the callers' business
    // — the arrows still pass 0.1 or 0.05 — and no longer the model's.

    func updatePan(id: UUID, pan: Float) {
        update(id: id) { $0.pan = pan.clamped(to: -1...1) }
        recordAutomationTouch(id, .pan)
        pushMix(id)
        propagateLinkedAttr(.pan, from: id)
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
            update(id: id) { $0.pan = (anchor + delta).clamped(to: -1...1) }
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
