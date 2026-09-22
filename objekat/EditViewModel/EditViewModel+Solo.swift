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
//  2. A TEMPORARY solo: tied to the "s" key being HELD (keyboard or toolbar button), and to the
//     clicks that compose it while it is held (`toggleHeldSolo`). Writes nothing persistent:
//     `tempSoloRoots` is armed for the length of the hold and emptied on release. It does NOT OUST
//     the confirmed one, it adds to it: "s" makes the selection heard ON TOP of what is already
//     soloed, and releasing it gives back the listening as it was.
//
// Invariant: `tempSoloRoots != nil ⟺ heldSoloActive`. There is only ONE owner of the temporary
// layer — the held "s" — so every layer that exists has exactly one way to be lifted:
// `endHeldSolo()` (the key's release, ⌘-Tab, or the toolbar button) or `clearAllSolo()` (Esc).
//
// For as long as "s" is held, a click on an object brings it into or out of the listening
// (`toggleHeldSolo`): you compose by ear, then s + ⏎ freezes the result into the confirmed layer — without
// anything changing in the sound, since the two layers already add up.
//
// THE SEPARATION THAT MATTERS: solo FILTERS the listening, it does not PILOT the transport. Space
// is always play/stop and ⇧space is always pause/resume, whatever solo is active — playback starts
// at `cursorPosition` and runs to the stop, the caret or a traced zone making no difference. This
// used to be different: an "audition" (⇧+space, later s+space) seeked to a selection's start,
// played, and stopped automatically at its end. It was removed because a single key meaning two
// things — space plays / space auditions a zone — made the transport unpredictable, and because
// stopping at the zone's end is exactly wrong when what one wants to hear is what comes AFTER what
// was soloed.
//
// That removal decided what a time selection MEANS to solo, and it is the one rule to keep in mind
// here: since playback is no longer bounded by the zone, neither is the listening. A zone is read
// for its ROWS and never for its span — everything on a row it touches is soloed, whether or not a
// block of that row falls inside it, and a row it crosses while holding nothing is soloed just the
// same (@see objectIDs(onLanes:)). Solo therefore has no time filter anywhere, which is also what
// keeps "s" then space from ever playing into silence: with no zone and no selection, the caret's
// own row answers.
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
    /// selection, read by the same rule `beginHeldSolo` reads it with (a time selection → the
    /// whole of its ROWS, never a span of time). The two must agree: committing is meant to keep
    /// exactly what one is hearing, and a fallback of its own would freeze something else.
    ///
    /// Since the two layers add up, confirming changes NOTHING in the sound: it simply makes
    /// permanent what is being heard. The usual collective convention (as with mute): if everything is
    /// already confirmed, ⏎ unconfirms it — and removes it from the temporary layer too, otherwise the removal
    /// would only be heard on releasing "s".
    func toggleSoloForCurrentSelection() {
        let roots: Set<UUID>
        if let temp = tempSoloRoots, !temp.isEmpty { roots = temp }
        else if let sel = timeSelection            { roots = objectIDs(onLanes: sel.lanes) }
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

    /// "s" held: adds the current selection to the listening for the length of the hold, without
    /// starting anything or persisting anything. It ADDS to the confirmed solo — with no confirmed
    /// solo, only the selection is heard; with one, it is heard on top. The release (`endHeldSolo`)
    /// gives back the previous listening, the confirmed layer included.
    ///
    /// What one hears is chosen by ROWS or by OBJECTS, never by a span of time (@see
    /// objectIDs(onLanes:)). Three roots, tried in order, and NOT as an if/else chain — a row that
    /// holds nothing must fall through rather than stop the cascade with an empty set:
    ///   1. a traced time selection → everything on ITS ROWS, whole. The zone says which rows were
    ///      aimed at and nothing more: a row it crosses while holding no object inside it is soloed
    ///      all the same, with whatever sits on it elsewhere in time.
    ///   2. failing that, the object selection — the one root that is not a row, because pointing
    ///      at an object is pointing at it and not at its neighbours. It comes AFTER the zone and
    ///      BEFORE the caret on purpose: every plain click lays a caret down as it selects (@see
    ///      TimelineView+TapHandler), so reading the caret first would widen a one-object solo to
    ///      its whole row.
    ///   3. failing that too, the caret's own row. This is what stops "s" then space from doing
    ///      NOTHING when one has merely clicked somewhere: with no root at all the solo would have
    ///      nothing to filter and the key would read as dead.
    func beginHeldSolo() {
        var roots: Set<UUID> = []
        if let sel = timeSelection    { roots = objectIDs(onLanes: sel.lanes) }
        if roots.isEmpty              { roots = selectedIDs }
        if roots.isEmpty, let cl = caretLane { roots = objectIDs(onLanes: [cl]) }
        guard !roots.isEmpty else { return }
        tempSoloRoots  = roots
        heldSoloActive = true
        refreshSolo()
    }

    /// Releasing "s": lifts the temporary layer and hands back to the confirmed solo (or to the full
    /// mix). What was frozen by s+⏎ stays, the rest goes out. This is now, together with Esc, the
    /// ONLY path that lifts the temporary layer — the transport never touches it any more: space
    /// and ⇧space are plain play/stop and pause/resume, whatever solo is filtering the listening.
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
            // release). If a layer already existed, its owner is left alone — but that owner
            // can now only ever be the held "s" itself: since the audition (⇧+space) was
            // removed, a click-born layer has no other possible master.
            if !hadLayer { heldSoloActive = true }
        }
        refreshSolo()
    }

    // MARK: The set of sound objects on a set of lanes

    /// Everything sitting on `lanes`, with NO time bound at all. The one reader of rows solo has:
    /// a traced zone hands over its `lanes`, a bare caret its own row.
    ///
    /// The absence of a time filter is the whole rule, and it is what tells solo apart from every
    /// other gesture that reads a time selection (`deleteTimeSelection`, `carveTimeRange`…). Those
    /// act on MATTER, so they take what the zone crosses. Solo acts on the LISTENING, and the
    /// listening is not bounded in time since playback stopped being windowed: it starts at
    /// `cursorPosition` and runs past the zone's end, so an object the zone does not touch WILL be
    /// heard, and anything that will be heard has to be part of what one chose to hear.
    ///
    /// Hence a zone drawn across a row holding nothing inside it still solos that row ENTIRELY: the
    /// rows are what the gesture aimed at, and asking for a row is asking for what plays on it.
    /// Anything else makes the neighbour heard or silenced depending on where its block happens to
    /// sit relative to a zone that no longer bounds the playback.
    ///
    /// What "sitting on a lane" means is the visual truth and nothing else: a folded group is
    /// itself the entry on its row, an unfolded one puts its children on rows of their own —
    /// `laneEntries` already resolves that, so what gets soloed is what the eye sees on that row.
    func objectIDs(onLanes lanes: Set<Int>) -> Set<UUID> {
        Set(laneEntries.filter { lanes.contains($0.displayLane) }.map { $0.item.id })
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
