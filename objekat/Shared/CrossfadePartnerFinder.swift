import Foundation

// MARK: - Who crossfades with whom, found in one pass
//
// A drag that moves or crops objects asks, for each of them and on every frame, "which sibling does
// this edge form a crossfade with?" (@see EditViewModel.crossfadePairs, TimelineView
// .reshapedCrossfadeFade). It used to be `seamNeighbour(of:onRight:)`: a `find`, a `parentGroup` walk
// and a pass over every sibling — O(N) per question, O(N²) per frame, and with 600 objects selected
// that was two thirds of the main thread's time while the hand was down.
//
// The model does not change during a gesture, so the answers do not either: they are worked out ONCE
// per change of `items` (@see EditViewModel.crossfadePartners) by the finder below, and read in O(1).
//
// ⚠️ ONE CONTRACT: the partner it names is exactly the one `seamNeighbourAndGap(of:onRight:within: 0)`
// names whenever that one forms a crossfade — the FIRST sibling, in the model's order, whose pair with
// the object satisfies `isCrossfadePair`. (The old walk returns on the first match; "first" is the
// model's order, which is not the order of the starts: two siblings that begin within a hair of one
// another and both fit the fades are told apart by their position in the list, so that is what is
// kept.) `tools/test_crossfade_pairs.swift` compares both, on random layouts, ties included.
//
// The finder is pure — no model, no view — and does not own what makes two objects a crossfade
// (`isCrossfadePair`, which reads the objects' fades): it is handed that as a closure over positions.
// It only prunes: a pair needs the right-hand object to START inside the left-hand one, so the
// candidates of an object are the next ones in start order, up to its end — not the whole row.

enum CrossfadePartnerFinder {

    /// What the pruning reads of an object: its row and its extent, in its container's own time.
    struct Box {
        let lane: Int
        let start: Double
        let duration: Double
    }

    /// For each position of `boxes` (the siblings of ONE container, in the model's order): the
    /// position of the first sibling it forms a crossfade with on its right (`right`) and on its left
    /// (`left`), `nil` where there is none.
    ///
    /// `isPair(a, b)` answers "are the objects at positions `a` (the left-hand one) and `b` a
    /// crossfade?" — the caller's `isCrossfadePair`. It is only ever asked for two objects of one
    /// lane with `b` starting strictly after `a` and inside it, which is everything a pair is.
    static func partners(of boxes: [Box], isPair: (Int, Int) -> Bool)
        -> [(right: Int?, left: Int?)] {
        var out = [(right: Int?, left: Int?)](repeating: (nil, nil), count: boxes.count)
        guard boxes.count > 1 else { return out }

        var byLane: [Int: [Int]] = [:]
        for i in boxes.indices { byLane[boxes[i].lane, default: []].append(i) }

        for (_, row) in byLane where row.count > 1 {
            // By start; the position breaks the ties, so the order is the same on every run.
            let sorted = row.sorted {
                boxes[$0].start != boxes[$1].start ? boxes[$0].start < boxes[$1].start : $0 < $1
            }
            for k in sorted.indices {
                let a = sorted[k]
                let aEnd = boxes[a].start + boxes[a].duration
                var j = k + 1
                // A pair's overlap is strictly positive: only an object starting before `a` ends
                // can be its right-hand partner. (Equality is let through, the predicate decides.)
                while j < sorted.count, boxes[sorted[j]].start <= aEnd {
                    let b = sorted[j]
                    j += 1
                    guard boxes[b].start > boxes[a].start, isPair(a, b) else { continue }
                    if out[a].right == nil || b < out[a].right! { out[a].right = b }
                    if out[b].left  == nil || a < out[b].left!  { out[b].left  = a }
                }
            }
        }
        return out
    }

    /// The partners of every object of a tree, by id: each sibling list (the roots, then each
    /// group's children, at every depth) is a container of its own, and only objects that share one
    /// can pair. Objects with no partner are absent. Generic over the model's object type so that
    /// the test drives this very function with a stand-in.
    static func partnerMap<T>(roots: [T],
                              id: (T) -> UUID,
                              children: (T) -> [T],
                              box: (T) -> Box,
                              isPair: (T, T) -> Bool) -> [UUID: (left: UUID?, right: UUID?)] {
        var out: [UUID: (left: UUID?, right: UUID?)] = [:]
        func walk(_ siblings: [T]) {
            for o in siblings {
                let kids = children(o)
                if !kids.isEmpty { walk(kids) }
            }
            guard siblings.count > 1 else { return }
            let found = partners(of: siblings.map(box)) { a, b in isPair(siblings[a], siblings[b]) }
            for i in siblings.indices {
                guard found[i].right != nil || found[i].left != nil else { continue }
                out[id(siblings[i])] = (found[i].left.map { id(siblings[$0]) },
                                        found[i].right.map { id(siblings[$0]) })
            }
        }
        walk(roots)
        return out
    }
}
