import Foundation

extension EditViewModel {

    // MARK: - Volume

    /// A volume as the model keeps it: clamped, and at the resolution of a TENTH of a dB (it was a whole
    /// dB until 22 October 2026, which swallowed every ⇧ fine step). The session stores the Float as
    /// is, so no format change: a file written with whole dB reads the same. A gesture that wants whole
    /// dB (the bare drag on the timeline) snaps BEFORE calling.
    static func roundedVolume(_ db: Float) -> Float {
        ((db * 10).rounded() / 10).clamped(to: -96...40)
    }

    func updateVolume(id: UUID, volume: Float) {
        update(id: id) { $0.volume = Self.roundedVolume(volume) }
        // The fader has just been touched: it is the one the automation band will offer.
        recordAutomationTouch(id, .volume)
        pushMix(id)
    }

    func adjustVolumeDB(_ dB: Float) {
        guard !selectedIDs.isEmpty else { return }
        // One batch: a single rebuild of the lane entries instead of one per `items` write.
        batchItemsMutation {
            // ONE traversal and ONE write of `items` (`updateMany`), then the engine.
            let ids = selectedIDs
            updateMany(ids) { o in
                o.volume = Self.roundedVolume(o.volume + dB)
                o.recordAutomationTouch(.volume)
            }
            for id in ids { pushMix(id) }
            isDirty = true
        }
    }

    func resetVolumeSelected() {
        batchItemsMutation {
            for id in selectedIDs { updateVolume(id: id, volume: 0.0) }
            isDirty = true
        }
    }

    /// Toggles the mute of ONE precise object (used by the synoptic's "clip" rectangle,
    /// independent of the selection).
    func toggleMute(id: UUID) {
        guard let cur = find(id: id)?.isMuted else { return }
        update(id: id) { $0.isMuted = !cur }
        pushMix(id)
        isDirty = true
    }

    func toggleMuteSelected() {
        guard !selectedIDs.isEmpty else { return }
        let targetMuted = selectedIDs.contains { id in
            !(find(id: id)?.isMuted ?? false)
        }
        batchItemsMutation {
            for id in selectedIDs {
                update(id: id) { $0.isMuted = targetMuted }
                pushMix(id)
            }
            isDirty = true
        }
    }
}
