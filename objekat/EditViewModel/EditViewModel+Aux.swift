import Foundation

extension EditViewModel {

    // MARK: - Creating an aux

    /// Creates an AUX object (receive-only) from a time selection:
    /// its window = the selection's range, on the topmost lane of the selection.
    func createAuxFromTimeSelection(_ sel: TimeSelection) {
        let t1 = sel.timeRange.lowerBound
        let t2 = sel.timeRange.upperBound
        guard t2 > t1 else { return }
        pushUndo()
        // sel.lanes = display lanes: an open group shifts the display lanes, so the
        // aux is routed through placeClip (a top-level base lane, or a child if the display lane
        // falls inside the child range of an open group) instead of using the raw lane.
        let displayLane = sel.lanes.min() ?? 0
        let aux = SoundObject(startTime: t1, duration: t2 - t1, lane: displayLane, kind: .aux)
        let placed = placeClip(aux, snapshot: laneEntries)   // model + syncAdd → engineAddAux
        selectedIDs = [placed.id]
        timeSelection = nil
        isDirty = true
    }

    // MARK: - Auxes & overlap

    /// Every AUX object in the project (top-level AND children of groups), absolute positions.
    var allAuxes: [SoundObject] { allClips.filter(\.isAux) }

    // MARK: - The scope of a send
    //
    // A send is wired only if the sender is upstream of the LEVEL where the engine brings the aux's
    // return up — the only place we know the taps are written before being read. There are
    // two levels, and the rule differs:
    //   • direct children of the same group → inside the ContainerClip's local graph. Strict
    //     equality: nothing crosses a container's boundary, neither inwards nor
    //     outwards;
    //   • both TOP-LEVEL → onto the sum of the tracks of the STEM that carries the aux (in its
    //     submix FolderTrack), or onto the root tracks when the aux is at the Main. Nothing
    //     guarantees that the sender and the aux share a track — the engine allocates them by
    //     compartments — so a point where the whole stem has already gone past is needed.
    // Hence the top-level rule: THE SAME STEM, OR an aux of the Main. A send goes UP — the sum of the
    // root tracks already contains each stem's folder, detached from the Main or not — but it does not
    // go down, and two sibling stems cannot see each other. That is what makes a single reverb
    // shared by several stems possible, at the Main and there only.
    // An accepted cost for a send that goes up: the wet leaves its stem (out of its meter,
    // out of its bounce), so "Σ stems = mix" assumes the Main is delivered as a stem.
    // What stays out of scope, and will stay so: crossing a container's boundary.
    // Three consequences worth knowing:
    //   • a child of a sub-group does not reach the parent group's aux, nor a top-level aux.
    //     The way round: put the send on the sub-group itself, which IS a sibling;
    //   • a group cannot send towards an aux it CONTAINS — that would be a loop
    //     (the aux's output is already summed into its own). The rule excludes it outright;
    //   • moving an object OR an aux to another stem can tip the scope either
    //     way — hence the call to `resyncAllSends()` in `assignStem`.
    // Sends out of scope stay in the model, silent. We merely stop offering them.

    /// True if a send from `objectID` towards `auxID` can be wired by the engine.
    func canRouteSend(from objectID: UUID, to auxID: UUID) -> Bool {
        guard objectID != auxID,
              let sender = find(id: objectID), !sender.isAux,
              let aux = find(id: auxID), aux.isAux
        else { return false }

        let senderGroup = parentGroup(for: objectID)
        guard senderGroup?.id == parentGroup(for: auxID)?.id else { return false }

        // Inside a group, the container already makes the boundary (and a child has no stem of its
        // own: it follows its group). At the top level it is the stem that makes it — except for the
        // Main, whose level of assembly contains all the others.
        guard senderGroup == nil else { return true }
        let auxStem = aux.stemID ?? mainStemID
        return auxStem == mainStemID || auxStem == (sender.stemID ?? mainStemID)
    }

    /// The auxes whose window overlaps the object `objectID` in time AND that are within its
    /// scope — they are the only ones a send makes sense towards (the toggle is shown
    /// only for them). @see canRouteSend
    func overlappingAuxes(for objectID: UUID) -> [SoundObject] {
        guard let obj = find(id: objectID) else { return [] }
        let oStart = obj.startTime
        let oEnd   = obj.startTime + obj.duration
        return allAuxes
            .filter { aux in
                guard canRouteSend(from: objectID, to: aux.id) else { return false }
                // An infinite aux: a bus always active → it overlaps any sender.
                if aux.isInfiniteBus { return true }
                return aux.startTime < oEnd && (aux.startTime + aux.duration) > oStart
            }
            .sorted { $0.startTime < $1.startTime }
    }

    /// The auxes overlapping the object, ordered by vertical position (display lane) top → bottom.
    /// That is the order of the Send tool's knob rows.
    func sendToolAuxes(for objectID: UUID) -> [SoundObject] {
        let auxes = overlappingAuxes(for: objectID)
        func laneOf(_ id: UUID) -> Int {
            laneEntries.first { $0.item.id == id }?.displayLane ?? (find(id: id)?.lane ?? 0)
        }
        return auxes.sorted { laneOf($0.id) < laneOf($1.id) }
    }

