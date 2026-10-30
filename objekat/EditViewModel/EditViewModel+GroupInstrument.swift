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

    /// The words of a refusal (literal keys, so that `xcstrings.py orphans` sees them).
    static func refusalText(_ refusal: GroupInstrumentRefusal) -> String {
        switch refusal {
        case .audioChild:             return L("groupInstrument.refused.audioChild")
        case .auxChild:               return L("groupInstrument.refused.auxChild")
        case .childWithInstrument:    return L("groupInstrument.refused.childWithInstrument")
        case .consolidatedChild:      return L("groupInstrument.refused.consolidatedChild")
        case .audioInput:             return L("groupInstrument.refused.audioInput")
        case .insideInstrumentGroup:  return L("groupInstrument.refused.insideInstrumentGroup")
        }
    }

    /// Records and announces a refusal. Returns true if there was one.
    @discardableResult
    func refuseGroupInstrument(_ refusal: GroupInstrumentRefusal?) -> Bool {
        guard let refusal else { return false }
        groupInstrumentRefusal = refusal
        let reason = Self.refusalText(refusal)
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

    /// Is `id` an empty clip or a sub-group living under an instrument group? Consolidating it would bake the host's
    /// notes into a wave that then sits among the host's children: the wave violates the rule (E6). The menu hides the
    /// entry, the doors call `refusesConsolidating`.
    func isUnderInstrumentHost(_ id: UUID) -> Bool {
        guard let object = find(id: id), object.isGroup || GroupInstrumentRule.isEmptyClip(object) else { return false }
        return ancestorChain(of: id).contains { $0.isGroup && !$0.instruments.isEmpty }
    }

    func refusesConsolidating(_ id: UUID) -> Bool {
        isUnderInstrumentHost(id) && refuseGroupInstrument(.consolidatedChild)
    }

    /// The object a refused gesture left pending, read and cleared by the command bus.
    func takeGroupInstrumentRefusal() -> GroupInstrumentRefusal? {
        defer { groupInstrumentRefusal = nil }
        return groupInstrumentRefusal
    }

    // MARK: What the synoptic shows (E7)

    /// Why the instrument slot of the group `id` is closed, as a sentence — nil when an instrument can be put there
    /// (or when it already has one). Pure: nothing is announced, the slot only greys and says why in its tooltip.
    func instrumentSlotRefusalText(of id: UUID) -> String? {
        guard let object = find(id: id), object.isGroup, object.instruments.isEmpty else { return nil }
        return GroupInstrumentRule.refusal(puttingInstrumentOn: object, ancestors: ancestorChain(of: id))
            .map { Self.refusalText($0) }
    }

    /// The name of the group that plays the notes of the empty clip `object` (nil = nobody: it is muted).
    func hostName(ofEmptyClip object: SoundObject) -> String? {
        GroupInstrumentRule.host(of: object, ancestors: ancestorChain(of: object.id))
            .flatMap { find(id: $0)?.displayName }
    }

    // MARK: Passive chains (plan 2.5)
    //
    // The FX of an empty clip, and of a sub-group below a host, are compiled but DISABLED on the engine side: an
    // effect that has no MIDI to pass would eat the notes of the host (P11). The model keeps the user's choice
    // (`isEnabled`), the engine gets `isEnabled && !passive`.

    /// Is the chain of `object` passive? `ancestors` (parent first) is read only when the answer depends on it.
    func isChainPassive(_ object: SoundObject, ancestors: () -> [SoundObject]) -> Bool {
        if GroupInstrumentRule.isEmptyClip(object) { return true }
        guard object.isGroup, object.instruments.isEmpty else { return false }
        return ancestors().contains { $0.isGroup && !$0.instruments.isEmpty }
    }

    /// The on/off to hand the engine for a plugin of `hostID`: the user's choice, unless the chain is passive.
    /// The hot pushes (a bypass with no recompile) go through here, otherwise a click would wake a passive FX.
    func engineEnabled(_ enabled: Bool, onHost hostID: UUID) -> Bool {
        guard enabled, let host = find(id: hostID) else { return enabled }
        return !isChainPassive(host, ancestors: { ancestorChain(of: hostID) })
    }

    /// Recompiles the rack of every object whose passivity changed since it was last pushed (a host that appeared,
    /// vanished or changed place). Cheap when nothing changed: one walk, no engine call.
    func refreshPassiveChains() {
        guard engine != nil else { return }
        var changed: [SoundObject] = []
        func walk(_ nodes: [SoundObject], underHost: Bool) {
            for o in nodes {
                let passive = GroupInstrumentRule.isEmptyClip(o) || (o.isGroup && o.instruments.isEmpty && underHost)
                if !o.plugins.isEmpty, passive != passiveChainIDs.contains(o.id) { changed.append(o) }
                if case .group(let children, _) = o.kind {
                    walk(children, underHost: underHost || (o.isGroup && !o.instruments.isEmpty))
                }
            }
        }
        walk(items, underHost: false)
        for o in changed { compileRack(objectID: o.id) }
    }
}
