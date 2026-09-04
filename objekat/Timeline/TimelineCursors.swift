import AppKit

// MARK: - Holding the cursor

/// What the host has to know how to do when the timeline hands back: release the cursor zone
/// laid on the view being touched (@see HoverTracker.TrackerView).
@MainActor
protocol TimelineCursorClaiming: AnyObject {
    /// Refreshes the claim for the last hovered point.
    func syncCursorClaim()
    func dropCursorClaim()
}

/// Holds the cursor the timeline WANTS to show, and gives it back when AppKit overrides it.
///
/// What puts the arrow back is the tracking-area manager:
/// `-[_NSTrackingAreaAKManager setCursorForMouseLocation:]`, called from the display cycle's
/// flush. On every SwiftUI update of the window — and there are a couple of dozen a second
/// during playback, if only for the transport counter — it looks for whoever claims the point
/// under the mouse and, finding nobody, puts the arrow back. With the mouse still, nothing
/// recomputed our cursor any more: hence 'right while I move, plain as soon as I stop'.
///
/// Two arrangements hold it:
/// - the CLAIM (@see CursorClaim, carried by HoverTracker.TrackerView) gives AppKit
///   somebody to ask;
/// - the END-OF-LOOP GUARD below puts the wanted cursor back after the display cycle, in
///   case the claim is not honoured.
///
/// NOT to be done again: turning the window's cursor rects off (`disableCursorRects`). That was
/// the previous attempt, and it did exactly the opposite of what was expected of it: it never
/// prevented a single arrow from being set (the tracking-area manager is another mechanism),
/// but it gagged the claim. Measured: with it, not a single `cursorUpdate` in three attempts;
/// without it, a couple of dozen a second and no arrow at all.
@MainActor
enum TimelineCursorKeeper {
    /// The last wanted cursor. `arrow` at rest: it is also what we put back on the way out.
    private(set) static var current: NSCursor = .arrow

    /// Does the timeline have the cursor? Not when the pointer is over a piano roll, an automation
    /// band or the ruler: those views set their own cursor (a point, a segment, a velocity, loop
    /// markers) and getting in front of them would make it flicker.
    private(set) static var owned = false

    /// The timeline's tracking view — a mark of ownership (several project windows can be open) and
    /// the carrier of the claim. Weak: it is a SwiftUI view, it comes and goes.
    ///
    static weak var host: NSView?

    static func set(_ cursor: NSCursor) {
        owned = true
        installLateGuard()
        current = cursor
        cursor.set()
        // The claim is laid HERE as much as on mouse movement: the piano roll and the automation
        // bands decide their cursor from their own SwiftUI hover, hence AFTER the tracking view has
        // handled the movement — without this reminder, entering a note and then stopping would
        // leave the point without a claimant, and the arrow would come back.
        (host as? TimelineCursorClaiming)?.syncCursorClaim()
    }

    /// Hands back: the cursors of the rest of the window (the ruler's markers, the transport's
    /// zoom handles…) go back into service.
    static func relinquish() {
        owned = false
        (host as? TimelineCursorClaiming)?.dropCursorClaim()
    }

    /// A net: an end-of-runloop observer, which puts the wanted cursor back if it was overridden
    /// all the same.
    ///
    /// It wakes as the loop goes to sleep — hence AFTER the display cycle the AppKit arrow-setting
    /// comes from — with a deliberately huge order so as to queue behind every AppKit and Core
    /// Animation observer. It does nothing while the wanted cursor is already in place, which is
    /// now the case at all times (measured: zero recoveries a second once the claim is honoured).
    /// It is kept in case the claim were to drop between two mouse movements — SwiftUI rebuilds
    /// its tracking areas whenever it pleases, and nothing would lay it again before the next
    /// movement.
    private static var lateGuard: CFRunLoopObserver?

    private static func installLateGuard() {
        guard lateGuard == nil else { return }
        let observer = CFRunLoopObserverCreateWithHandler(
            nil, CFRunLoopActivity.beforeWaiting.rawValue, true, .max
        ) { _, _ in
            MainActor.assumeIsolated {
                guard owned, NSCursor.current !== current else { return }
                current.set()
            }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        lateGuard = observer
    }
}

enum TimelineCursors {

    static let fadeIn: NSCursor    = makeDiagonal(slash: true)
    static let fadeOut: NSCursor   = makeDiagonal(slash: false)

    /// The edge cursor: the bracket of the edge being grabbed (`[` start, `]` end) and, BELOW it,
    /// two small arrows saying where that edge can still go. They go out one by one when a stop is
    /// reached (timeline 0, the start / end of the source content, the minimum length) — on hover
    /// as DURING the drag, which updates them live.
    static func edge(open: Bool, canLeft: Bool, canRight: Bool) -> NSCursor {
        let key = EdgeKey(open: open, canLeft: canLeft, canRight: canRight)
        if let c = edgeCache[key] { return c }
        let c = makeEdge(open: open, canLeft: canLeft, canRight: canRight)
        edgeCache[key] = c
        return c
    }

