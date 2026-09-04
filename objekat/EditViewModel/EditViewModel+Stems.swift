import SwiftUI
import AppKit

extension EditViewModel {

    // MARK: - The stem of a new group

    /// The bus decision for a group being formed.
    enum GroupStemChoice {
        /// The bus chosen (nil = Main).
        case stem(UUID?)
        /// The user gave up: group nothing.
        case cancelled
    }

    /// The bus a group formed of `members` must carry.
    ///
    /// All on the SAME bus → the group joins it: grouping is a gesture of structure, it has
    /// no reason to move the sound onto another bus (the earlier behaviour sent the group
    /// back to the Main every time). MIXED buses → we ask: a group is a
    /// submix, it leaves through a single bus and all of its content follows it there — deciding on our own
    /// would move, or silence, part of the selection without saying so.
    func stemForNewGroup(from members: [SoundObject]) -> GroupStemChoice {
        let distinct = Set(members.map { $0.stemID ?? mainStemID })
        if distinct.count <= 1 {
            let sid = distinct.first ?? mainStemID
            return .stem(sid == mainStemID ? nil : sid)
        }
        return askStemForNewGroup(among: distinct)
    }

    private func askStemForNewGroup(among candidates: Set<UUID>) -> GroupStemChoice {
        // The toolbar's order (the project's order, Main at the head if it is concerned).
        let choices = stems.filter { candidates.contains($0.id) }
        guard !choices.isEmpty else { return .stem(nil) }

        // The order of the titles IS that of `choices`: the automatic policy takes the
        // first, hence the stem at the head of the toolbar (Main if it is concerned).
        let titles = choices.map { $0.id == mainStemID ? L("stem.main.name") : $0.name }
        guard let index = choose(L("stem.choose.title"),
                                 L("stem.choose.info"),
                                 options: titles,
                                 confirmTitle: L("stem.choose.confirm"))
        else { return .cancelled }

        let picked = choices[index]
        return .stem(picked.id == mainStemID ? nil : picked.id)
    }

    /// Aligns `stemID` over a whole sub-tree. A child of a group has no bus of its own: it
    /// follows its group (the same invariant as `assignStem` and `disbandGroup`, applied here from
    /// creation / entry into a group onwards).
    static func propagatingStemID(_ sid: UUID?, in children: [SoundObject]) -> [SoundObject] {
        children.map { child in
            var c = child
            c.stemID = sid
            if case .group(let grandchildren, let isExpanded) = c.kind {
                c.kind = .group(children: propagatingStemID(sid, in: grandchildren),
                                isExpanded: isExpanded)
            }
            return c
        }
    }

    // MARK: - Stems

    func stemColor(for objectID: UUID) -> Color {
        guard let obj = find(id: objectID) else { return .cyan }
        let sid = obj.stemID ?? mainStemID
        return stems.first(where: { $0.id == sid })?.color ?? stems.first?.color ?? .cyan
    }

    func stem(for objectID: UUID) -> Stem? {
        guard let obj = find(id: objectID) else { return stems.first }
        let sid = obj.stemID ?? mainStemID
        return stems.first(where: { $0.id == sid }) ?? stems.first
    }

    // A note on undo: the DISCRETE operations (creating/deleting/renaming/recolouring/detaching a
    // stem) push an undo; setStemGain stays undo-free (a continuous setting during a
    // drag, the same convention as updateVolume — the gesture's undo is pushed by the caller).
    @discardableResult
    func addStem(name: String, colorIndex: Int = 1, format: StemFormat = .stereo) -> UUID {
        pushUndo()
        let stem = Stem(id: UUID(), name: name, colorIndex: colorIndex, format: format)
        stems.append(stem)
        engine?.createStemBus(stem.id.uuidString)
        isDirty = true
        return stem.id
    }

    func removeStem(id: UUID) {
        guard stems.first?.id != id else { return }  // the Main cannot be deleted
        pushUndo()

        // Every object of the stem, GROUPS INCLUDED: `allClips` flattens the groups, yet it is a
        // group's ContainerClip that sits on a track of the folder — that is what has to be
        // brought back, and that is what would be left with a dangling `stemID`. A stemID pointing at a deleted
        // stem is not cosmetic: the scope of a top-level send is read from it.
        var members: [SoundObject] = []
        func walk(_ arr: [SoundObject]) {
            for o in arr {
                if o.stemID == id { members.append(o) }
                if case .group(let children, _) = o.kind { walk(children) }
            }
        }
        walk(items)

        engine?.disbandStemBus(id.uuidString, memberIDs: members.map(\.id.uuidString))
        for m in members {
            update(id: m.id) { $0.stemID = nil }
        }
        stems.removeAll { $0.id == id }

        // Deleting a MUTED stem left its objects silent: the bus no longer exists, so the
        // composition has to be redone for everybody (and the snapshot purged of that stem).
        refreshAudibility()
        // With the stem gone, everybody ends up at the Main: some sends become possible again.
        resyncAllSends()
        isDirty = true
    }

