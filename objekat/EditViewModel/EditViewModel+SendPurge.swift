import Foundation

// Dangling sends — docs/plan_sends_rework.md §1.7 (Q-U2).
//
// A send names its aux by id and lives on the SENDER. When the aux is deleted the send stays behind:
// silent, invisible (no row offers it), and — now that the scope is wide — a future surprise should an id
// ever come back. They are purged, together with the automation lanes aimed at them, in two places:
//   • on LOAD, from the document as read (the engine never sees them);
//   • after a DELETION of an aux, in the same undo point as the gesture (the sweep runs on the run-loop
//     turn that follows, before any other gesture can push its own undo point).
// Nothing else about a session of format < 21 is migrated: the sends that were silent only because the
// old scope did not reach their aux now SOUND (Q-U2).

extension EditViewModel {

    /// The ids of every aux in `items`, at any depth.
    static func auxIDs(in items: [SoundObject]) -> Set<UUID> {
        var ids: Set<UUID> = []
        func walk(_ array: [SoundObject]) {
            for o in array {
                if o.isAux { ids.insert(o.id) }
                if case .group(let children, _) = o.kind { walk(children) }
            }
        }
        walk(items)
        return ids
    }

    /// `items` without the sends whose aux is not in the tree, and without the automation lanes (and
    /// their place in the touch order) aimed at those sends. Pure. `changed` is the number of sends
    /// removed.
    static func purgingDanglingSends(_ items: [SoundObject]) -> (items: [SoundObject], sends: Int, lanes: Int) {
        let alive = auxIDs(in: items)
        var sends = 0, lanes = 0

        func purged(_ array: [SoundObject]) -> [SoundObject] {
            array.map { o in
                var o = o
                if o.sends.contains(where: { !alive.contains($0.auxID) }) {
                    let before = o.sends.count
                    o.sends.removeAll { !alive.contains($0.auxID) }
                    sends += before - o.sends.count
                }
                func dangling(_ ref: ParamRef) -> Bool {
                    if case .send(let auxID) = ref { return !alive.contains(auxID) }
                    return false
                }
                if o.automation.contains(where: { dangling($0.param) }) {
                    let before = o.automation.count
                    o.automation.removeAll { dangling($0.param) }
                    lanes += before - o.automation.count
                }
                o.automationTouchOrder.removeAll { dangling($0) }
                if case .group(let children, let expanded) = o.kind {
                    o.kind = .group(children: purged(children), isExpanded: expanded)
                }
                return o
            }
        }

        // Nothing dangling is the overwhelming case: answer without rebuilding a tree.
        func hasDangling(_ array: [SoundObject]) -> Bool {
            for o in array {
                if o.sends.contains(where: { !alive.contains($0.auxID) }) { return true }
                if o.automation.contains(where: { if case .send(let a) = $0.param { return !alive.contains(a) } else { return false } }) { return true }
                if case .group(let children, _) = o.kind, hasDangling(children) { return true }
            }
            return false
        }
        guard hasDangling(items) else { return (items, 0, 0) }
        let out = purged(items)
        return (out, sends, lanes)
    }

    /// Sweeps the LIVE model after an aux was deleted. A no-op unless `removeFromEngine` saw an aux go
    /// (`sendPrunePending`), and when it did, unless a send really dangles: an aux that was merely
    /// replaced in place (same id, rebuilt) leaves nothing to purge. The engine side needs nothing
    /// (`removeAux` drops its sends; the bridge sync confirms the rest).
    func pruneOrphanSends() {
        guard sendPrunePending else { return }
        sendPrunePending = false
        let result = Self.purgingDanglingSends(items)
        guard result.sends > 0 || result.lanes > 0 else { return }
        items = result.items
        isDirty = true
        NSLog("[SENDS] purged %d send(s) and %d automation lane(s) aimed at a deleted aux", result.sends, result.lanes)
    }
}
