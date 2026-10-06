import Foundation

// MARK: - A canvas's history: ENTRIES, not ops
//
// The pure half of the history of a script canvas (`ScriptCanvasStore` holds one per canvas). A unit
// of its own for the reason `ScriptCanvasGeometry`, `CutSelection` and `SendColumns` are: it has no
// model, no JSON and no window behind it, so it can be compiled alone and asserted with no screen
// (@see tools/test_script_canvas_history.swift). The reference is `docs/plan_spectral_gain.md` §9.2
// and §9.4 (revision 3).
//
// Everything here is `nonisolated`: the project's default isolation is MainActor, and this code has
// no business there (the store and the command layer read it).
//
// ONE linear stack of ENTRIES, `cursor` over it (the active entries are `entries[..<cursor]`):
//  - a DRAFT: one selection gesture not yet applied (exactly one op);
//  - a STEP: a committed step — its ops in order, and `params`, the snapshot of the controls' values
//    at the moment it was SEALED. The history does not know what is in `params`, nor what an op is.
//
// THE RULES (§9.2):
//  - Instant: a gesture appends a step of one op (`appendStep`). Selection: it appends a draft.
//  - `commit`: the trailing active drafts (always contiguous at the top: a commit consumes them
//    all) are REPLACED by one step holding their ops in order. The redo tail is dropped. With no
//    active draft it is a no-op.
//  - Any new entry drops the redo tail (a linear history, chronology kept).
//  - ⌘Z = ONE ENTRY back: the last selection gesture alone if the top is a draft, a WHOLE applied
//    step otherwise — and the drafts it was made from do NOT come back, since the step replaced
//    them. ⇧⌘Z = one entry forward: a step comes back whole.
//  - `activeSince` is set when an entry is added, sealed or redone; it is the history revision at
//    which the entry last became active.
//
// A SECOND WAY OUT OF A PENDING SELECTION, `discardPending` (the "Ignore" answer of the alerts the
// canvas raises when a mode switch or Validate finds a selection pending, user answers Q-A / Q-B of
// 6 October 2026): the trailing active drafts are REMOVED, not undone — nothing of them stays to be
// redone — and so is whatever lay in the redo tail. The same alerts' "Apply" answer is `commit`.
// The history never decides which of the two a hand wants; the canvas asks.

nonisolated enum CanvasEntryKind: String, Equatable, Sendable {
    case draft, step
}

nonisolated struct CanvasEntry<Op, Params> {
    /// Monotonic per history, from 1; never reused, even after the entry has been undone and dropped.
    let id: Int
    let kind: CanvasEntryKind
    /// The history revision at which the entry last became active.
    var activeSince: Int
    /// A step's snapshot; nil for a draft.
    let params: Params?
    /// A draft holds exactly one op; a step holds the ops of its gesture(s), in order.
    let ops: [Op]
}

extension CanvasEntry: Equatable where Op: Equatable, Params: Equatable {}

nonisolated struct CanvasHistory<Op, Params> {
    typealias Entry = CanvasEntry<Op, Params>

    private(set) var entries: [Entry] = []
    /// The active entries are `entries[..<cursor]`.
    private(set) var cursor = 0
    /// Moves each time the ACTIVE list changes (an entry added, sealed, discarded, an undo, a redo).
    private(set) var rev = 0
    private(set) var nextEntryID = 1

    init() {}

    // MARK: Reading

    var count: Int { entries.count }
    var canUndo: Bool { cursor > 0 }
    var canRedo: Bool { cursor < entries.count }

    var activeEntries: ArraySlice<Entry> { entries[..<cursor] }

    /// The number of TRAILING active drafts: what a commit would seal, and what a mode switch or a
    /// Validate would have to ask about.
    var pending: Int {
        var n = 0
        var i = cursor - 1
        while i >= 0, entries[i].kind == .draft {
            n += 1
            i -= 1
        }
        return n
    }

    /// The active ops, flattened, in order.
    var activeOps: [Op] { entries[..<cursor].flatMap(\.ops) }

    /// The active entries whose `activeSince` is later than `reflected` — those a layer reflecting
    /// history revision `reflected` does not cover yet (their raw trace is still drawn).
    func activeEntries(since reflected: Int) -> [Entry] {
        entries[..<cursor].filter { $0.activeSince > reflected }
    }

    // MARK: Writing — each returns whether it changed anything (and moved `rev`)

    /// Drops the undone tail; bumps the revision; returns it.
    private mutating func openNewEntry() -> Int {
        if cursor < entries.count { entries.removeSubrange(cursor...) }
        rev += 1
        return rev
    }

    private mutating func push(kind: CanvasEntryKind, params: Params?, ops: [Op], since: Int) {
        entries.append(Entry(id: nextEntryID, kind: kind, activeSince: since, params: params, ops: ops))
        nextEntryID += 1
        cursor = entries.count
    }

    /// Instant mode: a gesture applied at once, one step. Refused (false, nothing changed) while a
    /// selection is pending — a step cannot sit above a draft, and the canvas never switches mode
    /// with one pending, so this is the guard of an invariant rather than a case to plan for.
    @discardableResult
    mutating func appendStep(ops: [Op], params: Params) -> Bool {
        guard pending == 0, !ops.isEmpty else { return false }
        let since = openNewEntry()
        push(kind: .step, params: params, ops: ops, since: since)
        return true
    }

    /// Selection mode: a gesture that joins the pending selection.
    mutating func appendDraft(_ op: Op) {
        let since = openNewEntry()
        push(kind: .draft, params: nil, ops: [op], since: since)
    }

    /// Seals the pending selection into ONE step, whose ops are the drafts' in order and whose params
    /// are the ones given (the values NOW). A no-op (false) with no pending draft.
    @discardableResult
    mutating func commit(params: Params) -> Bool {
        let p = pending
        guard p > 0 else { return false }
        let sealed = entries[(cursor - p)..<cursor].flatMap(\.ops)
        entries.removeSubrange((cursor - p)...)   // the drafts AND the redo tail
        rev += 1
        push(kind: .step, params: params, ops: sealed, since: rev)
        return true
    }

    /// Throws the pending selection away: the trailing active drafts, and the redo tail, are removed.
    /// A no-op (false) with no pending draft.
    @discardableResult
    mutating func discardPending() -> Bool {
        let p = pending
        guard p > 0 else { return false }
        entries.removeSubrange((cursor - p)...)
        cursor = entries.count
        rev += 1
        return true
    }

    /// One entry back. At the start of the history it is a no-op.
    @discardableResult
    mutating func undo() -> Bool {
        guard cursor > 0 else { return false }
        cursor -= 1
        rev += 1
        return true
    }

    /// One entry forward: it becomes active AGAIN, so `activeSince` is refreshed. At the end of the
    /// history it is a no-op.
    @discardableResult
    mutating func redo() -> Bool {
        guard cursor < entries.count else { return false }
        rev += 1
        entries[cursor].activeSince = rev
        cursor += 1
        return true
    }
}
