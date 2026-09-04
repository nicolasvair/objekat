import Foundation

extension EditViewModel {

    // MARK: - Volume

    func updateVolume(id: UUID, volume: Float) {
        update(id: id) { $0.volume = volume.rounded().clamped(to: -96...40) }
        // The fader has just been touched: it is the one the automation band will offer.
        recordAutomationTouch(id, .volume)
        pushMix(id)
        propagateLinkedAttr(.volume, from: id)
    }

    func adjustVolumeDB(_ dB: Float) {
        guard !selectedIDs.isEmpty else { return }
        // Two passes: the delta is applied to the whole selection FIRST, and only THEN propagated.
        // Otherwise propagating along the loop would bump a linked instance still to come → doubled delta.
        for id in selectedIDs {
            update(id: id) { $0.volume = ($0.volume + dB).rounded().clamped(to: -96...40) }
            recordAutomationTouch(id, .volume)
            pushMix(id)
        }
        for id in selectedIDs { propagateLinkedAttr(.volume, from: id) }
        isDirty = true
    }

    func resetVolumeSelected() {
        for id in selectedIDs { updateVolume(id: id, volume: 0.0) }
        isDirty = true
    }

    /// Toggles the mute of ONE precise object (used by the synoptic's "clip" rectangle,
    /// independent of the selection).
    func toggleMute(id: UUID) {
        guard let cur = find(id: id)?.isMuted else { return }
        update(id: id) { $0.isMuted = !cur }
        pushMix(id)
        propagateLinkedAttr(.mute, from: id)
        isDirty = true
    }

    func toggleMuteSelected() {
        guard !selectedIDs.isEmpty else { return }
        let targetMuted = selectedIDs.contains { id in
            !(find(id: id)?.isMuted ?? false)
        }
        for id in selectedIDs {
            update(id: id) { $0.isMuted = targetMuted }
            pushMix(id)
            propagateLinkedAttr(.mute, from: id)
        }
        isDirty = true
    }
}
