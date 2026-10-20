import Foundation

// The plugins ON a send (INC 3, docs/plan_sends_rework.md §D.2.A.j): a send's mini-chain is the THIRD
// kind of chain host, beside an object and a stem. Its id is DERIVED from the pair (sender, aux) —
// `SendChain.hostID` — and never stored, so every plugin gesture written against a chain host
// (`chainPlugins`, `updateChainPlugins`, the doors, the selection, the `plugin.*` commands) works on
// it without a parallel family of functions.
//
// What a send host is NOT: an object. `find(id:)` does not know it. A site that takes a host and then
// needs the OBJECT (the engine's key, the automation lanes, the undo patch) goes through
// `engineHostKey` / `chainOwnerObjectID`; a site that takes an OBJECT and a plugin id and must write
// the plugin goes through `chainHost(holding:on:)`.

extension EditViewModel {

    /// Derived host id → (sender, aux), for every send of every non-aux object. Lazy, dropped with
    /// `items` (the same pattern as `sendScopeIndexCache`).
    var sendChainHosts: [UUID: SendKey] {
        if let sendChainHostsCache { return sendChainHostsCache }
        var index: [UUID: SendKey] = [:]
        func walk(_ array: [SoundObject]) {
            for o in array {
                if !o.isAux {
                    for send in o.sends {
                        index[SendChain.hostID(sender: o.id, aux: send.auxID)] = SendKey(sender: o.id, aux: send.auxID)
                    }
                }
                if case .group(let children, _) = o.kind { walk(children) }
            }
        }
        walk(items)
        sendChainHostsCache = index
        return index
    }

    /// The send whose mini-chain `hostID` names, or nil (an object, a stem, or nothing).
    func sendChainKey(_ hostID: UUID) -> SendKey? { sendChainHosts[hostID] }

    /// True if `hostID` names a send's mini-chain.
    func isSendChainHost(_ hostID: UUID) -> Bool { sendChainKey(hostID) != nil }

    /// The key the ENGINE knows a chain host by: the SENDER's for a send's mini-chain (its plugins are
    /// keyed instances owned by the sender's chain), the host itself otherwise. Every engine call
    /// `forObjectID:` that receives a chain host passes through here.
    func engineHostKey(_ hostID: UUID) -> UUID { sendChainKey(hostID)?.sender ?? hostID }

    /// The OBJECT a chain host belongs to — the sender for a send's mini-chain, the host itself for an
    /// object; a stem answers itself (it is no object, as before).
    func chainOwnerObjectID(_ hostID: UUID) -> UUID { engineHostKey(hostID) }

    /// The chain host that actually HOLDS the leaf `pluginID`, given what a caller has in hand — an
    /// object id, a stem id or a send host id: the host itself if its own chain holds the plugin,
    /// else (an object) the mini-chain of the send that does. Falls back on `hostID`.
    func chainHost(holding pluginID: UUID, on hostID: UUID) -> UUID {
        if let chain = chainPlugins(hostID), Self.flattenLeaves(chain).contains(where: { $0.id == pluginID }) {
            return hostID
        }
        if let o = find(id: hostID), let aux = SendChain.auxID(holding: pluginID, in: o) {
            return SendChain.hostID(sender: o.id, aux: aux)
        }
        return hostID
    }

    /// What the compile is told about the sends of an object: one entry per send that CARRIES plugins
    /// and that the bridge does not refuse (a refused send has no engine plugin and its mini-chain is
    /// not instantiated — the model keeps the states). `leaf` serialises one plugin.
    func sendChainSpec(sender: UUID, sends: [AuxSend], isAux: Bool,
                       leaf: ([ObjectPlugin]) -> [[String: Any]]) -> [[String: Any]] {
        guard !isAux else { return [] }
        return sends.compactMap { send in
            guard !send.plugins.isEmpty, !sendCarrierIsRefused(sender: sender, aux: send.auxID) else { return nil }
            return ["aux": send.auxID.uuidString, "plugins": leaf(SendChain.sanitised(send.plugins))]
        }
    }

    /// True if the bridge refuses the send (the static scope from the model now; a scheduling loop or
    /// a full chain from the last sync's verdicts).
    func sendCarrierIsRefused(sender: UUID, aux: UUID) -> Bool {
        if sendScopeIndex.staticRefusal(sender: sender, aux: aux) != nil { return true }
        if let why = sendRouteStatus[SendKey(sender: sender, aux: aux)], why != .chainFull { return true }
        return false
    }

