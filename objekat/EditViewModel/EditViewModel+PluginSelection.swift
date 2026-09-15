import Foundation

// MARK: - A selection of plugin cards, and what one does to several at once
//
// The signal view used to hold ONE selected card, in a `@State` of its own view. It now holds a
// SET, and that set lives in the view-model — not out of tidiness, but because every batch
// operation below needs the chain's READING ORDER, which only the model knows, and because a
// selection nothing can drive is a selection nothing can verify with no screen.
//
// Three rules the whole file rests on:
//
//  • A selection belongs to ONE host. The signal view shows one chain at a time — an object or a
//    stem/master bus — so `selectedPluginHostID` travels with the ids, and aiming at another host
//    REPLACES the selection rather than growing it. There is no cross-chain selection to speak of.
//
//  • The order is the CHAIN's, never the set's. A `Set<UUID>` has no order, and pasting, moving or
//    duplicating a handful of cards in the wrong order silently rewires the signal. Every operation
//    starts by reading `orderedSelectedPlugins()`, which walks the model tree.
//
//  • One undo per GESTURE, not per card. The single-plugin functions each push their own undo
//    point; calling them in a loop would leave the user pressing ⌘Z once per plugin to come back
//    from one gesture. So the batch is the real implementation and the singles delegate to it
//    (@see movePlugin / copyPlugin / linkAcrossObjects), rather than the two drifting apart.

/// What a drag of one or more cards onto ANOTHER host does. The three gestures the timeline drop
/// has spoken since the chips: nothing = move, ⌥ = an independent copy, ⌘ = a copy that stays
/// linked to its source.
enum PluginTransferMode {
    case move
    /// An INDEPENDENT copy: a new identity, no link, a colour of its own.
    case copy
    /// A copy that JOINS the source's link group (created on the spot if the source had none).
    case link
}

@MainActor
extension EditViewModel {

    // MARK: - The selection itself

    /// Replaces the selection with `ids` on `host`. Aiming at another host replaces rather than
    /// grows: see the file's header.
    ///
    /// The host is recorded EVEN FOR AN EMPTY SET, and that is the whole of the signal view's
    /// keyboard claim: a click in its empty space takes ⌫ ⌘C ⌘V ⌘D away from the timeline and
    /// keeps them, so ⌘V can land in a chain that has no card yet to click on. The cost is a
    /// handful of keys that do nothing while the view holds them with no card chosen — a dead key,
    /// which is the harmless half of the alternative: the other half was ⌫ deleting the OBJECT
    /// while the hand was plainly in the signal view. A click in the timeline gives everything
    /// back (@see clearPluginSelection).
    func setPluginSelection(_ ids: Set<UUID>, host: UUID) {
        selectedPluginHostID = host
        selectedPluginIDs = ids
    }

    /// True while the signal view holds the keyboard for ⌫ ⌘C ⌘V ⌘D. @see setPluginSelection
    var pluginSurfaceHasKeyboard: Bool { selectedPluginHostID != nil }

    /// A click on a card. `additive` (⌘) toggles it one by one; otherwise the click is exclusive.
    /// A click on another host always starts a fresh selection.
    func selectPlugin(_ id: UUID, host: UUID, additive: Bool = false) {
        guard additive, selectedPluginHostID == host else {
            setPluginSelection([id], host: host)
            return
        }
        var ids = selectedPluginIDs
        if ids.contains(id) { ids.remove(id) } else { ids.insert(id) }
        setPluginSelection(ids, host: host)
    }

    /// Gives the keyboard back to the timeline. Called by every click that lands in the timeline
    /// canvas: while cards are selected they own ⌫ ⌘C ⌘V ⌘D, and a hand that goes back to the
    /// objects must not have to guess which of the two a key will reach.
    func clearPluginSelection() {
        guard !selectedPluginIDs.isEmpty || selectedPluginHostID != nil else { return }
        selectedPluginIDs = []
        selectedPluginHostID = nil
    }

