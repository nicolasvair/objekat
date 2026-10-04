import Foundation

// The audio bridge, model side: which plugin's sidechain input is keyed by which object or stem,
// and the sync that lays it down in the engine (docs/plan_sidechain.md §5.9–§5.11).
//
// The model is the SOLE authority. A key is `ObjectPlugin.sidechain` — written, saved, copied and
// undone like any other field of the plugin. Everything derived from it (is the route valid? which
// units must run after which? at which rank?) is computed by `BridgeScope.plan` on every sync and
// NEVER stored — the lesson of `automationTouchOrder`: anything recorded outside the undo stack
// makes objects unrecoverable if the snapshot compares it. The engine side (the tap plugins, the
// wires, the ranks) is a projection, rebuilt from the plan by `syncBridge`.
//
// `BridgeScope` is where the rules live (scope, cycles, what a deleted source becomes). This file
// only reads the model into its vocabulary, asks, and pushes the answer.

/// Why `setSidechain` refused.
enum BridgeSidechainError: Error, Equatable {
    case notAPlugin                          // the id is not a leaf plugin or instrument of that host
    case refused(BridgeScope.Refusal)        // the rules say no
    case cannotSidechain                     // the live plugin has no sidechain input (or is still loading)
}

extension EditViewModel {

    // MARK: - Reading the model

    /// The model in `BridgeScope`'s terms: every object (depth first, array order), then the stems
    /// (the first is the Main), and one route per plugin that carries a key — the leaves of every
    /// chain (racks and FX link blocks walked down) and the instruments. `routeOwners[i]` names the
    /// host and the plugin of `routes[i]`.
    func bridgeTopology() -> (nodes: [BridgeScope.Node], routes: [BridgeScope.Route],
                              routeOwners: [(host: UUID, plugin: UUID)]) {
        var nodes: [BridgeScope.Node] = []
        var routes: [BridgeScope.Route] = []
        var owners: [(host: UUID, plugin: UUID)] = []
        let main = mainStemID

        func collectLeaves(_ plugins: [ObjectPlugin], into out: inout [ObjectPlugin]) {
            for p in plugins {
                if let rack = p.rack { for voice in rack.voices { collectLeaves(voice, into: &out) } }
                else if let block = p.fxBlock { collectLeaves(block.plugins, into: &out) }
                else { out.append(p) }
            }
        }
        func addRoutes(host: UUID, chain: [ObjectPlugin], instruments: [ObjectPlugin]) {
            var leaves: [ObjectPlugin] = []
            collectLeaves(chain, into: &leaves)
            collectLeaves(instruments, into: &leaves)
            for p in leaves {
                guard let key = p.sidechain else { continue }
                routes.append(BridgeScope.Route(source: key.sourceID, host: host, consumer: .sidechain(plugin: p.id)))
                owners.append((host: host, plugin: p.id))
            }
        }
        func walk(_ array: [SoundObject], parent: UUID?) {
            for o in array {
                let kind: BridgeScope.Kind
                if case .group = o.kind { kind = .group } else if o.isAux { kind = .aux } else { kind = .object }
                // A child follows its top-level ancestor: only a top-level object names its stem.
                let stem: UUID? = parent == nil ? ((o.stemID == nil || o.stemID == main) ? nil : o.stemID) : nil
                nodes.append(BridgeScope.Node(id: o.id, kind: kind, parent: parent, stem: stem))
                addRoutes(host: o.id, chain: o.plugins, instruments: o.instruments)
                if case .group(let children, _) = o.kind { walk(children, parent: o.id) }
            }
        }
        walk(items, parent: nil)
        for s in stems {
            nodes.append(BridgeScope.Node(id: s.id, kind: s.id == main ? .main : .stem, parent: nil, stem: nil))
            addRoutes(host: s.id, chain: s.plugins, instruments: [])
        }
        return (nodes, routes, owners)
    }

    // MARK: - Syncing the engine

