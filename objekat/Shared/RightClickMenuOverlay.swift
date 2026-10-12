import AppKit
import SwiftUI

// MARK: - A right click on a SwiftUI view, answered with an NSMenu

/// A transparent NSView laid over a SwiftUI view: it only catches the RIGHT click (`hitTest` returns
/// nil for any other event, so the left click, the hover and the scroll wheel of what lies under it
/// are untouched) and pops `menuProvider`'s menu up. Used by the stem strips' colour menu and by the
/// plugin browser's category menu.
final class RightClickCaptureView: NSView {
    var menuProvider: ((RightClickCaptureView) -> NSMenu)?
    /// Called once the menu is closed again, whether or not an item was taken (nil = nothing to do).
    var menuDidClose: (() -> Void)?

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let event = NSApp.currentEvent,
              event.type == .rightMouseDown || event.type == .rightMouseUp else { return nil }
        return super.hitTest(point)
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let menuProvider else { return }
        NSMenu.popUpContextMenu(menuProvider(self), with: event, for: self)
        menuDidClose?()
    }
}

/// `RightClickCaptureView` as a SwiftUI overlay. `menu` is evaluated at the CLICK, never at render time.
struct RightClickMenuOverlay: NSViewRepresentable {
    let menu: () -> NSMenu
    var onClose: (() -> Void)? = nil

    func makeNSView(context: Context) -> RightClickCaptureView {
        let v = RightClickCaptureView()
        bind(v)
        return v
    }

    func updateNSView(_ nsView: RightClickCaptureView, context: Context) { bind(nsView) }

    private func bind(_ v: RightClickCaptureView) {
        v.menuProvider = { _ in menu() }
        v.menuDidClose = onClose
    }
}
