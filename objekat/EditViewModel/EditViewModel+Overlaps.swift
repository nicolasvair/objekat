import Foundation

extension EditViewModel {

    // MARK: - Overwrite (resolving overlaps)

    /// The operation to apply to an overlapped group (the same rules as clips).
    private enum GroupOverlapOp {
        case delete(UUID)
        case trimStart(UUID, to: Double, end: Double)        // keep [to, end]
        case trimEnd(UUID, to: Double, start: Double)        // keep [start, to]
        case hole(UUID, ns: Double, ne: Double, start: Double, end: Double)
    }

    /// Resolves the overlaps for an item (clip or group), top-level or a child of
    /// a group at any depth.
    func resolveOverlaps(for id: UUID) {
        if let new = items.first(where: { $0.id == id }) {
            _resolveTopLevel(new: new)
            return
        }
        guard let child = find(id: id),
              let parent = parentGroup(for: id),
              case .group(let children, _) = parent.kind
        else { return }
        _resolveChild(id: id, child: child, children: children, parent: parent)
    }

    /// Classifies the overlap of an existing group [es, ee] by a new item [ns, ne].
    private func _groupOp(id: UUID, es: Double, ee: Double,
                          ns: Double, ne: Double, minDur: Double) -> GroupOverlapOp {
        if ns <= es && ne >= ee { return .delete(id) }
        if ns <= es {
            return (ee - ne < minDur) ? .delete(id) : .trimStart(id, to: ne, end: ee)
        }
        if ne >= ee {
            return (ns - es < minDur) ? .delete(id) : .trimEnd(id, to: ns, start: es)
        }
        let lDur = ns - es
        let rDur = ee - ne
        if lDur >= minDur && rDur >= minDur { return .hole(id, ns: ns, ne: ne, start: es, end: ee) }
        if lDur >= minDur { return .trimEnd(id, to: ns, start: es) }
        if rDur >= minDur { return .trimStart(id, to: ne, end: ee) }
        return .delete(id)
    }

    /// Applies a group op: removal, truncation (bounds + cutting the children)
    /// or a hole (split in two, then truncating the left part).
    private func _applyGroupOp(_ op: GroupOverlapOp) {
        switch op {
        case .delete(let gid):
            remove(id: gid)

        case .trimStart(let gid, let to, let end):
            guard let g = find(id: gid) else { return }
            _cutGroupChildren(groupID: gid, cutLo: g.startTime, cutHi: to)
            update(id: gid) { obj in
                obj.startTime = to
                obj.duration  = end - to
                obj.fadeIn    = min(obj.fadeIn, obj.duration)
            }
            if let obj = find(id: gid) { syncPosition(obj) }

        case .trimEnd(let gid, let to, _):
            guard let g = find(id: gid) else { return }
            _cutGroupChildren(groupID: gid, cutLo: to, cutHi: g.startTime + g.duration)
            update(id: gid) { obj in
                obj.duration = to - obj.startTime
                obj.fadeOut  = min(obj.fadeOut, obj.duration)
            }
            if let obj = find(id: gid) { syncPosition(obj) }

        case .hole(let gid, let ns, let ne, let start, _):
            // Split at ne → the right part [ne, end] left intact, then truncate the
            // left part (its id kept) to [start, ns].
            guard _splitInternal(id: gid, atTime: ne) != nil else {
                // A safety net (split refused: degenerate bounds…): truncate at the hole's left
                // edge rather than leave the overlap unresolved.
                _applyGroupOp(.trimEnd(gid, to: ns, start: start))
                return
            }
            _cutGroupChildren(groupID: gid, cutLo: ns, cutHi: ne)
            update(id: gid) { obj in
                obj.duration = ns - start
                obj.fadeOut  = 0
            }
            if let obj = find(id: gid) { syncPosition(obj) }
        }
        isDirty = true
    }

    // ── A top-level item (clip or group) ─────────────────────────────────────────

    /// The source offset of a piece that survived an overlap: its window is a trim of `ex`'s,
    /// hence the same reverse mirroring as a trim or a cut
    /// (@see WaveformShaping.retrimmedSourceOffset).
    private func overlapOffset(_ ex: SoundObject, newStart: Double, newDuration: Double) -> Double {
        WaveformShaping.retrimmedSourceOffset(ex.sourceOffset,
                                              oldStart: ex.startTime, oldDuration: ex.duration,
                                              newStart: newStart, newDuration: newDuration,
                                              speedRatio: ex.speedRatio, isReversed: ex.isReversed)
    }

