import Foundation

// MARK: - The doors of a group that carries an instrument (docs/plan_groupes_midi.md, E5)
//
// `GroupInstrumentRule` is the ONE place the rule is written; this file is the ONE place the gestures ask it.
// A door asks BEFORE it touches anything (before `pushUndo`, where the door pushes one itself), and a refusal is
// all-or-nothing: a gesture that carries several objects is refused whole, never trimmed.
//
// A refusal does three things: it tells the user (`notify`, journalled in headless), it is recorded in
// `groupInstrumentRefusal` (the command bus reads it back and answers `invalid_state` with `details.reason`), and
// the door returns without having changed the model. `edit { }` and the bus then take back the undo point they had
// pushed for a gesture that turned out to do nothing.

extension EditViewModel {

    /// `[target, parent, grandparent…]` for the group `id`; empty for nil (the root: no rule applies there).
    func instrumentChain(ofGroup id: UUID?) -> [SoundObject] {
        guard let id, let target = find(id: id) else { return [] }
        return [target] + ancestorChain(of: id)
    }

    /// Records and announces a refusal. Returns true if there was one.
    @discardableResult
    func refuseGroupInstrument(_ refusal: GroupInstrumentRefusal?) -> Bool {
        guard let refusal else { return false }
        groupInstrumentRefusal = refusal
        let reason: String
        switch refusal {
        case .audioChild:             reason = L("groupInstrument.refused.audioChild")
        case .auxChild:               reason = L("groupInstrument.refused.auxChild")
        case .childWithInstrument:    reason = L("groupInstrument.refused.childWithInstrument")
        case .consolidatedChild:      reason = L("groupInstrument.refused.consolidatedChild")
        case .audioInput:             reason = L("groupInstrument.refused.audioInput")
        case .insideInstrumentGroup:  reason = L("groupInstrument.refused.insideInstrumentGroup")
        }
        notify(L("groupInstrument.refused.title"), reason)
        return true
    }

    /// Would adding `objects` to the group `groupID` (nil = the root) break the rule? Refuses (and says so) if it would.
    func refusesAdding(_ objects: [SoundObject], toGroup groupID: UUID?) -> Bool {
        guard let groupID else { return false }
        let target = sessionDropTarget(groupID)
        return refuseGroupInstrument(GroupInstrumentRule.refusal(adding: objects, toChain: instrumentChain(ofGroup: target)))
    }

    /// The same, for objects already in the model, named by id.
    func refusesAdding(ids: Set<UUID>, toGroup groupID: UUID?) -> Bool {
        guard groupID != nil else { return false }
        return refusesAdding(ids.compactMap { find(id: $0) }, toGroup: groupID)
    }

    /// The same, for a batch whose objects each have their own target group (nil = the root): refused whole.
    func refusesAdding(targets: [(object: SoundObject, groupID: UUID?)]) -> Bool {
        var byGroup: [UUID: [SoundObject]] = [:]
        for t in targets { if let g = t.groupID { byGroup[g, default: []].append(t.object) } }
        for (gid, objects) in byGroup where refusesAdding(objects, toGroup: gid) { return true }
        return false
    }

    /// Would putting an instrument on `objectID` (a group, or a MIDI clip) break the rule?
    func refusesInstrument(on objectID: UUID) -> Bool {
        guard let object = find(id: objectID) else { return false }
        let ancestors = ancestorChain(of: objectID)
        if object.isGroup {
            return refuseGroupInstrument(GroupInstrumentRule.refusal(puttingInstrumentOn: object, ancestors: ancestors))
        }
        // A MIDI clip below an instrument group would be a second instrument on the same chain.
        if object.isMIDI, ancestors.contains(where: { $0.isGroup && !$0.instruments.isEmpty }) {
            return refuseGroupInstrument(.childWithInstrument)
        }
        return false
    }

    /// Would an AUDIO recording source on the zone `groupID` break the rule?
    func refusesAudioInput(on groupID: UUID) -> Bool {
        guard let group = find(id: groupID) else { return false }
        return refuseGroupInstrument(GroupInstrumentRule.refusal(settingAudioInputOn: group, ancestors: ancestorChain(of: groupID)))
    }

    /// The group (id) the display-lane placement of `clip` resolves to, by the rule of `placeClip`: the innermost open
    /// group whose child range holds `clip.lane`, nil for the root.
    func placementGroupID(forDisplayLane lane: Int, snapshot: [LaneEntry], excludingGroups: Set<UUID> = []) -> UUID? {
        snapshot
            .filter { e in
                guard e.item.showsChildrenInline, !excludingGroups.contains(e.item.id) else { return false }
                return lane >= e.displayLane + 1 && lane <= e.displayLane + e.item.childLaneCount
            }
            .max(by: { $0.displayLane < $1.displayLane })?
            .item.id
    }

    /// Would laying `clips` (display lanes) down through `placeClip` break the rule? Each is asked at the group it lands in.
    func refusesPlacing(_ clips: [SoundObject], snapshot: [LaneEntry], excludingGroups: Set<UUID> = []) -> Bool {
        var byGroup: [UUID: [SoundObject]] = [:]
        for clip in clips {
            if let gid = placementGroupID(forDisplayLane: clip.lane, snapshot: snapshot, excludingGroups: excludingGroups) {
                byGroup[gid, default: []].append(clip)
            }
        }
        for (gid, objects) in byGroup where refusesAdding(objects, toGroup: gid) { return true }
        return false
    }

    /// The object a refused gesture left pending, read and cleared by the command bus.
    func takeGroupInstrumentRefusal() -> GroupInstrumentRefusal? {
        defer { groupInstrumentRefusal = nil }
        return groupInstrumentRefusal
    }
}