    /// The selection, pruned to what the host's chain still holds and IN that chain's reading
    /// order (parallel branches walked in place). Empty if the host has gone or nothing is selected.
    func orderedSelectedPlugins() -> [ObjectPlugin] {
        guard let host = selectedPluginHostID, !selectedPluginIDs.isEmpty,
              let plugins = chainPlugins(host) else { return [] }
        return Self.flattenLeaves(plugins).filter { selectedPluginIDs.contains($0.id) }
    }

    /// The same, as ids — the form the batch operations take.
    func orderedSelectedPluginIDs() -> [UUID] { orderedSelectedPlugins().map(\.id) }

    // MARK: - ⌫ — removing the selection

    /// Removes every selected card in ONE undo step, then folds the tree back (emptied branches
    /// removed, a one-branch parallel inlined) and recompiles once.
    @discardableResult
    func removeSelectedPlugins() -> Int {
        guard let host = selectedPluginHostID else { return 0 }
        let ids = orderedSelectedPluginIDs()
        guard !ids.isEmpty, chainPlugins(host) != nil, engine != nil else { return 0 }
        pushUndo()
        // Same two cleanups as the single removal, per card: the touch listening RETAINS the
        // plugin, and what was known of its parameters is worth nothing once it has left the chain.
        for id in ids {
            endPluginParamTouchWatch(id)
            invalidatePluginParamInfos(id)
        }
        updateChainPlugins(host) { p in
            p = Self.simplifyTree(Self.removingPlugins(Set(ids), from: p))
        }
        compileRack(objectID: host)
        clearPluginSelection()
        isDirty = true
        return ids.count
    }

    // MARK: - On/off — bypassing the selection

    /// Bypasses or re-enables every selected card AT ONCE. Mixed states resolve one way: if a
    /// single one of them is still on, the gesture turns them ALL off — "off" is what a hand asks
    /// for when it reaches for a bypass over several plugins, and a second press brings them all
    /// back. Like the single toggle, it is a realtime bypass: no recompilation, and no undo point.
    @discardableResult
    func toggleSelectedPluginsEnabled() -> Bool? {
        guard let host = selectedPluginHostID, let engine else { return nil }
        let selected = orderedSelectedPlugins()
        guard !selected.isEmpty else { return nil }
        let newEnabled = !selected.contains { $0.isEnabled }
        for p in selected {
            engine.setPlugin(p.id.uuidString, enabled: newEnabled, forObjectID: host.uuidString)
        }
        updateChainPlugins(host) { plugins in
            for p in selected { plugins = Self.settingEnabled(p.id, newEnabled, in: plugins) }
        }
        isDirty = true
        return newEnabled
    }

    // MARK: - ⌘D / ⌘C / ⌘V — duplicating, copying, pasting

    /// Duplicates the selection IN PLACE: independent copies laid just after the LAST selected
    /// card, in its own series — a branch's cards therefore duplicate inside that branch and not
    /// at the trunk's end. The copies become the new selection, so a second ⌘D chains from them.
    ///
    /// Independent and not linked, unlike an object's duplication (@see copiedPlugins): the hand
    /// has a gesture of its own for the link (⌘-dragging onto another object), and a ⌘D that
    /// silently tied the copy to its original would leave no way of asking for the plain one.
    @discardableResult
    func duplicateSelectedPlugins() -> [UUID] {
        guard let host = selectedPluginHostID else { return [] }
        let selected = orderedSelectedPlugins()
        guard !selected.isEmpty, let plugins = chainPlugins(host), engine != nil else { return [] }
        guard let anchor = selected.last,
              let (loc, idx) = Self.locate(anchor.id, in: plugins) else { return [] }
        let copies = selected.map { independentCopy(of: $0) }
        pushUndo()
        updateChainPlugins(host) { p in
            for (offset, c) in copies.enumerated() {
                p = Self.inserting(c, into: loc, at: idx + 1 + offset, plugins: p)
            }
        }
        compileRack(objectID: host)
        setPluginSelection(Set(copies.map(\.id)), host: host)
        isDirty = true
        return copies.map(\.id)
    }

