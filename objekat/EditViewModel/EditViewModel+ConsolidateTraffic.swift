import Foundation

// What CROSSES the boundary of an open consolidated object's content while it is open.
//
// A session replaces the instance by a stage holding the content, and gives the instance back as it was
// opened when it is cancelled (or when the closing's ⌘Z is taken). Anything the hand moved ACROSS the
// content's edge in between is not in that picture:
//
//   • an object dragged INTO the content lived somewhere else before — the stage's replacement takes
//     it away with the rest of the content, so it was simply LOST (the bug this file answers);
//   • an object taken OUT of the content (allowed since the plan's Q8, option a′) now lives outside, and
//     the instance given back reads the wave — which still holds it — so it would play TWICE.
//
// Both are READ against the project as it was before the opening (`ConsolidateEditSession.itemsAtOpen`)
// and the content as it was laid (`openedSubtree`), at the moment the session ends, so none of the doors
// a move can come through (a drag, `group.reparent`, `group.eject`, a ⌥ drag…) has anything to record.
// A new object (dropped, pasted, created) is neither: it was not there before, it dies with the stage.

/// What crossed the content's boundary: the sounds that left it, and the ones that entered it.
struct SessionTraffic {
    /// The objects of the content now living OUTSIDE it — the top-most ones, a group that left with
    /// its children being one entry.
    var exits: [UUID] = []
    /// The objects that entered: each as it was BEFORE the session, and the group it was a child of
    /// (nil = the top level). Shallowest first, so that a group is back before what it holds.
    var entries: [(object: SoundObject, parentID: UUID?)] = []

    var isEmpty: Bool { exits.isEmpty && entries.isEmpty }
}

extension EditViewModel {

    /// What crossed the boundary of `session`'s content, read in `items` (the live project, the stage
    /// still open).
    static func sessionTraffic(of session: ConsolidateEditSession, in items: [SoundObject]) -> SessionTraffic {
        var traffic = SessionTraffic()

        // What the content held when it was laid: every descendant of the root (the root itself cannot
        // be moved out, @see sessionMoveDropGate).
        var openedIDs = Set<UUID>()
        func collect(_ o: SoundObject) {
            if case .group(let kids, _) = o.kind { for k in kids { openedIDs.insert(k.id); collect(k) } }
        }
        if let opened = session.openedSubtree { collect(opened) }

        // What the project held before the opening, by id: the object and the group it was in.
        var before: [UUID: (object: SoundObject, parentID: UUID?, depth: Int)] = [:]
        func index(_ list: [SoundObject], parent: UUID?, depth: Int) {
            for o in list {
                before[o.id] = (o, parent, depth)
                if case .group(let kids, _) = o.kind { index(kids, parent: o.id, depth: depth + 1) }
            }
        }
        index(session.itemsAtOpen, parent: nil, depth: 0)

        func walk(_ list: [SoundObject], insideStage: Bool) {
            for o in list {
                if o.id == session.placementID {
                    if case .group(let kids, _) = o.kind { walk(kids, insideStage: true) }
                    continue
                }
                if insideStage {
                    if let was = before[o.id] {
                        traffic.entries.append((was.object, was.parentID))
                        continue
                    }
                } else if openedIDs.contains(o.id) {
                    traffic.exits.append(o.id)
                    continue
                }
                if case .group(let kids, _) = o.kind { walk(kids, insideStage: insideStage) }
            }
        }
        walk(items, insideStage: false)

        traffic.entries.sort { (before[$0.object.id]?.depth ?? 0) < (before[$1.object.id]?.depth ?? 0) }
        return traffic
    }

    /// `items` with the traffic undone: the exits removed (wherever they went), the entries put back
    /// at the end of the group they came from — or at the top level when that group is gone. Pure.
    static func revertingTraffic(_ traffic: SessionTraffic, in items: [SoundObject]) -> [SoundObject] {
        guard !traffic.isEmpty else { return items }
        let gone = Set(traffic.exits)
        func removing(_ list: [SoundObject]) -> [SoundObject] {
            list.compactMap { o in
                if gone.contains(o.id) { return nil }
                guard case .group(let kids, let e) = o.kind else { return o }
                var n = o
                n.kind = .group(children: removing(kids), isExpanded: e)
                return n
            }
        }
        var out = removing(items)

        func ids(in list: [SoundObject]) -> Set<UUID> {
            var s = Set<UUID>()
            func go(_ l: [SoundObject]) {
                for o in l { s.insert(o.id); if case .group(let k, _) = o.kind { go(k) } }
            }
            go(list)
            return s
        }
        func appending(_ child: SoundObject, to parentID: UUID, in list: [SoundObject]) -> ([SoundObject], Bool) {
            var done = false
            let mapped: [SoundObject] = list.map { o in
                guard !done, case .group(let kids, let e) = o.kind else { return o }
                var n = o
                if o.id == parentID {
                    n.kind = .group(children: kids + [child], isExpanded: e)
                    done = true
                } else {
                    let (inner, found) = appending(child, to: parentID, in: kids)
                    if found { n.kind = .group(children: inner, isExpanded: e); done = true }
                }
                return n
            }
            return (mapped, done)
        }
        for entry in traffic.entries {
            guard !ids(in: out).contains(entry.object.id) else { continue }   // already back with a group that held it
            if let parent = entry.parentID {
                let (next, placed) = appending(entry.object, to: parent, in: out)
                if placed { out = next; continue }
            }
            out.append(entry.object)
        }
        return out
    }

    /// Undoes `traffic` on the LIVE model and engine, once the stage has been replaced by the instance:
    /// the sounds that left the content leave the world (the instance's wave holds them), the ones
    /// that entered it return to the group they came from.
    func restoreSessionTraffic(_ traffic: SessionTraffic) {
        guard !traffic.isEmpty else { return }
        for id in traffic.exits where find(id: id) != nil { remove(id: id) }
        for entry in traffic.entries where find(id: entry.object.id) == nil {
            if let parent = entry.parentID, find(id: parent)?.isGroup == true {
                addChild(entry.object, toResolvedGroupID: parent)
            } else {
                add(entry.object)
            }
        }
        resyncAllSends()
        NSLog("[OBJECT] session traffic undone: \(traffic.exits.count) left the content, \(traffic.entries.count) entered it")
    }
}
