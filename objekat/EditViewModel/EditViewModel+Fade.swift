import Foundation

extension EditViewModel {

    // MARK: - Fades

    /// What the three `updateFade…` setters do to ONE object's value, with no lookup, no engine and
    /// no write to `items` — the part a crossfade drag replays on its own copies of the objects
    /// (@see CrossfadeShadow), so that the copy and the model can never be two arithmetics.
    func applyFadeIn(to obj: inout SoundObject, fadeIn: Double) {
        let D  = obj.duration
        let fi = max(0, min(fadeIn, D))
        let fo = max(0, min(obj.fadeOut, D - fi))
        obj.fadeIn  = fi
        obj.fadeOut = fo
    }

    func applyFadeOut(to obj: inout SoundObject, fadeOut: Double) {
        let D  = obj.duration
        let fo = max(0, min(fadeOut, D))
        let fi = max(0, min(obj.fadeIn, D - fo))
        obj.fadeIn  = fi
        obj.fadeOut = fo
    }

    func applyFadeCurve(to obj: inout SoundObject, fadeIn: FadeCurve?, fadeOut: FadeCurve?) {
        if let fadeIn  { obj.fadeInCurve  = fadeIn }
        if let fadeOut { obj.fadeOutCurve = fadeOut }
    }

    func updateFadeIn(id: UUID, fadeIn: Double) {
        update(id: id) { obj in applyFadeIn(to: &obj, fadeIn: fadeIn) }
        syncFade(id: id)
    }

    func updateFadeOut(id: UUID, fadeOut: Double) {
        update(id: id) { obj in applyFadeOut(to: &obj, fadeOut: fadeOut) }
        syncFade(id: id)
    }

    /// The SHAPE of one edge, or of both. A shape has no length of its own: setting it on an
    /// object with no fade changes nothing audible, and shows up the moment one is pulled.
    func updateFadeCurve(id: UUID, fadeIn: FadeCurve? = nil, fadeOut: FadeCurve? = nil) {
        guard fadeIn != nil || fadeOut != nil else { return }
        update(id: id) { obj in applyFadeCurve(to: &obj, fadeIn: fadeIn, fadeOut: fadeOut) }
        if let obj = find(id: id) { pushFadeCurveTree(obj) }
        isDirty = true
    }

    /// The fade-out an object keeps when matter is REMOVED off its end — a time selection deleted
    /// off the tail, the Cut tool's 'keep the left', a relink onto a shorter file.
    ///
    /// NOT the crop / trim by dragging, nor `object.resize` / `object.trim`, which go through
    /// `updateDuration` / `updateTrim`: there the hand is on the edge HANDLE and a fade keeps its
    /// SIZE, travelling with the edge it is anchored to. The two gestures are told apart by what
    /// the hand is doing, not by the fact that the object got shorter — that is the one distinction
    /// this helper and its mirror exist to serve.
    ///
    /// THE RULE, for removal: the fade's START stays where it is and the fade ends earlier. A
    /// fade-out is laid on the sound one can see — it starts at a point IN the matter — so deleting
    /// half a second of that matter must not carry the point half a second back over material
    /// nobody touched, and must not clear the fade either. What was a fade down to silence stays
    /// one: it simply has less room, and reaches silence at the new end.
    ///
    /// A removal PAST the fade's own start leaves nothing to fade (the result goes negative, hence
    /// the floor at 0): the whole of the curve was inside the piece that went.
    ///
    /// Only for matter going: an end that moves OUTWARDS gets its fade back untouched.
    static func fadeOutAnchoredAtStart(oldDuration: Double, oldFadeOut: Double,
                                       newDuration: Double) -> Double {
        guard newDuration < oldDuration else { return oldFadeOut }
        return max(0, newDuration - (oldDuration - oldFadeOut))
    }

    /// The fade-IN an object keeps when matter is REMOVED off its head — a time selection deleted
    /// there. The exact mirror of `fadeOutAnchoredAtStart`, and bounded by the same distinction:
    /// NOT the left trim by dragging, nor `object.trim`, where the hand is on the edge handle and
    /// the fade-in keeps its SIZE against the new start (@see `updateTrim`).
    ///
    /// THE RULE, for removal: the fade's END — the instant the sound reaches its full level, a
    /// point IN the matter — stays where it is, so the fade starts later and is SHORTENED by
    /// exactly what was taken. Clearing it, which is what this path did, made the passage start
    /// dead on; keeping it whole would carry the level's arrival point forward over material
    /// nobody touched. Its SHAPE is untouched: `fadeInCurve` is a separate field, and a shorter
    /// fade is the same curve read over less room.
    ///
    /// A removal PAST the end of the curve leaves nothing to fade (the result goes negative, hence
    /// the floor at 0): the whole of it was inside the piece that went.
    ///
    /// Only for matter going: a start that moves back OUTWARDS gets its fade back untouched.
    static func fadeInAnchoredAtEnd(oldStart: Double, oldFadeIn: Double,
                                    newStart: Double) -> Double {
        guard newStart > oldStart else { return oldFadeIn }
        return max(0, oldFadeIn - (newStart - oldStart))
    }

