import CoreGraphics

/// Where a plugin editor window REOPENS: the geometry of "back where it was, and on screen".
/// Pure, AppKit coordinates (bottom-left origin, y up); a screen is its `visibleFrame` (menu bar and
/// Dock already taken out). Compiled alone by `tools/test_editor_frame_placement.swift`.
///
/// What is remembered is the window's TOP-LEFT corner, not its origin: the size of an editor is the
/// plugin's to change (a resizable GUI, a scale setting, a newer version), and the corner that stays
/// put when a window grows is the top-left one, the way JUCE and the title bar both read it.
///
/// The remembered corner can be anywhere by the time the window comes back — the screen it was on
/// is no longer plugged in, the arrangement changed, the editor is now bigger — so the answer is
/// always a place the window can be SEEN:
///  - the screen is the one the window overlapped most; when it overlaps none (its own is gone) the
///    nearest one, `visibleFrames[0]` winning a tie (the main screen comes first in `NSScreen.screens`);
///  - the title bar never goes above the screen's visible area, and a window that fits is never left
///    partly below or beside it either; one bigger than the screen keeps its title bar and its left
///    edge (anchored top-left, as `EditorTiling` does).
enum EditorFramePlacement {

    /// The window's origin (bottom-left) for a window of `size` that was last seen with its top-left
    /// corner at `topLeft`. With no screen to judge against (none is known), the corner as it was.
    static func origin(topLeft: CGPoint, size: CGSize, visibleFrames: [CGRect]) -> CGPoint {
        let rect = CGRect(x: topLeft.x, y: topLeft.y - size.height, width: size.width, height: size.height)
        guard let area = area(for: rect, in: visibleFrames) else { return rect.origin }

        // Left / right: inside the area when the window fits, else anchored on the left edge.
        let x = max(area.minX, min(rect.minX, area.maxX - size.width))
        // Top: never above the area. Bottom: not below it either, unless the window is taller than the area
        // (then the top stays visible and the bottom is cut — the title bar is what one grabs).
        var y = min(rect.minY, area.maxY - size.height)
        if size.height <= area.height { y = max(y, area.minY) }
        return CGPoint(x: x, y: y)
    }

    /// The screen a window at `rect` belongs to: the one it overlaps most, else the nearest (by the
    /// distance from the window's centre), the first of the list winning ties. nil for an empty list.
    static func area(for rect: CGRect, in frames: [CGRect]) -> CGRect? {
        var best: (frame: CGRect, overlap: CGFloat)? = nil
        for f in frames {
            let i = f.intersection(rect)
            let overlap = i.isNull ? 0 : i.width * i.height
            if overlap > (best?.overlap ?? 0) { best = (f, overlap) }
        }
        if let best { return best.frame }
        let centre = CGPoint(x: rect.midX, y: rect.midY)
        var nearest: (frame: CGRect, distance: CGFloat)? = nil
        for f in frames {
            let dx = max(f.minX - centre.x, 0, centre.x - f.maxX)
            let dy = max(f.minY - centre.y, 0, centre.y - f.maxY)
            let d = dx * dx + dy * dy
            if d < (nearest?.distance ?? .greatestFiniteMagnitude) { nearest = (f, d) }
        }
        return nearest?.frame
    }
}
