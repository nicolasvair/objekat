import Foundation

// MARK: - Graph mutations (by value, recursive)
//
// Every transformation returns a new copy of the graph. They preserve the invariants
// (see SynopticGraph.swift) through `simplified()` + `asRootSeries()`.

extension SynopticNode {

    // MARK: Bypass

    func togglingBypass(_ pluginID: UUID) -> SynopticNode {
        switch kind {
        case .plugin(var p):
            if p.id == pluginID { p.isEnabled.toggle() }
            return SynopticNode(id: id, kind: .plugin(p))
        case .series(let a):
            return SynopticNode(id: id, kind: .series(a.map { $0.togglingBypass(pluginID) }))
        case .parallel(let a):
            return SynopticNode(id: id, kind: .parallel(a.map { $0.togglingBypass(pluginID) }))
        }
    }

    // MARK: Adding a plugin in series (at a given index in the target series)

    func insertingPlaceholder(intoSeries seriesID: UUID, atIndex idx: Int) -> SynopticNode {
        switch kind {
        case .plugin:
            return self
        case .series(var a):
            a = a.map { $0.insertingPlaceholder(intoSeries: seriesID, atIndex: idx) }
            if id == seriesID {
                let clamped = min(max(0, idx), a.count)
                a.insert(.plugin(.placeholder()), at: clamped)
            }
            return SynopticNode(id: id, kind: .series(a))
        case .parallel(let a):
            return SynopticNode(id: id, kind: .parallel(a.map { $0.insertingPlaceholder(intoSeries: seriesID, atIndex: idx) }))
        }
    }

    // MARK: Putting an element in parallel (a branch)

    /// Puts the element `elementID` in a branch:
    ///  - a plugin → becomes a parallel block with 2 branches (the plugin plus a new branch),
    ///  - an existing parallel block → simply receives one more branch.
    func branching(_ elementID: UUID) -> SynopticNode {
        func makeParallel(from element: SynopticNode) -> SynopticNode {
            if case .parallel(let voies) = element.kind {
                return SynopticNode(id: element.id,
                                    kind: .parallel(voies + [.series([.plugin(.placeholder())])]))
            }
            // a plugin (or anything else): wrapped in a parallel with 2 branches (branches = series)
            return .parallel([.series([element]), .series([.plugin(.placeholder())])])
        }
        switch kind {
        case .plugin:
            return id == elementID ? makeParallel(from: self) : self
        case .series(let a):
            return SynopticNode(id: id, kind: .series(a.map {
                $0.id == elementID ? makeParallel(from: $0) : $0.branching(elementID)
            }))
        case .parallel(let a):
            return SynopticNode(id: id, kind: .parallel(a.map { $0.branching(elementID) }))
        }
    }

    // MARK: Removing a plugin (folding the emptied containers back)

    /// Returns `nil` if the whole node disappears (having become empty). To be applied at the root
    /// through `removingPluginAtRoot`, which wraps it back into a `.series`.
    func removingPlugin(_ pluginID: UUID) -> SynopticNode? {
        switch kind {
        case .plugin(let p):
            return p.id == pluginID ? nil : self
        case .series(let a):
            let kept = a.compactMap { $0.removingPlugin(pluginID) }
            if kept.isEmpty { return nil }
            return SynopticNode(id: id, kind: .series(kept)).simplified()
        case .parallel(let a):
            let kept = a.compactMap { $0.removingPlugin(pluginID) }
            if kept.isEmpty { return nil }
            return SynopticNode(id: id, kind: .parallel(kept)).simplified()
        }
    }

    func removingPluginAtRoot(_ pluginID: UUID) -> SynopticNode {
        (removingPlugin(pluginID) ?? .series([])).asRootSeries()
    }

    // MARK: Normalisation

    /// Folds degenerate containers back: nested series are flattened, and a parallel/series with a
    /// single element is unwrapped.
    func simplified() -> SynopticNode {
        switch kind {
        case .plugin:
            return self
        case .series(let a):
            var flat: [SynopticNode] = []
            for c in a.map({ $0.simplified() }) {
                if case .series(let inner) = c.kind { flat.append(contentsOf: inner) }
                else { flat.append(c) }
            }
            if flat.count == 1 { return flat[0] }   // unwraps the one-element series
            return SynopticNode(id: id, kind: .series(flat))
        case .parallel(let a):
            let s = a.map { $0.simplified() }
            if s.count == 1 { return s[0] }          // unwraps the parallel with a single branch
            return SynopticNode(id: id, kind: .parallel(s))
        }
    }

    /// Guarantees that the root is a `.series` (the trunk), so as to keep the end-of-chain '+'.
    func asRootSeries() -> SynopticNode {
        if case .series = kind { return self }
        return .series([self])
    }
}
