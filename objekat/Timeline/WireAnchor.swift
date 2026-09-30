import Foundation

// MARK: - Where a link wire lands on a block — and nothing else
//
// A wire (the red send links first of all) used to land on the MIDDLE of the block it reaches. For
// a block wider than the window — a long object, and above all an infinite bus, whose band runs the
// whole timeline — that middle is screens away: the wire left the view and pointed at nothing.
//
// It lands on the middle of the block's VISIBLE portion now, kept a little inside the window's
// edges. A block that is wholly on screen keeps its exact middle, so nothing moves for the ordinary
// case. The arithmetic has no view and no model behind it, hence its own unit and a standalone test
// (@see tools/test_wire_anchor.swift). The caller MUST hand it the EXACT scroll
// (`TimelineScrollAnchor.x`, read inside the drawing closure) and not the culling window's
// `cullScrollX`, which is off by up to a notch.

/// How far inside the window's edges a wire lands, in px.
let wireAnchorMargin: Double = 24

/// The x (canvas coordinates) at which a wire should land on the block `[blockX, blockX + blockWidth]`.
///
/// - The block wholly inside the window, or wholly outside it: its exact middle.
/// - Otherwise: the middle of the part inside the window, clamped to the window shrunk by `margin`
///   on each side (and to the block itself). A window narrower than two margins collapses onto its
///   own middle.
func wireAnchorX(blockX: Double, blockWidth: Double,
                 scrollX: Double, viewportWidth: Double,
                 margin: Double = wireAnchorMargin) -> Double {
    let mid = blockX + blockWidth / 2
    let blockEnd = blockX + blockWidth
    let winStart = scrollX, winEnd = scrollX + viewportWidth
    // Wholly on screen: nothing to adapt.
    if blockX >= winStart && blockEnd <= winEnd { return mid }
    let v0 = max(blockX, winStart), v1 = min(blockEnd, winEnd)
    // Nothing of the block is visible: there is no better place than its middle.
    guard v1 > v0 else { return mid }
    let visibleMid = (v0 + v1) / 2
    let lo = winStart + margin, hi = winEnd - margin
    guard hi > lo else { return (winStart + winEnd) / 2 }
    // Inside the margins, and never outside the block itself.
    let x = min(max(visibleMid, lo), hi)
    return min(max(x, blockX), blockEnd)
}