    private func _resolveTopLevel(new: SoundObject) {
        let ns = new.startTime
        let ne = ns + new.duration
        let minDur = 0.05

        struct Trim { let id: UUID; let startTime: Double; let sourceOffset: Double; let duration: Double }
        var toDelete: [UUID]           = []
        var toTrim:   [Trim]           = []
        var toAdd:    [SoundObject]    = []
        var groupOps: [GroupOverlapOp] = []

        for ex in items where ex.id != new.id && ex.lane == new.lane {
            let es = ex.startTime
            let ee = es + ex.duration
            guard ne > es && ns < ee else { continue }

            guard case .clip(let exFP, _, let exFD, let exSR, let exRev) = ex.kind else {
                // An overlapped group: the same rules as clips.
                groupOps.append(_groupOp(id: ex.id, es: es, ee: ee, ns: ns, ne: ne, minDur: minDur))
                continue
            }

            if ns <= es && ne >= ee {
                toDelete.append(ex.id)

            } else if ns <= es {
                let d = ee - ne
                if d < minDur { toDelete.append(ex.id) }
                else { toTrim.append(Trim(id: ex.id, startTime: ne, sourceOffset: overlapOffset(ex, newStart: ne, newDuration: d), duration: d)) }

            } else if ne >= ee {
                let d = ns - es
                if d < minDur { toDelete.append(ex.id) }
                else { toTrim.append(Trim(id: ex.id, startTime: es, sourceOffset: overlapOffset(ex, newStart: es, newDuration: d), duration: d)) }

            } else {
                let lDur = ns - es
                let rDur = ee - ne
                if lDur >= minDur {
                    toTrim.append(Trim(id: ex.id, startTime: es, sourceOffset: overlapOffset(ex, newStart: es, newDuration: lDur), duration: lDur))
                } else {
                    toDelete.append(ex.id)
                }
                if rDur >= minDur {
                    // derivedCopy + copiedPlugins: the right-hand piece inherits the sends/chain
                    // gains/sound-object link, and its plugins are CLONED (reusing ex.plugins
                    // duplicated the UUIDs across two objects → a collision in the engine's
                    // _pluginMap, and no link).
                    toAdd.append(ex.derivedCopy(
                        startTime: ne, duration: rDur, lane: ex.lane,
                        fadeIn: 0, fadeOut: ex.fadeOut,
                        plugins: copiedPlugins(of: ex),
                        // The RIGHT-hand piece: its start is `ne`, the curves rebase on it.
                        automation: ex.automation.shiftedInTime(by: -(ne - es)),
                        kind: .clip(filePath: exFP, sourceOffset: overlapOffset(ex, newStart: ne, newDuration: rDur),
                                    fileDuration: exFD, speedRatio: exSR, isReversed: exRev)
                    ))
                }
            }
        }

        if !toDelete.isEmpty || !toTrim.isEmpty {
            NSLog("🔴 [overlaps] top-level new=%@ L%d @%.2f→%.2f : supprime %d, rogne %d",
                  new.displayName, new.lane, ns, ne, toDelete.count, toTrim.count)
        }
        for uid in toDelete {
            items.removeAll { $0.id == uid }
            engine?.removeSoundObject(withID: uid.uuidString)
            selectedIDs.remove(uid)
        }
        for t in toTrim {
            guard let i = items.firstIndex(where: { $0.id == t.id }) else { continue }
            // The LEFT edge may have moved back: the curves realign on the matter, which has not
            // moved (the same rule as `updateTrim`). A trim on the right → a null delta, a no-op.
            let delta = t.startTime - items[i].startTime
            items[i].automation   = items[i].automation.shiftedInTime(by: -delta)
            items[i].startTime    = t.startTime
            items[i].sourceOffset = t.sourceOffset
            items[i].duration     = t.duration
            syncPosition(items[i])
        }
        for obj in toAdd {
            items.append(obj)
            syncAdd(obj)
        }
        for op in groupOps { _applyGroupOp(op) }
        isDirty = true
    }

    // ── A child (clip or sub-group) inside a group, at any depth ─────────────────

