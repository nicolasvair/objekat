import AppKit

// Sends that tap inside a chain, at the moment the chain is baked (docs/plan_sends_rework.md §A.i,
// Q-U6). The rule and the model transformation are `SendBakePolicy` (pure); this is the view-model's
// side: the question, the write, the engine.
//
// Hooked at the ENTRY of every operation that bakes an object: `consolidate(groupID:)`,
// `consolidateWrappingClip`, `consolidateEachInSelection`, `consolidateSelectionAsLinkedInstances`.
// It runs BEFORE the first mutation of the operation, so a "Cancel" leaves the project untouched, and
// the existing bake path is otherwise unchanged.

extension EditViewModel {

    /// The concerned sends of these objects (top level of each: the children of a baked group are
    /// baked inside, with their own sends — unchanged from INC 1).
    func midChainSends(of ids: [UUID]) -> [SendBakePolicy.Concerned] {
        var seen = Set<UUID>()
        let objects = ids.filter { seen.insert($0).inserted }.compactMap { find(id: $0) }
        return SendBakePolicy.concerned(in: objects)
    }

    /// Settles the concerned sends of `ids` before they are baked. True if the operation may go on:
    /// nothing was concerned, or the choice was applied. False if the operation must NOT start
    /// (refused, cancelled, or no way to ask) — nothing has been changed then.
    ///
    ///   • `choice == nil` is the hand's path: an alert offers Fold / Delete / Cancel. Without an
    ///     interface or under an automatic dialogue policy nobody can answer, and both other choices
    ///     change what is heard without anyone having seen it: it is a refusal, journalled.
    ///   • an explicit choice is the API's (`mid_chain_sends`); `refuse` leaves everything as it is.
    ///
    /// The change is ONE undo point taken before it (the convention), distinct from the bake's own,
    /// which is pushed when the render lands.
    @discardableResult
    func resolveMidChainSends(for ids: [UUID], choice: SendBakePolicy.Choice? = nil) -> Bool {
        let concerned = midChainSends(of: ids)
        guard !concerned.isEmpty else { return true }

        let decided: SendBakePolicy.Choice
        if let choice {
            decided = choice
        } else if let asked = askMidChainSends(concerned) {
            decided = asked
        } else {
            return false
        }
        guard decided != .refuse else {
            NSLog("[BAKE] refused: %d send(s) tap inside the chain (mid_chain_sends = refuse)", concerned.count)
            return false
        }

        pushUndo()
        let owners = Array(Set(concerned.map(\.objectID)))
        for id in owners {
            let hadMarker = find(id: id).map { o in
                ObjectPlugin.containsSendMarker(in: o.plugins) { _ in true }
            } ?? false
            update(id: id) { $0 = SendBakePolicy.resolve($0, choice: decided) }
            if hadMarker { recompileForSendMarker(id) }
        }
        for c in concerned { syncSendEngine(objectID: c.objectID, auxID: c.auxID) }
        scheduleBridgeSync()
        isDirty = true
        return true
    }

    /// The hand's question. nil = cancel (or: nobody can answer).
    private func askMidChainSends(_ concerned: [SendBakePolicy.Concerned]) -> SendBakePolicy.Choice? {
        let maxLines = 8
        let lines = concerned.prefix(maxLines).map { c -> String in
            let aux = find(id: c.auxID)?.displayName ?? "?"
            let at: String
            switch c.position {
            case .input: at = L("sendBake.at.input")
            default:     at = L("sendBake.at.chain")
            }
            return "\u{2022} " + L("sendBake.line", c.objectName, aux, at)
        }
        var shown = lines
        if concerned.count > maxLines { shown.append("\u{2026}") }
        let title = L("sendBake.title")
        let info = L("sendBake.info", shown.joined(separator: "\n"))

        guard dialogPolicy == .ask, hasInterface else {
            recordDialog(title, info, answer: "refused")
            return nil
        }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = info
        alert.alertStyle = .warning
        alert.addButton(withTitle: L("sendBake.fold"))
        alert.addButton(withTitle: L("sendBake.remove"))
        let cancel = alert.addButton(withTitle: L("common.cancel"))
        cancel.keyEquivalent = "\u{1b}"
        switch alert.runModal() {
        case .alertFirstButtonReturn:  return .fold
        case .alertSecondButtonReturn: return .remove
        default:                       return nil
        }
    }
}
