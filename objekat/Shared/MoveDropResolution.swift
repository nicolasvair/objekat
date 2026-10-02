import Foundation

/// Where a MOVE lands when the hand lets go — one pure definition, asserted with no screen
/// (`tools/test_nested_drop_target.swift`).
///
/// The fault it closes (point D of the 2026-10-02 feedback): the release rebuilt the row the hand
/// was on from the grabbed object's MODEL lane (`sourceGroup.displayLane + 1 + lane + dl`), which
/// forgets the height of every open sub-group, piano roll or automation band standing ABOVE the
/// object inside its own group. So a clip lifted out of A (or out of B inside A) and carried to a
/// deep group C was resolved against ANOTHER row than the one the preview drew: C was missed, the
/// clip was EJECTED to the root and `resolveOverlaps` there cut A whole, or it was reparented one
/// level too high and cut B — "as if it had been dropped on A".
///
/// The rule now has two halves, and the preview and the release read the same one:
///
///   1. the row is the grabbed block's DISPLAY row + `dl` — `previewOffset` draws the block at
///      `entry.displayLane + dl`, so the release lands exactly where the eye saw it (`finalRow`);
///   2. every display row is turned back into a MODEL lane of the frame that RECEIVES it — the
///      target group's own children, the source group's, or the root — with the inverse that
///      counts the same spans `buildLaneEntries` counts (`baseLane(forDisplay:origin:siblings:)`,
///      the pure twin of `EditViewModel.baseLaneForDisplay(_:inParent:)`).
///
/// No SoundObject here: the caller flattens what it knows into `Lane`s and `OpenGroup`s, which is
/// what lets the test compile this very file.
enum MoveDropResolution {

    /// A sibling of a frame: its MODEL lane and the rows it unfolds under itself
    /// (`SoundObject.expandedSpan`: an open group's children, a piano roll, an automation band).
    struct Lane: Equatable {
        let lane: Int
        let span: Int
    }

    /// A group that shows its children inline, as the drop sees it.
    struct OpenGroup {
        let id: UUID
        /// The row the group's own block is drawn on; its children start one row below.
        let displayLane: Int
        /// The rows its band holds: its children's rows plus the drop row (`childLaneCount`).
        let childLaneCount: Int
        /// The group is a moved object or one of its descendants: never a target, and a drop onto
        /// its band cancels the gesture (a group cannot enter itself).
        let isMoved: Bool
        /// Its children, for the display → model conversion of ITS frame.
        let children: [Lane]
    }

    enum Decision: Equatable {
        /// A drop onto the moved objects' own subtree: nothing happens.
        case cancel
        /// Stays in the source group, at that model lane of the source group's frame.
        case moveInSource(lane: Int)
        /// Enters (or, from another group, changes to) `groupID`, at that model lane of ITS frame.
        case reparent(groupID: UUID, lane: Int)
        /// Leaves the source group for the root, at that root model lane.
        case eject(rootLane: Int)
        /// A root object staying at the root, at that root model lane.
        case root(lane: Int)
    }

    /// The row the release believes the hand is on: where the preview draws the grabbed block.
    static func finalRow(grabbedDisplayLane: Int, dl: Int) -> Int {
        grabbedDisplayLane + dl
    }

    /// A display row turned back into a MODEL lane of one frame: `origin` is the row the frame's
    /// lane 0 is drawn on (the group's row + 1, or 0 for the root), `siblings` the frame's items.
    /// The inverse of `origin + lane + Σ span of the siblings on lanes below`.
    static func baseLane(forDisplay target: Int, origin: Int, siblings: [Lane]) -> Int {
        var b = 0
        while b < 512 {
            var extra = 0
            for s in siblings where s.lane < b { extra += s.span }
            if origin + b + extra >= target { return b }
            b += 1
        }
        return b
    }

    /// What the release does with the row `row`.
    ///
    /// - `sourceGroupID`: the group the moved objects are children of, nil for root objects.
    /// - `allowsGroupTarget`: false for an ⌥ copy from the root (it lands on the root only).
    ///   The own-subtree guard still applies to it, as it always did.
    static func resolve(row: Int,
                        sourceGroupID: UUID?,
                        allowsGroupTarget: Bool,
                        openGroups: [OpenGroup],
                        rootSiblings: [Lane]) -> Decision {
        let holding = openGroups.filter { g in
            let cl = row - g.displayLane - 1
            return cl >= 0 && cl < g.childLaneCount
        }
        // The INNERMOST open group holding the row (the one drawn last, deepest).
        let target: OpenGroup? = allowsGroupTarget
            ? holding.filter { !$0.isMoved }.max(by: { $0.displayLane < $1.displayLane })
            : nil
        if target == nil, holding.contains(where: { $0.isMoved }) { return .cancel }

        if let t = target {
            let lane = baseLane(forDisplay: row, origin: t.displayLane + 1, siblings: t.children)
            if let sg = sourceGroupID, sg == t.id { return .moveInSource(lane: lane) }
            return .reparent(groupID: t.id, lane: lane)
        }
        let rootLane = baseLane(forDisplay: max(0, row), origin: 0, siblings: rootSiblings)
        return sourceGroupID == nil ? .root(lane: rootLane) : .eject(rootLane: rootLane)
    }
}