    /// The fade an edge the CUT has just OPENED is born with: none at all, SHAPE included.
    ///
    /// The third gesture, beside the two above. A crop moves an edge and the fade travels with it;
    /// matter removed shortens the fade against the material left; and DIVIDING matter — the
    /// scissors, the Cut tool, a hole pierced by a time selection or by an object dropped over
    /// another — makes an edge that did not exist a moment ago. That edge inherits nothing: each
    /// half keeps the edge it already had, fade and shape, and the two faces of the cut start bare.
    ///
    /// The LENGTH has always been zeroed at these sites. The SHAPE had not, and a shape left on a
    /// fade of no length does not show: it lies in wait, and comes out bent the first time that
    /// edge is pulled — a fade nobody drew curved. It is the very reasoning of the double click
    /// that clears a fade, which clears its shape with its length (@see CLAUDE.md, "Shaped fades");
    /// with the bend anchored on what is already there, nothing else in the gesture would bring
    /// that edge back to the straight line.
    ///
    /// NOT for the edges the cut did not touch: the left half's fade-in and the right half's
    /// fade-out are the ORIGINAL edges and keep their curve as they keep their length — and no
    /// more for the fades merely SHORTENED by matter going (@see fadeOutAnchoredAtStart /
    /// fadeInAnchoredAtEnd), where the edge is the old one with less room.
    static let freshCutCurve: FadeCurve = .linear

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
        previewFades([FadePreviewItem(id: id, fadeIn: fadeIn, fadeOut: fadeOut, curve: curve)])
    }

    /// What a fade gesture makes of ONE object on one frame: the length of the side it holds and the
    /// shape it is giving it.
    struct FadePreviewItem {
        let id: UUID
        var fadeIn: Double? = nil
        var fadeOut: Double? = nil
        var curve: FadeCurve? = nil
    }

    /// The picture's side of one frame of a fade drag — ONE index for the whole frame, however many
    /// objects the hand holds. `previewFade` used to hand the preview window an index per object, each
    /// started again from the model's, so with several pictures selected the last one erased the others
    /// and only one followed the hand. Here every fade of the frame lands in the same index, and the
    /// objects whose fade has spilled onto a neighbour (a crossfade being made: @see
    /// `crossfadeSpillCopies`) are replaced by their copies — window, fades and curves of the zone the
    /// release will lay down — instead of the plain fade, which is bounded by the window they still have.
    func videoFadeFrameIndex(_ items: [FadePreviewItem], spilling copies: [SoundObject] = []) -> VideoObjectIndex {
        var index = videoObjectIndex
        if !copies.isEmpty { index = index.previewing(replacing: copies) }
        let replaced = Set(copies.map(\.id))
        var patches: [UUID: VideoFadePatch] = [:]
        for item in items where !replaced.contains(item.id) {
            patches[item.id] = VideoFadePatch(fadeIn: item.fadeIn, fadeOut: item.fadeOut,
                                              fadeInCurve: item.fadeIn != nil ? item.curve : nil,
                                              fadeOutCurve: item.fadeOut != nil ? item.curve : nil)
        }
        return index.previewing(fades: patches)
    }

    /// One frame of a fade drag, every object it holds: the picture first (one index, one sending), then
    /// the engine, object by object.
    func previewFades(_ items: [FadePreviewItem], spilling copies: [SoundObject] = []) {
        // The picture follows the hand like the sound does (plan-video, fades): the preview window is
        // handed the index as it would be with these fades, the model still untouched. Where no window is
        // open nobody listens, and the engine below is the whole of it.
        if let sink = videoFadePreviewSink {
            sink(videoFadeFrameIndex(items, spilling: copies))
        }
        guard let engine else { return }
        for item in items {
            guard let obj = find(id: item.id) else { continue }
            let D  = max(0, obj.duration)
            let fi = min(item.fadeIn  ?? obj.fadeIn,  D)
            let fo = min(item.fadeOut ?? obj.fadeOut, D)
            engine.previewFades(in: max(0, fi), out: max(0, fo), forID: item.id.uuidString)
            if let curve = item.curve {
                let inCurve  = item.fadeIn  != nil ? curve : obj.fadeInCurve
                let outCurve = item.fadeOut != nil ? curve : obj.fadeOutCurve
                engine.updateFadeCurves(in: inCurve.shape.engineCode,
                                        amountIn: Float(inCurve.amount),
                                        out: outCurve.shape.engineCode,
                                        amountOut: Float(outCurve.amount),
                                        forID: item.id.uuidString)
            }
        }
    }

    /// The fade gesture is over (committed or not): the picture goes back to what the MODEL says. A
    /// commit that writes nothing (a fade dragged back to where it was) would otherwise leave the
    /// preview index of the last frame on the screen.
    func endFadePreview() {
        guard videoFadePreviewSink != nil else { return }
        videoAudibilityRevision &+= 1
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
