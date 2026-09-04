import Foundation

// MARK: - Slip: sliding the content INSIDE a clip's window
//
// The window (startTime / duration) does not move: only the source offset changes, so "what is
// heard at that point of the timeline" moves forwards or backwards in the file. Gesture: ⌥ + drag
// on the UPPER BAND — a time selection laid down, or simply the top half of a block: no prior
// selection is required (see TimelineView+DragHandler). Offset convention:
// `sourceOffset` is in SOURCE SECONDS, invariant of speed — a timeline delta converts to
// ×speed (see the design note on the varispeed offset).

extension EditViewModel {

    /// Repositions a clip's content within its window. The offset is bounded by the file:
    /// [0, file duration − duration played in source seconds].
    func setSourceOffset(id: UUID, to offset: Double) {
        update(id: id) { obj in
            guard case .clip(let fp, _, let fd, let sr, let rev) = obj.kind else { return }
            let maxOffset = max(0, fd - obj.duration * sr)
            obj.kind = .clip(filePath: fp,
                             sourceOffset: min(max(0, offset), maxOffset),
                             fileDuration: fd, speedRatio: sr, isReversed: rev)
        }
        if let obj = find(id: id) { syncPosition(obj) }
        isDirty = true
    }

    /// Clips (leaves with a file) touched by a time selection, at any depth of nesting.
    /// Groups, auxes and MIDI clips have no source offset: they do not "slip" themselves —
    /// a FOLDED group, on the other hand, hands over its content (below).
    func slippableClips(inLanes lanes: Set<Int>, from t1: Double, to t2: Double) -> [SoundObject] {
        var out: [SoundObject] = []
        for e in laneEntries where lanes.contains(e.displayLane) {
            let item = e.item
            guard e.absStart < t2, e.absStart + item.duration > t1 else { continue }
            if item.isClip, item.fileDuration > 0 { out.append(item); continue }
            // A FOLDED group: its children have no display lane of their own, its own row is what
            // stands for them — covering the group is covering its content. Without this descent,
            // a selection laid over closed groups (the common case) found nothing to slip and the
            // gesture fell back silently on drawing a selection.
            // An UNFOLDED group, on the other hand, shows its children on their own lanes: they are
            // already in `laneEntries` and only come in if the selection reaches down to them — what
            // is taken is then what is seen, no more and no less.
            if item.isGroup, !item.showsChildrenInline {
                appendSlippable(in: item, from: t1, to: t2, into: &out)
            }
        }
        return out
    }

    /// The slippable clips of ONE grabbed object: itself if it carries a file, otherwise the whole
    /// content of a group (at any depth, folded or not — it is the whole block that is being
    /// grabbed). Used by a slip taken directly on an object, with no prior time selection.
    /// An aux or a MIDI clip has no source offset: nothing to slip.
    func slippableClips(in object: SoundObject) -> [SoundObject] {
        if object.isClip, object.fileDuration > 0 { return [object] }
        guard object.isGroup else { return [] }
        var out: [SoundObject] = []
        appendSlippable(in: object, from: -.infinity, to: .infinity, into: &out)
        return out
    }

    /// Descends into an unfolded group: its clips (and those of its sub-groups) whose window
    /// crosses [t1, t2]. Children's startTimes are ABSOLUTE, as everywhere.
    private func appendSlippable(in group: SoundObject, from t1: Double, to t2: Double,
                                 into out: inout [SoundObject]) {
        guard case .group(let children, _) = group.kind else { return }
        for c in children {
            guard c.startTime < t2, c.startTime + c.duration > t1 else { continue }
            if c.isClip, c.fileDuration > 0 { out.append(c) }
            else if c.isGroup { appendSlippable(in: c, from: t1, to: t2, into: &out) }
        }
    }
}
