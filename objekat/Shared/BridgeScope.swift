import Foundation

// The audio bridge's RULES — who may key whom, which routes would loop, and the RANK every unit
// runs at so that a key is written before it is read. docs/plan_sidechain.md §5.5 and §5.10.
//
// Everything the user has not yet confirmed lives HERE and nowhere else, on purpose, so that
// changing a rule means changing this one file (and its case table, tools/fixtures/
// bridge_scope_cases.json, which the Python reference and the Swift test both read):
//
//   - the SCOPE rule (D2): any source is allowed except the host itself, its ancestors (its groups,
//     its stem) and the Main / an aux (D4);
//   - the CYCLE rule (D3): decided per SCOPE UNIT, the granularity the scheduler really has — the
//     routes are accepted greedily in input order, and one that would close a loop in its scope's
//     dependency graph is refused `cycle`;
//   - what becomes of a DELETED source: its route stays in the model and is refused
//     `unknownSource` (the plan simply never activates it) — that choice is the caller's, this
//     unit only reports it.
//
// No model, no view, Foundation only: it is the half of the bridge that has nothing behind it, so
// it can be compiled and asserted alone —
//
//     swiftc -parse-as-library objekat/Shared/BridgeScope.swift tools/test_bridge_scope.swift \
//         -o /tmp/bs && /tmp/bs
//
// The scheduling model, in one paragraph. The root player runs UNITS: a top-level object (one pool
// track's combiner), a top-level aux (its return), and a stem's bus (the folder's chain, its readers
// and its tap). A container runs its direct children the same way, atomically for its parent — so
// the dependency graph is PER SCOPE (the root, and each container), and acyclicity per scope is
// enough. Two kinds of dependency: DATA edges (a stem's bus runs after its members, an aux after
// the objects it sums — weight 0) and KEY edges (a reader's unit runs after the unit that writes
// its key — weight 1). A unit's rank is the longest weighted path below it; a unit of rank r is
// made to wait for every unit of a lower rank.

enum BridgeScope {

    enum Kind: String, Codable { case object, group, aux, stem, main }

    /// `parent`: the GROUP holding it (nil = top level). `stem`: for a TOP-LEVEL object / group / aux,
    /// its stem (nil = Main). Ignored for children (they follow their top-level ancestor) and stems.
    struct Node: Codable, Equatable {
        let id: UUID
        let kind: Kind
        let parent: UUID?
        let stem: UUID?
    }

    enum Consumer: Codable, Equatable {
        case sidechain(plugin: UUID)
        case auxInput(sender: UUID)
    }

    /// `host`: the object / aux / stem / Main whose chain holds the reader (`auxInput`: the aux).
    struct Route: Codable, Equatable {
        let source: UUID
        let host: UUID
        let consumer: Consumer
    }

    enum Refusal: String, Codable {
        case unknownSource, unknownHost, selfSource, ancestorSource, auxSource, mainSource, cycle
    }

    struct Plan: Equatable {
        /// Route index → why; absent = active.
        var refused: [Int: Refusal] = [:]
        /// Top-level non-aux objects (and groups), rank > 0 only.
        var rootRanks: [UUID: Int] = [:]
        /// Top-level auxes, rank > 0 only.
        var auxRanks: [UUID: Int] = [:]
        /// Group children (any depth, each in its own container), rank > 0 only.
        var innerRanks: [UUID: Int] = [:]
        /// Stems that are an ACTIVE source or host an ACTIVE reader — the rank may be 0.
        var stemRanks: [UUID: Int] = [:]
        /// Active route index → the rank of the unit hosting its reader, rank > 0 only.
        var readerRanks: [Int: Int] = [:]
        /// Active sources → tap rank (-1 for an object or group, the stem's rank for a stem).
        var taps: [UUID: Int] = [:]
    }

    // MARK: - The plan

