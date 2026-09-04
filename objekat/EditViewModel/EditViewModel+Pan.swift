import Foundation

extension EditViewModel {

    // MARK: - Pan

    func updatePan(id: UUID, pan: Float) {
        update(id: id) { $0.pan = ((pan * 10).rounded() / 10).clamped(to: -1...1) }
        recordAutomationTouch(id, .pan)
        pushMix(id)
        propagateLinkedAttr(.pan, from: id)
    }

    func adjustPanSelected(_ delta: Float) {
        guard !selectedIDs.isEmpty else { return }
        // Two passes (see adjustVolumeDB): apply the delta everywhere BEFORE propagating, otherwise a
        // linked instance still to come in the loop would see its delta doubled.
        for id in selectedIDs {
            update(id: id) { $0.pan = ((($0.pan + delta) * 10).rounded() / 10).clamped(to: -1...1) }
            recordAutomationTouch(id, .pan)
            pushMix(id)
        }
        for id in selectedIDs { propagateLinkedAttr(.pan, from: id) }
        isDirty = true
    }

    func resetPanSelected() {
        for id in selectedIDs { updatePan(id: id, pan: 0.0) }
        isDirty = true
    }
}
