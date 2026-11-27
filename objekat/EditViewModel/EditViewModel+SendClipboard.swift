import Foundation
import AppKit

// MARK: - Selecting, copying, pasting and deleting the SEND CARDS of the signal view
//
// The cards of an object's sends (the line at the foot of each send's column) are selected like the plugin
// cards are: a click, ⌘ to add or remove, ⇧ for a range. They then hold the keyboard — ⌫ deletes them,
// ⌘C copies them, ⌘V pastes the copy onto the objects selected — exactly the claim the plugin cards make
// (@see EditViewModel+PluginSelection), and exclusive with it: a card is a plugin card or a send card, never
// both, which is what keeps every key's meaning single.
//
// WHAT A COPY HOLDS (user decision of 27 November 2026): the send's level, its switch, its POSITION (post /
// pre-fader, input, or a marker in the chain), the plugins of its mini-chain (a deep copy, with the state read
// off the live instances) AND the curve of its level. Nothing else: the automation of the mini-chain's plugins
// stays behind.
//
// WHAT A PASTE DOES: onto every object selected, each send of the clipboard is laid towards its aux; an
// object that already sends to that aux has that send OVERWRITTEN (the position, the plugins, the curve go
// with it — nothing of the old send is kept). A target the plan refuses (@see sendCreationRefusal, and the
// mini-chain's capacity) is ignored, and so is an aux the project does not hold (a paste into another tab).
// ONE undo point for the whole paste, taken only if something is really laid.
//
// There is NO ⌘X (a send is deleted, not moved) and none of this exists in the timeline's Send tool, where
// ⌫ means "back to -∞" (@see resetSelectedObjectsSends).

/// ONE send, as the clipboard holds it.
struct SendClipboardEntry {
    /// The send's fields by value: aux, level, switch, and a mini-chain that is only a TEMPLATE (ids that
    /// no object holds; every paste gives its own copy fresh ones).
    var send: AuxSend
    /// Where it takes its signal (`chain(i)` stands for the marker's place).
    var position: SendPosition
    /// The points of the level's curve, in the SENDER's time (nil = the level was not automated).
    var levelCurve: [AutomationPoint]?
}

/// What ⌘C on the cards put aside.
struct SendClipboard {
    /// The object the sends were taken from.
    var sourceObjectID: UUID
    var entries: [SendClipboardEntry]
}

// MARK: - The pure half: laying a copied send on an object

extension SoundObject {

    /// The object with `entry` laid on it, towards `entry.send.auxID`: a send that already goes there is
    /// REPLACED (its entry, its marker, its curves and its plugins' curves go, @see removingSends) and the
    /// new one takes its rank among the sends. The mini-chain's plugins come out under FRESH ids (two
    /// objects never share a plugin id), unlinked (@see SendChain.sanitised). Position and level curve are
    /// laid last. Pure: no engine, no refusal check — the caller has made them.
    func pastingSend(_ entry: SendClipboardEntry) -> SoundObject {
        let aux = entry.send.auxID
        let rank = sends.firstIndex { $0.auxID == aux }
        var o = removingSends([aux])
        var s = entry.send
        s.plugins = SendChain.sanitised(entry.send.plugins.map { p in var q = p; q.id = UUID(); return q })
        s.tap = .postFader                       // `settingSendPosition` writes the real one
        o.sends.insert(s, at: min(rank ?? o.sends.count, o.sends.count))
        o = o.settingSendPosition(auxID: aux, entry.position)
        if let curve = entry.levelCurve, !curve.isEmpty {
            o.automation.append(AutomationLane(param: .send(auxID: aux), points: curve))
            o.automationTouchOrder.append(.send(auxID: aux))
        }
        return o
    }
}

@MainActor
extension EditViewModel {

    // MARK: - The selection

    /// True while the send cards of the signal view hold the keyboard for ⌫ ⌘C ⌘V (and swallow ⌘X, ⌘D).
    /// The claim is the selection itself, like the plugin cards': a sender recorded — even with no card
    /// chosen — is what keeps ⌫ from deleting the OBJECT while the hand is plainly on the cards.
    var sendSurfaceHasKeyboard: Bool { selectedSendSenderID != nil }

    /// Replaces the selection by `auxes`, the sends of `sender`. The plugin selection lets go (the two
    /// are exclusive) and so does the keyboard claim of a value box (@see KeyboardClaim): a click on a
    /// card is a click elsewhere than its field, and "leaving is validating".
    func setSendSelection(_ auxes: Set<UUID>, sender: UUID) {
        clearPluginSelection()               // also lets go of an older send selection
        selectedSendSenderID = sender
        selectedSendAuxIDs = auxes
    }

    /// A click on a card. Plain = that card alone; ⌘ = toggles it; ⇧ = the range between the cards held
    /// and this one, in `order` (the cards as the signal view lays them, top to bottom). A click on another
    /// object's card always starts afresh.
    func clickSendCard(_ aux: UUID, sender: UUID, flags: NSEvent.ModifierFlags, order: [UUID]) {
        KeyboardClaim.shared.revoke()
        let held = selectedSendSenderID == sender ? selectedSendAuxIDs : []
        if flags.contains(.command) {
            var next = held
            if next.contains(aux) { next.remove(aux) } else { next.insert(aux) }
            setSendSelection(next, sender: sender)
        } else if flags.contains(.shift), let clicked = order.firstIndex(of: aux), !held.isEmpty {
            let marked = order.indices.filter { held.contains(order[$0]) } + [clicked]
            let range = (marked.min() ?? clicked)...(marked.max() ?? clicked)
            setSendSelection(Set(order[range]), sender: sender)
        } else {
            setSendSelection([aux], sender: sender)
        }
    }