    static func plan(nodes: [Node], routes: [Route]) -> Plan {
        var plan = Plan()
        let world = World(nodes: nodes)

        // 1–2. Static refusals, then the key edges (@see `accepted`).
        let step = accepted(world: world, routes: routes)
        plan.refused = step.refused
        let graphs = step.graphs
        let acceptedRoutes = step.accepted

        // 3. Ranks per scope (longest path, key = 1, data = 0).
        var ranks: [UUID: [UUID: Int]] = [:]       // scope → unit → rank
        for (scope, g) in graphs { ranks[scope] = g.ranks() }
        func rank(_ unit: UUID, in scope: UUID) -> Int { ranks[scope]?[unit] ?? 0 }

        // 4. Fill the plan (zero ranks omitted, but for the stems).
        for n in nodes {
            switch n.kind {
            case .stem, .main:
                break
            case .object, .group, .aux:
                if let parent = n.parent {
                    let r = rank(n.id, in: parent)
                    if r > 0 { plan.innerRanks[n.id] = r }
                } else {
                    let r = rank(n.id, in: World.rootScope)
                    if r > 0 { if n.kind == .aux { plan.auxRanks[n.id] = r } else { plan.rootRanks[n.id] = r } }
                }
            }
        }

        for i in acceptedRoutes {
            let route = routes[i]
            guard let host = world.node(route.host), let source = world.node(route.source) else { continue }
            if source.kind == .stem { plan.stemRanks[source.id] = rank(source.id, in: World.rootScope) }
            if host.kind == .stem   { plan.stemRanks[host.id]   = rank(host.id, in: World.rootScope) }
            plan.taps[source.id] = source.kind == .stem ? rank(source.id, in: World.rootScope) : -1

            let hostRank: Int
            switch host.kind {
            case .main:  hostRank = 0
            case .stem:  hostRank = rank(host.id, in: World.rootScope)
            default:     hostRank = rank(host.id, in: host.parent ?? World.rootScope)
            }
            if hostRank > 0 { plan.readerRanks[i] = hostRank }
        }
        return plan
    }

    // MARK: - Candidates

