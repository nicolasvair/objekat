// Which blocks stay rich under a tool — the partition rule, asserted with no screen.
//
// `ToolOverlayPartition` is Foundation only and reads `ToolOverlayGeometry` (the narrow-block rule,
// who shows what). The rule: a block is rich under a tool only if it is AIMED AT, or the tool draws
// something on it AND it follows the exact scroll while the Canvas knows only the culling window.
// Everything else — an unselected wide block under Volume or Pan, any block under no tool, a block
// no viewport edge can cut — is the Canvas's.
//
//     swiftc -parse-as-library \
//         ../objekat/Timeline/SendColumns.swift ../objekat/Timeline/ToolOverlayGeometry.swift \
//         ../objekat/Timeline/ToolOverlayPartition.swift \
//         test_tool_overlay_partition.swift -o /tmp/toolpartition && /tmp/toolpartition
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

typealias P = ToolOverlayPartition

func v(_ tool: P.Tool, w: Double = 200, selected: Bool = false, aimed: Bool = false,
       rows: Bool = false, invariant: Bool = true) -> P.Verdict {
    P.verdict(tool: tool, blockWidth: w, isSelected: selected, isAimed: aimed,
              hasSendRows: rows, spanIsInvariant: invariant)
}

@main
enum ToolOverlayPartitionTest {
  static func main() {

    // No tool: nothing is laid over the blocks, whatever else is true.
    for sel in [false, true] {
        check("no tool, selected=\(sel): canvas", v(.none, selected: sel, invariant: false) == .canvas)
        check("no tool, aimed: canvas (nothing to aim with)", v(.none, selected: sel, aimed: true) == .canvas)
    }

    // The aimed block is always rich, under every tool, whatever its width, selection or span.
    for tool in [P.Tool.volume, .pan, .aux, .stem] {
        for w in [2.0, 49.0, 50.0, 400.0] {
            check("\(tool) aimed w=\(w): rich (aimed)", v(tool, w: w, aimed: true) == .richAimed)
            check("\(tool) aimed w=\(w) selected, edge-cut: rich (aimed)",
                  v(tool, w: w, selected: true, aimed: true, rows: true, invariant: false) == .richAimed)
        }
    }

    // Volume: a wide unselected block draws nothing → canvas, even when a viewport edge cuts it.
    check("volume wide unselected, edge-cut: canvas", v(.volume, invariant: false) == .canvas)
    check("volume wide unselected, invariant: canvas", v(.volume) == .canvas)
    // A wide SELECTED one draws the minimal veil on the visible portion: exact span needed.
    check("volume wide selected, invariant: canvas", v(.volume, selected: true) == .canvas)
    check("volume wide selected, edge-cut: rich (span)", v(.volume, selected: true, invariant: false) == .richSpan)
    // A narrow one draws the minimal veil but keeps the culling window's span: canvas always.
    check("volume narrow (49), edge-cut: canvas", v(.volume, w: 49, invariant: false) == .canvas)
    check("volume narrow (49) selected, edge-cut: canvas", v(.volume, w: 49, selected: true, invariant: false) == .canvas)
    check("volume 50 px selected, edge-cut: rich (span)", v(.volume, w: 50, selected: true, invariant: false) == .richSpan)

    // Pan: the panel shows on a selected block (exact span), or a narrow one (culling span).
    check("pan wide unselected, edge-cut: canvas", v(.pan, invariant: false) == .canvas)
    check("pan wide selected, invariant: canvas", v(.pan, selected: true) == .canvas)
    check("pan wide selected, edge-cut: rich (span)", v(.pan, selected: true, invariant: false) == .richSpan)
    check("pan narrow, edge-cut: canvas", v(.pan, w: 10, invariant: false) == .canvas)

    // Stem: only the aimed block draws (its veil), so nothing else is ever rich.
    check("stem not aimed, edge-cut, selected: canvas", v(.stem, selected: true, invariant: false) == .canvas)

    // Aux: the columns follow the exact scroll, whatever the width — rich only when there ARE
    // columns and a viewport edge can cut the block.
    check("aux with rows, edge-cut: rich (span)", v(.aux, rows: true, invariant: false) == .richSpan)
    check("aux with rows, narrow, edge-cut: rich (span)", v(.aux, w: 20, rows: true, invariant: false) == .richSpan)
    check("aux with rows, invariant: canvas", v(.aux, rows: true) == .canvas)
    check("aux without rows, edge-cut: canvas (nothing to draw)", v(.aux, rows: false, invariant: false) == .canvas)

    // `need`: what the tool lays over a block that is not aimed at.
    check("need volume wide unselected: nothing", P.need(tool: .volume, blockWidth: 200, isSelected: false, hasSendRows: false) == .nothing)
    check("need volume narrow: draws, culling span",
          P.need(tool: .volume, blockWidth: 30, isSelected: false, hasSendRows: false) == P.Need(draws: true, needsExactSpan: false))
    check("need pan selected: draws, exact span",
          P.need(tool: .pan, blockWidth: 200, isSelected: true, hasSendRows: false) == P.Need(draws: true, needsExactSpan: true))
    check("need aux with rows: draws, exact span",
          P.need(tool: .aux, blockWidth: 200, isSelected: false, hasSendRows: true) == P.Need(draws: true, needsExactSpan: true))
    check("need stem: nothing", P.need(tool: .stem, blockWidth: 200, isSelected: true, hasSendRows: true) == .nothing)

    // Consistency over the whole input space: a canvas verdict never has an unmet exact-span need,
    // and a rich-span verdict always has one.
    var swept = 0
    for tool in [P.Tool.none, .volume, .pan, .aux, .stem] {
        for w in [2.0, 30.0, 49.99, 50.0, 120.0, 800.0] {
            for sel in [false, true] { for rows in [false, true] { for inv in [false, true] {
                let verdict = v(tool, w: w, selected: sel, aimed: false, rows: rows, invariant: inv)
                let n = P.need(tool: tool, blockWidth: w, isSelected: sel, hasSendRows: rows)
                let wantsExact = tool != .none && n.draws && n.needsExactSpan && !inv
                swept += 1
                if (verdict == .richSpan) != wantsExact {
                    check("sweep \(tool) w=\(w) sel=\(sel) rows=\(rows) inv=\(inv)", false, "\(verdict)")
                }
            } } }
        }
    }
    check("sweep over \(swept) inputs: rich-span <=> draws && needs exact span && edge-cut", true)

    print("\n\(total - fails.count)/\(total) passed")
    exit(fails.isEmpty ? 0 : 1)
  }
}