    func renameStem(id: UUID, name: String) {
        guard let i = stems.firstIndex(where: { $0.id == id }) else { return }
        let newName = name.isEmpty ? "Stem" : name
        guard stems[i].name != newName else { return }
        pushUndo()
        stems[i].name = newName
        isDirty = true
    }

    /// Changes the stem's identity colour (a right-click on a toolbar slice).
    /// Does NOT touch the clips' custom colours: those left on "the stem's colour"
    /// (`colorIndex == nil`) repaint by themselves, and clips with a custom colour see only
    /// their stem band (the top 10%) update — it is all reactive through `stemColor(for:)`.
    func recolorStem(id: UUID, colorIndex: Int) {
        guard let i = stems.firstIndex(where: { $0.id == id }) else { return }
        pushUndo()
        stems[i].colorIndex = colorIndex
        isDirty = true
    }

    func assignStem(objectID: UUID, stemID: UUID) {
        guard let obj = find(id: objectID) else { return }
        // A CHILD of a group has no stem assignment of its own: its output feeds the
        // group's submix, and it is the group (the root) that belongs to a stem. (Routing a
        // child directly to a stem while staying in the group = a future "edit group",
        // not implemented.) The UI shows "output → group" instead (GroupRoutingZoneView).
        guard parentGroup(for: objectID) == nil else { return }
        // An AUX, on the other hand, has one: the engine brings its return up into the FolderTrack of the stem that
        // carries its ContainerClip (createSubmixAuxReturns), so its wet goes through the bus's FX
        // and counts in its meter. That is also what defines the scope of a top-level send:
        // the objects of the same stem, plus all the others if the aux is at the Main (see `canRouteSend`)
        // — moving an aux to or out of the Main therefore widens or narrows its clientele.
        let oldStemID = obj.stemID ?? mainStemID
        guard oldStemID != stemID else { return }
        let isMain = (stemID == mainStemID)
        let newStemID: UUID? = isMain ? nil : stemID
        update(id: objectID) { $0.stemID = newStemID }
        if case .group(let children, _) = obj.kind {
            // Recursive propagation into every descendant (sub-groups included).
            func propagate(_ kids: [SoundObject]) {
                for child in kids {
                    update(id: child.id) { $0.stemID = newStemID }
                    if case .group(let grandkids, _) = child.kind {
                        propagate(grandkids)
                    }
                }
            }
            propagate(children)
        }
        engine?.moveObject(objectID.uuidString,
                           fromStemID: oldStemID == mainStemID ? nil : oldStemID.uuidString,
                           toStemID: isMain ? nil : stemID.uuidString)

        // A SHARED object: the stem is SYNCHRONISED across every placement of the same definition
        // (the same logic as colour/name, see EditViewModel+ObjectColor/renameObject) — a
        // linked object stays on the same bus everywhere it appears. EXCEPTION: an instance
        // inside a group follows its group (no stem of its own), and is skipped.
        if let defID = obj.definitionID {
            for sid in placementIDs(forDefinition: defID, excluding: objectID) {
                guard let sibling = find(id: sid),
                      parentGroup(for: sid) == nil else { continue }
                let siblingOld = sibling.stemID ?? mainStemID
                guard siblingOld != stemID else { continue }
                update(id: sid) { $0.stemID = newStemID }
                engine?.moveObject(sid.uuidString,
                                   fromStemID: siblingOld == mainStemID ? nil : siblingOld.uuidString,
                                   toStemID: isMain ? nil : stemID.uuidString)
                pushMixTree(sid)
            }
        }

        // The stem takes part in composing the silence: joining a muted bus (or leaving it)
        // changes what the engine must hear, with no volume having moved. Targeted, and not
        // a global refreshAudibility: `assignStemSelected` calls this in a loop.
        pushMixTree(objectID)

        // The scope of a top-level send is the stem: this move can tip it either
        // way — breaking the sends that now cross a bus, and restoring those that
        // find themselves reunited. The same reason as after a (un)grouping. @see canRouteSend
        resyncAllSends()
        isDirty = true
    }

