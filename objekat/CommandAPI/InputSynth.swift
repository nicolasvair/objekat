import AppKit
@preconcurrency import CoreGraphics   // CGEvent is not Sendable; it crosses to the main queue once, untouched

/// Synthetic input for the navigation commands (`input.*`, @see Commands+View).
///
/// The rule this file exists for: a scripted scroll or zoom must go through EXACTLY the door a hand
/// goes through. So nothing here calls a setter of the viewport — it builds real `CGEvent`s
/// (pixel-precise scroll with trackpad phases and inertia, key presses) and hands them to the
/// app's own event queue. From there they meet the same local monitors
/// (@see TimelineKeyHandler) and the same `NSScrollView` as the events of a real trackpad.
///
/// The one exception is the HOVER: the timeline only zooms when it believes the pointer is over it,
/// and it learns that from its `NSTrackingArea`, which a synthetic event does not feed. The hover
/// is therefore set through `HoverTracker.TrackerView.simulateHover` — the same callback a
/// `mouseMoved` calls, minus the mouse (decision of 24 September).
///
/// Every event carries `tag` in `eventSourceUserData`: `InputProbe` tells a scripted event from a
/// real one with it, which is what `contaminated` in a report rests on.
enum InputSynth {

    /// "OBJEKAT synth" — any value no real device writes into `eventSourceUserData` (they write 0).
    nonisolated static let tag: Int64 = 0x0B7E_5A17

    /// How the event reaches the app's queue. Measured, not assumed: `input.selftest` says which
    /// one really reaches the monitors AND moves the scroll view on this machine.
    enum Route: String, CaseIterable, Sendable {
        /// `CGEvent.postToPid(getpid())` — would arrive as if from the window server. Measured
        /// NOT delivered on macOS 15 (24 September 2026), silently; kept for `input.selftest` to
        /// re-ask on another system.
        case cgevent
        /// `NSApp.postEvent` — the app's own event queue, the one a real event is taken from:
        /// under load, events pile up there exactly as a trackpad's do. The default.
        case post
        /// `NSApp.sendEvent` — straight to dispatch, bypassing the queue. The last resort.
        case send
    }

    /// Where an event lands: a window and a point in it, in both coordinate systems AppKit and
    /// Core Graphics need.
    struct Target: Sendable {
        let windowNumber: Int
        /// Global display coordinates, origin top-left of the main screen (Core Graphics).
        let globalPoint: CGPoint
        /// The same point in the window, origin TOP-left (the convention of a CGEvent's window
        /// location).
        let windowPoint: CGPoint
        /// The same point in AppKit's window coordinates (origin bottom-left) — what
        /// `NSEvent.locationInWindow` must read for the hit-test to land on the timeline.
        let appKitWindowPoint: CGPoint
        /// The same point in the timeline canvas's own coordinates (what the hover callback wants).
        let canvasPoint: CGPoint
    }

    // MARK: - The timeline, seen from outside

    /// The view that covers the whole timeline canvas (@see HoverTracker.TrackerView). nil with no
    /// interface (`--headless`) or before the timeline has appeared.
    static func timelineHost() throws -> HoverTracker.TrackerView {
        guard let host = TimelineCursorKeeper.host as? HoverTracker.TrackerView,
              host.window != nil else {
            throw CommandError(code: .invalid_state,
                               message: "no interface: the timeline is not on screen (--headless?)")
        }
        return host
    }