    /// ⌘C: puts the selection aside, deep-copied WITH the state read back off the live instances.
    /// The clipboard holds a fragment, not a reference — deleting the originals afterwards leaves
    /// it perfectly pasteable.
    @discardableResult
    func copySelectedPluginsToClipboard() -> Int {
        let selected = orderedSelectedPlugins()
        guard !selected.isEmpty else { return 0 }
        pluginClipboard = selected.map { independentCopy(of: $0) }
        return pluginClipboard.count
    }

    /// ⌘V: lays the clipboard into `host`, just after the last selected card of THAT host, or at
    /// the chain's end when nothing is selected there. Fresh identities on every paste, so pasting
    /// twice gives two independent sets rather than two views of one.
    @discardableResult
    func pastePlugins(into host: UUID) -> [UUID] {
        guard !pluginClipboard.isEmpty,
              let plugins = chainPlugins(host), engine != nil else { return [] }
        let fresh = pluginClipboard.map { independentCopy(of: $0) }
        // The insertion point: after the last selected card IF the selection is this host's.
        var target: (SeriesLocation, Int)? = nil
        if selectedPluginHostID == host, let anchor = orderedSelectedPlugins().last {
            target = Self.locate(anchor.id, in: plugins)
        }
        pushUndo()
        updateChainPlugins(host) { p in
            if let (loc, idx) = target {
                for (offset, c) in fresh.enumerated() {
                    p = Self.inserting(c, into: loc, at: idx + 1 + offset, plugins: p)
                }
            } else {
                p.append(contentsOf: fresh)
            }
        }
        compileRack(objectID: host)
        setPluginSelection(Set(fresh.map(\.id)), host: host)
        isDirty = true
        return fresh.map(\.id)
    }

    // MARK: - Dragging onto another host: move / copy / link, N at a time

