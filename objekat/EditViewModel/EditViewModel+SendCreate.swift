import AppKit
import SwiftUI

// Making a send from the signal view (INC 2, step 2.11, docs/plan_sends_rework.md §A.j): the "Send to…"
// menu's data, the hand's creation door, "Change target…", and the pick mode on the timeline
// (`RoutePick`, the generalisation of the Sidechain strip's "choose an object").

/// A send being made (or re-aimed) by clicking an aux on the timeline.
struct SendPick: Equatable {
    let sender: UUID
    /// Where the new send will be taken (the slot the menu was opened from).
    let position: SendPosition
    /// non-nil = "Change target…" of this existing send: the click re-aims it instead of making one.
    let retargeting: UUID?
}

/// The timeline's "choose an object" mode, whoever armed it: the key of a plugin (the Sidechain strip)
/// or the target of a send (the signal view's "Send to…").
enum RoutePick: Equatable {
    case sidechain(SidechainPick)
    case send(SendPick)
}

/// Why `retargetSend` did nothing.
enum SendRetargetRefusal: Equatable {
    case noSuchSend, notAnAux, alreadyThere, sameAux
    case refused(BridgeScope.Refusal)

    /// A sentence, for the hand and for the command API.
    var text: String {
        switch self {
        case .noSuchSend:     return L("send.retarget.noSend")
        case .notAnAux:       return L("send.reason.hostNotAux")
        case .alreadyThere:   return L("send.retarget.exists")
        case .sameAux:        return L("send.retarget.same")
        case .refused(let r): return EditViewModel.sendReasonText(r)
        }
    }
}

extension EditViewModel {

    // MARK: - The menu's data

    /// The auxes `sender` can send to, as the "Send to…" menu lists them: those that overlap it in time
    /// within its scope (the Aux tool's offer), with their tier, the plan's refusal worded, and whether
    /// a send to them already exists. `retargeting`: the aux of the send being re-aimed, left out.
    func sendTargetCandidates(for sender: UUID, retargeting: UUID? = nil) -> [SendTargetMenu.Candidate] {
        guard let obj = find(id: sender), !obj.isAux else { return [] }
        let auxes = sendToolAuxes(for: sender).filter { $0.id != retargeting }
        let refusals = sendRefusals(from: sender, among: Set(auxes.map(\.id)))
        let existing = Set(obj.sends.map(\.auxID))
        let index = sendScopeIndex
        return auxes.map { aux in
            SendTargetMenu.Candidate(id: aux.id, name: aux.displayName,
                                     tier: index.offerTier(sender: sender, aux: aux.id),
                                     refusal: refusals[aux.id].map { Self.sendReasonText($0) },
                                     alreadySending: existing.contains(aux.id))
        }
    }

    /// The menu's sections for `sender` (@see SendTargetMenu).
    func sendTargetSections(for sender: UUID, retargeting: UUID? = nil) -> [SendTargetMenu.Section] {
        SendTargetMenu.sections(sendTargetCandidates(for: sender, retargeting: retargeting),
                                alreadySendingReason: L("send.menu.alreadySending"))
    }

    // MARK: - Making a send (the hand)

    /// Creates the send of `sender` towards `aux` at `position`: silent (-inf), on, already where the
    /// hand asked. ONE undo point. An existing send to that aux is moved, not duplicated. A refused
    /// creation beeps and changes nothing (Q-U10).
    @discardableResult
    func createSendFromHand(from sender: UUID, to aux: UUID, at position: SendPosition) -> Bool {
        guard let obj = find(id: sender), !obj.isAux, handMayCreateSend(from: sender, to: aux) else { return false }
        pushUndo()
        if !obj.sends.contains(where: { $0.auxID == aux }) {
            setSendEnabled(from: sender, to: aux, enabled: true)     // a silent entry, -inf
        }
        guard setSendPosition(from: sender, to: aux, position) else { return false }
        return true
    }

    // MARK: - Change target

