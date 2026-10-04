import AppKit

// MARK: - FX link bins whose members do not sound alike: detection, question, repair (F4)
//
// The detection and the plan are `FXLinkDivergence` (pure). Here: reading the states (the file's,
// or the live instances'), the question put to a hand after an opening, and the repair itself.
//
// NEVER a silent repair (the user's rule, 4 October 2026). An opening by a hand asks; a script,
// an automatic dialogue policy or a session with no interface answers "not repaired" and writes
// the question in the journal; the API repairs only on an explicit `fxlink.repair_divergences`.
//
// THE REPAIR is ONE undo step: the snapshot taken before (`pushUndo`, which captures every
// plugin's live state) gives the members their former states back on ⌘Z — the ordinary undo of a
// plugin's state (@see `adoptingPluginStates`). Each target receives the reference's chunk on its
// LIVE instance (`applyPluginStateXML`, re-asserted if the AU is not initialised yet) and in the
// model. Nothing is relayed to the other members: no hand made it (@see the user-origin gate of
// `OBJEngineCore.propagateLinkedParamFromKey`), and they already hold the reference.

extension EditViewModel {

    /// The bins' definitions whose attached members disagree, read off the LIVE instances (what
    /// the project sounds like now) — or, `live: false`, off the model's `stateXML` (what the file
    /// said, as long as nothing has been saved or edited since the load).
    func fxLinkDivergences(live: Bool = true) -> [FXLinkDivergence.Detail] {
        if live { engine?.flushLinkedStateSync() }
        return FXLinkDivergence.details(items: items, stems: stems, fxLinks: fxLinks,
                                        state: live ? { self.fxLiveState(of: $0) } : { $0.stateXML })
    }

    /// Lays the reference's state on the members of `details` that differ from it (and, with
    /// `.majority`, on the definition when it is outside the majority). One undo step; nothing
    /// pushed when there is nothing to do. `live` says which states `details` were read from — the
    /// plan reads the same ones. Returns what was laid.
    @discardableResult
    func repairFXLinkDivergences(_ details: [FXLinkDivergence.Detail],
                                 reference: FXLinkDivergence.Reference,
                                 live: Bool = true) -> [FXLinkDivergence.Fix] {
        let plan = FXLinkDivergence.repairPlan(details, reference: reference, items: items, stems: stems,
                                               fxLinks: fxLinks,
                                               state: live ? { self.fxLiveState(of: $0) } : { $0.stateXML })
        guard !plan.isEmpty else { return [] }
        pushUndo()
        for fix in plan {
            switch fix.target {
            case let .instance(hostID, blockID, instanceID):
                updateChainPlugins(hostID) { chain in
                    chain = Self.updatingBlock(blockID, in: chain) { b in
                        guard var fb = b.fxBlock,
                              let k = fb.plugins.firstIndex(where: { $0.id == instanceID }) else { return }
                        fb.plugins[k].stateXML = fix.stateXML
                        b.fxBlock = fb
                    }
                }
                engine?.applyPluginStateXML(fix.stateXML, forPlugin: instanceID.uuidString,
                                            forObjectID: hostID.uuidString)
            case let .definition(linkID, definitionID):
                guard let i = fxLinkIndex(linkID),
                      let k = fxLinks[i].plugins.firstIndex(where: { $0.id == definitionID }) else { continue }
                fxLinks[i].plugins[k].stateXML = fix.stateXML
            }
        }
        isDirty = true
        NSLog("[FXLINK] divergence repaired (%@): %d state(s) laid on %d bin(s)",
              reference.rawValue, plan.count, details.count)
        return plan
    }

    /// After an opening by a HAND: the bins the file holds at odds with themselves
    /// (`lastProjectLoad.fxLinkDivergences`), put as a question, and repaired if the answer is
    /// "Repair". Nothing at all for a sound file.
    func offerFXLinkDivergenceRepair() {
        guard let details = lastProjectLoad?.fxLinkDivergences, !details.isEmpty else { return }
        guard let reference = askFXLinkDivergenceRepair(details: details, projectName: projectName,
                                                        filePath: lastProjectLoad?.path ?? "")
        else { return }
        // Read off the model: right after the load it IS the file, and the alert described the
        // file. A member whose live state moved since (it should not, @see the user-origin gate)
        // still receives the reference.
        repairFXLinkDivergences(details, reference: reference, live: false)
    }

    // MARK: The question

    /// The lines the alert lists, at most this many (@see `maxPluginIDAlertLines`).
    private static let maxDivergenceAlertLines = 8

    /// The question a file whose FX link members disagree raises when a hand opens it: repair (on
    /// the definition's state, or — the box ticked — on the state most members share), copy a
    /// report, or leave it as it is. nil = not repaired.
    func askFXLinkDivergenceRepair(details: [FXLinkDivergence.Detail], projectName: String,
                                   filePath: String) -> FXLinkDivergence.Reference? {
        let lines = details.map { d -> String in
            let line = L("fxLinkDivergence.line", d.linkName, d.pluginName,
                         d.divergentFromDefinition.count, d.members.count)
            return d.definitionInMajority ? line : line + " " + L("fxLinkDivergence.lineMinority")
        }
        var shown = lines.prefix(Self.maxDivergenceAlertLines).map { "\u{2022} " + $0 }
        if lines.count > Self.maxDivergenceAlertLines {
            let rest = lines.count - Self.maxDivergenceAlertLines
            shown.append(Ln("pluginIDs.duplicate.more", rest, rest))
        }
        let title = L("fxLinkDivergence.title")
        let info = L("fxLinkDivergence.info", projectName, shown.joined(separator: "\n"))

        guard dialogPolicy == .ask, hasInterface else {
            recordDialog(title, info, answer: "not repaired")
            return nil
        }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = info
        alert.alertStyle = .warning
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = L("fxLinkDivergence.useMajority")
        alert.suppressionButton?.state = .off
        alert.addButton(withTitle: L("fxLinkDivergence.repair"))
        alert.addButton(withTitle: L("fxLinkDivergence.copyReport"))
        let dont = alert.addButton(withTitle: L("fxLinkDivergence.dontRepair"))
        dont.keyEquivalent = "\u{1b}"
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return alert.suppressionButton?.state == .on ? .majority : .definition
        case .alertSecondButtonReturn:
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(FXLinkDivergence.report(filePath: filePath, details: details), forType: .string)
            return nil
        default:
            return nil
        }
    }
}
