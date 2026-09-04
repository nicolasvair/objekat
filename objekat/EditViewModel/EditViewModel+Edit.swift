import Foundation

extension EditViewModel {

    // MARK: - CRUD

    func add(_ object: SoundObject) {
        items.append(object)
        syncAdd(object)
        isDirty = true
    }

    func remove(id: UUID) {
        guard let obj = find(id: id) else { return }
        removeFromEngine(obj)   // recursive: clip = track, group = descendants + folder
        // A child of a group (at any depth): removed through its DIRECT parent.
        if let parent = parentGroup(for: id) {
            update(id: parent.id) { p in
                guard case .group(let children, let isExpanded) = p.kind else { return }
                p.kind = .group(children: children.filter { $0.id != id }, isExpanded: isExpanded)
            }
        } else {
            removeFromItems(id: id)
        }
        selectedIDs.remove(id)
        isDirty = true
    }

    func removeSelected() {
        var childrenByGroup: [UUID: [UUID]] = [:]
        var topLevel: [UUID] = []
        for id in effectiveSelectedIDs {
            if let group = parentGroup(for: id) {
                childrenByGroup[group.id, default: []].append(id)
            } else {
                topLevel.append(id)
            }
        }
        for (groupID, childIDs) in childrenByGroup {
            for childID in childIDs {
                if let obj = find(id: childID) { removeFromEngine(obj) }
            }
            update(id: groupID) { obj in
                if case .group(let children, let isExpanded) = obj.kind {
                    obj.kind = .group(children: children.filter { !childIDs.contains($0.id) },
                                      isExpanded: isExpanded)
                }
            }
        }
        for id in topLevel {
            if let obj = find(id: id) { removeFromEngine(obj) }
            removeFromItems(id: id)
        }
        selectedIDs = []
        isDirty = true
    }

    /// Detaches the object from the engine. Folder model: a clip = its track (removeSoundObject),
    /// a group = its descendants (recursive, bottom-up) then its FolderTrack. Independent of
    /// nesting (no more nested/top-level distinction).
    func removeFromEngine(_ obj: SoundObject) {
        switch obj.kind {
        case .clip, .midiClip:
            engine?.removeSoundObject(withID: obj.id.uuidString)
        case .aux:
            engine?.removeAux(obj.id.uuidString)
        case .group(let children, _):
            for child in children { removeFromEngine(child) }
            engine?.removeGroupFolder(obj.id.uuidString)
        }
    }

    // MARK: - Position / Geometry

    /// Recursively shifts the startTime of a list of objects (sub-groups included).
    static func shiftStartTimes(_ items: inout [SoundObject], by delta: Double) {
        for i in items.indices {
            items[i].startTime += delta
            if case .group(var ch, let e) = items[i].kind {
                shiftStartTimes(&ch, by: delta)
                items[i].kind = .group(children: ch, isExpanded: e)
            }
        }
    }

    func updateStartTime(id: UUID, newStart: Double) {
        let snapped = max(0, snapTime(newStart))
        guard let obj = find(id: id) else { return }
        let delta = snapped - obj.startTime
        update(id: id) { item in
            item.startTime = snapped
            if case .group(var children, let isExpanded) = item.kind, delta != 0 {
                EditViewModel.shiftStartTimes(&children, by: delta)
                item.kind = .group(children: children, isExpanded: isExpanded)
            }
        }
        if let updated = find(id: id) { syncPosition(updated) }
    }

    func updateLane(id: UUID, lane: Int) {
        update(id: id) { $0.lane = max(0, lane) }
    }

