import SwiftUI
import AppKit

// MARK: - The grip between the left panel and the timeline
//
// A 1 pt line in the middle of a 5 pt hit area (@see LeftPanelLayout.dividerWidth). It replaces the
// split view's own divider, whose position nobody could read or save: this one WRITES the panel's width
// into the view-model, and the panel is a fixed-width column that follows.
//
// The travel is measured in the GLOBAL coordinate space, from where the mouse went down: the handle moves
// under the hand as the panel resizes, so a travel measured in its own coordinates would feed back on itself.

struct LeftPanelDivider: View {
    /// The width the panel has now (the stored one).
    let width: Double
    /// The window's content width — the ceiling that keeps the timeline its minimum.
    let containerWidth: Double
    /// Every step of the drag, with the width it reaches.
    let onDrag: (Double) -> Void
    /// The end of the drag, with the width it reached (what the app remembers for the next project).
    let onEnd: (Double) -> Void

    /// The panel's width at the mouse-down; nil outside a drag.
    @State private var startWidth: Double? = nil

    var body: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(width: 1)
            .frame(width: LeftPanelLayout.dividerWidth)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .background(ResizeCursorArea())
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { v in
                        let start = startWidth ?? LeftPanelLayout.clampedWidth(width, containerWidth: containerWidth)
                        startWidth = start
                        onDrag(LeftPanelLayout.draggedWidth(startWidth: start,
                                                            travelX: v.location.x - v.startLocation.x,
                                                            containerWidth: containerWidth))
                    }
                    .onEnded { v in
                        let start = startWidth ?? LeftPanelLayout.clampedWidth(width, containerWidth: containerWidth)
                        startWidth = nil
                        let reached = LeftPanelLayout.draggedWidth(startWidth: start,
                                                                 travelX: v.location.x - v.startLocation.x,
                                                                 containerWidth: containerWidth)
                        onDrag(reached)
                        onEnd(reached)
                    }
            )
    }
}

/// The left-right resize cursor over the whole handle, through a cursor rect (the system's own mechanism: it
/// follows the pointer with no tracking of ours, and is withdrawn by AppKit when the handle leaves the
/// window). The view takes no mouse event itself: they go on to the SwiftUI gesture above it.
private struct ResizeCursorArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { CursorView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class CursorView: NSView {
        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .resizeLeftRight)
        }
        override func layout() {
            super.layout()
            window?.invalidateCursorRects(for: self)
        }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
