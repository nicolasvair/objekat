import Foundation

// MARK: - Which blocks stay rich under a tool — the rule, and nothing else
//
// Foundation only, like `ToolOverlayGeometry` (which it reads): no view, no model, no scroll. Under
// the Volume / Pan / Aux tools EVERY block used to be a rich SwiftUI view, because each carried an
// interactive overlay (`ToolVolumeLayer`, `ToolPanLayer`, `ToolSendLayer`) — a view per block, which
// is what 1.4–1.9 fps at 600 blocks was made of. The overlays have a Canvas drawing now
// (@see ToolOverlayDrawing), and this is the rule that says which blocks still need the view:
//
//   (a) the block is AIMED AT — hovered, grabbed by a drag, or (Aux) holding the send focus. Its
//       overlay is the full one and it changes with the hand; one block at a time.
//   (b) the tool draws something over it AND it follows the EXACT scroll while the Canvas of the
//       blocks only knows the culling window (`cullScrollX`, a 512 px notch). A tool's controls sit
//       in the block's VISIBLE portion; `LiveScroll.spanIsInvariant` is false precisely for the
//       blocks a viewport edge can cut, within the notch, so those are the ones that must read the
//       live anchor — and the Canvas does not.
//
// A block the tool draws nothing on (an unselected wide one under Volume or Pan) is a Canvas block
// like any other; a narrow one (< 50 px) keeps the culling window's span in the rich views too
// (`needsExactSpan` is false for it), so the Canvas reproduces it exactly.
//
// The reasons that have nothing to do with the tool — a custom colour, a MIDI clip, an aux, a
// consolidated instance, a rename, a drag preview… — stay where they were
// (`TimelineView.clipRichReason` / `groupRichReason`) and are asked FIRST.
//
// Compiled alone and asserted with no screen: tools/test_tool_overlay_partition.swift.

enum ToolOverlayPartition {

    /// The tool, as far as the partition is concerned.
    enum Tool: Equatable {
        case none       // selection, cut… — nothing is laid over the blocks
        case volume
        case pan
        case aux
        case stem
    }

    enum Verdict: Equatable {
        /// The Canvas draws it (and the tool's overlay, when there is one — `drawsOverlay`).
        case canvas
        /// Rich: the block is aimed at.
        case richAimed
        /// Rich: the tool draws something here and it follows the exact scroll.
        case richSpan
    }

    /// What the tool lays over a block that is NOT aimed at: whether it draws anything, and whether
    /// what it draws follows the exact scroll (`needsExactSpan`) or the culling window's.
    struct Need: Equatable {
        let draws: Bool
        let needsExactSpan: Bool
        static let nothing = Need(draws: false, needsExactSpan: false)
    }

    /// `blockWidth` in px; `hasSendRows` = the Send tool has at least one column for this block.
    static func need(tool: Tool, blockWidth: Double, isSelected: Bool, hasSendRows: Bool) -> Need {
        switch tool {
        case .none, .stem:
            // Stem: only the aimed block draws (its veil), and that one is rich.
            return .nothing
        case .volume:
            // Not hovered: only the minimal veil can show (selected, or narrow).
            let plan = ToolOverlayGeometry.volumePlan(blockWidth: blockWidth, isSelected: isSelected,
                                                      isToolHovered: false)
            return Need(draws: plan.showMinimal, needsExactSpan: plan.showMinimal && plan.needsExactSpan)
        case .pan:
            let plan = ToolOverlayGeometry.panPlan(blockWidth: blockWidth, isSelected: isSelected,
                                                   isToolHovered: false)
            return Need(draws: plan.shown, needsExactSpan: plan.shown && plan.needsExactSpan)
        case .aux:
            // The columns always follow the exact scroll (they set off from the visible portion).
            return Need(draws: hasSendRows, needsExactSpan: hasSendRows)
        }
    }

    /// The rule. `spanIsInvariant` = `LiveScroll.spanIsInvariant` for this block (the visible span
    /// is the same for every exact scroll the current notch allows).
    static func verdict(tool: Tool, blockWidth: Double, isSelected: Bool, isAimed: Bool,
                        hasSendRows: Bool, spanIsInvariant: Bool) -> Verdict {
        if tool == .none { return .canvas }
        if isAimed { return .richAimed }
        let n = need(tool: tool, blockWidth: blockWidth, isSelected: isSelected, hasSendRows: hasSendRows)
        if n.draws && n.needsExactSpan && !spanIsInvariant { return .richSpan }
        return .canvas
    }
}
