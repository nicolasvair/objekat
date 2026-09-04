import Foundation

// MARK: - Solo at the clip level
//
// An "object" solo, the counterpart of the bus mute (EditViewModel+Stems) but at the level of individual
// sound objects. Two layers, which ADD UP — a single rule: what is heard is the union.
//
//     audible = closure(soloedIDs ∪ tempSoloRoots) ∪ the members of the soloed stems
//               ∪ the AUXES fed by the above
//
//  1. A CONFIRMED solo (the "solo on" attribute): persistent until it is turned off (Esc, ⇧⌫,
//     s+⏎ on what is already confirmed). Carried by `soloedIDs` (objects confirmed one by one) and
//     `soloedStemIDs` (stems confirmed wholesale, combinable: s+2+3+4).
//  2. A TEMPORARY solo: tied to ONE playback (⇧+space) or to the "s" key being HELD. Writes nothing
//     persistent: `tempSoloRoots` is armed for the length of the playback (emptied on stop) or of the
//     hold (emptied on release). It does NOT OUST the confirmed one, it adds to it: "s" makes
//     the selection heard ON TOP of what is already soloed, and releasing it gives back the listening
//     as it was.
//
// For as long as "s" is held, a click on an object brings it into or out of the listening
// (`toggleHeldSolo`): you compose by ear, then s + ⏎ freezes the result into the confirmed layer — without
// anything changing in the sound, since the two layers already add up.
//
// The engine has no notion of solo: it is emulated by pushing -96 dB onto the objects that have to be
// silenced. What "have to" means is NOT decided here: solo is only one of the layers of
// listening, composed with the mutes by EditViewModel+Audibility — that is where to read why
// a direct solo beats a mute and an inherited solo does not. `soloedIDs` lives outside the `items`
// model (session state, not persisted, outside undo) — like the bus mute, solo is a transient
// listening state.

extension EditViewModel {

    // MARK: Derived state

    /// True if a confirmed solo (object or stem) is active.
    var soloActive: Bool { !soloedIDs.isEmpty || !soloedStemIDs.isEmpty }

    /// True if any solo (confirmed OR temporary) is currently filtering the listening → drives the
    /// dimming of inaudible objects.
    var hasAnySolo: Bool { soloActive || tempSoloRoots != nil }

    /// True if the object `id` must be shown "almost transparent": a solo is active and this
    /// object (or all of its descendants) is not audible. An O(1) read on the cached set.
    func isSoloDimmed(_ id: UUID) -> Bool {
        hasAnySolo && !soloAudibleObjectIDs.contains(id)
    }

    // MARK: The confirmed solo (a persistent attribute)

    /// s + Enter: freezes into the confirmed layer what is being listened to temporarily — the "s"
    /// layer if it is armed (the starting selection, retouched by clicks), otherwise the current
    /// selection (a time selection → the sounds in the selection).
    ///
    /// Since the two layers add up, confirming changes NOTHING in the sound: it simply makes
    /// permanent what is being heard. The usual collective convention (as with mute): if everything is
    /// already confirmed, ⏎ unconfirms it — and removes it from the temporary layer too, otherwise the removal
    /// would only be heard on releasing "s".
    func toggleSoloForCurrentSelection() {
        let roots: Set<UUID>
        if let temp = tempSoloRoots, !temp.isEmpty { roots = temp }
        else if let sel = timeSelection            { roots = objectIDs(inZone: sel) }
        else                                       { roots = selectedIDs }
        guard !roots.isEmpty else { return }

        if roots.allSatisfy({ soloedIDs.contains($0) }) {
            soloedIDs.subtract(roots)
            if var temp = tempSoloRoots {
                temp.subtract(roots)
                tempSoloRoots = temp.isEmpty ? nil : temp
                if tempSoloRoots == nil { heldSoloActive = false }
            }
        } else {
            soloedIDs.formUnion(roots)
        }
        refreshSolo()
    }

    /// Toggles the "hold" solo of ONE object, outside any keyboard chord — this is the inspector's
    /// solo button. Writes into the CONFIRMED layer, and never into the temporary one: an inspector
    /// click is not backed by any hold of "s", so it has nothing to release it, and
    /// a temporary layer laid there would evaporate at the first Esc with nothing to bring it back.
    ///
    /// The same convention as s+⏎ on a single object: un-holding removes it from the temporary layer TOO, otherwise
    /// the click would have no audible effect for as long as "s" stayed held down.
    func toggleSoloHold(objectID id: UUID) {
        if soloedIDs.contains(id) {
            soloedIDs.remove(id)
            if var temp = tempSoloRoots, temp.contains(id) {
                temp.remove(id)
                tempSoloRoots = temp.isEmpty ? nil : temp
                if tempSoloRoots == nil { heldSoloActive = false }
            }
        } else {
            soloedIDs.insert(id)
        }
        refreshSolo()
    }

    /// s + N: toggles the solo of every element of a stem (combinable — s+2+3+4).
    func toggleStemSolo(_ stemID: UUID) {
        if soloedStemIDs.contains(stemID) { soloedStemIDs.remove(stemID) }
        else { soloedStemIDs.insert(stemID) }
        refreshSolo()
    }

