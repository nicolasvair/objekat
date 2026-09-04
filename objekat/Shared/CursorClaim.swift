import AppKit
import SwiftUI

// MARK: - Cursor claim

/// Has AppKit claim a cursor for the point under the mouse.
///
/// WORTH KNOWING, or none of what follows makes sense: setting a cursor with `NSCursor.set()`
/// does not hold. The tracking-area manager (`-[_NSTrackingAreaAKManager
/// setCursorForMouseLocation:]`) is called from the display cycle's flush, hence on EVERY SwiftUI
/// update of the window — a couple of dozen a second during playback, if only for the transport
/// counter. It looks for whoever claims the point under the mouse and, finding nobody, puts the
/// arrow back. It always comes after us: our own settings come from events earlier than the
/// cycle. The result is a correct cursor while the mouse moves, and the arrow as soon as it stops.
///
/// The way round is to give it somebody to ask. Two traps lead there:
/// - a `.cursorUpdate` tracking area is only consulted on a view reachable by hit-testing;
///   an overlay view that returns `nil` to let clicks through is ignored. Hence the area laid
///   on the view ACTUALLY hit under the pointer, with a separate owner;
/// - `NSWindow.disableCursorRects()` gags that claim (measured: not a single `cursorUpdate`
///   left) without preventing a single arrow from being set. Never to be called again here.
///
/// See also `TimelineCursorKeeper` (the timeline's dynamic cursor) and `CursorZone` (a fixed
/// cursor over a SwiftUI area).
@MainActor
final class CursorClaim {

    /// The cursor to impose, asked for again on every AppKit query — `nil` = we claim nothing and
    /// normal behaviour resumes.
    private let cursor: () -> NSCursor?

    private var area: NSTrackingArea?
    private weak var host: NSView?

    init(cursor: @escaping () -> NSCursor?) {
        self.cursor = cursor
    }

    /// Lays down (or moves) the claim for the given point, in WINDOW coordinates.
    /// To be called again on every mouse move: the view being touched changes, and SwiftUI may have
    /// rebuilt its tracking areas in the meantime, carrying ours away.
    func post(from view: NSView, at locationInWindow: NSPoint) {
        // The window's frame view has the same coordinates as the window: its `hitTest`
        // gives the deepest view under the pointer directly.
        guard let window = view.window,
              let hit = window.contentView?.superview?.hitTest(locationInWindow)
                        ?? window.contentView,
              hit !== view
        else { return }
        if hit === host, let a = area, hit.trackingAreas.contains(a) { return }
        drop()
        let a = NSTrackingArea(rect: .zero,
                               options: [.activeInActiveApp, .cursorUpdate, .inVisibleRect],
                               owner: owner, userInfo: nil)
        hit.addTrackingArea(a)
        area = a
        host = hit
    }

    /// Releases the claim: AppKit takes its decisions back for that point.
    func drop() {
        guard let a = area else { return }
        if let h = host, h.trackingAreas.contains(a) { h.removeTrackingArea(a) }
        area = nil
        host = nil
    }

    deinit { MainActor.assumeIsolated { drop() } }

    private lazy var owner = Owner(cursor: cursor)

    /// The area's owner, the one AppKit asks for the cursor. A separate object: when it is the
    /// overlay view itself, AppKit never asks it (it is not reachable by hit-testing).
    private final class Owner: NSResponder {
        private let cursor: () -> NSCursor?
        init(cursor: @escaping () -> NSCursor?) {
            self.cursor = cursor
            super.init()
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has no place here") }

        override func cursorUpdate(with event: NSEvent) {
            MainActor.assumeIsolated {
                guard let c = cursor() else { return super.cursorUpdate(with: event) }
                c.set()
            }
        }
    }
}

// MARK: - Fixed-cursor area

extension View {
    /// Imposes `cursor` while this view is hovered, and HOLDS it — unlike an
    /// `.onHover { NSCursor…push()/pop() }`, which AppKit undoes on the first window update where
    /// the mouse does not move (@see CursorClaim).
    ///
    /// An overlay transparent to clicks: the view's SwiftUI gestures keep working.
    func cursorZone(_ cursor: NSCursor) -> some View {
        overlay(CursorZone(cursor: cursor))
    }
}

/// The overlay that claims a fixed cursor while the mouse hovers it.
struct CursorZone: NSViewRepresentable {
    var cursor: NSCursor

    func makeNSView(context: Context) -> ZoneView { ZoneView(cursor: cursor) }
    func updateNSView(_ v: ZoneView, context: Context) { v.cursor = cursor }

    final class ZoneView: NSView {
        var cursor: NSCursor
        private var claim: CursorClaim!
        private var trackingArea: NSTrackingArea?

        init(cursor: NSCursor) {
            self.cursor = cursor
            super.init(frame: .zero)
            claim = CursorClaim { [weak self] in self?.cursor }
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has no place here") }

        // Transparent to hit-testing: clicks and gestures pass through to the view being dressed.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            // `.inVisibleRect` makes the area follow on its own: nothing more to redo afterwards.
            guard trackingArea == nil else { return }
            let t = NSTrackingArea(rect: bounds,
                                   options: [.activeInActiveApp, .mouseMoved,
                                             .mouseEnteredAndExited, .inVisibleRect],
                                   owner: self, userInfo: nil)
            addTrackingArea(t)
            trackingArea = t
        }

        override func mouseEntered(with event: NSEvent) { claim.post(from: self, at: event.locationInWindow) }
        override func mouseMoved(with event: NSEvent)   { claim.post(from: self, at: event.locationInWindow) }
        override func mouseExited(with event: NSEvent)  { claim.drop() }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { claim.drop() }
        }
    }
}
