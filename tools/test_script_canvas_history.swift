// The history of a script canvas — entries (drafts and steps), commit, discard, undo / redo —
// asserted with no screen.
//
// `CanvasHistory` is generic over the op and the params and depends on Foundation alone, which is the
// whole reason it is a unit of its own: it has no model, no JSON and no window behind it.
//
//     swiftc -parse-as-library \
//         ../objekat/Shared/ScriptCanvasHistory.swift test_script_canvas_history.swift \
//         -o /tmp/sch && /tmp/sch
//
// Exit: 0 if every assertion passes, 1 otherwise.

import Foundation

var fails: [String] = []
var total = 0

func check(_ label: String, _ ok: Bool, _ detail: String = "") {
    total += 1
    if ok { print("ok    " + label) }
    else { fails.append(label); print("FAIL  \(label)  \(detail)") }
}

typealias H = CanvasHistory<Int, String>

/// The ops of the active entries, kind by kind — a compact way to read a whole history.
func shape(_ h: H) -> String {
    h.activeEntries.map { e in
        (e.kind == .step ? "S" : "d") + "[" + e.ops.map(String.init).joined(separator: ",") + "]"
    }.joined()
}

func tail(_ h: H) -> String {
    h.entries[h.cursor...].map { e in
        (e.kind == .step ? "S" : "d") + "[" + e.ops.map(String.init).joined(separator: ",") + "]"
    }.joined()
}

