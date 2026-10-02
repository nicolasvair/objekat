// The lane compaction of a new group (`Shared/LaneCompaction.swift`), asserted with no screen.
//
//     swiftc -parse-as-library ../objekat/Shared/LaneCompaction.swift test_lane_compaction.swift \
//         -o /tmp/lanecompact && /tmp/lanecompact

import Foundation

var fails = 0
func check(_ label: String, _ ok: Bool) {
    if ok { print("ok    " + label) } else { fails += 1; print("FAIL  " + label) }
}

@main
enum LaneCompactionTest {
  static func main() {
    func rel(_ lanes: [Int]) -> [Int] {
        let r = LaneCompaction.ranks(of: lanes)
        return lanes.map { r[$0]! }
    }
    check("1, 3, 6 -> 0, 1, 2", rel([1, 3, 6]) == [0, 1, 2])
    check("already compact stays (4, 5, 6 -> 0, 1, 2)", rel([4, 5, 6]) == [0, 1, 2])
    check("a single lane -> 0", rel([7]) == [0])
    check("objects sharing a lane keep sharing it (2, 2, 9, 2 -> 0, 0, 1, 0)", rel([2, 2, 9, 2]) == [0, 0, 1, 0])
    check("relative order is kept whatever the input order (6, 1, 3 -> 2, 0, 1)", rel([6, 1, 3]) == [2, 0, 1])
    check("zero and a far lane (0, 100 -> 0, 1)", rel([0, 100]) == [0, 1])
    check("nothing -> nothing", LaneCompaction.ranks(of: []).isEmpty)
    print(fails == 0 ? "ALL PASS" : "\(fails) FAILED")
    exit(fails == 0 ? 0 : 1)
  }
}
