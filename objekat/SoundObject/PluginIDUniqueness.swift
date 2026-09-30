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
// Nothing the app itself does writes such a file (every copy path mints fresh ids), so the check
// lives here, PURE, at the one funnel every load goes through (`performStructureSetup`). It is a
// DECISION for the user, not a silent fix: a load always DETECTS (`duplicateDetails`), and only
// REPAIRS (`deduplicated`) when asked — the alert's "Repair" button, or `repair_plugin_ids` on the
// API. Repairing re-keys: the first occurrence keeps its id, every later one gets a fresh one. A
// project opened without repair keeps its duplicates, and the engine copes with them on its own
// (`_pluginOwnerHost` in `OBJEngineCore`: the first host to compile a key keeps the instance, the
// others play without it) — see `plugin_id_audit`.
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

    // MARK: Detail (read-only, for the alert and the report)

    /// What kind of host holds an occurrence.
    enum HostKind: String, Equatable {
        case object
        case stem
    }

    /// One place an id sits in the FILE: who holds it, what it is called, which bin it belongs to (if
    /// any), and where to find it in the JSON.
    struct Site: Equatable {
        let hostID: UUID
        let hostKind: HostKind
        /// `SoundObject.displayName`, or `Stem.name`.
        let hostName: String
        let pluginName: String
        /// The bin the entry belongs to: a block entry itself and every instance inside its `fxBlock`
        /// carry it. `fxLinkName` is nil when the registry does not know the bin.
        let fxLinkID: UUID?
        let fxLinkName: String?
        /// From the root of the document, with the real array indexes and the real Codable keys:
        /// `items[3].kind.children[1].plugins[0].fxBlock.plugins[2]`, `items[0].plugins[1].rack.voices[0][2]`,
        /// `items[5].instruments[0]`, `stems[2].plugins[4]`.
        let jsonPath: String
    }

    /// One id held more than once. `sites` follows the traversal order, so `sites[0]` is the
    /// occurrence that KEEPS its id (the one `deduplicated` leaves alone); the others are the copies
    /// to re-key.
    struct DuplicateDetail: Equatable {
        let id: UUID
        let sites: [Site]
    }

    /// The ids held more than once, with every place they sit. Same walk as `occurrences` and
    /// `deduplicated` (an object's chain, then its instruments, then its children; the stems last), so
    /// `sites[0]` of each detail is the very occurrence the repair keeps — asserted by
    /// `tools/test_plugin_id_uniqueness.swift`. Pure: reads `items`, `stems` and the bins' registry (for
    /// their names) and nothing else.
    ///
    /// Two passes on purpose. The load calls this on EVERY opening, to know whether to ask: the first
    /// pass is the cheap count `duplicates` already does; the second, which builds paths and host names
    /// (a group's `displayName` composes its children's names), only runs for a file that has a problem.
    static func duplicateDetails(items: [SoundObject], stems: [Stem], fxLinks: [FXLink])
        -> [DuplicateDetail] {
        let dupIDs = duplicates(items: items, stems: stems).map(\.id)
        if dupIDs.isEmpty { return [] }
        let wanted = Set(dupIDs)
        let linkNames = Dictionary(fxLinks.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        var sitesByID: [UUID: [Site]] = [:]

        func walk(_ chain: [ObjectPlugin], path: String, hostID: UUID, hostKind: HostKind,
                  hostName: () -> String, link: UUID?) {
            for (k, p) in chain.enumerated() {
                let here = "\(path)[\(k)]"
                // The block's own entry belongs to its bin; so does everything it holds.
                let entryLink = p.fxBlock?.linkID ?? link
                if wanted.contains(p.id) {
                    sitesByID[p.id, default: []].append(
                        Site(hostID: hostID, hostKind: hostKind, hostName: hostName(), pluginName: p.name,
                             fxLinkID: entryLink, fxLinkName: entryLink.flatMap { linkNames[$0] },
                             jsonPath: here))
                }
                if let rack = p.rack {
                    for (v, voice) in rack.voices.enumerated() {
                        walk(voice, path: "\(here).rack.voices[\(v)]", hostID: hostID, hostKind: hostKind,
                             hostName: hostName, link: entryLink)
                    }
                } else if let block = p.fxBlock {
                    walk(block.plugins, path: "\(here).fxBlock.plugins", hostID: hostID, hostKind: hostKind,
                         hostName: hostName, link: entryLink)
                }
            }
        }
        func walkItems(_ arr: [SoundObject], path: String) {
            for (i, obj) in arr.enumerated() {
                let here = "\(path)[\(i)]"
                let name = { obj.displayName }
                walk(obj.plugins, path: "\(here).plugins", hostID: obj.id, hostKind: .object,
                     hostName: name, link: nil)
                walk(obj.instruments, path: "\(here).instruments", hostID: obj.id, hostKind: .object,
                     hostName: name, link: nil)
                if case .group(let children, _) = obj.kind { walkItems(children, path: "\(here).kind.children") }
            }
        }
        walkItems(items, path: "items")
        for (s, stem) in stems.enumerated() {
            walk(stem.plugins, path: "stems[\(s)].plugins", hostID: stem.id, hostKind: .stem,
                 hostName: { stem.name }, link: nil)
        }
        return dupIDs.compactMap { id in sitesByID[id].map { DuplicateDetail(id: id, sites: $0) } }
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