    /// Carries `ids` from one chain HOST to another — an object or a stem bus on either side, which
    /// is why nothing here goes through `find`/`update` (a stem's chain does not live in `items`).
    ///
    /// One undo point for the whole batch, one recompilation per chain touched, and the cards laid
    /// down IN the source chain's order: a set has none, and a reordered chain is a different sound.
    @discardableResult
    func transferPlugins(_ ids: [UUID], from sourceHostID: UUID, to targetHostID: UUID,
                         mode: PluginTransferMode) -> [UUID] {
        guard let engine, chainPlugins(targetHostID) != nil,
              let sourcePlugins = chainPlugins(sourceHostID) else { return [] }
        // Moving or linking a chain onto ITSELF means nothing: a move would be a no-op that still
        // burnt an undo point, and a link would tie a plugin to its own instance.
        if mode != .copy && sourceHostID == targetHostID { return [] }
        let wanted = Set(ids)
        let ordered = Self.flattenLeaves(sourcePlugins).filter { wanted.contains($0.id) }
        guard !ordered.isEmpty else { return [] }

        pushUndo()

        // A LINK needs the source registered in a group before the copy can join it. Gathered
        // first, in one pass over the source, so the writes below stay a single update.
        var groups: [UUID: UUID] = [:]      // source plugin id → the group it will share
        if mode == .link {
            for p in ordered {
                // A DETACHED source goes back into ITS group rather than opening another —
                // otherwise it would drag a dormant group around while an active link holds it
                // elsewhere (@see linkAcrossObjects, whose rule this is).
                groups[p.id] = p.effectiveLinkGroupID ?? UUID()
            }
            updateChainPlugins(sourceHostID) { plugins in
                for p in ordered where p.linkGroupID == nil {
                    guard let gid = groups[p.id] else { continue }
                    plugins = Self.settingDetachedLinkGroup(p.id, nil, in: plugins)
                    plugins = Self.settingLinkGroup(p.id, gid, in: plugins)
                }
            }
        }

        let placed: [ObjectPlugin] = ordered.map { p in
            let stateXML = liveStateXML(of: p)
            switch mode {
            case .move:
                // The same logical plugin, another chain: it keeps its link, its detached group
                // (a detached plugin stays reattachable after a move) and its identity colour.
                return ObjectPlugin(id: UUID(), name: p.name, manufacturer: p.manufacturer,
                                    identifier: p.identifier, formatName: p.formatName,
                                    isEnabled: p.isEnabled, stateXML: stateXML,
                                    linkGroupID: p.linkGroupID,
                                    detachedLinkGroupID: p.detachedLinkGroupID,
                                    colorIndex: p.colorIndex)
            case .copy:
                // No colour carried over: an independent copy draws its own, which is what makes
                // it recognisable as a second plugin and not the same one seen twice.
                return ObjectPlugin(id: UUID(), name: p.name, manufacturer: p.manufacturer,
                                    identifier: p.identifier, formatName: p.formatName,
                                    isEnabled: p.isEnabled, stateXML: stateXML, linkGroupID: nil)
            case .link:
                return ObjectPlugin(id: UUID(), name: p.name, manufacturer: p.manufacturer,
                                    identifier: p.identifier, formatName: p.formatName,
                                    isEnabled: p.isEnabled, stateXML: stateXML,
                                    linkGroupID: groups[p.id], colorIndex: p.colorIndex)
            }
        }

        if mode == .move {
            updateChainPlugins(sourceHostID) { p in
                p = Self.simplifyTree(Self.removingPlugins(wanted, from: p))
            }
        }
        updateChainPlugins(targetHostID) { $0.append(contentsOf: placed) }

        if mode == .move { compileRack(objectID: sourceHostID) }
        compileRack(objectID: targetHostID)   // creates the target instances (state restored)

        if mode == .link {
            for (src, new) in zip(ordered, placed) {
                guard let gid = groups[src.id] else { continue }
                engine.setPluginLinkGroup(src.id.uuidString, groupID: gid.uuidString)
                engine.setPluginLinkGroup(new.id.uuidString, groupID: gid.uuidString)
            }
        }
        if mode == .move && placed.contains(where: { $0.linkGroupID != nil }) { rewireLinkGroups() }
        isDirty = true
        return placed.map(\.id)
    }

    /// The selection carried onto `targetHostID`. What a drag of several cards onto a timeline
    /// object does; after a MOVE the cards have new identities, so the selection follows them
    /// rather than pointing at ids nothing holds any more.
    @discardableResult
    func transferSelectedPlugins(to targetHostID: UUID, mode: PluginTransferMode) -> [UUID] {
        guard let source = selectedPluginHostID else { return [] }
        let ids = orderedSelectedPluginIDs()
        guard !ids.isEmpty else { return [] }
        let placed = transferPlugins(ids, from: source, to: targetHostID, mode: mode)
        if mode == .move && !placed.isEmpty { setPluginSelection(Set(placed), host: targetHostID) }
        return placed
    }

    // MARK: - Shared machinery

    /// A plugin's state as it REALLY is: read back off the live instance when there is one, and
    /// falling back on the model otherwise. The setting of an open plugin lives in the engine, not
    /// in `stateXML` — a copy that skipped this step left with the factory settings.
    private func liveStateXML(of p: ObjectPlugin) -> String? {
        let live = engine?.getPluginStateXML(p.id.uuidString)
        return (live?.isEmpty == false) ? live : p.stateXML
    }

    /// An INDEPENDENT twin: a new identity, the live state, no link of any kind, a fresh colour.
    /// The shape ⌘D, ⌘C and ⌘V all take.
    private func independentCopy(of p: ObjectPlugin) -> ObjectPlugin {
        ObjectPlugin(id: UUID(), name: p.name, manufacturer: p.manufacturer,
                     identifier: p.identifier, formatName: p.formatName,
                     isEnabled: p.isEnabled, stateXML: liveStateXML(of: p), linkGroupID: nil)
    }
}
