import Foundation

extension EditViewModel {

    // MARK: - The left edge of a LOOPING clip

    /// What a looping audio clip becomes when its window's LEFT edge goes to `newStart`: the pattern
    /// stays anchored in the file and on the timeline, only the window moves over it
    /// (@see LoopRetrim for the arithmetic and the reasoning).
    ///
    /// `nil` when the ordinary rule applies — the object is not a looping, forwards-played clip, the
    /// edge does not move, or the loop has no period — so a caller reads:
    ///
    ///     if let w = loopAnchoredRetrim(obj, newStart: s) { adopt it } else { retrimmedSourceOffset }
    ///
    /// (a reversed clip never loops, @see SoundObject.canLoop). Reads the object AS IT IS: call it
    /// before the start changes.
    func loopAnchoredRetrim(_ obj: SoundObject, newStart: Double) -> LoopRetrim.Window? {
        guard case .clip(_, let so, _, let sr, let rev) = obj.kind, !rev,
              obj.loopEnabled, obj.loopRangeStart != nil,
              abs(newStart - obj.startTime) > 1e-12 else { return nil }
        let bounds = clipLoopFileBounds(obj)
        return LoopRetrim.anchored(startTime: obj.startTime, sourceOffset: so, speedRatio: sr,
                                   fileLoopIn: bounds.start, fileLoopOut: bounds.end,
                                   newStart: newStart)
    }

    /// Writes a window computed by `loopAnchoredRetrim` into `obj` (offset + IN/OUT bounds).
    func adopt(_ window: LoopRetrim.Window, in obj: inout SoundObject) {
        obj.sourceOffset  = window.sourceOffset
        obj.loopRangeStart = window.loopStart
        obj.loopRangeEnd   = window.loopEnd
    }

    /// The model-side result of putting the LEFT edge of `obj` at `newStart` — for the paths that
    /// cut a clip into pieces (a cut, an overwrite, a carve): a looping clip's piece is the same
    /// pattern seen through another window, any other clip keeps the ordinary trim rule
    /// (`retrimmedSourceOffset`, which `fallback` evaluates).
    func leftEdgeRetrim(of obj: SoundObject, to newStart: Double,
                        fallback: () -> Double)
        -> (sourceOffset: Double, loopStart: Double?, loopEnd: Double?) {
        if let w = loopAnchoredRetrim(obj, newStart: newStart) {
            return (w.sourceOffset, w.loopStart, w.loopEnd)
        }
        return (fallback(), obj.loopRangeStart, obj.loopRangeEnd)
    }

    /// Pushes a clip's position AND its loop to the engine without the rest of `syncPosition`
    /// (curves, lane): for the pieces of a clip a path has just cut, whose engine clip was created or
    /// reduced without the loop (@see OBJEngineCore splitSoundObjectWithID:) — nothing else would
    /// lay the loop range and its phase on them. A no-op for a clip that does not loop.
    func pushLoopWindow(_ obj: SoundObject) {
        guard obj.loopEnabled, case .clip(_, let so, _, _, _) = obj.kind else { return }
        let bounds = clipLoopFileBounds(obj)
        engine?.updatePosition(obj.startTime, duration: obj.duration,
                               sourceOffset: so, loopEnabled: true,
                               loopRangeStart: bounds.start, loopRangeEnd: bounds.end,
                               forID: obj.id.uuidString)
    }
}