    /// Esc / ⇧⌫: turns off every solo (confirmed AND temporary).
    func clearAllSolo() {
        guard hasAnySolo else { return }
        soloedIDs.removeAll()
        soloedStemIDs.removeAll()
        tempSoloRoots = nil
        heldSoloActive = false
        refreshSolo()
    }

    // MARK: The temporary solo (the "s" key held)

    /// "s" held: adds the selection to the listening for the length of the hold, without starting anything or
    /// persisting anything. The same layer as the audition (`tempSoloRoots`), which ADDS to the confirmed solo —
    /// with no confirmed solo, only the selection is heard; with one, it is heard on top. The
    /// release (`endHeldSolo`) gives back the previous listening, the confirmed layer included.
    /// With no selection there is nothing to add → a no-op; the click (`toggleHeldSolo`) and the
    /// s+N, s+⏎… chords stay armed.
    func beginHeldSolo() {
        var roots: Set<UUID> = []
        if let sel = timeSelection {
            roots = objectIDs(inZone: sel)
        } else if !selectedIDs.isEmpty {
            roots = selectedIDs
        }
        guard !roots.isEmpty else { return }
        tempSoloRoots  = roots
        heldSoloActive = true
        refreshSolo()
    }

    /// Releasing "s": lifts the temporary layer and hands back to the confirmed solo (or to the full
    /// mix). What was frozen by s+⏎ stays, the rest goes out.
    func endHeldSolo() {
        guard heldSoloActive else { return }
        heldSoloActive = false
        tempSoloRoots  = nil
        refreshSolo()
    }

    /// A click on an object (clip, group or aux) while "s" is held: brings it into or
    /// out of the listening, without touching the selection or the transport. This is how what is heard
    /// gets composed by ear, then s + ⏎ freezes the result.
    ///
    /// The click acts on the layer that makes the object audible: if it is audible because it is CONFIRMED, it
    /// leaves that layer (what is seen lit is what gets put out); if it is audible through the temporary layer, it leaves that;
    /// otherwise it joins the temporary layer. With no layer armed (no selection at the moment of the "s"), the
    /// first click brings one into being.
    ///
    /// Three cases do not go out on a click, for want of existing in a layer of their own: an object
    /// audible because its STEM is soloed, or because an ANCESTOR GROUP is — the stem must then be
    /// un-soloed (s+N) or the group; and an AUX opened by an audible sender, which is
    /// closed by cutting the send (or by un-soloing the sender).
    func toggleHeldSolo(objectID id: UUID) {
        if soloedIDs.contains(id) {
            soloedIDs.remove(id)
            if var temp = tempSoloRoots, temp.contains(id) {
                temp.remove(id)
                tempSoloRoots = temp.isEmpty ? nil : temp
                if tempSoloRoots == nil { heldSoloActive = false }
            }
            refreshSolo()
            return
        }

        let hadLayer = tempSoloRoots != nil
        var roots = tempSoloRoots ?? []
        if roots.contains(id) { roots.remove(id) } else { roots.insert(id) }

        if roots.isEmpty {
            tempSoloRoots  = nil
            heldSoloActive = false
        } else {
            tempSoloRoots = roots
            // A layer born of the click → it belongs to the hold of "s" (HUD + lifted on
            // release). If a layer already existed, its owner is left alone:
            // an audition (⇧space) under way stays master of its own lifting.
            if !hadLayer { heldSoloActive = true }
        }
        refreshSolo()
    }

    // MARK: The temporary solo (tied to a playback)

    /// The playback window of a temporary solo: `start`/`end` in timeline seconds. `end == nil`
    /// = play to the end (no automatic stop).
    struct TempSoloWindow { var start: Double; var end: Double? }

    /// ⇧+space: arms a temporary solo and returns the window to play, or nil if there is nothing to
    /// audition. A time selection → the [start, end] range + the objects inside it; an already composed
    /// "s" layer (selection + clicks) → that layer; otherwise an object selection → [the start of the
    /// earliest, the end of the latest]. The transport (ContentView) takes care of the seek/play and of stopping at
    /// `end`. Like any temporary layer, it ADDS to the confirmed solo: the audition is heard
    /// over what is already soloed.
    func beginTemporarySolo() -> TempSoloWindow? {
        var roots: Set<UUID> = []
        var start = 0.0
        var end: Double? = nil

        if let sel = timeSelection {
            roots = objectIDs(inZone: sel)
            start = sel.timeRange.lowerBound
            end   = sel.timeRange.upperBound
        } else if heldSoloActive, let temp = tempSoloRoots, !temp.isEmpty {
            // "s" held: what is auditioned is what has just been composed by clicking, not the
            // selection alone. The window = the span of those objects in ABSOLUTE time (children of groups
            // included), hence going through laneEntries rather than through `startTime`.
            roots = temp
            let spans = laneEntries.filter { temp.contains($0.item.id) }
            guard let s = spans.map(\.absStart).min(),
                  let e = spans.map({ $0.absStart + $0.item.duration }).max() else { return nil }
            start = s; end = e
        } else if !selectedIDs.isEmpty {
            roots = selectedIDs
            let objs = selectedIDs.compactMap { find(id: $0) }
            guard let s = objs.map(\.startTime).min(),
                  let e = objs.map({ $0.startTime + $0.duration }).max() else { return nil }
            start = s; end = e
        }

        guard !roots.isEmpty else { return nil }
        tempSoloRoots  = roots
        heldSoloActive = false   // the audition takes over from the held "s" (HUD included)
        refreshSolo()
        return TempSoloWindow(start: max(0, start), end: end)
    }