    /// The send-knob rows for the Send tool's overlay on `objectID`.
    func sendRows(for objectID: UUID) -> [SendRow] {
        sendToolAuxes(for: objectID).map { aux in
            let e = sendEntry(from: objectID, to: aux.id)
            return SendRow(
                auxID:   aux.id,
                label:   aux.label ?? L("aux.defaultLabel", Int(aux.startTime.rounded())),
                level:   e?.levelDb ?? sendMinDb,
                enabled: e?.enabled ?? false,
                focused: sendToolFocus == SendFocus(objectID: objectID, auxID: aux.id)
            )
        }
    }

    // MARK: - Multi-selection sends
    //
    // "Send to all": a setting on the selection touches every selected (non-aux) object
    // that overlaps the target aux. If their levels differ, the edit is
    // relative (it preserves the gaps), like Volume/Pan. Objects with no send (-∞) are
    // included: a send is created/enabled on them as soon as the level goes above -∞.

    /// The auxes overlapping AT LEAST one selected (non-aux) object, de-duplicated and ordered
    /// by display lane, top→bottom. These are the rows of the inspector's "Sends" column
    /// in a multiple selection.
    func selectionSendAuxes() -> [SoundObject] {
        let senders = selectedIDs.compactMap { find(id: $0) }.filter { !$0.isAux }
        var seen = Set<UUID>()
        var result: [SoundObject] = []
        for s in senders {
            for aux in overlappingAuxes(for: s.id) where seen.insert(aux.id).inserted {
                result.append(aux)
            }
        }
        func laneOf(_ id: UUID) -> Int {
            laneEntries.first { $0.item.id == id }?.displayLane ?? (find(id: id)?.lane ?? 0)
        }
        return result.sorted { laneOf($0.id) < laneOf($1.id) }
    }

    /// The selected (non-aux) objects that overlap `auxID` → the targets of a send towards that aux.
    func selectedSenders(toAux auxID: UUID) -> [UUID] {
        selectedIDs.compactMap { find(id: $0) }
            .filter { !$0.isAux && overlappingAuxes(for: $0.id).contains { $0.id == auxID } }
            .map(\.id)
    }

    /// A relative nudge of the send level towards `auxID` over the whole selection (preserves the gaps).
    func adjustSendLevelSelected(toAux auxID: UUID, deltaDb: Float) {
        for id in selectedSenders(toAux: auxID) {
            setSendLevel(from: id, to: auxID, levelDb: sendLevel(from: id, to: auxID) + deltaDb)
        }
        isDirty = true
    }

    /// Sets one identical absolute level towards `auxID` over the whole selection.
    func setSendLevelSelected(toAux auxID: UUID, levelDb: Float) {
        for id in selectedSenders(toAux: auxID) {
            setSendLevel(from: id, to: auxID, levelDb: levelDb)
        }
        isDirty = true
    }

    /// Turns the send towards `auxID` on/off over the whole selection.
    func setSendEnabledSelected(toAux auxID: UUID, enabled: Bool) {
        for id in selectedSenders(toAux: auxID) {
            setSendEnabled(from: id, to: auxID, enabled: enabled)
        }
        isDirty = true
    }

    /// The senders (clips AND groups) with an ACTIVE send (level > -∞) towards `auxID`, in
    /// time order. Used by the inspector when an aux is selected: the incoming sends are then
    /// listed so they can be adjusted straight from the aux.
    func activeSenders(toAux auxID: UUID) -> [UUID] {
        var result: [(id: UUID, start: Double)] = []
        func walk(_ arr: [SoundObject]) {
            for o in arr where !o.isAux {
                if let s = o.sends.first(where: { $0.auxID == auxID }), s.levelDb > sendMinDb,
                   canRouteSend(from: o.id, to: auxID) {   // the same scope as the Send tool
                    result.append((o.id, o.startTime))
                }
                if case .group(let children, _) = o.kind { walk(children) }
            }
        }
        walk(items)
        return result.sorted { $0.start < $1.start }.map(\.id)
    }

    // MARK: - Sends
    //
    // The model: an AuxSend remembers its level (in dB) AND an `enabled` flag (the user's
    // intention, through the toggle). The send is audible/wired to the engine only if it is
    // `isRouted` = enabled && level > -∞ (sendMinDb). Auto-enabling rules:
    //   • raising the level above -∞  → enabled becomes true
    //   • lowering the level to -∞     → enabled becomes false
    // The toggle stays independent: it can cut a send while keeping its level.

    /// The send entry from `objectID` towards `auxID`, if it exists.
    func sendEntry(from objectID: UUID, to auxID: UUID) -> AuxSend? {
        find(id: objectID)?.sends.first { $0.auxID == auxID }
    }

    /// The user's intention (the toggle's state).
    func isSendEnabled(from objectID: UUID, to auxID: UUID) -> Bool {
        sendEntry(from: objectID, to: auxID)?.enabled ?? false
    }