    /// Resolves a point given RELATIVE TO THE VISIBLE TIMELINE (origin top-left of what is on
    /// screen, in points) into a target. nil = the centre of the visible area.
    static func target(atViewport point: CGPoint?) throws -> Target {
        let host = try timelineHost()
        guard let window = host.window else {
            throw CommandError(code: .invalid_state, message: "the timeline has no window")
        }
        let visible = host.visibleRect
        let p = point ?? CGPoint(x: visible.width / 2, y: visible.height / 2)
        guard p.x >= 0, p.y >= 0, p.x <= visible.width, p.y <= visible.height else {
            throw CommandError(code: .bad_params,
                               message: "point (\(p.x), \(p.y)) outside the visible timeline "
                                      + "(\(Int(visible.width))×\(Int(visible.height)))")
        }
        let canvas = CGPoint(x: visible.minX + p.x, y: visible.minY + p.y)   // host is flipped
        let inWindow = host.convert(canvas, to: nil)
        let onScreen = window.convertPoint(toScreen: inWindow)
        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
        return Target(windowNumber: window.windowNumber,
                      globalPoint: CGPoint(x: onScreen.x, y: mainHeight - onScreen.y),
                      windowPoint: CGPoint(x: inWindow.x, y: window.frame.height - inWindow.y),
                      appKitWindowPoint: inWindow,
                      canvasPoint: canvas)
    }

    /// Brings the app and the timeline's window to the front: the key monitor only sees key
    /// events of the key window, and a hand scrolls an app it is looking at.
    static func activate() throws {
        let host = try timelineHost()
        NSApp.activate(ignoringOtherApps: true)
        host.window?.makeKeyAndOrderFront(nil)
    }

    /// Sets the timeline's hover at a viewport point (nil = the centre), as a mouse movement
    /// would. Answers the point in canvas coordinates.
    @discardableResult
    static func hover(atViewport point: CGPoint?) throws -> CGPoint {
        let host = try timelineHost()
        let t = try target(atViewport: point)
        host.simulateHover(at: t.canvasPoint)
        return t.canvasPoint
    }

    /// The pointer leaves the timeline, as `mouseExited` says it.
    static func leaveHover() throws {
        try timelineHost().simulateHover(at: nil)
    }

    // MARK: - Building events (any thread)

    /// `CGScrollPhase` / `CGMomentumScrollPhase` raw values, spelled out: these are what a real
    /// trackpad writes, and what `NSEvent.phase` / `.momentumPhase` are read from.
    enum ScrollPhase: Int64, Sendable {
        case none = 0, began = 1, changed = 2, ended = 4, cancelled = 8, mayBegin = 128
    }
    enum MomentumPhase: Int64, Sendable {
        case none = 0, begin = 1, `continue` = 2, end = 3
    }