    func updateDuration(id: UUID, duration: Double) {
        update(id: id) { obj in
            let D = max(0.01, duration)
            var fi = obj.fadeIn
            var fo = obj.fadeOut
            if D < fi { fi = D; fo = 0 }
            else if D < fi + fo { fo = D - fi }
            // The RIGHT edge moves: played forwards the source range does not move, but in reverse
            // it is that edge which commands it (@see WaveformShaping.retrimmedSourceOffset).
            if case .clip(let fp, let so, let fd, let sr, let rev) = obj.kind, rev {
                obj.kind = .clip(filePath: fp,
                                 sourceOffset: WaveformShaping.retrimmedSourceOffset(
                                    so, oldStart: obj.startTime, oldDuration: obj.duration,
                                    newStart: obj.startTime, newDuration: D,
                                    speedRatio: sr, isReversed: rev),
                                 fileDuration: fd, speedRatio: sr, isReversed: rev)
            }
            obj.duration = D
            obj.fadeIn   = fi
            obj.fadeOut  = fo
        }
        if let obj = find(id: id) {
            syncPosition(obj)
            if obj.isClip || obj.isMIDI {   // the same ObjWindowFade chain on the engine side
                engine?.updateFade(in: obj.fadeIn, fadeOut: obj.fadeOut, forID: id.uuidString)
            }
        }
        isDirty = true
    }

    func updateTrim(id: UUID, newStart: Double, newDuration: Double) {
        update(id: id) { obj in
            let delta = newStart - obj.startTime
            let oldStart = obj.startTime
            let oldDuration = obj.duration
            let D = max(0.01, newDuration)
            var fi = obj.fadeIn
            var fo = obj.fadeOut
            if D < fo { fo = D; fi = 0 }
            else if D < fi + fo { fi = D - fo }
            obj.startTime = newStart
            obj.duration  = D
            obj.fadeIn    = fi
            obj.fadeOut   = fo
            // The edge moves, the CONTENT does not — so the ORIGIN of the automation points'
            // frame of reference moves under them. The same rebasing as the MIDI notes just below, and
            // the same non-destructiveness: a point left behind the new edge keeps a NEGATIVE time
            // and comes back if the edge is reopened (@see AutomationLane.shifted). Without this, a
            // curve followed the edge instead of staying in front of the matter it modulates.
            obj.automation = obj.automation.shiftedInTime(by: -delta)
            if case .clip(let fp, let so, let fd, let sr, let rev) = obj.kind {
                // The left edge moves by `delta` on the timeline → the source advances by delta×speed.
                // In reverse it is the right edge that commands the source range: trimming the entry
                // does not touch the offset (@see WaveformShaping.retrimmedSourceOffset).
                obj.kind = .clip(filePath: fp,
                                 sourceOffset: WaveformShaping.retrimmedSourceOffset(
                                    so, oldStart: oldStart, oldDuration: oldDuration,
                                    newStart: newStart, newDuration: D,
                                    speedRatio: sr, isReversed: rev),
                                 fileDuration: fd, speedRatio: sr, isReversed: rev)
            }
            if case .midiClip(let notes, let lengthBeats) = obj.kind {
                // The same gesture as for an audio clip, in beats: the edge moves, the CONTENT does
                // not. The notes keep their absolute place, so their position relative to the start
                // of the clip recedes by `delta`. Without this they followed the edge — the trim
                // shifted the clip instead of revealing / hiding its inside.
                //
                // Notes left behind the new edge are KEPT (a negative startBeat), exactly like the
                // matter outside the bounds of an audio clip: the clip masks them, pulling the edge
                // back to the left gives them again. A non-destructive trim.
                let dBeats = beatsFromSeconds(delta)
                obj.kind = .midiClip(notes: notes.map { n in
                                        var m = n
                                        m.startBeat -= dBeats
                                        return m
                                     },
                                     lengthBeats: max(0.01, lengthBeats - dBeats))
            }
        }
        if let obj = find(id: id) {
            syncPosition(obj)
            if obj.isClip || obj.isMIDI {   // the same ObjWindowFade chain on the engine side
                engine?.updateFade(in: obj.fadeIn, fadeOut: obj.fadeOut, forID: id.uuidString)
            }
            // The notes have been rebased on the new edge: the engine's MidiList follows.
            if obj.isMIDI { syncMidiNotes(obj) }
        }
        isDirty = true
    }

    // MARK: - Internal helper

    func removeFromItems(id: UUID) {
        items.removeAll { $0.id == id }
    }
}
