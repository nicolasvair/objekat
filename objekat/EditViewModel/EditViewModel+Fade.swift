import Foundation

extension EditViewModel {

    // MARK: - Fades

    func updateFadeIn(id: UUID, fadeIn: Double) {
        update(id: id) { obj in
            let D  = obj.duration
            let fi = max(0, min(fadeIn, D))
            let fo = max(0, min(obj.fadeOut, D - fi))
            obj.fadeIn  = fi
            obj.fadeOut = fo
        }
        syncFade(id: id)
    }

    func updateFadeOut(id: UUID, fadeOut: Double) {
        update(id: id) { obj in
            let D  = obj.duration
            let fo = max(0, min(fadeOut, D))
            let fi = max(0, min(obj.fadeIn, D - fo))
            obj.fadeIn  = fi
            obj.fadeOut = fo
        }
        syncFade(id: id)
    }

    /// Pushes the fade to the engine: the clip's native fade, or the folder's window+fade
    /// envelope for a group.
    private func syncFade(id: UUID) {
        guard let obj = find(id: id) else { return }
        switch obj.kind {
        case .clip, .midiClip:
            engine?.updateFade(in: obj.fadeIn, fadeOut: obj.fadeOut, forID: id.uuidString)
        case .group:
            syncGroupWindow(obj)
        case .aux:
            syncAuxWindow(obj)
        }
    }
}