    /// The end of the auditioned playback: lifts the temporary solo and restores the listening (either the
    /// solo still toggled on, or the full mix).
    func endTemporarySolo() {
        guard tempSoloRoots != nil else { return }
        tempSoloRoots  = nil
        heldSoloActive = false
        refreshSolo()
    }

    // MARK: The set of sound objects in a time selection

    /// The IDs of the objects (at any depth) whose block crosses the selection (lanes + time).
    /// The same overlap rule as `deleteTimeSelection`.
    func objectIDs(inZone sel: TimeSelection) -> Set<UUID> {
        let lo = sel.timeRange.lowerBound, hi = sel.timeRange.upperBound
        return Set(laneEntries.filter { e in
            sel.lanes.contains(e.displayLane)
                && e.absStart < hi
                && e.absStart + e.item.duration > lo
        }.map { $0.item.id })
    }

    // MARK: Applying it to the engine + the cached audible set

    /// Recomputes the set of audible objects (leaves + ancestor groups) then hands back to
    /// the listening composition, which pushes the emulated mute to the engine. Called after every change
    /// of solo state. The order matters: the snapshot copies the closure that has just been built.
    func refreshSolo() {
        recomputeSoloAudible()
        refreshAudibility()
    }

    /// (Re)builds `soloAudibleObjectIDs`: every audible leaf, plus the AUXES they
    /// feed, plus the ancestor groups of all of those (a group stays "lit" for as long
    /// as at least one of its descendants is).
    ///
    /// Soloing a clip means wanting to hear it WITH its send: closing the aux it aims at
    /// would be listening to only half the object. Only ITS share of the bus is heard, with
    /// nothing more to do — the other senders are at -96 dB and their tap is taken after
    /// their fader. That is what makes the send relevant at the clip level, and not at the bus level.
    ///
    /// An aux does not send (`canRouteSend` excludes aux senders), so there is nothing to propagate down the
    /// chain. An audible but MUTED sender opens its aux all the same: it sends nothing there, the
    /// bus turns over empty — inaudible, and no point duplicating here the silence rule, which
    /// is precisely composed only afterwards (@see refreshSolo).
    private func recomputeSoloAudible() {
        guard hasAnySolo else { soloAudibleObjectIDs = []; return }
        var audible: Set<UUID> = []

        func closeOverAncestors() {
            for id in Array(audible) {
                var anc = parentGroup(for: id)
                while let a = anc { audible.insert(a.id); anc = parentGroup(for: a.id) }
            }
        }

        for leaf in allClips where isLeafAudible(leaf) { audible.insert(leaf.id) }
        closeOverAncestors()   // groups first: an audible group can itself send

        for o in allObjectsFlat where !o.isAux && audible.contains(o.id) {
            for s in o.sends where s.isRouted && canRouteSend(from: o.id, to: s.auxID) {
                audible.insert(s.auxID)
            }
        }
        closeOverAncestors()   // a group's aux lights its ancestors too

        soloAudibleObjectIDs = audible
    }

    /// The roots of the listening: the confirmed AND the temporary, added together. A single rule, no
    /// priority of one layer over the other. This is also the DIRECT solo in the sense of the listening
    /// composition — the one that beats a mute, as opposed to the solo inherited from an ancestor group
    /// or from a stem. @see AudibilitySnapshot
    var soloRootIDs: Set<UUID> {
        guard let temp = tempSoloRoots else { return soloedIDs }
        return soloedIDs.union(temp)
    }

    /// A leaf is audible if it — or an ancestor — appears in the roots (confirmed ∪
    /// temporary), or if its stem is soloed. "Audible" in the sense of solo alone: the mutes are
    /// composed on top (@see AudibilitySnapshot), they are not read here.
    private func isLeafAudible(_ leaf: SoundObject) -> Bool {
        let sid = leaf.stemID ?? mainStemID
        if soloedStemIDs.contains(sid) { return true }
        return isInRootClosure(leaf.id, roots: soloRootIDs)
    }

    /// True if `id` — or one of its ancestors — belongs to `roots`.
    private func isInRootClosure(_ id: UUID, roots: Set<UUID>) -> Bool {
        if roots.contains(id) { return true }
        var anc = parentGroup(for: id)
        while let a = anc { if roots.contains(a.id) { return true }; anc = parentGroup(for: a.id) }
        return false
    }

}
