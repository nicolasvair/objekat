import Foundation

// The signal view's reading of a send (INC 2, docs/plan_sends_rework.md §D.1.A.j): the model's
// `SendPosition` <-> the layout's `SynopticSendSlot`, and the one line a greyed card says.

extension EditViewModel {

    /// The slot a send hangs at in the layout. A send with no reading (the object has none) falls back
    /// to the default, post-fader.
    static func synopticSlot(_ position: SendPosition?) -> SynopticSendSlot {
        switch position {
        case .input:         return .input
        case .chain(let i):  return .chain(i)
        case .preFader:      return .preFader
        case .postFader, .none: return .postFader
        }
    }

    /// The model's position for a slot (the inverse of `synopticSlot`).
    static func sendPosition(of slot: SynopticSendSlot) -> SendPosition {
        switch slot {
        case .input:         return .input
        case .chain(let i):  return .chain(i)
        case .preFader:      return .preFader
        case .postFader:     return .postFader
        }
    }

    /// Why the card of the send `objectID` -> `auxID` is greyed, for a person; nil = the send is
    /// accepted. The scope's and the plan's refusals (a scheduling loop included, "as if appended last"),
    /// then Q-U15: the aux no longer overlaps the object in time — the card stays, the reason is said.
    func sendCardRefusalText(from objectID: UUID, to auxID: UUID) -> String? {
        if let why = sendRefusals(from: objectID, among: [auxID])[auxID] {
            return Self.sendReasonText(why)
        }
        if case .refused(let why) = sendStatus(from: objectID, to: auxID) {
            return Self.sendReasonText(why)
        }
        let reachable = sendToolAuxes(for: objectID)
        if !reachable.contains(where: { $0.id == auxID }) { return L("synoptic.send.noOverlap") }
        return nil
    }
}

extension SynopticSendSlot {

    /// A few letters, for a received row of an aux (nil for the usual post-fader).
    var shortLabel: String? {
        switch self {
        case .input:     return L("synoptic.send.pos.short.input")
        case .chain:     return L("synoptic.send.pos.short.chain")
        case .preFader:  return L("synoptic.send.pos.short.preFader")
        case .postFader: return nil
        }
    }

    /// The position in words (a tooltip).
    var longLabel: String {
        switch self {
        case .input:        return L("synoptic.send.pos.input")
        case .chain(let i): return L("synoptic.send.pos.chain", i + 1)
        case .preFader:     return L("synoptic.send.pos.preFader")
        case .postFader:    return L("synoptic.send.pos.postFader")
        }
    }
}