    private func _resolveChild(id: UUID, child: SoundObject,
                               children: [SoundObject], parent: SoundObject) {
        let ns = child.startTime
        let ne = ns + child.duration
        let minDur = 0.05

        struct Trim { let old: SoundObject; let startTime: Double; let sourceOffset: Double; let duration: Double }
        var toDelete: [UUID]           = []
        var toTrim:   [Trim]           = []
        var toAdd:    [SoundObject]    = []
        var groupOps: [GroupOverlapOp] = []

        for ex in children where ex.id != id && ex.lane == child.lane {
            let es = ex.startTime
            let ee = es + ex.duration
            guard ne > es && ns < ee else { continue }

            guard case .clip(let exFP, _, let exFD, let exSR, let exRev) = ex.kind else {
                // An overlapped sibling sub-group: the same rules as clips.
                groupOps.append(_groupOp(id: ex.id, es: es, ee: ee, ns: ns, ne: ne, minDur: minDur))
                continue
            }

            if ns <= es && ne >= ee {
                toDelete.append(ex.id)

            } else if ns <= es {
                let d = ee - ne
                if d < minDur { toDelete.append(ex.id) }
                else { toTrim.append(Trim(old: ex, startTime: ne, sourceOffset: overlapOffset(ex, newStart: ne, newDuration: d), duration: d)) }

            } else if ne >= ee {
                let d = ns - es
                if d < minDur { toDelete.append(ex.id) }
                else { toTrim.append(Trim(old: ex, startTime: es, sourceOffset: overlapOffset(ex, newStart: es, newDuration: d), duration: d)) }

            } else {
                let lDur = ns - es
                let rDur = ee - ne
                if lDur >= minDur {
                    toTrim.append(Trim(old: ex, startTime: es, sourceOffset: overlapOffset(ex, newStart: es, newDuration: lDur), duration: lDur))
                } else {
                    toDelete.append(ex.id)
                }
                if rDur >= minDur {
                    // derivedCopy + copiedPlugins: the same reasons as _resolveTopLevel
                    // (inheriting the attributes + cloning the plugins, no shared UUIDs).
                    toAdd.append(ex.derivedCopy(
                        startTime: ne, duration: rDur, lane: ex.lane,
                        fadeIn: 0, fadeOut: ex.fadeOut,
                        plugins: copiedPlugins(of: ex),
                        // The RIGHT-hand piece: its start is `ne`, the curves rebase on it.
                        automation: ex.automation.shiftedInTime(by: -(ne - es)),
                        kind: .clip(filePath: exFP, sourceOffset: overlapOffset(ex, newStart: ne, newDuration: rDur),
                                    fileDuration: exFD, speedRatio: exSR, isReversed: exRev)
                    ))
                }
            }
        }

        // Engine: removals, repositionings and additions of the sibling clips. Folder model:
        // a child = its own track at an ABSOLUTE position → a trim = updatePosition (no
        // remove/re-add, so the plugin instances survive).
        let deleteSet = Set(toDelete)
        for uid in toDelete {
            engine?.removeSoundObject(withID: uid.uuidString)
            selectedIDs.remove(uid)
        }
        for t in toTrim {
            let loopBounds = clipLoopFileBounds(t.old)
            engine?.updatePosition(t.startTime, duration: t.duration,
                                   sourceOffset: t.sourceOffset, loopEnabled: t.old.loopEnabled,
                                   loopRangeStart: loopBounds.start, loopRangeEnd: loopBounds.end,
                                   forID: t.old.id.uuidString)
            engine?.updateFade(in: t.old.fadeIn, fadeOut: t.old.fadeOut, forID: t.old.id.uuidString)
            // A trim without going through `syncPosition`: the trimmed sibling's curves, for their part,
            // are in relative time. They follow its new start on the ENGINE side, and realign on the
            // matter on the model side if it is the LEFT edge that moved (see `updateTrim`).
            var trimmed = t.old
            trimmed.automation = t.old.automation.shiftedInTime(by: -(t.startTime - t.old.startTime))
            trimmed.startTime  = t.startTime
            pushAutomation(trimmed)
        }
        for obj in toAdd {
            engineAddClip(obj)
            engine?.assignObject(obj.id.uuidString, toGroupFolder: parent.id.uuidString)
            syncSends(obj)
            pushAutomation(obj)   // carriers in place → the right-hand piece's curves
        }

        // Model: a single pass over the parent's CURRENT children (not the snapshot)
        update(id: parent.id) { obj in
            guard case .group(var current, let isExpanded) = obj.kind else { return }
            current.removeAll { deleteSet.contains($0.id) }
            for t in toTrim {
                guard let i = current.firstIndex(where: { $0.id == t.old.id }) else { continue }
                current[i].automation   = current[i].automation
                    .shiftedInTime(by: -(t.startTime - current[i].startTime))
                current[i].startTime    = t.startTime
                current[i].sourceOffset = t.sourceOffset
                current[i].duration     = t.duration
            }
            current.append(contentsOf: toAdd)
            obj.kind = .group(children: current, isExpanded: isExpanded)
        }

        // Sibling sub-groups: removal / truncation / hole (they handle model + engine)
        for op in groupOps { _applyGroupOp(op) }
        isDirty = true
    }
}
