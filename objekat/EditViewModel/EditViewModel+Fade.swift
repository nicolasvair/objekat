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

    /// The fade-out an object keeps when its END is taken away — the crop by dragging, a time
    /// selection deleted off the tail, the Cut tool's 'keep the left'.
    ///
    /// THE RULE: the fade's START stays where it is and the fade ends earlier. A fade-out is laid
    /// on the sound one can see — it starts at a point IN the matter, not at a distance from the
    /// edge — so taking half a second off the end must not carry that point half a second back over
    /// material the hand never meant to touch, and must not clear the fade either. What was a fade
    /// down to silence stays one: it simply has less room, and reaches silence at the new end.
    ///
    /// A cut PAST the fade's own start leaves nothing to fade (the result goes negative, hence the
    /// floor at 0): the whole of the curve was inside the piece that went.
    ///
    /// Only for an edge coming IN. Pulling the end back OUT reveals matter the fade never covered,
    /// and a fade that grew with it would be a shape nobody drew — there the fade keeps its length
    /// and follows the edge, as it always has.
    static func fadeOutAnchoredAtStart(oldDuration: Double, oldFadeOut: Double,
                                       newDuration: Double) -> Double {
        guard newDuration < oldDuration else { return oldFadeOut }
        return max(0, newDuration - (oldDuration - oldFadeOut))
    }

    /// The fade-IN an object keeps when its START is taken away — the left trim by dragging, a
    /// time selection deleted off the head. The exact mirror of `fadeOutAnchoredAtStart`.
    ///
    /// THE RULE: the fade's END — the instant the sound reaches its full level, a point IN the
    /// matter — stays where it is, so the fade starts later and is SHORTENED by exactly what was
    /// taken. Clearing it, which is what this did, made the passage start dead on; keeping it whole
    /// would carry the level's arrival point forward over material the hand never meant to touch.
    /// Its SHAPE is untouched: `fadeInCurve` is a separate field, and a shorter fade is the same
    /// curve read over less room.
    ///
    /// A cut PAST the end of the curve leaves nothing to fade (the result goes negative, hence the
    /// floor at 0): the whole of it was inside the piece that went.
    ///
    /// Only for an edge coming IN. Reopening the start reveals matter the fade never covered, and
    /// there the fade keeps its length and follows the edge, as it always has.
    static func fadeInAnchoredAtEnd(oldStart: Double, oldFadeIn: Double,
                                    newStart: Double) -> Double {
        guard newStart > oldStart else { return oldFadeIn }
        return max(0, oldFadeIn - (newStart - oldStart))
    }

    /// The fade the hand is MAKING, heard while it is being made — pushed to the engine and to
    /// NOTHING else: no model change, no undo point, no dirty flag. The gesture goes on owning
    /// the value; this is the engine being told what the eye is already shown.
    ///
    /// Why it costs nothing: every fade in OBJEKAT lives in ONE plugin at the tail of the object's
    /// chain (@see ObjWindowFadePlugin), so a preview is two doubles written into it — no clip
    /// moved, no window reposed, no graph recompiled. Which is what makes it affordable on every
    /// frame of a drag, where the committing path (`updateFadeOut` → `syncFade` → the whole group
    /// window) would not be.
    ///
    /// The length is bounded by the object's CURRENT window: a fade pulled out past its edge will
    /// grow the object at the drop, but until then that matter does not exist, and a fade longer
    /// than the window would open part-way down its own curve (@see clampFades) — a preview of
    /// something nobody is going to get.
    func previewFade(id: UUID, fadeIn: Double? = nil, fadeOut: Double? = nil,
                     curve: FadeCurve? = nil) {
        guard let engine, let obj = find(id: id) else { return }
        let D  = max(0, obj.duration)
        let fi = min(fadeIn  ?? obj.fadeIn,  D)
        let fo = min(fadeOut ?? obj.fadeOut, D)
        engine.previewFades(in: max(0, fi), out: max(0, fo), forID: id.uuidString)
        if let curve {
            let inCurve  = fadeIn  != nil ? curve : obj.fadeInCurve
            let outCurve = fadeOut != nil ? curve : obj.fadeOutCurve
            engine.updateFadeCurves(in: inCurve.shape.engineCode,
                                    amountIn: Float(inCurve.amount),
                                    out: outCurve.shape.engineCode,
                                    amountOut: Float(outCurve.amount),
                                    forID: id.uuidString)
        }
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
