import Foundation

/// The lanes of the objects a new group takes in, brought back to 0, 1, 2… without the HOLES.
///
/// Grouping objects that sat on lanes 1, 3 and 6 used to give a group whose children kept those
/// relative gaps (0, 2, 5): two empty rows inside the unfolded group, for nothing. The rule is the
/// RANK of the lane among the distinct lanes taken in: relative order kept, empty intermediate lanes
/// squeezed out, and objects that shared a lane (a crossfade chain, a take after a take) still
/// sharing it. The group itself stays where it was (its own lane is not touched by this).
///
/// Pure, so `tools/test_lane_compaction.swift` can compile it alone.
nonisolated enum LaneCompaction {

    /// `lane -> rank` for the distinct lanes of `lanes` (ascending: the lowest lane is rank 0).
    static func ranks(of lanes: [Int]) -> [Int: Int] {
        var out: [Int: Int] = [:]
        for (rank, lane) in Set(lanes).sorted().enumerated() { out[lane] = rank }
        return out
    }
}