    /// One scroll event. `dx`/`dy` are in AppKit's `scrollingDeltaX/Y` convention: a positive dy
    /// reveals what is ABOVE, a positive dx what is on the LEFT.
    nonisolated static func scrollEvent(dx: Double, dy: Double,
                                        precise: Bool,
                                        phase: ScrollPhase, momentum: MomentumPhase,
                                        flags: CGEventFlags,
                                        target: Target,
                                        timestamp: CGEventTimestamp? = nil) -> CGEvent? {
        let units: CGScrollEventUnit = precise ? .pixel : .line
        guard let e = CGEvent(scrollWheelEvent2Source: nil, units: units, wheelCount: 2,
                              wheel1: Int32(dy.rounded()), wheel2: Int32(dx.rounded()),
                              wheel3: 0) else { return nil }
        e.location = target.globalPoint
        e.flags = flags
        if precise {
            // The fractional deltas a trackpad produces: `scrollingDeltaX/Y` of a continuous
            // event are read from the point / fixed-point fields, not from the integer wheel.
            e.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
            e.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: dy)
            e.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: dx)
            e.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: Int64(dy.rounded()))
            e.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: Int64(dx.rounded()))
            e.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase.rawValue)
            e.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum.rawValue)
        }
        stamp(e, target: target, timestamp: timestamp)
        return e
    }

    /// A key press or release, with the characters the current layout gives that key.
    nonisolated static func keyEvent(keyCode: CGKeyCode, down: Bool, flags: CGEventFlags,
                                     characters: String?, target: Target,
                                     timestamp: CGEventTimestamp? = nil) -> CGEvent? {
        guard let e = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: down) else {
            return nil
        }
        e.flags = flags
        if let characters, !characters.isEmpty {
            let utf16 = Array(characters.utf16)
            e.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
        }
        e.location = target.globalPoint
        stamp(e, target: target, timestamp: timestamp)
        return e
    }

    /// Raw field 51 of a CGEvent: the window the event is FOR. Undocumented, and the one
    /// `NSEvent(cgEvent:)` reads to fill `window` — measured on 24 September 2026 (macOS 15):
    /// without it `window` is nil, the monitors see the event and the scroll view never does,
    /// since `NSApp.sendEvent` hands an event to its window and there is none. The documented
    /// `mouseEventWindowUnderMousePointer` fields are set too but read by nobody here.
    nonisolated private static let windowNumberField = CGEventField(rawValue: 51)

    /// `CGEventSetWindowLocation` — private CoreGraphics, the only way to give a synthetic event
    /// its point IN the window (what becomes `locationInWindow`, hence the hit-test). A real
    /// event gets it from the window server. Looked up at run time, so a macOS without it costs
    /// the hit-test and not the launch: `input.selftest` then says `ok: false`.
    private typealias SetWindowLocation = @convention(c) (CGEvent, CGPoint) -> Void
    nonisolated private static let setWindowLocation: SetWindowLocation? = {
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGEventSetWindowLocation") else {
            return nil
        }
        return unsafeBitCast(sym, to: SetWindowLocation.self)
    }()

    /// Now, in a CGEvent's clock (nanoseconds of uptime).
    nonisolated static func now() -> CGEventTimestamp {
        CGEventTimestamp(clock_gettime_nsec_np(CLOCK_UPTIME_RAW))
    }

    nonisolated private static func stamp(_ e: CGEvent, target: Target, timestamp: CGEventTimestamp?) {
        e.setIntegerValueField(.eventSourceUserData, value: tag)
        // A real event is dated by the device; a synthetic one is born at 0. The date matters:
        // the scroll view's deceleration reads the speed off it (measured — undated, the same
        // swipe travelled 1503 px instead of 2200).
        e.timestamp = timestamp ?? now()
        // Which window the event is for, and where in it — what a real event gets from the
        // window server, and what `NSEvent(cgEvent:)` turns into `window` / `locationInWindow`.
        if let windowNumberField {
            e.setIntegerValueField(windowNumberField, value: Int64(target.windowNumber))
        }
        setWindowLocation?(e, target.windowPoint)
        e.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(target.windowNumber))
        e.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent,
                               value: Int64(target.windowNumber))
    }

    nonisolated static func isSynthetic(_ event: NSEvent) -> Bool {
        event.cgEvent?.getIntegerValueField(.eventSourceUserData) == tag
    }

    // MARK: - Delivering

    /// Hands one event to the app by the chosen route. `cgevent` is safe from any thread; the two
    /// AppKit routes hop onto the main thread (they are main-thread APIs), which is also where
    /// a real event would be dispatched.
    nonisolated static func deliver(_ event: CGEvent, route: Route) {
        switch route {
        case .cgevent:
            event.postToPid(getpid())
        case .post:
            DispatchQueue.main.async {
                guard let ns = NSEvent(cgEvent: event) else { return }
                NSApp.postEvent(ns, atStart: false)
            }
        case .send:
            DispatchQueue.main.async {
                guard let ns = NSEvent(cgEvent: event) else { return }
                NSApp.sendEvent(ns)
            }
        }
    }

    // MARK: - Keys

    /// US virtual key codes (`kVK_*`) of the keys a navigation script needs. A key code names a
    /// physical key, not a letter: the characters are passed alongside so that the event reads
    /// the same whatever the layout.
    nonisolated static func keyCode(for name: String) -> (CGKeyCode, String?)? {
        let named: [String: (CGKeyCode, String?)] = [
            "left": (123, "\u{F702}"), "right": (124, "\u{F703}"),
            "down": (125, "\u{F701}"), "up": (126, "\u{F700}"),
            "space": (49, " "), "return": (36, "\r"), "escape": (53, "\u{1B}"),
            "delete": (51, "\u{7F}"), "tab": (48, "\t"),
            "home": (115, "\u{F729}"), "end": (119, "\u{F72B}"),
            "pageup": (116, "\u{F72C}"), "pagedown": (121, "\u{F72D}"),
        ]
        if let k = named[name.lowercased()] { return k }
        let letters: [Character: CGKeyCode] = [
            "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
            "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19,
            "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28,
            "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "l": 37, "j": 38,
            "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46, ".": 47,
            "`": 50,
        ]
        guard name.count == 1, let c = name.lowercased().first, let code = letters[c] else {
            return nil
        }
        return (code, name)
    }

    /// `["shift", "cmd", …]` → the flags of a CGEvent.
    nonisolated static func flags(_ names: [String]) throws -> CGEventFlags {
        var f: CGEventFlags = []
        for n in names {
            switch n.lowercased() {
            case "shift":                      f.insert(.maskShift)
            case "cmd", "command":             f.insert(.maskCommand)
            case "alt", "option", "opt":       f.insert(.maskAlternate)
            case "ctrl", "control":            f.insert(.maskControl)
            default:
                throw CommandError(code: .bad_params, message: "unknown modifier '\(n)'")
            }
        }
        return f
    }
}