    /// Every node but `host` itself, each either allowed (nil) or refused, as if it were added as a
    /// route on `host` — replacing route number `replacing` if given. A caller filters what it does
    /// not want to show (the Main, the auxes); the reason is what a menu shows beside a disabled entry.
    /// `among` restricts the nodes evaluated (a menu offers the selection, the objects at the same
    /// time and the stems, not all four thousand objects).
    ///
    /// The model's routes are laid ONCE; each candidate is then one static check and one reachability
    /// query in its scope's graph — no copy of the plan, no ranks. The answers are the ones a full
    /// `plan` with the candidate appended last would give (the case table asserts both).
    static func candidates(host: UUID, nodes: [Node], routes: [Route], replacing: Int?,
                           among: Set<UUID>? = nil) -> [(id: UUID, refusal: Refusal?)] {
        var base = routes
        if let r = replacing, base.indices.contains(r) { base.remove(at: r) }
        let world = World(nodes: nodes)
        let step = accepted(world: world, routes: base)
        let dummy = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))

        var result: [(id: UUID, refusal: Refusal?)] = []
        for n in nodes where n.id != host && (among?.contains(n.id) ?? true) {
            let probe = Route(source: n.id, host: host, consumer: .sidechain(plugin: dummy))
            if let why = world.staticRefusal(probe) {
                result.append((id: n.id, refusal: why))
            } else if let edge = world.keyEdge(probe),
                      step.graphs[edge.scope]?.reaches(from: edge.after, to: edge.unit) == true {
                result.append((id: n.id, refusal: .cycle))
            } else {
                result.append((id: n.id, refusal: nil))     // no edge, an implied one, or one that closes no loop
            }
        }
        return result
    }

    /// Steps 1 and 2 of the plan: the static refusals, then the key edges laid greedily, in input
    /// order, over the data graphs (so the same model always yields the same plan).
    ///
    /// A key edge the DATA graph already implies — the host's unit already runs after the source's —
    /// is accepted without being laid: it would add a rank and a gate for nothing (an aux in a stem
    /// keyed by a member of that stem). A new edge that would close a loop is refused `cycle`.
    fileprivate static func accepted(world: World, routes: [Route])
        -> (graphs: [UUID: ScopeGraph], refused: [Int: Refusal], accepted: [Int]) {
        var refused: [Int: Refusal] = [:]
        var staticallyOK: [Bool] = []
        for (i, route) in routes.enumerated() {
            if let why = world.staticRefusal(route) {
                refused[i] = why
                staticallyOK.append(false)
            } else {
                staticallyOK.append(true)
            }
        }

        var graphs = world.dataGraphs()
        let dataOnly = graphs
        var accepted: [Int] = []
        for (i, route) in routes.enumerated() where staticallyOK[i] {
            guard let edge = world.keyEdge(route) else { accepted.append(i); continue }   // no edge needed
            if dataOnly[edge.scope]?.reaches(from: edge.unit, to: edge.after) == true {
                accepted.append(i)                                                         // implied by the data
                continue
            }
            var g = graphs[edge.scope] ?? ScopeGraph()
            if g.reaches(from: edge.after, to: edge.unit) {
                refused[i] = .cycle
                continue
            }
            g.add(unit: edge.unit, after: edge.after, weight: 1)
            graphs[edge.scope] = g
            accepted.append(i)
        }
        return (graphs, refused, accepted)
    }

    // MARK: - Internals

    /// One scope's dependency graph: `unit` runs AFTER each `(v, weight)` in `after[unit]`.
    fileprivate struct ScopeGraph {
        var order: [UUID] = []                          // units in insertion order (determinism)
        var after: [UUID: [(UUID, Int)]] = [:]

        mutating func touch(_ u: UUID) {
            if after[u] == nil { after[u] = []; order.append(u) }
        }

        mutating func add(unit: UUID, after v: UUID, weight: Int) {
            touch(unit); touch(v)
            after[unit]!.append((v, weight))
        }

        /// Is `target` reachable from `start` by following "runs after" edges (start == target counts)?
        func reaches(from start: UUID, to target: UUID) -> Bool {
            var seen = Set<UUID>()
            var stack = [start]
            while let u = stack.popLast() {
                if u == target { return true }
                if !seen.insert(u).inserted { continue }
                for (v, _) in after[u] ?? [] { stack.append(v) }
            }
            return false
        }

        /// Longest weighted path below each unit. The graph is acyclic by construction.
        func ranks() -> [UUID: Int] {
            var memo: [UUID: Int] = [:]
            func rank(_ u: UUID) -> Int {
                if let r = memo[u] { return r }
                var best = 0
                for (v, w) in after[u] ?? [] { best = max(best, rank(v) + w) }
                memo[u] = best
                return best
            }
            for u in order { _ = rank(u) }
            return memo
        }
    }

    fileprivate struct KeyEdge { let scope: UUID; let unit: UUID; let after: UUID }

    fileprivate struct World {
        /// The root scope has no node of its own: a fixed id stands for it.
        static let rootScope = UUID(uuid: (255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255))

        let nodes: [Node]
        let index: [UUID: Node]
        /// The nodes of every container, in array order (built once: a filter per group is O(N · G)).
        let childrenByParent: [UUID: [Node]]

        init(nodes: [Node]) {
            self.nodes = nodes
            var idx: [UUID: Node] = [:]
            var kids: [UUID: [Node]] = [:]
            for n in nodes {
                if idx[n.id] == nil { idx[n.id] = n }
                if let p = n.parent, n.kind == .object || n.kind == .group || n.kind == .aux { kids[p, default: []].append(n) }
            }
            self.index = idx
            self.childrenByParent = kids
        }

        func node(_ id: UUID) -> Node? { index[id] }

        /// The chain from the top-level ancestor down to `id` inclusive (`[top, …, id]`).
        func path(to id: UUID) -> [UUID] {
            var chain = [id]
            var cur = index[id]
            var guardCount = 0
            while let p = cur?.parent, let parent = index[p], guardCount < 10_000 {
                chain.append(parent.id)
                cur = parent
                guardCount += 1
            }
            return chain.reversed()
        }

        func top(of id: UUID) -> UUID { path(to: id)[0] }

        /// The stem a node lives in (nil = Main), through its top-level ancestor.
        func stemOf(_ id: UUID) -> UUID? { index[top(of: id)]?.stem }

        func staticRefusal(_ r: Route) -> Refusal? {
            guard let source = index[r.source] else { return .unknownSource }
            guard let host = index[r.host] else { return .unknownHost }
            if source.id == host.id { return .selfSource }
            if source.kind == .main { return .mainSource }
            if source.kind == .aux { return .auxSource }
            switch source.kind {
            case .stem:
                // A stem contains every object living in it; a stem host is never inside another.
                if host.kind != .stem && host.kind != .main && stemOf(host.id) == source.id { return .ancestorSource }
            default:
                if host.kind != .stem && host.kind != .main && path(to: host.id).dropLast().contains(source.id) {
                    return .ancestorSource
                }
            }
            return nil
        }

        /// Data edges (weight 0), per scope — what already orders units without any key.
        func dataGraphs() -> [UUID: ScopeGraph] {
            var graphs: [UUID: ScopeGraph] = [:]
            var root = ScopeGraph()
            let topLevel = nodes.filter { ($0.kind == .object || $0.kind == .group || $0.kind == .aux) && $0.parent == nil }

            for n in nodes where n.kind == .stem { root.touch(n.id) }
            for t in topLevel { root.touch(t.id) }

            // A stem's bus runs after everything mounted in it; an aux after the objects of its stem.
            for s in nodes where s.kind == .stem {
                for t in topLevel where t.stem == s.id {
                    root.add(unit: s.id, after: t.id, weight: 0)
                    if t.kind == .aux {
                        for o in topLevel where o.stem == s.id && o.kind != .aux {
                            root.add(unit: t.id, after: o.id, weight: 0)
                        }
                    }
                }
            }
            // A Main aux runs after every top-level non-aux object and every stem's bus.
            for t in topLevel where t.kind == .aux && (t.stem == nil || index[t.stem!] == nil || index[t.stem!]!.kind != .stem) {
                for o in topLevel where o.kind != .aux { root.add(unit: t.id, after: o.id, weight: 0) }
                for s in nodes where s.kind == .stem { root.add(unit: t.id, after: s.id, weight: 0) }
            }
            graphs[World.rootScope] = root

            // Inside a container: an aux child runs after the non-aux children.
            for c in nodes where c.kind == .group {
                guard let children = childrenByParent[c.id], !children.isEmpty else { continue }
                var g = ScopeGraph()
                for ch in children { g.touch(ch.id) }
                for a in children where a.kind == .aux {
                    for o in children where o.kind != .aux { g.add(unit: a.id, after: o.id, weight: 0) }
                }
                graphs[c.id] = g
            }
            return graphs
        }

        /// The key edge a (statically valid) route needs: the host's unit must run after the
        /// source's, in the lowest scope that holds both. nil = no edge is needed.
        func keyEdge(_ r: Route) -> KeyEdge? {
            guard let source = index[r.source], let host = index[r.host] else { return nil }
            if host.kind == .main { return nil }

            if host.kind == .stem {
                if source.kind == .stem { return KeyEdge(scope: World.rootScope, unit: host.id, after: source.id) }
                // A stem's bus already runs after its own members.
                if stemOf(source.id) == host.id { return nil }
                return KeyEdge(scope: World.rootScope, unit: host.id, after: top(of: source.id))
            }

            let hostTop = top(of: host.id)
            if source.kind == .stem {
                return KeyEdge(scope: World.rootScope, unit: hostTop, after: source.id)
            }

            let pathH = path(to: host.id), pathS = path(to: source.id)
            if pathH[0] != pathS[0] { return KeyEdge(scope: World.rootScope, unit: pathH[0], after: pathS[0]) }

            // Same top-level object: descend until the two paths part.
            var depth = 0
            while depth < pathH.count && depth < pathS.count && pathH[depth] == pathS[depth] { depth += 1 }
            // `depth` is the first index where they differ (or one path ended).
            if depth >= pathH.count { return nil }                   // the host IS the container
            if depth >= pathS.count { return nil }                   // cannot happen (ancestorSource), be safe
            return KeyEdge(scope: pathH[depth - 1], unit: pathH[depth], after: pathS[depth])
        }
    }
}