    /// Re-aims the send of `objectID` towards `old` at `new`: same level, switch, position, marker,
    /// automation lane and touch order. nil = done; otherwise why nothing happened. Takes no undo point:
    /// the command bus (or the hand's door below) owns it.
    @discardableResult
    func retargetSend(from objectID: UUID, aux old: UUID, to new: UUID) -> SendRetargetRefusal? {
        guard let obj = find(id: objectID), !obj.isAux, obj.sends.contains(where: { $0.auxID == old }) else {
            return .noSuchSend
        }
        if old == new { return .sameAux }
        guard find(id: new)?.isAux == true else { return .notAnAux }
        if obj.sends.contains(where: { $0.auxID == new }) { return .alreadyThere }
        if let why = sendScopeIndex.staticRefusal(sender: objectID, aux: new) ?? sendRefusals(from: objectID, among: [new])[new] {
            return .refused(why)
        }
        var hadMarker = false
        if case .chain? = obj.sendPosition(auxID: old) { hadMarker = true }
        // A send that CARRIES plugins is re-keyed IN PLACE in the engine, BEFORE the sync that follows
        // the model: its plugins, their editors and their states stay (no instance re-created). A
        // send without plugins keeps INC 2's path (the sync removes the old one and lays the new).
        let carries = !(obj.sends.first { $0.auxID == old }?.plugins.isEmpty ?? true)
        if carries {
            _ = engine?.retargetBridgeSend(from: objectID.uuidString, oldAux: old.uuidString, newAux: new.uuidString)
            // The plugin selection names the box by a host DERIVED from the pair: it follows.
            if selectedPluginHostID == SendChain.hostID(sender: objectID, aux: old) {
                selectedPluginHostID = SendChain.hostID(sender: objectID, aux: new)
            }
        }
        update(id: objectID) { $0 = $0.retargetingSend(from: old, to: new) }
        if hadMarker { recompileForSendMarker(objectID) }
        syncSendEngine(objectID: objectID, auxID: old)       // the old pair is gone: its tap is torn down
        syncSendEngine(objectID: objectID, auxID: new)
        scheduleBridgeSync()
        isDirty = true
        return nil
    }

    /// The hand's door: an undo point BEFORE the write, popped if nothing moved; beeps on a refusal.
    @discardableResult
    func retargetSendFromHand(from objectID: UUID, aux old: UUID, to new: UUID) -> Bool {
        if old == new { return true }
        pushUndo()
        if retargetSend(from: objectID, aux: old, to: new) != nil {
            _ = undoStack.popLast()          // nothing was written: the point goes with it
            NSSound.beep()
            return false
        }
        return true
    }

    // MARK: - The pick mode

    /// Arms "choose an aux on the timeline" for a send of `sender` taken at `position` (or re-aimed:
    /// `retargeting`). Arming it again for the same thing disarms it.
    func beginSendPick(sender: UUID, position: SendPosition, retargeting: UUID? = nil) {
        let pick = RoutePick.send(SendPick(sender: sender, position: position, retargeting: retargeting))
        if routePick == pick { routePick = nil; return }
        routePick = pick
        if let window = titledWindow ?? NSApp.mainWindow {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        }
    }

    /// Leaves the mode, whoever armed it.
    func endRoutePick() { routePick = nil }

    /// Why the armed pick would refuse `objectID`, as a sentence (nil = it would take it). Read on hover.
    func routePickRefusalText(for objectID: UUID) -> String? {
        switch routePick {
        case .none:
            return nil
        case .sidechain?:
            return sidechainPickRefusal(for: objectID).map { Self.sidechainReasonText($0) }
        case .send(let pick)?:
            guard find(id: objectID)?.isAux == true else { return Self.sendReasonText(.hostNotAux) }
            if let old = pick.retargeting {
                if objectID == old { return nil }                     // already the target: a no-op
                if find(id: pick.sender)?.sends.contains(where: { $0.auxID == objectID }) == true {
                    return L("send.retarget.exists")
                }
                if let why = sendScopeIndex.staticRefusal(sender: pick.sender, aux: objectID)
                    ?? sendRefusals(from: pick.sender, among: [objectID])[objectID] { return Self.sendReasonText(why) }
                return nil
            }
            return sendCreationRefusal(from: pick.sender, to: objectID).map { Self.sendReasonText($0) }
        }
    }

    /// The click of the armed pick on an object, whoever armed it. A refused object leaves the mode armed
    /// (the veil already said why).
    @discardableResult
    func commitRoutePick(objectID: UUID) -> Bool {
        switch routePick {
        case .none:
            return false
        case .sidechain?:
            return commitSidechainPick(objectID: objectID)
        case .send(let pick)?:
            guard routePickRefusalText(for: objectID) == nil else { NSSound.beep(); return false }
            routePick = nil
            if let old = pick.retargeting {
                return retargetSendFromHand(from: pick.sender, aux: old, to: objectID)
            }
            return createSendFromHand(from: pick.sender, to: objectID, at: pick.position)
        }
    }

    /// The HUD's name for what the armed send pick is making a send FOR.
    func sendPickSenderName(_ pick: SendPick) -> String {
        find(id: pick.sender).map { displayName(of: $0) } ?? ""
    }
}