    /// True if the send is effectively routed (enabled && level > -∞).
    func isSendRouted(from objectID: UUID, to auxID: UUID) -> Bool {
        sendEntry(from: objectID, to: auxID)?.isRouted ?? false
    }

    /// The remembered level; -∞ (sendMinDb) by default if there is no entry.
    func sendLevel(from objectID: UUID, to auxID: UUID) -> Float {
        sendEntry(from: objectID, to: auxID)?.levelDb ?? sendMinDb
    }

    /// The inspector's toggle: turns the send on/off while keeping its level.
    /// Enabling with no existing entry creates a silent send (-∞) until the level is raised.
    func setSendEnabled(from objectID: UUID, to auxID: UUID, enabled: Bool) {
        update(id: objectID) { obj in
            if let i = obj.sends.firstIndex(where: { $0.auxID == auxID }) {
                obj.sends[i].enabled = enabled
            } else if enabled {
                obj.sends.append(AuxSend(auxID: auxID, levelDb: sendMinDb, enabled: true))
            }
        }
        syncSendEngine(objectID: objectID, auxID: auxID)
        isDirty = true
    }

    /// Sets the send level (clamped -∞…+sendMaxDb) with auto enabling/disabling
    /// at the extremes. Creates the entry on the fly if it is raised above -∞.
    func setSendLevel(from objectID: UUID, to auxID: UUID, levelDb: Float) {
        let lv = levelDb.clamped(to: sendMinDb...sendMaxDb)
        update(id: objectID) { obj in
            if let i = obj.sends.firstIndex(where: { $0.auxID == auxID }) {
                obj.sends[i].levelDb = lv
                obj.sends[i].enabled = lv > sendMinDb        // auto on/off at the extremes
            } else if lv > sendMinDb {
                obj.sends.append(AuxSend(auxID: auxID, levelDb: lv, enabled: true))
            }
        }
        recordAutomationTouch(objectID, .send(auxID: auxID))
        syncSendEngine(objectID: objectID, auxID: auxID)
        isDirty = true
    }

    /// Reconciles a send's engine state with the model (idempotent).
    ///
    /// `isRouted` (enabled AND level > -∞) was enough as long as a send had only a static
    /// level: not wiring a silent tap avoids a graph node for nothing. A level CURVE
    /// changes that — it needs the send plugin to write itself into, even if the
    /// static level has stayed at -∞ (that is even the normal case: the curve is laid on a send
    /// that has never been raised by hand). The switch, for its part, keeps the last word: cutting it
    /// is an explicit intention of silence.
    func syncSendEngine(objectID: UUID, auxID: UUID) {
        let s = sendEntry(from: objectID, to: auxID)
        let alive = (s?.enabled ?? false)
            && (!(s?.isSilent ?? true) || isAutomated(.send(auxID: auxID), on: objectID))
        if let s, alive, canRouteSend(from: objectID, to: auxID) {
            engine?.addSend(objectID.uuidString, toAux: auxID.uuidString, levelDb: s.levelDb)
        } else {
            engine?.removeSend(objectID.uuidString, toAux: auxID.uuidString)
        }
    }

    /// Reconciles EVERY send in the project with the engine, both ways: wires those that
    /// are routable, unwires the others. To be called after a full rebuild (load /
    /// undo-redo), where a sender can be synced before the target aux, but ALSO after any
    /// change of group membership: a send's scope is "siblings of the same
    /// container", so grouping or ungrouping can tip it either
    /// way. Idempotent.
    func resyncAllSends() {
        func walk(_ arr: [SoundObject]) {
            for o in arr {
                for s in o.sends { syncSendEngine(objectID: o.id, auxID: s.auxID) }
                if case .group(let children, _) = o.kind { walk(children) }
            }
        }
        walk(items)
        // A rewired send is a BRAND-NEW plugin: its curve has gone back to nothing on the engine side. And
        // since this pass is precisely the meeting point of everything that reshapes the topology
        // (loading, undo, composing/dissolving a group, changing stem, pasting),
        // it is the right place to push the rest of the project's curves again as well — a plain
        // tree walk, free for objects with no automation.
        pushAllAutomation()
    }

    /// Copies onto `newAuxID` every send that targeted `origAuxID` (the same level).
    /// Used by the aux split: both halves stay fed by the same senders.
    func duplicateSendsTarget(from origAuxID: UUID, to newAuxID: UUID) {
        func walk(_ arr: [SoundObject]) {
            for o in arr {
                if let s = o.sends.first(where: { $0.auxID == origAuxID }) {
                    update(id: o.id) { obj in
                        if !obj.sends.contains(where: { $0.auxID == newAuxID }) {
                            obj.sends.append(AuxSend(auxID: newAuxID,
                                                     levelDb: s.levelDb, enabled: s.enabled))
                        }
                    }
                    syncSendEngine(objectID: o.id, auxID: newAuxID)
                }
                if case .group(let children, _) = o.kind { walk(children) }
            }
        }
        walk(items)
    }
}
