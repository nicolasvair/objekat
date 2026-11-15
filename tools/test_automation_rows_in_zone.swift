// Which automation rows a zone reaches — the arithmetic, asserted with no screen.
//
// `AutomationZoneFilter.swift` depends on nothing but Foundation. The filter is what keeps two
// objects laid on the SAME lane (consecutive children of a group) from being confused: their bands
// share a lane number and nothing else.
//
//     swiftc -parse-as-library ../objekat/Shared/AutomationZoneFilter.swift \
//         test_automation_rows_in_zone.swift -o /tmp/autozone && /tmp/autozone
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

typealias Z = AutomationZoneFilter

func span(_ a: Double, _ b: Double) -> ClosedRange<Double> { a...b }

@main
struct Main {
    static func main() {
        // --- a zone with a length ---------------------------------------------------------------
        check("zone inside the span", Z.reaches(span: span(0, 10), zone: 2...4))
        check("zone straddling the span's start", Z.reaches(span: span(5, 10), zone: 3...6))
        check("zone straddling the span's end", Z.reaches(span: span(0, 5), zone: 4...8))
        check("zone covering the span", Z.reaches(span: span(2, 3), zone: 0...10))
        check("zone wholly before", !Z.reaches(span: span(5, 10), zone: 0...4))
        check("zone wholly after", !Z.reaches(span: span(0, 5), zone: 6...9))
        // the edges: two children laid end to end, a zone exactly over the second
        check("edge: zone starting where the span ends does NOT reach it", !Z.reaches(span: span(0, 5), zone: 5...10))
        check("edge: zone ending where the span starts does NOT reach it", !Z.reaches(span: span(5, 10), zone: 0...5))
        check("edge: zone exactly over the span", Z.reaches(span: span(5, 10), zone: 5...10))
        check("edge: a rounding error at the seam does not read as an overlap",
              !Z.reaches(span: span(0, 5.0000000001), zone: 5...10))
        check("edge: a real overlap (1 ms) does", Z.reaches(span: span(0, 5.001), zone: 5...10))

        // --- a zone with no length --------------------------------------------------------------
        check("null zone inside", Z.reaches(span: span(0, 10), zone: 4...4))
        check("null zone on the span's start (edge included)", Z.reaches(span: span(5, 10), zone: 5...5))
        check("null zone on the span's end (edge included)", Z.reaches(span: span(5, 10), zone: 10...10))
        check("null zone before", !Z.reaches(span: span(5, 10), zone: 4...4))
        check("null zone after", !Z.reaches(span: span(5, 10), zone: 11...11))

        // --- an infinite bus ---------------------------------------------------------------------
        let inf = Z.span(origin: 7, duration: 3, isInfinite: true)
        check("infinite: always reached (zone)", Z.reaches(span: inf, zone: -50...(-40)))
        check("infinite: always reached (far zone)", Z.reaches(span: inf, zone: 9000...9001))
        check("infinite: always reached (null zone)", Z.reaches(span: inf, zone: 123...123))
        let fin = Z.span(origin: 7, duration: 3, isInfinite: false)
        check("span of a finite object", fin == 7...10)
        check("span with a negative origin (temps négatif)", Z.span(origin: -2, duration: 5, isInfinite: false) == (-2)...3)
        check("a negative duration does not invert the span", Z.span(origin: 4, duration: -1, isInfinite: false) == 4...4)

        // --- the filter: lanes AND time ----------------------------------------------------------
        struct Row { var name: String; var lane: Int; var span: ClosedRange<Double> }
        let rows = [Row(name: "A", lane: 1, span: 0...5),
                    Row(name: "B", lane: 1, span: 5...10),
                    Row(name: "C", lane: 2, span: 0...10),
                    Row(name: "bus", lane: 3, span: Z.span(origin: 0, duration: 0, isInfinite: true))]
        func pick(_ lanes: Set<Int>, _ zone: ClosedRange<Double>) -> [String] {
            Z.rows(rows, lanes: lanes, zone: zone, lane: { $0.lane }, span: { $0.span }).map(\.name)
        }
        check("two objects on one lane: a zone over A takes A only", pick([1], 1...4) == ["A"])
        check("two objects on one lane: a zone over B takes B only", pick([1], 6...9) == ["B"])
        check("two objects on one lane: a zone exactly over B takes B only", pick([1], 5...10) == ["B"])
        check("a zone across both takes both, in order", pick([1], 3...7) == ["A", "B"])
        check("lanes still filter", pick([2], 1...4) == ["C"])
        check("several lanes, in order", pick([1, 2, 3], 6...9) == ["B", "C", "bus"])
        check("a lane with no row", pick([9], 0...10).isEmpty)
        check("a zone beyond every object only reaches the infinite bus", pick([1, 2, 3], 50...60) == ["bus"])

        print("\n\(total) assertions, \(fails.count) failed")
        print(fails.isEmpty ? "ALL PASS" : "FAILED:\n  " + fails.joined(separator: "\n  "))
        exit(fails.isEmpty ? 0 : 1)
    }
}
