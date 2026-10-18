import AppKit
import Foundation

// WHAT AN OPEN CONSOLIDATED OBJECT PROTECTS.
//
// An open instance is a STAGE (a group, id = the placement's) holding exactly ONE child, the content
// root A (@see SoundObject.consolidateStage). Both are scaffolding the session depends on, and the
// closing reads them back: the stage carries the instance level, A is what gets baked.
//
//   • The STAGE and A are never split, deleted, ungrouped, regrouped, consolidated, nor taken out of
//     the place they hold. A's CONTENT is free (that is what the session is for), and so are A's own
//     trim, fades, loop and position inside the stage (QA-2: they are content).
//   • The STAGE cannot be MOVED IN TIME: its window is a frame laid over absolute positions, and a
//     group drags its children with it — the content would move for every other instance, whose
//     mirrors are placed against the position it had when the session opened. Its edges can be
//     trimmed, its fades and FX and sends edited, and it can change lane.
//   • Whatever is dropped ON the stage goes into A: the stage always has exactly one child.
//   • Copying or duplicating the stage (or a mirror) hands out the CLOSED instance it stands for.
//
// Every door a gesture can come through asks `sessionRefusal`; a refusal beeps and does nothing.
// The command API turns it into an `invalid_state` error with the reason.

/// A gesture the session's scaffolding refuses.
enum SessionGesture {
    case split, delete, ungroup, regroup, consolidate, deconsolidate
    /// Taking the stage or A out of the place they hold (reparent, eject, alt-copy into a group).
    case relocate
    /// Moving in TIME (the stage only: A may move inside it).
    case moveInTime
}

extension EditViewModel {

    /// The stages of every open session (a nested edit stacks sessions).
    var sessionStageIDs: Set<UUID> { Set(consolidateEditStack.map(\.placementID)) }
    /// The content roots of every open session.
    var sessionContentRootIDs: Set<UUID> { Set(consolidateEditStack.map(\.contentRootID)) }

    /// True for a stage or a content root of an open session.
    func isSessionScaffold(_ id: UUID) -> Bool {
        consolidateEditStack.contains { $0.placementID == id || $0.contentRootID == id }
    }

    /// Why `gesture` is refused on `ids` right now, or nil when it goes through.
    func sessionRefusal<S: Sequence>(_ gesture: SessionGesture, ids: S) -> String? where S.Element == UUID {
        guard !consolidateEditStack.isEmpty else { return nil }
        switch gesture {
        case .moveInTime:
            if ids.contains(where: { sessionStageIDs.contains($0) }) {
                return "the stage of an open consolidated object cannot be moved in time (trim its edges instead)"
            }
        case .split, .delete, .ungroup, .regroup, .consolidate, .deconsolidate, .relocate:
            if ids.contains(where: { isSessionScaffold($0) }) {
                return "the stage and the content root of an open consolidated object cannot be "
                     + "split, deleted, ungrouped, regrouped, consolidated or taken out of place"
            }
        }
        return nil
    }

    /// `sessionRefusal`, with the beep a refused gesture gives. Returns true when REFUSED.
    func refusedBySession<S: Sequence>(_ gesture: SessionGesture, ids: S) -> Bool where S.Element == UUID {
        guard sessionRefusal(gesture, ids: ids) != nil else { return false }
        NSSound.beep()
        return true
    }

    /// Where a drop aimed at `groupID` lands: whatever is dropped on a stage goes into A (the stage
    /// has exactly one child, always).
    func sessionDropTarget(_ groupID: UUID) -> UUID {
        consolidateEditStack.first(where: { $0.placementID == groupID })?.contentRootID ?? groupID
    }

    /// The open stage that `id` lies strictly inside (its content), nil when it lies in none.
    func sessionStageContaining(_ id: UUID) -> UUID? {
        guard !consolidateEditStack.isEmpty else { return nil }
        let stages = sessionStageIDs
        var p = parentGroup(for: id)
        while let g = p {
            if stages.contains(g.id) { return g.id }
            p = parentGroup(for: g.id)
        }
        return nil
    }

    /// The drop gate of a drag (@see commitMoveDrop): the decision to carry out, or nil when the
    /// session refuses the gesture.
    ///   • the STAGE: stays where it is in time, stays in its container, is not copied by an ⌥ drag
    ///     (it may change lane);
    ///   • A: only moves inside the stage (`moveInSource`), never copied;
    ///   • anything else: dropped ON the stage it goes into A; it never leaves a stage's content
    ///     (an eject, a reparent to a container outside it); entering one is free.
    func sessionMoveDropGate(ids: Set<UUID>, sourceGroupID: UUID?, isAltCopy: Bool, dt: Double,
                             decision: MoveDropResolution.Decision) -> MoveDropResolution.Decision? {
        guard !consolidateEditStack.isEmpty, decision != .cancel else { return decision }
        if ids.contains(where: { sessionStageIDs.contains($0) }) {
            if isAltCopy || abs(dt) > 1e-9 { return nil }
            switch decision {
            case .reparent, .eject: return nil
            default: break
            }
            if ids.contains(where: { sessionContentRootIDs.contains($0) }) { return nil }
            return decision
        }
        if ids.contains(where: { sessionContentRootIDs.contains($0) }) {
            if isAltCopy || ids.count != 1 { return nil }
            if case .moveInSource = decision { return decision }
            return nil
        }
        // The container the movers come from, and the one they would land in.
        let from = ids.first.flatMap { sessionStageContaining($0) }
        switch decision {
        case .reparent(let g, let lane):
            let target = sessionDropTarget(g)
            let to = sessionStageIDs.contains(g) ? g : sessionStageContaining(g)
            if from != nil && from != to { return nil }
            return .reparent(groupID: target, lane: lane)
        case .eject:
            return from == nil ? decision : nil
        case .root:
            return from == nil ? decision : nil
        default:
            return decision
        }
    }