// MARK: - A timed sequence, pumped on its own clock

/// What to post, and when (seconds from the start of the sequence).
struct TimedInput: Sendable {
    enum Kind: Sendable {
        case scroll(dx: Double, dy: Double, precise: Bool,
                    phase: InputSynth.ScrollPhase, momentum: InputSynth.MomentumPhase,
                    flags: CGEventFlags)
        case key(code: CGKeyCode, down: Bool, flags: CGEventFlags, characters: String?)
    }
    let at: Double
    let kind: Kind
}

/// Posts a sequence on a thread of its own, on its own clock.
///
/// Why not from the main thread: when the main thread hitches, a real trackpad does NOT wait for
/// it — its events pile up in the queue and AppKit coalesces them. A generator running on the
/// main thread would slow down with the app and hide exactly the hitches a measurement is after.
nonisolated final class InputPump: @unchecked Sendable {

    struct Outcome: Sendable {
        let posted: Int
        let failed: Int
        /// How late, at worst, an event left compared with its schedule (the pump's own jitter).
        let maxLatenessMs: Double
        let durationMs: Double
    }

    static func run(_ inputs: [TimedInput], target: InputSynth.Target,
                    route: InputSynth.Route) async -> Outcome {
        await withCheckedContinuation { continuation in
            let thread = Thread {
                continuation.resume(returning: pump(inputs, target: target, route: route))
            }
            thread.qualityOfService = .userInteractive
            thread.name = "objekat.input-pump"
            thread.start()
        }
    }

    private static func pump(_ inputs: [TimedInput], target: InputSynth.Target,
                             route: InputSynth.Route) -> Outcome {
        let start = CFAbsoluteTimeGetCurrent()
        // Each event is dated at its SCHEDULED instant, not the one it actually left at: a
        // trackpad samples on its own clock whatever the app is doing, and the scroll view reads
        // speeds off those dates — dating by the pump's own jitter would turn it into speed noise.
        let base = InputSynth.now()
        var posted = 0, failed = 0
        var maxLate = 0.0
        for input in inputs.sorted(by: { $0.at < $1.at }) {
            let due = start + input.at
            // A coarse sleep, then a short spin: `Thread.sleep` alone wakes up to a millisecond
            // late, which is an eighth of a 120 Hz frame.
            let wait = due - CFAbsoluteTimeGetCurrent()
            if wait > 0.002 { Thread.sleep(forTimeInterval: wait - 0.0015) }
            while CFAbsoluteTimeGetCurrent() < due {}
            maxLate = max(maxLate, CFAbsoluteTimeGetCurrent() - due)

            let when = base + CGEventTimestamp(max(0, input.at) * 1_000_000_000)
            let event: CGEvent?
            switch input.kind {
            case let .scroll(dx, dy, precise, phase, momentum, flags):
                event = InputSynth.scrollEvent(dx: dx, dy: dy, precise: precise, phase: phase,
                                               momentum: momentum, flags: flags, target: target,
                                               timestamp: when)
            case let .key(code, down, flags, characters):
                event = InputSynth.keyEvent(keyCode: code, down: down, flags: flags,
                                            characters: characters, target: target, timestamp: when)
            }
            if let event { InputSynth.deliver(event, route: route); posted += 1 } else { failed += 1 }
        }
        return Outcome(posted: posted, failed: failed, maxLatenessMs: maxLate * 1000,
                       durationMs: (CFAbsoluteTimeGetCurrent() - start) * 1000)
    }
}