@main
enum ScriptCanvasHistoryTest {
  static func main() {

    // MARK: - Empty

    do {
        var h = H()
        check("empty: nothing pending, nothing to undo or redo",
              h.pending == 0 && h.count == 0 && h.cursor == 0 && h.rev == 0 && !h.canUndo && !h.canRedo)
        check("empty: undo is a no-op and moves nothing", !h.undo() && h.rev == 0)
        check("empty: redo is a no-op and moves nothing", !h.redo() && h.rev == 0)
        check("empty: commit is a no-op and moves nothing", !h.commit(params: "p") && h.rev == 0 && h.count == 0)
        check("empty: discard is a no-op and moves nothing", !h.discardPending() && h.rev == 0)
        check("empty: no active ops", h.activeOps.isEmpty)
    }

    // MARK: - Instant: a gesture is a step

    do {
        var h = H()
        check("instant: a gesture appends a step", h.appendStep(ops: [1], params: "A") && shape(h) == "S[1]")
        check("instant: the step carries the params it was sealed with", h.entries[0].params == "A")
        check("instant: it is active from its own revision", h.entries[0].activeSince == h.rev && h.rev == 1)
        h.appendStep(ops: [2], params: "B")
        check("instant: two gestures are two steps", shape(h) == "S[1]S[2]" && h.cursor == 2 && h.pending == 0)
        check("instant: no draft is ever pending", h.pending == 0)
        check("instant: an empty op list is refused", !h.appendStep(ops: [], params: "C") && h.count == 2)
        check("instant: a step may hold several ops, in order",
              h.appendStep(ops: [3, 4, 5], params: "C") && shape(h) == "S[1]S[2]S[3,4,5]")
        check("instant: activeOps flattens in order", h.activeOps == [1, 2, 3, 4, 5])
    }

    // MARK: - Selection: gestures are drafts, commit seals them

    do {
        var h = H()
        h.appendDraft(1)
        h.appendDraft(2)
        check("selection: gestures are drafts", shape(h) == "d[1]d[2]" && h.pending == 2)
        check("selection: a draft has no params", h.entries[0].params == nil && h.entries[0].kind == .draft)
        let revBefore = h.rev
        check("commit: seals the drafts into ONE step", h.commit(params: "NOW"))
        check("commit: the step holds the ops in order, with the new params",
              shape(h) == "S[1,2]" && h.entries[0].params == "NOW")
        check("commit: nothing is pending any more", h.pending == 0)
        check("commit: moves the revision", h.rev == revBefore + 1)
        check("commit: the step is active from the sealing revision", h.entries[0].activeSince == h.rev)
        check("commit: the cursor is at the top", h.cursor == h.count && h.count == 1)
        let rev = h.rev
        check("commit with nothing pending is a no-op", !h.commit(params: "again") && h.rev == rev && shape(h) == "S[1,2]")
    }

    do {
        // A commit seals only the TRAILING drafts: the steps below stay as they are.
        var h = H()
        h.appendStep(ops: [1], params: "A")
        h.appendDraft(2)
        h.appendDraft(3)
        h.commit(params: "B")
        check("commit leaves the steps below alone", shape(h) == "S[1]S[2,3]" && h.entries[0].params == "A" && h.entries[1].params == "B")
        h.appendDraft(4)
        check("a new selection after a commit starts afresh", shape(h) == "S[1]S[2,3]d[4]" && h.pending == 1)
    }

    // MARK: - Undo walks entries

    do {
        var h = H()
        h.appendStep(ops: [1], params: "A")
        h.appendDraft(2)
        h.appendDraft(3)
        check("undo peels the last draft alone", h.undo() && shape(h) == "S[1]d[2]" && h.pending == 1)
        check("undo peels the next draft", h.undo() && shape(h) == "S[1]" && h.pending == 0)
        check("undo then removes a WHOLE applied step", h.undo() && shape(h) == "" && h.cursor == 0)
        check("undo at the start is a no-op", !h.undo())
        check("the tail keeps the entries, in order", tail(h) == "S[1]d[2]d[3]")
    }

    do {
        // The drafts a step was made from do NOT come back when the step is undone.
        var h = H()
        h.appendDraft(1)
        h.appendDraft(2)
        h.commit(params: "A")
        h.undo()
        check("undo of a commit: the step goes and its drafts do NOT come back",
              shape(h) == "" && h.pending == 0 && h.count == 1 && h.entries[0].kind == .step)
        check("undo of a commit: the ops are not active any more", h.activeOps.isEmpty)
        h.redo()
        check("redo of a commit brings the step back WHOLE", shape(h) == "S[1,2]" && h.entries[0].params == "A" && h.pending == 0)
    }

    // MARK: - Redo

    do {
        var h = H()
        h.appendStep(ops: [1], params: "A")
        h.appendStep(ops: [2], params: "B")
        h.undo()
        h.undo()
        let revAtUndo = h.rev
        check("redo brings a step back", h.redo() && shape(h) == "S[1]")
        check("redo moves the revision", h.rev == revAtUndo + 1)
        check("redo refreshes activeSince", h.entries[0].activeSince == h.rev && h.entries[1].activeSince == 2)
        check("redo again", h.redo() && shape(h) == "S[1]S[2]")
        check("redo at the end is a no-op", !h.redo())
        check("redo of an entry that was active before: its activeSince is the NEW revision",
              h.entries[1].activeSince == h.rev && h.entries[1].activeSince > 2)
    }

    do {
        // Redo of drafts: one at a time.
        var h = H()
        h.appendDraft(1)
        h.appendDraft(2)
        h.undo()
        h.undo()
        check("redo of drafts, one entry at a time", h.redo() && shape(h) == "d[1]" && h.pending == 1)
        check("... and the second", h.redo() && shape(h) == "d[1]d[2]" && h.pending == 2)
    }

    // MARK: - A new entry drops the redo tail

    do {
        var h = H()
        h.appendStep(ops: [1], params: "A")
        h.appendStep(ops: [2], params: "B")
        h.undo()
        check("the tail is there before a new entry", tail(h) == "S[2]")
        h.appendStep(ops: [3], params: "C")
        check("a new step drops the redo tail", shape(h) == "S[1]S[3]" && tail(h) == "" && !h.canRedo)
        h.undo()
        h.appendDraft(4)
        check("a new draft drops it too", shape(h) == "S[1]d[4]" && tail(h) == "")
    }

    do {
        // ... including after an undone commit.
        var h = H()
        h.appendDraft(1)
        h.appendDraft(2)
        h.commit(params: "A")
        h.undo()
        check("an undone commit leaves its step in the tail", tail(h) == "S[1,2]")
        h.appendDraft(3)
        check("a new draft after an undone commit drops that step for good", shape(h) == "d[3]" && tail(h) == "" && h.count == 1)
    }

    do {
        // Commit drops the redo tail as well.
        var h = H()
        h.appendStep(ops: [1], params: "A")
        h.appendDraft(2)
        h.appendDraft(3)
        h.undo()                       // d[3] now in the tail; d[2] still pending
        check("commit with an undone draft in the tail", tail(h) == "d[3]" && h.pending == 1)
        h.commit(params: "B")
        check("commit drops the redo tail", shape(h) == "S[1]S[2]" && tail(h) == "" && !h.canRedo)
    }

    // MARK: - Pending, with the cursor inside the tail

    do {
        var h = H()
        h.appendStep(ops: [1], params: "A")
        h.appendDraft(2)
        h.appendDraft(3)
        h.undo()
        check("pending counts ACTIVE drafts only", h.pending == 1)
        h.undo()
        check("pending is zero once the drafts are undone", h.pending == 0 && h.cursor == 1)
        h.undo()
        check("pending is zero with the cursor at the start", h.pending == 0)
        h.redo(); h.redo()
        check("pending comes back with redo", h.pending == 1)
    }

    // MARK: - Instant refuses while a selection is pending

    do {
        var h = H()
        h.appendDraft(1)
        let rev = h.rev
        check("a step cannot sit above a draft", !h.appendStep(ops: [2], params: "A") && shape(h) == "d[1]" && h.rev == rev)
        h.commit(params: "A")
        check("... but can once it is sealed", h.appendStep(ops: [2], params: "B") && shape(h) == "S[1]S[2]")
    }

    // MARK: - Discard: the second way out of a pending selection

    do {
        var h = H()
        h.appendStep(ops: [1], params: "A")
        h.appendDraft(2)
        h.appendDraft(3)
        let rev = h.rev
        check("discard removes the pending drafts", h.discardPending() && shape(h) == "S[1]" && h.pending == 0)
        check("discard moves the revision", h.rev == rev + 1)
        check("discard leaves nothing to redo", tail(h) == "" && !h.canRedo && h.count == 1)
        check("discard again is a no-op", !h.discardPending() && h.rev == rev + 1)
        check("the step below is untouched", h.entries[0].params == "A" && h.entries[0].ops == [1])
        check("undo after a discard goes to the step below, nothing comes back",
              h.undo() && shape(h) == "" && tail(h) == "S[1]")
    }

    do {
        // Discard with some drafts undone: the pending ones go, and so does the redo tail.
        var h = H()
        h.appendStep(ops: [1], params: "A")
        h.appendDraft(2)
        h.appendDraft(3)
        h.appendDraft(4)
        h.undo()
        check("discard with a tail: before", shape(h) == "S[1]d[2]d[3]" && tail(h) == "d[4]" && h.pending == 2)
        h.discardPending()
        check("discard with a tail: both go", shape(h) == "S[1]" && tail(h) == "" && h.count == 1)
    }

    do {
        // Discard with a redo tail but nothing pending is a no-op: the tail is not the selection's.
        var h = H()
        h.appendStep(ops: [1], params: "A")
        h.undo()
        check("discard with nothing pending leaves a redo tail alone", !h.discardPending() && tail(h) == "S[1]")
    }

    do {
        var h = H()
        h.appendDraft(1)
        h.discardPending()
        check("discarding a lone selection empties the history", h.count == 0 && h.cursor == 0 && h.pending == 0)
        h.appendDraft(2)
        check("a fresh selection after a discard is fine", shape(h) == "d[2]" && h.entries[0].id == 2)
    }

    // MARK: - active_since, revisions and what a layer reflects

    do {
        var h = H()
        h.appendStep(ops: [1], params: "A")          // rev 1
        h.appendDraft(2)                             // rev 2
        h.appendDraft(3)                             // rev 3
        check("activeSince is the revision the entry was added at",
              h.entries.map(\.activeSince) == [1, 2, 3] && h.rev == 3)
        check("activeEntries(since:) lists what a layer at rev 2 does not cover",
              h.activeEntries(since: 2).map(\.id) == [3] && h.activeEntries(since: 0).count == 3)
        check("... and nothing once a layer is current", h.activeEntries(since: 3).isEmpty)
        h.commit(params: "B")                        // rev 4: sealing refreshes activeSince
        check("sealing refreshes activeSince", h.entries[1].activeSince == 4 && h.rev == 4)
        check("a layer at rev 3 does not cover the sealed step", h.activeEntries(since: 3).map(\.id) == [4])
        h.undo()                                     // rev 5
        h.redo()                                     // rev 6
        check("redo refreshes it again", h.entries[1].activeSince == 6 && h.rev == 6)
        check("undo and redo each move the revision", h.rev == 6)
    }

    // MARK: - Ids are never reused

    do {
        var h = H()
        h.appendDraft(1)                                         // id 1
        h.appendDraft(2)                                         // id 2
        h.commit(params: "A")                                    // id 3
        h.undo()
        h.appendDraft(3)                                         // the step (id 3) is dropped; this is id 4
        h.discardPending()
        h.appendStep(ops: [4], params: "B")                      // id 5
        let ids = h.entries.map(\.id)
        check("ids are never reused, even after drops and discards", ids == [5] && h.nextEntryID == 6, "\(ids) next \(h.nextEntryID)")
        var seen = Set<Int>()
        var g = H()
        for i in 0..<40 {
            switch i % 5 {
            case 0: g.appendDraft(i)
            case 1: g.appendDraft(i)
            case 2: g.commit(params: "p")
            case 3: g.undo()
            default: g.appendStep(ops: [i], params: "q")
            }
            for e in g.entries { seen.insert(e.id) }
        }
        let live = g.entries.map(\.id)
        check("ids strictly increase through a long mixed run", live == live.sorted() && Set(live).count == live.count)
        check("... and the counter is past every id ever seen", g.nextEntryID > (seen.max() ?? 0))
    }

    // MARK: - Revision discipline

    do {
        var h = H()
        var revs: [Int] = [h.rev]
        h.appendDraft(1); revs.append(h.rev)
        h.appendStep(ops: [9], params: "X"); revs.append(h.rev)       // refused while pending: unchanged
        h.undo(); revs.append(h.rev)
        h.redo(); revs.append(h.rev)
        h.commit(params: "A"); revs.append(h.rev)
        h.discardPending(); revs.append(h.rev)                        // nothing pending: unchanged
        check("every change moves the revision by exactly one, a no-op not at all", revs == [0, 1, 1, 2, 3, 4, 4], "\(revs)")
    }

    // MARK: - Undo that REVEALS (Selection mode, revision 6)

    func outcome(_ o: CanvasUndoOutcome<String>) -> String {
        switch o {
        case .nothing: return "nothing"
        case .removed: return "removed"
        case .revealed(let p): return "revealed(" + p + ")"
        }
    }

    do {
        // A step comes back as pending drafts, with its params.
        var h = H()
        h.appendStep(ops: [1], params: "A")
        h.appendDraft(2); h.appendDraft(3)
        h.commit(params: "B")                                    // S[1] S[2,3]
        let rev = h.rev
        let o = h.undoRevealing()
        check("reveal: the top step comes back as its params", outcome(o) == "revealed(B)", outcome(o))
        check("reveal: ... as one pending draft per op, in order, below the steps",
              shape(h) == "S[1]d[2]d[3]" && h.pending == 2 && h.cursor == h.count)
        check("reveal: the revision moved once and the drafts are active from it",
              h.rev == rev + 1 && h.activeEntries.last!.activeSince == h.rev && h.entries[1].activeSince == h.rev)
        check("reveal: the drafts have fresh ids, the step below keeps its own",
              h.entries[0].id == 1 && h.entries[1].id > 2 && h.entries[2].id > h.entries[1].id && h.entries[1].params == nil)
        check("reveal: the ops are the step's", h.activeOps == [1, 2, 3])
        check("reveal: a redo is available", h.canRedo)
    }

    do {
        // ... and sealing them again makes a NEW step with the params of NOW.
        var h = H()
        h.appendDraft(1); h.appendDraft(2); h.commit(params: "A")
        h.undoRevealing()
        check("reveal: commit re-seals the selection as a new step with the new params",
              h.commit(params: "TWEAKED") && shape(h) == "S[1,2]" && h.entries[0].params == "TWEAKED")
        check("reveal: after that there is nothing left to redo", !h.canRedo && !h.redo())
    }

    do {
        // Redo, right after a reveal: the step comes back exactly as it was.
        var h = H()
        h.appendStep(ops: [1], params: "A")
        h.appendStep(ops: [2, 3], params: "B")
        let original = h.entries[1]
        h.undoRevealing()
        let rev = h.rev
        check("reveal+redo: redo puts the step back", h.redo() && shape(h) == "S[1]S[2,3]" && h.pending == 0)
        check("reveal+redo: it is the SAME step (id, ops, params)",
              h.entries[1].id == original.id && h.entries[1].ops == original.ops && h.entries[1].params == "B")
        check("reveal+redo: the revision moved and the step is active from it", h.rev == rev + 1 && h.entries[1].activeSince == h.rev)
        check("reveal+redo: the cursor is at the top, no drafts left", h.cursor == h.count && h.count == 2)
        check("reveal+redo: a second redo does nothing", !h.redo() && !h.canRedo)
        // and the cycle can be repeated
        check("reveal+redo: ⌘Z reveals it again", outcome(h.undoRevealing()) == "revealed(B)" && shape(h) == "S[1]d[2]d[3]")
        check("reveal+redo: ... and redo restores it again", h.redo() && shape(h) == "S[1]S[2,3]")
    }

    do {
        // Anything done after a reveal forgets the step: the drafts are then no longer it.
        func fresh() -> H {
            var h = H()
            h.appendStep(ops: [1], params: "A")
            h.appendStep(ops: [2, 3], params: "B")
            h.undoRevealing()
            return h
        }
        var h = fresh()
        h.appendDraft(9)
        check("forgotten by a new gesture", !h.redo() && shape(h) == "S[1]d[2]d[3]d[9]" && !h.canRedo)
        h = fresh()
        h.undo()                                                  // peels the draft 3
        check("forgotten by peeling a gesture: redo brings the DRAFT back, not the step",
              h.redo() && shape(h) == "S[1]d[2]d[3]" && h.pending == 2 && h.entries.count == 3)
        check("... and then there is no step to redo", !h.redo())
        h = fresh()
        h.discardPending()
        check("forgotten by Ignore", !h.canRedo && shape(h) == "S[1]")
        h = fresh()
        h.commit(params: "C")
        check("forgotten by Apply", !h.canRedo && !h.redo())
    }

    do {
        // On pending drafts, or with Instant's plain undo, nothing is revealed.
        var h = H()
        h.appendDraft(1); h.appendDraft(2)
        check("a pending gesture is just peeled, as before", outcome(h.undoRevealing()) == "removed" && shape(h) == "d[1]" && h.pending == 1)
        check("... and redo brings it back", h.redo() && shape(h) == "d[1]d[2]")
        var g = H()
        check("at the start of the history there is nothing to reveal", outcome(g.undoRevealing()) == "nothing" && g.rev == 0)
        g.appendStep(ops: [1], params: "A")
        check("plain undo still removes a step WITHOUT revealing it", g.undo() && shape(g) == "" && g.pending == 0 && g.canRedo)
        check("... and plain redo brings it back whole", g.redo() && shape(g) == "S[1]")
    }

    do {
        // A reveal is a new entry: the redo tail goes, like any other.
        var h = H()
        h.appendStep(ops: [1], params: "A")
        h.appendStep(ops: [2], params: "B")
        h.undo()                                                  // plain: B in the tail
        check("tail before: B", tail(h) == "S[2]")
        check("reveal of A drops the tail", outcome(h.undoRevealing()) == "revealed(A)" && tail(h) == "" && shape(h) == "d[1]")
        // the ids stay unique
        let ids = h.entries.map(\.id)
        check("ids never reused through a reveal", Set(ids).count == ids.count && h.nextEntryID > (ids.max() ?? 0))
    }

    // MARK: - Equatable entries

    do {
        var a = H(), b = H()
        a.appendDraft(1); b.appendDraft(1)
        check("entries are Equatable when their parts are", a.entries == b.entries)
        b.appendDraft(2)
        check("... and differ when they differ", a.entries != b.entries)
    }

    print("\n\(total - fails.count)/\(total) assertions passed")
    if !fails.isEmpty {
        print("FAILED: \(fails.joined(separator: " | "))")
        exit(1)
    }
  }
}