    private struct EdgeKey: Hashable { let open: Bool; let canLeft: Bool; let canRight: Bool }
    /// Immutable and few in number (8 combinations): made once, then reused — `set()` is called on
    /// every hover event and on every drag step.
    private static var edgeCache: [EdgeKey: NSCursor] = [:]

    /// The edge cursor ON A LOOPED OBJECT: the same bracket, but an '∞' in place of the small
    /// arrows — beyond the edge, it REPEATS the content, it no longer reveals more of it. No
    /// `canLeft`/`canRight` variant: while looping the travel is unbounded on both sides
    /// (@see SoundObject.contentRoomAfter, [[loop-item-plan]]).
    static let loopEdgeOpen: NSCursor  = makeLoopEdge(open: true)
    static let loopEdgeClose: NSCursor = makeLoopEdge(open: false)
    static func loopEdge(open: Bool) -> NSCursor { open ? loopEdgeOpen : loopEdgeClose }

    private static func makeLoopEdge(open: Bool) -> NSCursor {
        let size = NSSize(width: 20, height: 26)
        let image = NSImage(size: size)
        image.lockFocus()
        defer { image.unlockFocus() }

        let cx = size.width / 2
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 15, weight: .semibold),
            .foregroundColor: NSColor.black
        ]
        let str = NSAttributedString(string: open ? "[" : "]", attributes: attrs)
        let strSize = str.size()
        str.draw(at: NSPoint(x: cx - strSize.width / 2, y: size.height - strSize.height - 1))

        let loopAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .bold),
            .foregroundColor: NSColor.black.withAlphaComponent(0.75)
        ]
        let loopStr = NSAttributedString(string: "∞", attributes: loopAttrs)
        let loopSize = loopStr.size()
        loopStr.draw(at: NSPoint(x: cx - loopSize.width / 2, y: 2))

        return NSCursor(image: image, hotSpot: NSPoint(x: cx, y: strSize.height / 2 + 1))
    }

    private static func makeEdge(open: Bool, canLeft: Bool, canRight: Bool) -> NSCursor {
        let size = NSSize(width: 20, height: 26)
        let image = NSImage(size: size)
        image.lockFocus()
        defer { image.unlockFocus() }

        // The AppKit frame of reference: y UPWARDS. The bracket takes the top of the image, and the
        // arrows sit just below it.
        let cx = size.width / 2
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 15, weight: .semibold),
            .foregroundColor: NSColor.black
        ]
        let str = NSAttributedString(string: open ? "[" : "]", attributes: attrs)
        let strSize = str.size()
        str.draw(at: NSPoint(x: cx - strSize.width / 2, y: size.height - strSize.height - 1))

        // Discreet arrows (a thin line, muted black), symmetrical about the bracket's axis and
        // clearly DETACHED from it: laid right at the bottom of the image, they read as an
        // annotation of the bracket, not as part of its drawing.
        let arrowY: CGFloat = 3
        let path = NSBezierPath()
        func arrow(sign: CGFloat) {
            let tail = NSPoint(x: cx + sign * 2.0, y: arrowY)
            let head = NSPoint(x: cx + sign * 6.0, y: arrowY)
            path.move(to: tail); path.line(to: head)
            path.move(to: head); path.line(to: NSPoint(x: cx + sign * 4.0, y: arrowY + 1.9))
            path.move(to: head); path.line(to: NSPoint(x: cx + sign * 4.0, y: arrowY - 1.9))
        }
        if canLeft  { arrow(sign: -1) }
        if canRight { arrow(sign:  1) }
        path.lineWidth = 0.9
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        NSColor.black.withAlphaComponent(0.75).setStroke()
        path.stroke()

        // The hot spot on the bracket itself (the edge actually grabbed), not at the centre.
        // The hot spot on the bracket itself (the edge actually grabbed), not at the centre.
        return NSCursor(image: image, hotSpot: NSPoint(x: cx, y: strSize.height / 2 + 1))
    }

    private static func makeDiagonal(slash: Bool) -> NSCursor {
        let size: CGFloat = 16
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()
        defer { image.unlockFocus() }

        let path = NSBezierPath()
        let inset: CGFloat = 2
        if slash {
            // "/" — bottom-left -> top-right
            path.move(to: NSPoint(x: inset, y: inset))
            path.line(to: NSPoint(x: size - inset, y: size - inset))
        } else {
            // "\\" — top-left -> bottom-right
            path.move(to: NSPoint(x: inset, y: size - inset))
            path.line(to: NSPoint(x: size - inset, y: inset))
        }
        path.lineWidth = 2
        path.lineCapStyle = .round
        NSColor.black.setStroke()
        path.stroke()

        return NSCursor(image: image, hotSpot: NSPoint(x: size / 2, y: size / 2))
    }
}
