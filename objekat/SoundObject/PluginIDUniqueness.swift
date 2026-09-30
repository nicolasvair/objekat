import Foundation

// MARK: - A plugin id is unique in the whole project
//
// `ObjectPlugin.id` is the engine's PLUGIN KEY: `OBJEngineCore._pluginMap` is indexed by it, for
// every leaf plugin, every container entry (a rack carrier, an FX link's block — whose derived
// `#wetN` / `#fxout` keys hang off it) and every instrument, in every host (object, group child,
// stem). The engine has room for ONE instance per key. A session carrying the same id under two
// hosts therefore cannot be honoured: the later chain to compile finds the key already taken and
// MOVES the existing instance into its own chain, so the earlier host silently plays dry (found
// 1 October 2026 on sessions whose JSON had been edited outside the app — FX link block entries
// copied from one object to another with a fresh block id but the SAME instance ids).
//
// Nothing the app itself does writes such a file (every copy path mints fresh ids), so the repair
// lives here, PURE, at the one funnel every load goes through (`performStructureSetup`): the first
// occurrence keeps its id, every later one is re-keyed. The engine has its own net for whatever
// could slip past (`_pluginOwnerHost` in `OBJEngineCore`) — see `plugin_id_audit`.
//
// Deliberately out of scope: `consolidateDefinitions` (a sidecar's chains never live in the engine
// at the same time as the project's own), and the FX link registry's definition plugins (never
// compiled — their ids are NAMED by the members' `linkGroupID`s, which must not move).

enum PluginIDUniqueness {

    /// One re-keyed occurrence: the id it had, the fresh one it got, and the host whose chain holds it
    /// (an object's id, or a stem's).
    struct Repair: Equatable {
        let oldID: UUID
        let newID: UUID
        let hostID: UUID
    }

    /// One id seen in one host's chains, in the traversal order (@see `traverse`).
    struct Occurrence: Equatable {
        let id: UUID
        let hostID: UUID
    }

    // MARK: Audit (read-only)

    /// Every plugin id in the project — leaves, carriers, blocks, block instances, instruments — with
    /// the host that holds it, in the order `deduplicated` walks them.
    static func occurrences(items: [SoundObject], stems: [Stem]) -> [Occurrence] {
        var out: [Occurrence] = []
        func walk(_ chain: [ObjectPlugin], host: UUID) {
            for p in chain {
                out.append(Occurrence(id: p.id, hostID: host))
                for series in p.childSeries { walk(series, host: host) }
            }
        }
        func walkItems(_ arr: [SoundObject]) {
            for obj in arr {
                walk(obj.plugins, host: obj.id)
                walk(obj.instruments, host: obj.id)
                if case .group(let children, _) = obj.kind { walkItems(children) }
            }
        }
        walkItems(items)
        for s in stems { walk(s.plugins, host: s.id) }
        return out
    }

    /// The ids held more than once — by two hosts, or twice by the same one — each with the hosts
    /// involved (a host listed once per occurrence), in first-seen order. Empty = the invariant holds.
    static func duplicates(items: [SoundObject], stems: [Stem]) -> [(id: UUID, hosts: [UUID])] {
        var order: [UUID] = []
        var hostsByID: [UUID: [UUID]] = [:]
        for o in occurrences(items: items, stems: stems) {
            if hostsByID[o.id] == nil { order.append(o.id) }
            hostsByID[o.id, default: []].append(o.hostID)
        }
        return order.compactMap { id in
            let hosts = hostsByID[id] ?? []
            return hosts.count > 1 ? (id: id, hosts: hosts) : nil
        }
    }

    // MARK: Repair

    /// Re-keys every plugin id already seen. Walk order — the FIRST occurrence keeps its id: `items`
    /// in order; for each object its chain (a leaf; a container's own id, then its series — a rack's
    /// branches, or a block's instances), then its instruments, then, for a group, its children;
    /// then the stems' chains.
    ///
    /// For each re-keyed occurrence, the automation of its HOST (`automation[].param`,
    /// `automationTouchOrder`, through `ParamRef.plugin(pluginKey:)`) follows to the new id. The
    /// remap table is PARTIAL and per host — an id the host did not have re-keyed is left alone (this
    /// is why `SoundObject.remapping(_:with:)` is not used: it DROPS a reference absent from its
    /// table). When the same id appears twice inside ONE host, the curve stays on the first
    /// occurrence — the one that kept the id if any did, otherwise the first re-keyed — the only
    /// choice that is not ambiguous.
    ///
    /// `linkGroupID`, `detachedLinkGroupID`, `stateXML`, `isEnabled`, `colorIndex` and the block's
    /// `linkID` are untouched: a block's instance stays the mirror of its definition.
    static func deduplicated(items: [SoundObject], stems: [Stem])
        -> (items: [SoundObject], stems: [Stem], repairs: [Repair]) {
        var seen = Set<UUID>()
        var repairs: [Repair] = []

        /// Per-host state: which ids this host kept, and the partial old → new table.
        struct HostScan {
            var kept = Set<UUID>()
            var table: [UUID: UUID] = [:]
        }

        func rekey(_ chain: [ObjectPlugin], host: UUID, scan: inout HostScan) -> [ObjectPlugin] {
            chain.map { original in
                var p = original
                if seen.insert(p.id).inserted {
                    scan.kept.insert(p.id)
                } else {
                    let fresh = UUID()
                    repairs.append(Repair(oldID: p.id, newID: fresh, hostID: host))
                    if !scan.kept.contains(p.id), scan.table[p.id] == nil { scan.table[p.id] = fresh }
                    p.id = fresh
                    seen.insert(fresh)
                }
                // The container's own id is settled above, its series next (pre-order, like `occurrences`).
                return p.mappingChildSeries { rekey($0, host: host, scan: &scan) }
            }
        }

        func remap(_ ref: ParamRef, _ table: [UUID: UUID]) -> ParamRef {
            guard case .plugin(let key, let paramID) = ref, let fresh = table[key] else { return ref }
            return .plugin(pluginKey: fresh, paramID: paramID)
        }

        func fix(_ arr: [SoundObject]) -> [SoundObject] {
            arr.map { original in
                var o = original
                var scan = HostScan()
                o.plugins = rekey(o.plugins, host: o.id, scan: &scan)
                o.instruments = rekey(o.instruments, host: o.id, scan: &scan)
                if !scan.table.isEmpty {
                    for i in o.automation.indices { o.automation[i].param = remap(o.automation[i].param, scan.table) }
                    o.automationTouchOrder = o.automationTouchOrder.map { remap($0, scan.table) }
                }
                if case .group(let children, let isExpanded) = o.kind {
                    o.kind = .group(children: fix(children), isExpanded: isExpanded)
                }
                return o
            }
        }

        let fixedItems = fix(items)
        let fixedStems = stems.map { original -> Stem in
            var s = original
            var scan = HostScan()
            s.plugins = rekey(s.plugins, host: s.id, scan: &scan)
            return s
        }
        return (fixedItems, fixedStems, repairs)
    }
}
