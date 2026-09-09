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

    /// The SHAPE of one edge, or of both. A shape has no length of its own: setting it on an
    /// object with no fade changes nothing audible, and shows up the moment one is pulled.
    func updateFadeCurve(id: UUID, fadeIn: FadeCurve? = nil, fadeOut: FadeCurve? = nil) {
        guard fadeIn != nil || fadeOut != nil else { return }
        update(id: id) { obj in
            if let fadeIn  { obj.fadeInCurve  = fadeIn }
            if let fadeOut { obj.fadeOutCurve = fadeOut }
        }
        if let obj = find(id: id) { pushFadeCurveTree(obj) }
        isDirty = true
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
