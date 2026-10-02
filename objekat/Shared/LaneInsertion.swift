import Foundation

/// INSERTING between two lanes — one pure definition, asserted with no screen
/// (`tools/test_lane_insertion.swift`).
///
/// Until now a move could only be DROPPED ON a lane: whatever was already there was overwritten
/// (`resolveOverlaps`) and the only way to put an object "between" two others was to make room by
/// hand. Dropping in the gap between two rows is a different gesture with different semantics —
/// a LIST one: the lanes below the gap go down by as many lanes as the selection takes, and the
/// lanes the selection leaves behind close up. Nothing is overwritten.
///
/// Three halves, kept apart on purpose:
///
///   1. `boundaryRow` — from where the hand has the grabbed block (a continuous row), is the block
///      straddling two rows, and which gap does it straddle;
///   2. `plan` — given that gap (a DISPLAY row `B`: "insert before row B"), which frame receives
///      the objects, which MODEL lane they start on, and which of the other objects and comments
///      change lane;
///   3. the caller (`EditViewModel.commitMoveDrop`) carries the plan out through the very primitives
///      the normal drop uses, by handing them the selection brought to RANKS (0, 1, 2… without
///      holes, `LaneCompaction`) and the base lane `plan.lane`.
///
/// No SoundObject here: the caller flattens what it knows into `Sibling`s and `Frame`s, which is
/// what lets the test compile this very file.
nonisolated enum LaneInsertion {

    /// A sibling of a frame: an object (with the rows it unfolds under itself — an open group's
    /// children, a piano roll, an automation band) or a comment (`span` 0, never moved).
    struct Sibling: Equatable {
        let id: UUID
        let lane: Int
        let span: Int
        let isMoved: Bool
    }

    /// The lanes of one parent: the root, or the children of a group.
    struct Frame {
        /// nil = the root.
        let parentID: UUID?
        /// The display row the frame's lane 0 is drawn on (0 for the root, the group's row + 1).
        let origin: Int
        /// The rows its band holds (a group: `childLaneCount`, drop row included); `Int.max` for the root.
        let rowCount: Int
        /// The group is a moved object or one of its descendants: never a target.
        let isMoved: Bool
        let siblings: [Sibling]

        init(parentID: UUID?, origin: Int, rowCount: Int, isMoved: Bool = false, siblings: [Sibling]) {
            self.parentID = parentID
            self.origin = origin
            self.rowCount = rowCount
            self.isMoved = isMoved
            self.siblings = siblings
        }
    }

    struct Plan: Equatable {
        /// The frame that receives the objects (nil = the root).
        let parentID: UUID?
        /// `B`: the objects land BEFORE this display row (for the line and for the release).
        let boundaryRow: Int
        /// `b`: the model lane under the gap, BEFORE the gesture (what the HUD names).
        let laneBefore: Int
        /// `b'`: the first lane of the inserted block, AFTER the lanes the selection empties closed up.
        let lane: Int
        /// `k`: the number of distinct lanes of the selection (the block's height in lanes).
        let count: Int
        /// The objects AND comments that are not moved and whose lane changes (source and target
        /// frames), with their new lane.
        let laneChanges: [UUID: Int]
    }

    // MARK: - 1. The gap under the block

    /// The half-width of the insertion band around the middle of a gap, in ROWS: the block must be
    /// straddling two rows to within this much. 12 % of the row step, between 4 and 14 px.
    static func halfBand(laneStep: Double) -> Double {
        guard laneStep > 0 else { return 0 }
        return min(14, max(4, 0.12 * laneStep)) / laneStep
    }

    /// `rawRows`: the vertical travel of the hand in rows (`translation.height / laneStep`), signed.
    /// The block's centre is then on the continuous row `r = grabbedDisplayLane + rawRows`; when it
    /// sits within `halfBand` of the middle between two rows (`f = r − ⌊r⌋ ≈ 0.5`) the block
    /// straddles them and the gap is "before row ⌊r⌋ + 1". nil = not straddling (or above the top).
    static func boundaryRow(grabbedDisplayLane: Int, rawRows: Double, halfBand: Double) -> Int? {
        let r = Double(grabbedDisplayLane) + rawRows
        let fl = r.rounded(.down)
        let f = r - fl
        guard abs(f - 0.5) <= halfBand else { return nil }
        let b = Int(fl) + 1
        return b >= 0 ? b : nil
    }

    // MARK: - 2. The plan

    /// The selection's lanes brought to ranks (`id -> rank`): 1 and 3 land on b' and b' + 1.
    static func movedRanks(_ movedLanes: [UUID: Int]) -> [UUID: Int] {
        let r = LaneCompaction.ranks(of: Array(movedLanes.values))
        return movedLanes.mapValues { r[$0] ?? 0 }
    }

    /// What inserting before display row `B` does, or nil when there is nothing to insert between
    /// (the caller then falls back to the normal drop).
    ///
    /// - `openGroups`: the open groups whose band may hold `B` (their children as siblings).
    /// - `root`: the root frame.
    /// - `source`: the frame the moved objects come from (nil = unknown / none).
    /// - `movedLanes`: the moved objects' MODEL lanes in their own frame.
    /// - `isCopy`: ⌥ — the originals stay, nothing closes up.
    /// - `allowsGroupTarget`: false for an ⌥ copy from the root (it lands on the root only).
    static func plan(boundaryRow B: Int,
                     openGroups: [Frame],
                     root: Frame,
                     source: Frame?,
                     movedLanes: [UUID: Int],
                     isCopy: Bool,
                     allowsGroupTarget: Bool) -> Plan? {
        guard B >= 0, !movedLanes.isEmpty else { return nil }

        // The innermost open group whose band holds the gap — a moved one cancels (a group cannot
        // enter itself; the same case the normal drop answers `cancel` to).
        let holding = openGroups.filter { g in
            let cl = B - g.origin
            return cl >= 0 && cl < g.rowCount
        }
        if holding.contains(where: { $0.isMoved }) { return nil }
        let target: Frame
        if let inner = holding.max(by: { $0.origin < $1.origin }) {
            guard allowsGroupTarget else { return nil }
            target = inner
        } else {
            target = root
        }

        // B must be the START of a lane of that frame: inside a piano roll or an automation band
        // there is no gap.
        let b = MoveDropResolution.baseLane(
            forDisplay: B, origin: target.origin,
            siblings: target.siblings.map { MoveDropResolution.Lane(lane: $0.lane, span: $0.span) })
        var extra = 0
        for s in target.siblings where s.lane < b { extra += s.span }
        guard target.origin + b + extra == B else { return nil }

        // Somebody has to be pushed, otherwise the normal drop overwrites nothing anyway.
        // (An ⌥ copy leaves its originals standing: they are pushed like the others.)
        let pushed = target.siblings.filter { !(isCopy ? false : $0.isMoved) && $0.lane >= b }
        guard !pushed.isEmpty else { return nil }

        // The lanes of the source frame the selection empties entirely close up (a LIST reorder).
        // A lane that carries a comment is never emptied: the comment is a non-moved sibling.
        var vacated: [Int] = []
        let closing = !isCopy && source != nil
        if closing, let src = source {
            var byLane: [Int: (all: Int, moved: Int)] = [:]
            for s in src.siblings {
                var e = byLane[s.lane] ?? (0, 0)
                e.all += 1
                if s.isMoved { e.moved += 1 }
                byLane[s.lane] = e
            }
            vacated = byLane.filter { $0.value.all == $0.value.moved }.map(\.key).sorted()
        }
        func closed(_ lane: Int) -> Int { lane - vacated.filter { $0 < lane }.count }

        let sameFrame = closing && source?.parentID == target.parentID
        let bPrime = sameFrame ? b - vacated.filter { $0 < b }.count : b
        let k = Set(movedLanes.values).count

        var changes: [UUID: Int] = [:]
        // Source frame: the lanes close up (when it is not the target, that is all that happens
        // there; when it is, the shift below starts from the closed lane).
        if closing, let src = source {
            for s in src.siblings where !s.isMoved {
                var final = closed(s.lane)
                if sameFrame, final >= bPrime { final += k }
                if final != s.lane { changes[s.id] = final }
            }
        }
        // Target frame, when it is another frame than the source: only the shift.
        if !sameFrame {
            for s in target.siblings where !(isCopy ? false : s.isMoved) {
                if s.lane >= bPrime { changes[s.id] = s.lane + k }
            }
        }
        return Plan(parentID: target.parentID, boundaryRow: B, laneBefore: b, lane: bPrime,
                    count: k, laneChanges: changes)
    }
}