    /// Gives the keyboard back to the timeline (the same doors as `clearPluginSelection`, which calls this).
    func clearSendSelection() {
        guard selectedSendSenderID != nil || !selectedSendAuxIDs.isEmpty else { return }
        selectedSendAuxIDs = []
        selectedSendSenderID = nil
    }

    /// The cards selected that still exist, in the ORDER OF THE SENDER's sends (the order a copy keeps).
    /// Empty if the sender has gone or nothing is selected.
    func orderedSelectedSendAuxIDs() -> [UUID] {
        guard let sender = selectedSendSenderID, !selectedSendAuxIDs.isEmpty,
              let o = find(id: sender), !o.isAux else { return [] }
        return o.sends.map(\.auxID).filter { selectedSendAuxIDs.contains($0) }
    }

    // MARK: - ⌫ — deleting the selection

    /// Deletes every selected send in ONE undo step (entry, marker, level curve, plugins and their curves,
    /// as the card's ✕ does one by one), then gives the keyboard back. Returns how many went.
    @discardableResult
    func removeSelectedSends() -> Int {
        guard let sender = selectedSendSenderID else { return 0 }
        let auxes = orderedSelectedSendAuxIDs()
        guard !auxes.isEmpty else { return 0 }
        pushUndo()
        for aux in auxes { removeSend(from: sender, to: aux) }
        clearSendSelection()
        isDirty = true
        return auxes.count
    }

    // MARK: - ⌘C

    /// Puts the selected sends aside, with the mini-chains' live states and the levels' curves. A copy
    /// that holds nothing (no card chosen) leaves the previous clipboard alone. Returns how many were taken.
    @discardableResult
    func copySelectedSends() -> Int {
        guard let sender = selectedSendSenderID, let object = find(id: sender), !object.isAux else { return 0 }
        let auxes = orderedSelectedSendAuxIDs()
        guard !auxes.isEmpty else { return 0 }
        // The plugins as templates under fresh ids, with the state read back off the live instances
        // (@see copiedSends: the same capture the duplication of an object makes).
        let templates = copiedSends(of: object)
        var entries: [SendClipboardEntry] = []
        for aux in auxes {
            guard let send = templates.first(where: { $0.auxID == aux }),
                  let position = object.sendPosition(auxID: aux) else { continue }
            let curve = object.automation.first { $0.param == .send(auxID: aux) }?.points
            entries.append(SendClipboardEntry(send: send, position: position,
                                              levelCurve: (curve?.isEmpty ?? true) ? nil : curve))
        }
        guard !entries.isEmpty else { return 0 }
        sendClipboard = SendClipboard(sourceObjectID: sender, entries: entries)
        sendClipboardIsLive = true
        return entries.count
    }

    // MARK: - ⌘V

    /// What a paste of the clipboard onto `targets` would lay, with the refusals already taken out:
    /// the (object, send) pairs. An aux the project does not hold is skipped (a clipboard from another
    /// tab), so are an aux object, a picture, a send the plan would refuse and a mini-chain too big.
    func sendPasteJobs(onto targets: [UUID]) -> [(target: UUID, entry: SendClipboardEntry)] {
        guard let clip = sendClipboard else { return [] }
        var jobs: [(target: UUID, entry: SendClipboardEntry)] = []
        for id in targets {
            guard let o = find(id: id), !o.isAux, !o.isPicture else { continue }
            for entry in clip.entries {
                let aux = entry.send.auxID
                guard find(id: aux)?.isAux == true else { continue }
                guard sendCreationRefusal(from: id, to: aux) == nil else { continue }
                guard SendChain.refusal(count: 0, adding: entry.send.plugins.count) == nil else { continue }
                jobs.append((id, entry))
            }
        }
        return jobs
    }

    /// ⌘V: lays the clipboard's sends onto every object selected (@see the file's header). Returns how
    /// many sends were laid, over all the targets; beeps when none could be.
    @discardableResult
    func pasteSendsOntoSelection() -> Int {
        pasteSends(onto: allObjectsFlat.map(\.id).filter { selectedIDs.contains($0) })
    }

    /// The same paste, onto the objects named (the machine's door: `send.paste`).
    @discardableResult
    func pasteSends(onto targets: [UUID]) -> Int {
        let jobs = sendPasteJobs(onto: targets)
        guard !jobs.isEmpty else { NSSound.beep(); return 0 }
        pushUndo()
        for job in jobs { layPastedSend(job.entry, on: job.target) }
        isDirty = true
        return jobs.count
    }

    /// One send laid on one object: the model write (pure, @see SoundObject.pastingSend), then the engine
    /// — the mini-chain compiled with its sender, the level's curve pushed, the send laid by the bridge.
    private func layPastedSend(_ entry: SendClipboardEntry, on objectID: UUID) {
        guard let before = find(id: objectID) else { return }
        let aux = entry.send.auxID
        let old = before.sends.first { $0.auxID == aux }
        let markerInvolved: Bool = {
            if case .chain? = before.sendPosition(auxID: aux) { return true }
            if case .chain = entry.position { return true }
            return false
        }()
        // What the overwritten send leaves behind: its plugins' touch watches, what was known of their
        // parameters, and the selection of their box.
        if old != nil { forgetSendPlugins(sender: objectID, aux: aux) }
        update(id: objectID) { $0 = $0.pastingSend(entry) }

        let carries = !entry.send.plugins.isEmpty
        let carried = !(old?.plugins.isEmpty ?? true)
        if carries || carried { compileRack(objectID: objectID) }
        else if markerInvolved { recompileForSendMarker(objectID) }
        if let now = find(id: objectID) { pushAutomationCurve(.send(auxID: aux), on: now) }
        syncSendEngine(objectID: objectID, auxID: aux)
        scheduleBridgeSync()
    }
}
