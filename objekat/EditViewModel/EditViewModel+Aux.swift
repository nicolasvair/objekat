import Foundation
import AppKit

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
    /// CACHED until `items` next changes (@see `allAuxesCache`): the inspector's multiple selection
    /// and the Send tool read it for every sender.
    var allAuxes: [SoundObject] {
        // Read through the observable property, cache or not (@see find(id:)).
        _ = items
        if let allAuxesCache { return allAuxesCache }
        let auxes = allClips.filter(\.isAux)
        allAuxesCache = auxes
        return auxes
    }

    // MARK: - The scope of a send
    //
    // docs/plan_sends_rework.md §A.3, and ONE place for the rule: `BridgeScope` (`SendIndex` for the
    // questions per pair, `plan` for the whole). Every send goes through the audio bridge: a tap per
    // send, read by the aux's return, whatever the depth of the sender and of the aux. So the only
    // question left is the STEM: an object reaches any aux of its own stem or of the Main, in any
    // group, at any depth. What it does NOT reach:
    //   • an aux in another stem (`outOfStem`) — two sibling stems cannot see each other, which is
    //     what makes a reverb shared at the Main possible and nothing else;
    //   • an aux inside the group that SENDS (`ancestorSource`): the aux's output is already summed
    //     into the group's own — that is a loop, excluded outright;
    //   • anything that is not an aux (`hostNotAux`); and an aux, a stem or the Main never sends.
    // A send is also refused `cycle` when the keys already laid make the aux's return run BEFORE the
    // sender — a scheduling loop, decided by the plan, not here (@see `sendStatus`).
    // Accepted costs: the wet of an aux outside the sender's group does not obey the group's fader,
    // FX or fades (Q-U1b) — but the group's MUTE silences it (Q-U1, @see `sendIsGated`) — and a send
    // that goes UP leaves its stem (out of its meter, out of its bounce).
    // Sends out of scope stay in the model, silent. We merely stop offering them.
    //
    // OBJ_SENDS_LEGACY=1 keeps the previous rule (siblings of one container, or one stem) for the null
    // test of the plan: `legacyCanRouteSend`.

    /// True if a send from `objectID` towards `auxID` is within the STATIC scope (the cycle apart:
    /// @see `sendStatus`).
    func canRouteSend(from objectID: UUID, to auxID: UUID) -> Bool {
        if Self.sendsLegacy { return legacyCanRouteSend(from: objectID, to: auxID) }
        return sendScopeIndex.staticRefusal(sender: objectID, aux: auxID) == nil
    }

    /// The rule as it stood before the rework (OBJ_SENDS_LEGACY=1 only).
    private func legacyCanRouteSend(from objectID: UUID, to auxID: UUID) -> Bool {
        guard objectID != auxID,
              let sender = find(id: objectID), !sender.isAux,
              let aux = find(id: auxID), aux.isAux
        else { return false }

        let senderGroup = parentGroup(for: objectID)
        guard senderGroup?.id == parentGroup(for: auxID)?.id else { return false }
        guard senderGroup == nil else { return true }
        let auxStem = aux.stemID ?? mainStemID
        return auxStem == mainStemID || auxStem == (sender.stemID ?? mainStemID)
    }

    /// What the bridge says about the send `objectID` → `auxID`: `off` (not alive), `active` (the plan
    /// lays it) or `refused` with why — the static rules from the model right now, the scheduling
    /// loop from the last sync's plan (or `status`, a reading computed by `sendStatusNow()`).
    func sendStatus(from objectID: UUID, to auxID: UUID,
                    using status: [SendKey: BridgeScope.Refusal]? = nil) -> SendStatus {
        guard let obj = find(id: objectID),
              let send = obj.sends.first(where: { $0.auxID == auxID }),
              isSendAlive(send, on: obj) else { return .off }
        if Self.sendsLegacy { return legacyCanRouteSend(from: objectID, to: auxID) ? .active : .refused(.outOfStem) }
        if let why = sendScopeIndex.staticRefusal(sender: objectID, aux: auxID) { return .refused(why) }
        if let why = (status ?? sendRouteStatus)[SendKey(sender: objectID, aux: auxID)] { return .refused(why) }
        return .active
    }

    /// The reasons the bridge would refuse a send from `sender` towards each of `auxIDs` — the static
    /// rules AND a scheduling loop with the keys already laid — as if it were appended last (an alive
    /// send to the same aux answers nil unless it IS the loop). One construction of the plan's graphs
    /// for the lot. Only the refused ones have an entry. Empty on the legacy path.
    func sendRefusals(from sender: UUID, among auxIDs: Set<UUID>) -> [UUID: BridgeScope.Refusal] {
        guard !Self.sendsLegacy, !auxIDs.isEmpty else { return [:] }
        let topology = bridgeTopology()
        var out: [UUID: BridgeScope.Refusal] = [:]
        for entry in BridgeScope.sendCandidates(sender: sender, nodes: topology.nodes, routes: topology.routes,
                                                among: auxIDs) {
            if let why = entry.refusal { out[entry.id] = why }
        }
        return out
    }

    /// Would a send from `objectID` towards `auxID` be refused if it were created now? nil = no. A send
    /// that is already alive is never "created": it is accepted or refused by the plan, and says so
    /// in `sendStatus`. What the doors of the HAND ask before laying a NEW send (Q-U10).
    func sendCreationRefusal(from objectID: UUID, to auxID: UUID) -> BridgeScope.Refusal? {
        if Self.sendsLegacy { return legacyCanRouteSend(from: objectID, to: auxID) ? nil : .outOfStem }
        if let why = sendScopeIndex.staticRefusal(sender: objectID, aux: auxID) { return why }
        if let obj = find(id: objectID), let send = obj.sends.first(where: { $0.auxID == auxID }),
           isSendAlive(send, on: obj) { return nil }
        return sendRefusals(from: objectID, among: [auxID])[auxID]
    }

    /// The hand's check before it LAYS a send (Q-U10): true = go ahead. A refused creation beeps (at
    /// most every half second: a drag asks on every frame) and the model is left untouched; the reason
    /// is what the greyed row says (`SendRow.refusal`, the signal view's tooltip).
    @discardableResult
    func handMayCreateSend(from objectID: UUID, to auxID: UUID) -> Bool {
        guard sendCreationRefusal(from: objectID, to: auxID) != nil else { return true }
        let now = CFAbsoluteTimeGetCurrent()
        if now - lastSendRefusalBeep > 0.5 { NSSound.beep(); lastSendRefusalBeep = now }
        return false
    }

    /// The offer's order (Q-U3): the auxes of the sender's own group first, then the other auxes of its
    /// stem, then those of the Main. @see `BridgeScope.SendIndex.offerTier`.
    private func stableByOfferTier(_ auxes: [SoundObject], sender: SoundObject) -> [SoundObject] {
        guard !Self.sendsLegacy, auxes.count > 1 else { return auxes }
        let index = sendScopeIndex
        var keyed: [(tier: Int, offset: Int, aux: SoundObject)] = []
        keyed.reserveCapacity(auxes.count)
        for (offset, aux) in auxes.enumerated() {
            keyed.append((tier: index.offerTier(sender: sender.id, aux: aux.id), offset: offset, aux: aux))
        }
        keyed.sort { l, r in
            if l.tier != r.tier { return l.tier < r.tier }
            return l.offset < r.offset
        }
        return keyed.map { $0.aux }
    }

    /// The auxes whose window overlaps the object `objectID` in time AND that are within its
    /// scope — they are the only ones a send makes sense towards (the toggle is shown
    /// only for them). @see canRouteSend
    func overlappingAuxes(for objectID: UUID) -> [SoundObject] {
        guard let obj = find(id: objectID) else { return [] }
        return sendScope(forSenders: [obj])[objectID] ?? []
    }

    /// `overlappingAuxes(for:)` for MANY senders at once: per sender, the auxes whose window
    /// overlaps it in time AND that are within its scope (@see `canRouteSend`), ordered by START
    /// (ties by position in `allAuxes`, which is the project's own order). A sender with nothing to
    /// send to has no entry, and neither has an aux (a send has no meaning FROM an aux).
    ///
    /// The cost is the point, the same as `sendToolAuxes(forObjects:)` and for the same reasons:
    /// asked sender by sender it was O(K·A·N) — every pair paid a `find` and two `parentGroup`
    /// walks of the whole tree — which froze the inspector for 38 s on a 178-object selection of a
    /// 4 000-object project. Here the auxes are collected and sorted ONCE, the parents come from
    /// the cached `parentIDMap()`, and a pair costs a couple of comparisons.
    func sendScope(forSenders senders: [SoundObject]) -> [UUID: [SoundObject]] {
        let auxes = allAuxes
        guard !auxes.isEmpty else { return [:] }
        // By start, stably: the position in `allAuxes` settles a tie, which a bare `sorted` would
        // leave to chance.
        let ordered = auxes.enumerated().sorted { l, r in
            if l.element.startTime != r.element.startTime { return l.element.startTime < r.element.startTime }
            return l.offset < r.offset
        }.map(\.element)
        return reachableAuxes(forSenders: senders, ordered: ordered)
    }

    /// The scope test shared by `sendScope` and `sendToolAuxes(forObjects:)`: for each sender, the
    /// auxes of `ordered` it can reach (time overlap AND scope), in that order but grouped by offer
    /// tier (@see `stableByOfferTier`). @see `canRouteSend`, of which this is the batch form — the
    /// equivalence is asserted by `debug.selection_send_scope`.
    private func reachableAuxes(forSenders senders: [SoundObject], ordered: [SoundObject]) -> [UUID: [SoundObject]] {
        let senders = senders.filter { !$0.isAux }
        guard !senders.isEmpty, !ordered.isEmpty else { return [:] }
        let legacy = Self.sendsLegacy
        let parents = legacy ? parentIDMap() : [:]
        let mainID = mainStemID
        let index = sendScopeIndex
        var result: [UUID: [SoundObject]] = [:]
        for s in senders {
            let oStart = s.startTime
            let oEnd = s.startTime + s.duration
            let sParent = parents[s.id]
            let sStem = s.stemID ?? mainID
            let reachable = ordered.filter { aux in
                guard aux.id != s.id else { return false }
                if legacy {
                    guard parents[aux.id] == sParent else { return false }
                    if sParent == nil {
                        let auxStem = aux.stemID ?? mainID
                        guard auxStem == mainID || auxStem == sStem else { return false }
                    }
                } else {
                    guard index.staticRefusal(sender: s.id, aux: aux.id) == nil else { return false }
                }
                // An infinite aux: a bus always active → it overlaps any sender.
                if aux.isInfiniteBus { return true }
                return aux.startTime < oEnd && (aux.startTime + aux.duration) > oStart
            }
            if !reachable.isEmpty { result[s.id] = stableByOfferTier(reachable, sender: s) }
        }
        return result
    }

    /// The auxes overlapping the object, ordered by vertical position (display lane) top → bottom.
    /// That is the order of the Send tool's knob rows.
    func sendToolAuxes(for objectID: UUID) -> [SoundObject] {
        guard let obj = find(id: objectID) else { return [] }
        return sendToolAuxes(forObjects: [obj])[objectID] ?? []
    }

    /// `sendToolAuxes(for:)` for MANY senders at once — what the timeline asks for every block it
    /// shows under the Send tool, once per pass. Per sender the answer is the same as
    /// `overlappingAuxes(for:)` (overlap in time AND scope, @see `canRouteSend`), in the Send
    /// tool's order: display lane, then start, then the project's own order.
    ///
    /// The cost is the point. Asked sender by sender this was O(V·A·N): every pair paid a `find` and
    /// a `parentGroup` walk of the whole tree, and every sort looked its lanes up in `laneEntries`
    /// by scanning. Here the auxes are collected and sorted ONCE, the lanes come from one
    /// dictionary, the parents from one `parentIDMap()`, the main stem is read once, and a pair
    /// costs a couple of comparisons. Senders with nothing to send to have no entry in the answer.
    func sendToolAuxes(forObjects senders: [SoundObject]) -> [UUID: [SoundObject]] {
        let senders = senders.filter { !$0.isAux }
        guard !senders.isEmpty else { return [:] }
        let auxes = allAuxes
        guard !auxes.isEmpty else { return [:] }

        // The Send tool's order, once for everybody: top → bottom by display lane (the model's own
        // lane for an aux that is not on screen — it sits in a closed group, where no sender
        // that matters sees it), ties by start, then by position in `allAuxes`. This is what the
        // sort by start followed by the (stable) sort by lane gave, as one key.
        var laneOf: [UUID: Int] = [:]
        for e in laneEntries where e.item.isAux { laneOf[e.item.id] = e.displayLane }
        let ordered = auxes.enumerated().sorted { l, r in
            let ll = laneOf[l.element.id] ?? l.element.lane
            let rl = laneOf[r.element.id] ?? r.element.lane
            if ll != rl { return ll < rl }
            if l.element.startTime != r.element.startTime { return l.element.startTime < r.element.startTime }
            return l.offset < r.offset
        }.map(\.element)

        return reachableAuxes(forSenders: senders, ordered: ordered)
    }

    /// The send-knob rows for the Send tool's overlay on `objectID`.
    func sendRows(for objectID: UUID) -> [SendRow] {
        guard let obj = find(id: objectID) else { return [] }
        return sendRows(forObjects: [obj])[objectID] ?? []
    }

    /// The rows for MANY senders at once (@see `sendToolAuxes(forObjects:)`): the timeline computes
    /// them ONCE per pass for the blocks it shows, and both the partition (which blocks have
    /// columns) and the drawing (the columns themselves) read that one answer. A sender with no row
    /// has no entry.
    func sendRows(forObjects senders: [SoundObject]) -> [UUID: [SendRow]] {
        let auxesBySender = sendToolAuxes(forObjects: senders)
        guard !auxesBySender.isEmpty else { return [:] }
        let focus = sendToolFocus
        var labels: [UUID: String] = [:]
        var result: [UUID: [SendRow]] = [:]
        for s in senders {
            guard let auxes = auxesBySender[s.id] else { continue }
            var rows: [SendRow] = []
            rows.reserveCapacity(auxes.count)
            for aux in auxes {
                let label: String
                if let known = labels[aux.id] { label = known }
                else {
                    label = aux.label ?? L("aux.defaultLabel", Int(aux.startTime.rounded()))
                    labels[aux.id] = label
                }
                let e = s.sends.first { $0.auxID == aux.id }
                rows.append(SendRow(
                    auxID:   aux.id,
                    label:   label,
                    level:   e?.levelDb ?? sendMinDb,
                    enabled: e?.enabled ?? false,
                    focused: focus == SendFocus(objectID: s.id, auxID: aux.id),
                    automated: isAutomated(.send(auxID: aux.id), on: s),
                    refusal: Self.sendsLegacy ? nil : sendRouteStatus[SendKey(sender: s.id, aux: aux.id)]))
            }
            result[s.id] = rows
        }
        return result
    }

    // MARK: - Multi-selection sends
    //
    // "Send to all": a setting on the selection touches every selected (non-aux) object
    // that overlaps the target aux. If their levels differ, the edit is
    // relative (it preserves the gaps), like Volume/Pan. Objects with no send (-∞) are
    // included: a send is created/enabled on them as soon as the level goes above -∞.

    /// The auxes overlapping AT LEAST one selected (non-aux) object, de-duplicated and ordered
    /// by display lane, top→bottom. These are the rows of the inspector's "Sends" column
    /// in a multiple selection. Read off the cached `multiSelectionSnapshot` — ONE batch for the
    /// whole selection (@see `sendScope(forSenders:)`), where it used to be one scope per sender.
    func selectionSendAuxes() -> [SoundObject] {
        multiSelectionSnapshot.sendAuxes
    }

    /// The selected (non-aux) objects that overlap `auxID` → the targets of a send towards that aux.
    func selectedSenders(toAux auxID: UUID) -> [UUID] {
        multiSelectionSnapshot.sendersByAux[auxID]?.map(\.id) ?? []
    }

    /// The same list, minus those whose send towards that aux carries a CURVE.
    ///
    /// A curve is the authority and the static value is no longer heard (@see
    /// EditViewModel+AutomationEngine, the whole doctrine): a hand that went on lowering a send
    /// under automation would be turning a knob that changes nothing — the exact fault
    /// `automationLocked` greys the signal view out to avoid, and which the timeline's own doors
    /// were not applying. It belongs HERE, at the selection-level setters, because those are the
    /// hand's doors and nothing else calls them; `setSendLevel(from:to:)` stays exact, being the
    /// machine's door (`object.set_send_level`) and the one the automation writes its own static
    /// value through. Same split as `updatePan` / `setPanFromHand`.
    ///
    /// The on/off SWITCH is deliberately left alone: cutting a send is an explicit intention of
    /// silence and keeps the last word over any curve (@see syncSendEngine).
    func selectedSendersWithFreeLevel(toAux auxID: UUID) -> [UUID] {
        selectedSenders(toAux: auxID).filter { !isAutomated(.send(auxID: auxID), on: $0) }
    }

    /// A relative nudge of the send level towards `auxID` over the whole selection (preserves the gaps).
    func adjustSendLevelSelected(toAux auxID: UUID, deltaDb: Float) {
        for id in selectedSendersWithFreeLevel(toAux: auxID) where handMayCreateSend(from: id, to: auxID) {
            setSendLevel(from: id, to: auxID, levelDb: sendLevel(from: id, to: auxID) + deltaDb)
        }
        isDirty = true
    }

    /// Sets one identical absolute level towards `auxID` over the whole selection.
    func setSendLevelSelected(toAux auxID: UUID, levelDb: Float) {
        for id in selectedSendersWithFreeLevel(toAux: auxID) where handMayCreateSend(from: id, to: auxID) {
            setSendLevel(from: id, to: auxID, levelDb: levelDb)
        }
        isDirty = true
    }

    /// Turns the send towards `auxID` on/off over the whole selection.
    func setSendEnabledSelected(toAux auxID: UUID, enabled: Bool) {
        for id in selectedSenders(toAux: auxID) where !enabled || handMayCreateSend(from: id, to: auxID) {
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

    /// True if the send is effectively routed: alive AND accepted by the plan (@see `sendStatus`). On
    /// the legacy path (OBJ_SENDS_LEGACY=1) it is what it always was: enabled && level > -∞.
    func isSendRouted(from objectID: UUID, to auxID: UUID) -> Bool {
        if Self.sendsLegacy { return sendEntry(from: objectID, to: auxID)?.isRouted ?? false }
        return sendStatus(from: objectID, to: auxID) == .active
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

    /// The door a HAND comes in by when it drags a send level with no box to type in — the Send
    /// tool's knob in the timeline. The level lands on the WHOLE dB, which is the step the
    /// inspector's own box has always used and the one `ParamRef.valueStep` declares for a send
    /// curve: the knob was the only one of the three laying down 3.47 dB. Unconditional, like the
    /// pan's detent (@see EditViewModel+Pan) and for the same reason — the grid is about time, and
    /// a level has nothing to place itself against.
    ///
    /// It may only be called by a gesture working from an ANCHOR and handing over its TOTAL
    /// travel: rounding a value that is then read back and added to again throws the travel away
    /// on every frame and the knob never moves (@see EditViewModel+Pan, which paid for that once).
    /// Which is why `adjustSendLevelSelected` does NOT go through it — it reads the stored value
    /// and adds, and its callers already hand over whole steps.
    func setSendLevelFromHand(from objectID: UUID, to auxID: UUID, levelDb: Float) {
        guard handMayCreateSend(from: objectID, to: auxID) else { return }
        setSendLevel(from: objectID, to: auxID, levelDb: levelDb.rounded())
    }

    /// Sets the send level (clamped -∞…+sendMaxDb) with auto enabling/disabling
    /// at the extremes. Creates the entry on the fly if it is raised above -∞.
    /// EXACT, and it stays so: it is the machine's door (`object.set_send_level`) and the one an
    /// automation writes its own static value through.
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

    /// Deletes the send entry `objectID` → `auxID` and the automation lane aimed at it. The engine side
    /// follows by itself: the bridge sync (or `removeSend` on the legacy path) takes the plugin away.
    func removeSend(from objectID: UUID, to auxID: UUID) {
        update(id: objectID) { obj in
            obj.sends.removeAll { $0.auxID == auxID }
            obj.automation.removeAll { $0.param == .send(auxID: auxID) }
            obj.automationTouchOrder.removeAll { $0 == .send(auxID: auxID) }
        }
        syncSendEngine(objectID: objectID, auxID: auxID)
        isDirty = true
    }

    /// Reconciles a send's engine state with the model (idempotent).
    ///
    /// ALIVE = enabled AND (not at -∞ OR driven by a curve). The old `isRouted` (enabled AND level >
    /// -∞) was enough as long as a send had only a static level; a level CURVE needs the send plugin to
    /// write itself into, even if the static level has stayed at -∞ (that is even the normal case: the
    /// curve is laid on a send that has never been raised by hand). The switch keeps the last word:
    /// cutting it is an explicit intention of silence.
    ///
    /// On the bridge, a send that is ALREADY laid and stays alive only changes its level: that is the
    /// knob's per-frame path, hot, no plan and no rebuild. Anything else — a send born, cut, or whose
    /// curve appeared or went — changes the topology: the coalesced bridge sync lays or removes it.
    func syncSendEngine(objectID: UUID, auxID: UUID) {
        let s = sendEntry(from: objectID, to: auxID)
        let alive = (s?.enabled ?? false)
            && (!(s?.isSilent ?? true) || isAutomated(.send(auxID: auxID), on: objectID))

        if Self.sendsLegacy {
            if let s, alive, canRouteSend(from: objectID, to: auxID) {
                engine?.addSend(objectID.uuidString, toAux: auxID.uuidString, levelDb: s.levelDb)
            } else {
                engine?.removeSend(objectID.uuidString, toAux: auxID.uuidString)
            }
            return
        }

        let laid = bridgeLaidSends.contains(SendKey(sender: objectID, aux: auxID))
        if let s, alive, laid {
            engine?.setSendLevel(objectID.uuidString, toAux: auxID.uuidString, levelDb: s.levelDb)
        } else if alive || laid {
            scheduleBridgeSync()
        }
    }

    /// Reconciles EVERY send in the project with the engine, both ways. To be called after a full
    /// rebuild (load / undo-redo), where a sender can be synced before the target aux, and after any
    /// change of group membership or stem, which can tip a send's scope either way. Idempotent.
    func resyncAllSends() {
        if Self.sendsLegacy {
            func walk(_ arr: [SoundObject]) {
                for o in arr {
                    for s in o.sends { syncSendEngine(objectID: o.id, auxID: s.auxID) }
                    if case .group(let children, _) = o.kind { walk(children) }
                }
            }
            walk(items)
            // A rewired send is a BRAND-NEW plugin: its curve has gone back to nothing on the engine
            // side. And since this pass is the meeting point of everything that reshapes the topology
            // (loading, undo, composing/dissolving a group, changing stem, pasting), it is the right
            // place to push the rest of the project's curves again as well.
            pushAllAutomation()
            syncBridge()
            return
        }
        // On the bridge the sends are part of the plan: ONE sync lays the keys AND the sends, and
        // only then are the curves pushed — a send laid by this sync is a brand-new plugin, so the
        // order is the reverse of the legacy walk's (which had run `addSend` before).
        syncBridge(pushingAutomation: false)
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