    // MARK: - The closed form of what is open

    /// The CLOSED instance an open stage stands for RIGHT NOW: the official wave it was opened on
    /// (the content has not been committed), the stage as it is — FX with their live states, fader,
    /// window, fades, sends, stem, automation.
    func closedInstanceOfOpenStage(_ session: ConsolidateEditSession) -> SoundObject? {
        guard let stage = find(id: session.placementID), let original = session.originalPlacement,
              case .clip(let path, _, let length, _, _) = original.kind else { return nil }
        return closedInstance(ofStage: stage, wavePath: path, waveLength: length,
                              oldWaveZero: session.oldWaveZero, delta: 0, defID: session.defID,
                              automationOpen: original.automationOpen)
    }

    /// The closed form of `item` when it IS an open stage or a live mirror, nil otherwise.
    func closedFormIfOpenOrNil(_ item: SoundObject) -> SoundObject? {
        guard item.consolidateID != nil, item.isGroup else { return nil }
        for session in consolidateEditStack {
            if session.placementID == item.id, let closed = closedInstanceOfOpenStage(session) { return closed }
            if let snapshot = session.mirrorSnapshots[item.id] { return snapshot }
        }
        return nil
    }

    /// `item` with every open stage / mirror it contains (itself included) put back in its closed
    /// form: what may leave the session (copy, duplicate, cross-project import).
    func folded(_ item: SoundObject) -> SoundObject {
        guard !consolidateEditStack.isEmpty else { return item }
        return itemsFoldingOpenSessions([item]).first ?? item
    }

    /// `items` as a FILE must hold them while consolidated objects are open: every stage back as the
    /// closed instance it opens from (official wave + the stage as it is now), every mirror as its
    /// snapshot. The edits of the content itself are not in the file — they are not baked yet, and a
    /// file that held a half-edited group in place of an instance would lose the link on reopening.
    func itemsFoldingOpenSessions(_ items: [SoundObject]) -> [SoundObject] {
        guard !consolidateEditStack.isEmpty else { return items }
        var replacements: [UUID: SoundObject] = [:]
        for session in consolidateEditStack {
            if let closed = closedInstanceOfOpenStage(session) { replacements[session.placementID] = closed }
            for (id, snapshot) in session.mirrorSnapshots { replacements[id] = snapshot }
        }
        func fold(_ list: [SoundObject]) -> [SoundObject] {
            list.map { o in
                if let r = replacements[o.id] { return r }
                guard case .group(let children, let e) = o.kind else { return o }
                var n = o
                n.kind = .group(children: fold(children), isExpanded: e)
                return n
            }
        }
        return fold(items)
    }

    // MARK: - A project that holds a stage

    /// Loading guard: an object that carries a link AND is a group is an open stage that reached a
    /// file (an older build, a hand edit). It is put back as the closed instance it stands for — on the
    /// definition's official wave, its window brought inside the content — or, when the definition is
    /// gone, unlinked into the plain group it looks like. Returns the repaired items and how many were
    /// repaired (the caller journals it).
    func repairedOpenStages(in list: [SoundObject]) -> (items: [SoundObject], repaired: Int) {
        // Nothing to do for the usual project: one cheap pass before any copy.
        func holdsStage(_ l: [SoundObject]) -> Bool {
            l.contains { o in
                guard case .group(let ch, _) = o.kind else { return false }
                return o.consolidateID != nil || holdsStage(ch)
            }
        }
        guard holdsStage(list) else { return (list, 0) }
        var count = 0
        func walkList(_ l: [SoundObject]) -> [SoundObject] {
            l.map { o in
                guard case .group(let children, let e) = o.kind else { return o }
                if let defID = o.consolidateID {
                    count += 1
                    guard let def = consolidateDefinitions[defID], let a = children.first,
                          let wave = consolidateWaveURL(def.wave, forConsolidate: defID) else {
                        var plain = o; plain.consolidateID = nil
                        plain.kind = .group(children: walkList(children), isExpanded: e)
                        return plain
                    }
                    let length = audioFileDuration(wave) ?? 0
                    return SoundObject
                        .closedInstance(fromStage: o, wavePath: wave.path, waveLength: length,
                                        waveZero: a.startTime, definitionID: defID, automationOpen: false)
                        .realignedInstance(delta: 0, wavePath: wave.path, waveLength: length)
                }
                var n = o
                n.kind = .group(children: walkList(children), isExpanded: e)
                return n
            }
        }
        let out = walkList(list)
        return (out, count)
    }
}