    /// Coalesces to ONE `syncBridge()` per main run-loop turn: a drag writes `items` on every frame.
    func scheduleBridgeSync() {
        guard !bridgeSyncScheduled else { return }
        bridgeSyncScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.bridgeSyncScheduled = false
            self.syncBridge()
        }
    }

    /// Reads the model, asks `BridgeScope` for the plan, and lays it down: taps, keys, ranks, in one
    /// engine transaction. The common case — no route anywhere and nothing laid before — costs one
    /// tree walk. An unchanged topology reuses the cached plan (the comparison skips `BridgeScope.plan`
    /// only) but STILL pushes it: the engine can have changed under an unchanged model (a chain remade,
    /// an AU re-instantiated, a clip recreated at rank 0), and every engine call is idempotent — it
    /// marks the transaction dirty, hence rebuilds, only on a real change.
    func syncBridge() {
        guard let engine else { return }
        // Never modify the Edit during an export (the engine's own rule). Try again shortly: the
        // model may have changed in the meantime and nothing else would sync it.
        if exportJob?.isRunning == true || exportBatch?.isActive == true {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.scheduleBridgeSync()
            }
            return
        }

        let topology = bridgeTopology()
        if topology.routes.isEmpty && !bridgeEngineHasTaps {
            if bridgePlan != BridgeScope.Plan() { bridgePlan = BridgeScope.Plan() }
            if !bridgeRouteStatus.isEmpty { bridgeRouteStatus = [:] }
            bridgeLastTopology = nil
            return
        }
        let plan: BridgeScope.Plan
        if let last = bridgeLastTopology, last.nodes == topology.nodes, last.routes == topology.routes {
            plan = last.plan
        } else {
            plan = BridgeScope.plan(nodes: topology.nodes, routes: topology.routes)
        }

        var status: [UUID: BridgeScope.Refusal] = [:]
        for (i, why) in plan.refused where topology.routeOwners.indices.contains(i) {
            status[topology.routeOwners[i].plugin] = why
        }
        // Written only on change: both are observed, and an equal value assigned at every sync would
        // invalidate every view that reads them.
        if plan != bridgePlan { bridgePlan = plan }
        if status != bridgeRouteStatus { bridgeRouteStatus = status }

        engine.beginBridgeSync()
        // Sorted: the order the engine sees must not depend on a dictionary's.
        for (source, rank) in plan.taps.sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
            engine.ensureBridgeTap(forSource: source.uuidString, rank: rank)
        }
        for (i, route) in topology.routes.enumerated() where topology.routeOwners.indices.contains(i) {
            let plugin = topology.routeOwners[i].plugin.uuidString
            if plan.refused[i] == nil {
                engine.setSidechain(forPlugin: plugin, source: route.source.uuidString, rank: plan.readerRanks[i] ?? 0)
            } else {
                engine.setSidechain(forPlugin: plugin, source: nil, rank: 0)     // refused: silent
            }
        }
        for (id, rank) in plan.rootRanks.sorted(by: { $0.key.uuidString < $1.key.uuidString }) { engine.setBridgeRank(rank, forID: id.uuidString) }
        for (id, rank) in plan.auxRanks.sorted(by: { $0.key.uuidString < $1.key.uuidString }) { engine.setBridgeRank(rank, forID: id.uuidString) }
        for (id, rank) in plan.innerRanks.sorted(by: { $0.key.uuidString < $1.key.uuidString }) { engine.setBridgeRank(rank, forID: id.uuidString) }
        engine.commitBridgeSync()

        bridgeEngineHasTaps = !plan.taps.isEmpty
        bridgeLastTopology = (topology.nodes, topology.routes, plan)
    }

    /// Plugin id → why its key is refused, computed NOW from the model (pure: no engine call, no
    /// published state touched). What a READING command answers with, so that it never depends on
    /// whether the coalesced sync has run yet.
    func bridgeStatusNow() -> [UUID: BridgeScope.Refusal] {
        let topology = bridgeTopology()
        if topology.routes.isEmpty { return [:] }
        let plan = BridgeScope.plan(nodes: topology.nodes, routes: topology.routes)
        var status: [UUID: BridgeScope.Refusal] = [:]
        for (i, why) in plan.refused where topology.routeOwners.indices.contains(i) {
            status[topology.routeOwners[i].plugin] = why
        }
        return status
    }

    // MARK: - Gestures

    /// The chain a plugin id lives in: the host's `plugins`, or (an object) its `instruments`.
    private func bridgeLeafExists(_ pluginID: UUID, host: UUID) -> Bool {
        func has(_ plugins: [ObjectPlugin]) -> Bool {
            plugins.contains { p in
                if let rack = p.rack { return rack.voices.contains { has($0) } }
                if let block = p.fxBlock { return block.plugins.contains { $0.id == pluginID } }
                return p.id == pluginID
            }
        }
        if let chain = chainPlugins(host), has(chain) { return true }
        if let o = find(id: host), has(o.instruments) { return true }
        return false
    }

    /// `plugins` with the key of leaf `pluginID` replaced, or nil if it is not in them.
    private static func settingSidechain(_ key: SidechainSource?, on pluginID: UUID,
                                         in plugins: [ObjectPlugin]) -> [ObjectPlugin]? {
        var found = false
        let out: [ObjectPlugin] = plugins.map { p in
            var q = p
            if let rack = p.rack {
                var voices: [[ObjectPlugin]] = []
                for v in rack.voices {
                    if let nv = settingSidechain(key, on: pluginID, in: v) { voices.append(nv); found = true }
                    else { voices.append(v) }
                }
                q.rack?.voices = voices
            } else if let block = p.fxBlock {
                if let inner = settingSidechain(key, on: pluginID, in: block.plugins) {
                    q.fxBlock?.plugins = inner
                    found = true
                }
            } else if p.id == pluginID {
                q.sidechain = key
                found = true
            }
            return q
        }
        return found ? out : nil
    }

    /// Keys (`source`) or un-keys (nil) a plugin's sidechain input. Throws when the plugin is not a
    /// leaf of `host`'s chain, when the rules refuse the source (`BridgeScope.candidates`), or when
    /// the live instance has no sidechain input. One undo point; the key is PATCHABLE on undo (no
    /// rebuild, no AU reload — @see `adoptingPluginStates`). On an attached FX link instance the key
    /// belongs to the DEFINITION and is mirrored on every attached instance; on a detached one, only
    /// that instance.
    func setSidechain(host: UUID, plugin: UUID, source: UUID?) throws {
        guard bridgeLeafExists(plugin, host: host) else { throw BridgeSidechainError.notAPlugin }

        if let source {
            let topology = bridgeTopology()
            let replacing = topology.routeOwners.firstIndex { $0.plugin == plugin }
            let verdict = BridgeScope.candidates(host: host, nodes: topology.nodes, routes: topology.routes,
                                                 replacing: replacing)
            if let entry = verdict.first(where: { $0.id == source }) {
                if let why = entry.refusal { throw BridgeSidechainError.refused(why) }
            } else {
                // Not a node: the host itself, or something that does not exist.
                throw BridgeSidechainError.refused(source == host ? .selfSource : .unknownSource)
            }
            if let engine, !engine.pluginCanSidechain(plugin.uuidString) { throw BridgeSidechainError.cannotSidechain }
        }

        let key = source.map { SidechainSource(sourceID: $0) }
        pushUndo()

        if let def = fxDefinition(ofInstance: plugin, on: host), let li = fxLinkIndex(def.linkID),
           let di = fxLinks[li].plugins.firstIndex(where: { $0.id == def.definitionID }) {
            fxLinks[li].plugins[di].sidechain = key
            for m in fxLinkAttachedMembers(def.linkID) {
                updateChainPlugins(m.hostID) { chain in
                    chain = Self.updatingBlock(m.block.id, in: chain) { b in
                        guard var block = b.fxBlock else { return }
                        for k in block.plugins.indices where block.plugins[k].linkGroupID == def.definitionID {
                            block.plugins[k].sidechain = key
                        }
                        b.fxBlock = block
                    }
                }
            }
        } else if let updated = chainPlugins(host).flatMap({ Self.settingSidechain(key, on: plugin, in: $0) }) {
            updateChainPlugins(host) { $0 = updated }
        } else if let o = find(id: host), let updated = Self.settingSidechain(key, on: plugin, in: o.instruments) {
            update(id: host) { $0.instruments = updated }
        }
        isDirty = true
        syncBridge()
    }

    /// The sources a plugin's key menu can offer, each allowed or refused (with the reason). The Main
    /// is left out (it is never a source); auxes are listed, refused. Names are what the user sees.
    func sidechainCandidates(host: UUID, plugin: UUID)
        -> [(id: UUID, kind: BridgeScope.Kind, name: String, refusal: BridgeScope.Refusal?)] {
        let topology = bridgeTopology()
        let replacing = topology.routeOwners.firstIndex { $0.plugin == plugin }
        let kinds = Dictionary(topology.nodes.map { ($0.id, $0.kind) }, uniquingKeysWith: { a, _ in a })
        return BridgeScope.candidates(host: host, nodes: topology.nodes, routes: topology.routes,
                                      replacing: replacing).compactMap { entry in
            guard let kind = kinds[entry.id], kind != .main else { return nil }
            let name: String
            if let s = stems.first(where: { $0.id == entry.id }) { name = s.name }
            else if let o = find(id: entry.id) { name = displayName(of: o) }
            else { name = entry.id.uuidString }
            return (id: entry.id, kind: kind, name: name, refusal: entry.refusal)
        }
    }
}