    func assignStemSelected(stemID: UUID) {
        guard !selectedIDs.isEmpty else { return }
        for id in selectedIDs { assignStem(objectID: id, stemID: stemID) }
    }

    // MARK: - Mixer (increment 1): the gain + meter of the stems and of the master

    /// The 0..1 (peak) level at the bus's output, to be polled for the meter. Main = the general output (master).
    func stemLevel(_ stemID: UUID) -> Float {
        guard let engine else { return 0 }
        if stemID == mainStemID { return engine.audioLevelForMaster() }
        return engine.audioLevel(forStem: stemID.uuidString)
    }

    /// The bus gain in dB (the model; nil ⇒ 0). Main = the master volume.
    func stemGainDb(_ stemID: UUID) -> Float {
        stems.first(where: { $0.id == stemID })?.gainDb ?? 0
    }

    /// Sets the bus gain live (engine) + persists it in the model.
    func setStemGain(_ stemID: UUID, dB: Float) {
        guard let i = stems.firstIndex(where: { $0.id == stemID }) else { return }
        stems[i].gainDb = dB
        if stemID == mainStemID { engine?.setMasterGain(dB) }
        else { engine?.setStemGain(dB, stemID: stemID.uuidString) }
        isDirty = true
    }

    /// Reapplies the remembered bus gains to the engine (to be called after loading a project).
    func syncStemGains() {
        for stem in stems {
            let dB = stem.gainDb ?? 0
            if stem.id == mainStemID { engine?.setMasterGain(dB) }
            else { engine?.setStemGain(dB, stemID: stem.id.uuidString) }
        }
    }

    /// The routing of a stem's output to the Main (master). false = a detached bus (no longer
    /// contributing to the main mix). Meaningless for the Main itself.
    func setStemRouteToMain(_ stemID: UUID, on: Bool) {
        guard stemID != mainStemID,
              let i = stems.firstIndex(where: { $0.id == stemID }),
              stems[i].routeToMain != on else { return }
        pushUndo()
        stems[i].routeToMain = on
        engine?.setStemRouteToMain(on, stemID: stemID.uuidString)
        isDirty = true
    }

    /// Reapplies the remembered bus routing to the engine (to be called after loading a project,
    /// once the buses are created). Only detached stems need any action.
    func syncStemRouting() {
        for stem in stems where stem.id != mainStemID && !stem.routeToMain {
            engine?.setStemRouteToMain(false, stemID: stem.id.uuidString)
        }
    }

    // MARK: - The bus mute (the "digit + M" shortcut)
    //
    // A stem's mute does NOT cut its FolderTrack's output: it is composed at the level of the
    // objects, which go to -96 dB (@see EditViewModel+Audibility). Two reasons for cutting at the
    // source rather than at the bus's output: an object's fader is upstream of its send tap,
    // so a muted object also stops feeding the auxes — a cut bus used to leave its reverb
    // ringing in the Main; and the state stays DERIVED from `stems[i].muted`, never copied into the
    // objects, otherwise un-muting a bus would crush the clip mutes.

    /// Toggles a stem's mute (all of its objects at once). The Main cannot be muted. The items
    /// assigned to the stem are dimmed in the timeline (see isMutedInMix).
    func toggleStemMute(_ stemID: UUID) {
        guard stemID != mainStemID,
              let i = stems.firstIndex(where: { $0.id == stemID }) else { return }
        pushUndo()
        stems[i].muted.toggle()
        refreshAudibility()
        isDirty = true
    }

    // "Is this object in a muted stem?" is not exposed here: the question never arises
    // on its own — a direct solo lifts that mute — and two functions answering the same
    // thing end up no longer saying the same thing. The answer is in `AudibilitySnapshot`,
    // which composes it with the rest (`isMutedInMix`, `isSilenced`).

    // MARK: - Per-bus FX (INC 2)

    /// Reapplies the remembered bus FX chains to the engine (stems + Main/master). To be called
    /// after loading a project, once the buses are created and the Main is declared (`setMasterStemKey`).
    /// `compileRack` reads the model's plugins + chain gains through the host primitives.
    /// needsChainCompile: a bus with ONLY trim gains has to be compiled too.
    func syncStemPlugins() {
        for stem in stems where stem.needsChainCompile {
            compileRack(objectID: stem.id)
        }
    }
}