// MARK: - Gesture shapes

enum GestureShape {

    /// A two-finger swipe: `.began` carrying the first delta, `.changed` for the rest, `.ended`
    /// with a zero delta — what a trackpad sends — then, optionally, the inertia the system
    /// would have generated (momentum `.begin` / `.continue` / `.end`).
    ///
    /// The fingers move at constant speed; the inertia starts from that speed and decays by
    /// `decayPerMs` every millisecond (0.998 is AppKit's own normal deceleration rate).
    ///
    /// Every delta is a WHOLE point: `NSEvent.scrollingDeltaX/Y` of a synthetic event reads the
    /// integer point-delta field (measured: 1.925 asked, 2 received). The rounding error is
    /// carried from one event to the next, so the deltas SUM to exactly what was asked.
    static func trackpadSwipe(dx: Double, dy: Double, durationMs: Double, rateHz: Double,
                              momentum: Bool, decayPerMs: Double,
                              flags: CGEventFlags) -> [TimedInput] {
        let period = 1.0 / rateHz
        let steps = max(1, Int((durationMs / 1000 / period).rounded()))
        let sx = dx / Double(steps), sy = dy / Double(steps)
        var carry = Carry()
        var out: [TimedInput] = []
        for i in 0..<steps {
            let (ix, iy) = carry.take(sx, sy)
            out.append(TimedInput(at: Double(i) * period,
                                  kind: .scroll(dx: ix, dy: iy, precise: true,
                                                phase: i == 0 ? .began : .changed,
                                                momentum: .none, flags: flags)))
        }
        var t = Double(steps) * period
        out.append(TimedInput(at: t, kind: .scroll(dx: 0, dy: 0, precise: true, phase: .ended,
                                                   momentum: .none, flags: flags)))
        guard momentum else { return out }

        let factor = pow(decayPerMs, period * 1000)
        var vx = sx, vy = sy
        var first = true
        // Until the speed falls under a tenth of a point per event, or 4 s at most.
        while max(abs(vx), abs(vy)) >= 0.1, t < Double(steps) * period + 4 {
            t += period
            vx *= factor; vy *= factor
            let (ix, iy) = carry.take(vx, vy)
            out.append(TimedInput(at: t, kind: .scroll(dx: ix, dy: iy, precise: true, phase: .none,
                                                       momentum: first ? .begin : .continue,
                                                       flags: flags)))
            first = false
        }
        out.append(TimedInput(at: t + period, kind: .scroll(dx: 0, dy: 0, precise: true,
                                                            phase: .none, momentum: .end,
                                                            flags: flags)))
        return out
    }

    /// Rounds a stream of fractional deltas to whole points without losing the remainder.
    struct Carry {
        private var rx = 0.0, ry = 0.0
        mutating func take(_ x: Double, _ y: Double) -> (Double, Double) {
            rx += x; ry += y
            let ix = rx.rounded(), iy = ry.rounded()
            rx -= ix; ry -= iy
            return (ix, iy)
        }
    }

    /// A mouse wheel: `notches` line-based events, no phase, no inertia.
    static func wheel(notchesX: Int, notchesY: Int, intervalMs: Double,
                      flags: CGEventFlags) -> [TimedInput] {
        let n = max(abs(notchesX), abs(notchesY))
        return (0..<n).map { i in
            TimedInput(at: Double(i) * intervalMs / 1000,
                       kind: .scroll(dx: i < abs(notchesX) ? Double(notchesX.signum()) : 0,
                                     dy: i < abs(notchesY) ? Double(notchesY.signum()) : 0,
                                     precise: false, phase: .none, momentum: .none, flags: flags))
        }
    }
}
