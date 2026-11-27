import Foundation

// MARK: - The channel width is DECIDED ONCE, when a plugin is inserted (2026-11-27)
//
// An external plugin comes out of its catalogue entry in the width it likes best (a reverb: 1 -> 2, 2 -> 2…).
// What the signal view and the ear want is the width of the signal that ARRIVES at that point of the chain:
//
//   • mono arrives  -> the plugin is put in mono (1 -> 1), never in 1 -> 2 on its own (reverb, imager,
//     delay included): a mono signal stays mono until the hand says otherwise;
//   • stereo arrives -> the plugin is put in stereo (2 -> 2);
//   • a plugin that REFUSES the width keeps its own (a stereo-only plugin on a mono signal: what follows
//     is then counted stereo, by the ordinary width arithmetic — @see SynopticWidthFlow);
//   • a group, an aux, a consolidated object (even one holding a single mono object), a MIDI clip's
//     instrument, a send's mini-chain (its tapped copy is a stereo pair): stereo. A card input's chain
//     follows the input itself: a mono input (one card channel) is mono, a pair is stereo;
//   • a choice of channel (L / R / C) laid on the cable that enters the plugin counts: the signal it
//     receives is mono, so is the plugin;
//   • an FX link: if ONE member of the link is stereo at that point, ALL the linked instances are stereo
//     (`setChannelVariant` moves the whole link group together, and the definition carries the width);
//   • a default preset that carries a width: the width decided here wins;
//   • a bypassed plugin upstream counts as active (the arithmetic never looked at the bypass).
//
// DECIDED ONCE: no continuous recalculation, no persistent "auto" flag, no format change. The width is the
// plugin's own `layout` (its state), saved and undone with it like any manual choice. Nothing already in a
// project moves.
//
// WHEN: an AudioUnit / VST3 instance loads asynchronously, and the engine refuses a width while the instance
// is not loaded. The decision therefore WAITS (a polling task on the main actor, 100 ms, 30 s at most; it
// gives up if the project is reloaded or the plugin goes) and is applied as soon as every instance of the
// group is there. It is part of the insertion's own undo step (no point of its own), and `Quiescence`
// reports it (`insertionWidthsPending`) so a script's `wait_idle` covers it.
//
// DURING PLAYBACK the change is applied at once, with a brief audio cut (the transport stops, the bus is
// changed, the transport resumes at the same position — @see OBJEngineCore), like the Channels menu's and the
// API's own doors since 27 November 2026. Only a RECORDING refuses it.

extension EditViewModel {

    /// Decides the width of the plugin just inserted as `pluginID` on host `host` (and of every instance
    /// linked to it). A built-in / in-house plugin, an instrument or an unknown key: nothing to do.
    func decideWidthAtInsertion(pluginID: UUID, host: UUID) {
        guard engine != nil, let plug = hostedPlugin(pluginID, of: host),
              !plug.isBuiltIn, !plug.isContainer, !isInstrument(pluginID, of: host)
        else { return }
        let token = projectLoadToken
        insertionWidthsPending += 1
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.insertionWidthsPending -= 1 }
            await self.settleInsertionWidth(pluginID: pluginID, host: host, token: token)
        }
    }

    /// The same for a plugin inserted in an FX link's bin: `definitionID` is the DEFINITION's id, every
    /// attached member's instance carries it as `linkGroupID`.
    func decideWidthAtInsertion(definitionID: UUID) {
        guard let anchor = allPluginRefs().first(where: { $0.plugin.linkGroupID == definitionID }) else { return }
        decideWidthAtInsertion(pluginID: anchor.plugin.id,
                               host: chainHost(holding: anchor.plugin.id, on: anchor.objectID))
    }

    // MARK: Waiting for the instances

    private enum InsertionReadiness { case ready, loading, notExternal }

    private func insertionReadiness(_ pluginID: UUID) -> InsertionReadiness {
        guard let d = engine?.pluginChannelInfo(pluginID.uuidString, probeVariants: false),
              (d["external"] as? NSNumber)?.boolValue == true
        else { return .notExternal }
        return (d["loaded"] as? NSNumber)?.boolValue == true ? .ready : .loading
    }

    private func settleInsertionWidth(pluginID: UUID, host: UUID, token: Int) async {
        for _ in 0..<300 {
            guard projectLoadToken == token, hostedPlugin(pluginID, of: host) != nil else { return }
            let members = [(plugin: pluginID, host: host)] + channelGroupPeers(of: pluginID, on: host)
            let states = members.map { insertionReadiness($0.plugin) }
            // Not an external plugin (a built-in, a service plugin): nothing to negotiate.
            if states.first == .notExternal { return }
            if states.allSatisfy({ $0 == .ready || $0 == .notExternal }) {
                applyInsertionWidth(pluginID: pluginID, host: host, members: members)
                return
            }
            try? await Task.compatSleep(.milliseconds(100))
        }
        NSLog("[WIDTH] plugin %@ never finished loading: its width is left as it is", pluginID.uuidString)
    }

    // MARK: Deciding

    /// The width of the signal that arrives at plugin `pluginID` of `host`: stereo for everything that
    /// is not an audio clip's own chain (group, aux, consolidated, MIDI instrument, bus), the file's width
    /// (after its channel choice and the plugins above) for a clip. nil = not measurable here.
    private func incomingWidth(of pluginID: UUID, on host: UUID) -> Int? {
        if let o = find(id: host), o.isGroup || o.isAux || o.isConsolidateInstance { return 2 }
        // A send's mini-chain: the tapped copy is a stereo pair.
        if isSendChainHost(host) { return 2 }
        guard let infos = cableInfos(host: host),
              let info = infos.first(where: { $0.entering == pluginID })
        else { return nil }
        // A choice of channel (L / R / C) laid on the cable that enters the plugin — a pick, or the file's own
        // choice at the head of a stereo clip — makes the signal the plugin receives MONO.
        // (`widthIn` is the width BEFORE that choice; an inherited fold of the plugin itself is not one.)
        if info.widthIn >= 2, info.explicit, !info.inert, info.choice != .stereo,
           info.pickID != nil || info.fileLevel { return 1 }
        return info.widthIn
    }

    private func applyInsertionWidth(pluginID: UUID, host: UUID,
                                     members: [(plugin: UUID, host: UUID)]) {
        var measured = false
        var stereo = false
        for m in members {
            guard let w = incomingWidth(of: m.plugin, on: m.host) else { continue }
            measured = true
            if w >= 2 { stereo = true }
        }
        // Nothing could be measured (a send's mini-chain): the plugin keeps its own width.
        guard measured else { return }
        let outcome = setChannelVariant(stereo ? .stereo : .mono, pluginID: pluginID, host: host,
                                        recordUndo: false)
        Diag.log(.plug, "largeur à l'insertion « \(stereo ? "stéréo" : "mono") » plugin=\(Diag.short(pluginID)) → \(outcome)")
    }
}