    // MARK: - The doors' rules

    /// Why `adding` more plain plugins cannot be laid into `hostID`'s chain — nil for an object, a
    /// stem, or a send's mini-chain that has the room (@see SendChain.refusal).
    func sendChainRefusal(adding: Int, to hostID: UUID, instrument: Bool = false) -> SendChain.Refusal? {
        guard isSendChainHost(hostID), find(id: hostID) == nil else { return nil }
        return SendChain.refusal(count: chainPlugins(hostID)?.count ?? 0, adding: adding, instrument: instrument)
    }

    /// The transfer a drag really performs between two chain hosts: a LINK (⌘) falls back on a plain
    /// COPY as soon as a send's mini-chain is the source or the target — a send's plugin is never
    /// linked, and "copy + link" without the link is a copy. The ONE definition: the drop's banner
    /// reads it too, so that it never shows the link's glyph over a gesture that will not link.
    func effectiveTransferMode(_ mode: PluginTransferMode, from source: UUID?, to target: UUID) -> PluginTransferMode {
        guard mode == .link else { return mode }
        if isSendChainHost(target) && find(id: target) == nil { return .copy }
        if let source, isSendChainHost(source), find(id: source) == nil { return .copy }
        return mode
    }

    /// What a send's plugins leave behind when the send goes: their touch watches, what was known
    /// of their parameters, and the plugin selection if it was that send's box.
    func forgetSendPlugins(sender: UUID, aux: UUID) {
        for p in sendEntry(from: sender, to: aux)?.plugins ?? [] {
            endPluginParamTouchWatch(p.id)
            invalidatePluginParamInfos(p.id)
        }
        if selectedPluginHostID == SendChain.hostID(sender: sender, aux: aux) { clearPluginSelection() }
    }

    // MARK: - Live copies

    /// The sends of `object` with every mini-chain plugin's state read LIVE from the engine — same
    /// ids, the model untouched. For a transformation that takes the object out of the engine and
    /// lays the SAME sends back (consolidate, its commit, de-consolidate): what the hand set on a
    /// send's plugin since the last capture must survive it.
    func sendsWithLiveStates(of object: SoundObject) -> [AuxSend] {
        guard object.sends.contains(where: { !$0.plugins.isEmpty }) else { return object.sends }
        engine?.flushLinkedStateSync()
        return SendChain.mapping(object.sends) { plugins in
            plugins.map { p in
                var q = p
                if let xml = engine?.getPluginStateXML(p.id.uuidString), !xml.isEmpty { q.stateXML = xml }
                return q
            }
        }
    }

    /// The sends of `object` for a NEW object (paste / duplicate / split): every mini-chain plugin
    /// under a FRESH id, with the state read live from the engine when the source instance exists
    /// (and written back into the original's model, as `copiedPlugins` does for the chain). The
    /// counterpart of `copiedPlugins(of:)` for the third root; `derivedCopy(sends:)` derives the
    /// id table the automation lanes follow.
    ///
    /// LINK: none. A send's plugin is copied INDEPENDENT — fresh id, state copied, no link created
    /// nor kept (user decision of 10 October 2026, @see SendChain.sanitised) — unlike the chain's own
    /// default, which joins an FX link bin.
    func copiedSends(of object: SoundObject) -> [AuxSend] {
        guard object.sends.contains(where: { !$0.plugins.isEmpty }) else { return object.sends }
        var captured: [(UUID, String)] = []
        let copied = SendChain.mapping(object.sends) { plugins in
            plugins.map { p in
                let live = engine?.getPluginStateXML(p.id.uuidString)
                let xml = (live?.isEmpty == false) ? live : nil
                if let xml { captured.append((p.id, xml)) }
                return ObjectPlugin(id: UUID(), name: p.name, manufacturer: p.manufacturer,
                                    identifier: p.identifier, formatName: p.formatName,
                                    isEnabled: p.isEnabled, stateXML: xml ?? p.stateXML,
                                    linkGroupID: nil, colorIndex: p.colorIndex,
                                    sidechain: p.sidechain).withTrims(of: p)
            }
        }
        if !captured.isEmpty {
            update(id: object.id) { obj in
                for i in obj.sends.indices where !obj.sends[i].plugins.isEmpty {
                    for (id, xml) in captured {
                        obj.sends[i].plugins = Self.settingStateXML(id, xml, in: obj.sends[i].plugins)
                    }
                }
            }
        }
        return copied
    }
}
