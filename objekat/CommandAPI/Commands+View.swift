import AppKit
import Foundation

/// The navigation family: read and set the timeline's view (`view.*`), drive it with synthetic
/// trackpad / wheel / keyboard input (`input.*`), and count the frames it costs (`perf.frames.*`).
///
/// The point of `input.*` is that it goes through the SAME door as a hand: real events posted
/// into the app's queue, met by the same monitors and the same scroll view (@see InputSynth). So a
/// measurement taken through it measures what a user would feel — which a setter of the viewport
/// would not, since it skips the event dispatch, the monitors' own logic and AppKit's coalescing.
///
/// Every command here needs an interface: with `--headless` they answer `invalid_state`.
/// None of them touches the document — `undo: none` throughout.
extension CommandRegistry {

    func registerViewCommands() {

        // MARK: view.*

        register("view.state",
                 summary: """
                 The timeline's current view: zoom (`pps`, `block_height`), scroll, visible area \
                 and time span, whether the window is key. `scroll_x/y` are read off the view \
                 itself; `model_scroll_x/y` are the view-model's mirror (the one saved with the \
                 project) — they only differ for the frame a scroll takes to be reported back.
                 """) { _ in
            try Self.viewState()
        }

        register("view.set",
                 summary: """
                 Puts the view in a known state before a test: zoom and/or scroll, through the \
                 door a project opening uses (`pendingViewRestore`). Waits until it is applied \
                 and answers the resulting `view.state`.
                 """,
                 params: [ParamSpec("pps", "number", required: false, "Pixels per second."),
                          ParamSpec("block_height", "number", required: false, "Lane block height (pt)."),
                          ParamSpec("scroll_x", "number", required: false, "Horizontal scroll (pt)."),
                          ParamSpec("scroll_y", "number", required: false, "Vertical scroll (pt).")]) { p in
            let vm = try CommandContext.shared.requireViewModel()
            let host = try InputSynth.timelineHost()
            if let pps = try p.optionalDouble("pps") {
                guard pps > 0 else { throw CommandError(code: .bad_params, message: "'pps' must be > 0") }
                vm.pixelsPerSecond = pps
            }
            if let bh = try p.optionalDouble("block_height") {
                guard bh > 0 else { throw CommandError(code: .bad_params, message: "'block_height' must be > 0") }
                vm.blockHeight = bh
            }
            let visible = host.visibleRect
            let x = try p.double("scroll_x", or: Double(visible.minX))
            let y = try p.double("scroll_y", or: Double(visible.minY))
            vm.pendingViewRestore = ViewportState(pixelsPerSecond: vm.pixelsPerSecond,
                                                  blockHeight: vm.blockHeight, scrollX: x, scrollY: y)
            // The view applies it one run-loop turn later and sets it back to nil — then the layout,
            // and any deceleration a previous gesture left running, have to come to rest.
            let deadline = Date().addingTimeInterval(2)
            while vm.pendingViewRestore != nil, Date() < deadline {
                try? await Task.sleep(for: .milliseconds(5))
            }
            _ = await Self.waitViewAtRest(host)
            return try Self.viewState()
        }

        // MARK: input.*

        register("input.hover",
                 summary: """
                 Tells the timeline the pointer is at a point of its VISIBLE area (origin top-left, \
                 points), or that it has left. The same callback a mouse movement calls — the \
                 timeline only zooms under a hover, and a synthetic scroll does not feed its \
                 tracking area. `input.scroll` / `input.zoom` set it themselves.
                 """,
                 params: [ParamSpec("x", "number", required: false, "Default: centre."),
                          ParamSpec("y", "number", required: false, "Default: centre."),
                          ParamSpec("leave", "bool", required: false, "The pointer leaves the timeline.")]) { p in
            if try p.bool("leave", or: false) {
                try InputSynth.leaveHover()
                return .object(["hover": .null])
            }
            let canvas = try InputSynth.hover(atViewport: try Self.viewportPoint(p))
            return .object(["hover": Self.pointJSON(canvas)])
        }

        register("input.scroll",
                 summary: """
                 Scrolls the timeline with synthetic events that take the hand's own path. \
                 `direction` + `distance_px` says what the CONTENT does (right = later time comes \
                 into view, down = lower lanes), or `dx`/`dy` give AppKit's raw deltas. \
                 `style: trackpad` = pixel deltas with began/changed/ended phases (+ `momentum` \
                 for the system's inertia); `style: wheel` = `notches` line events, no phase. \
                 `modifiers: ["shift"]` turns it into the ⇧-scroll zoom. Answers the frame \
                 report and the view before/after.
                 """,
                 params: Self.scrollParams + Self.runParams) { p in
            let flags = try InputSynth.flags(try Self.strings(p, "modifiers"))
            let style = try p.string("style", or: "trackpad")
            let inputs: [TimedInput]
            switch style {
            case "trackpad":
                let (dx, dy) = try Self.deltas(p)
                inputs = GestureShape.trackpadSwipe(
                    dx: dx, dy: dy,
                    durationMs: try Self.positive(p, "duration_ms", or: 500),
                    rateHz: try Self.positive(p, "rate_hz", or: 120),
                    momentum: try p.bool("momentum", or: false),
                    decayPerMs: try p.double("decay", or: 0.998),
                    flags: flags)
            case "wheel":
                let notches = try p.int("notches", or: 10)
                let dir = try p.string("direction", or: "down")
                let (nx, ny): (Int, Int) = switch dir {
                    case "up":    (0, notches)
                    case "down":  (0, -notches)
                    case "left":  (notches, 0)
                    case "right": (-notches, 0)
                    default: throw CommandError(code: .bad_params, message: "unknown direction '\(dir)'")
                }
                inputs = GestureShape.wheel(notchesX: nx, notchesY: ny,
                                            intervalMs: try Self.positive(p, "interval_ms", or: 30),
                                            flags: flags)
            default:
                throw CommandError(code: .bad_params, message: "'style' is trackpad or wheel")
            }
            return try await Self.run(inputs, p, hover: true)
        }

        register("input.zoom",
                 summary: """
                 Zooms the timeline the way a hand does. `via: shift_scroll` (default) = a ⇧ + \
                 two-finger swipe, the delta computed from the timeline's own law \
                 (×e^(0.01·dx) horizontally, ×e^(0.012·dy) vertically) — its 3-point dead zone \
                 included, so the zoom reached can fall short of `factor` by a hair, and \
                 `achieved_factor` says by how much. `via: keys` = `t` / `r` presses (⇧ for \
                 vertical), ×1.5 each, `factor` rounded to a whole number of presses.
                 """,
                 params: [ParamSpec("factor", "number", "> 1 zooms in, < 1 zooms out."),
                          ParamSpec("axis", "string", required: false, "horizontal (default) | vertical"),
                          ParamSpec("via", "string", required: false, "shift_scroll (default) | keys"),
                          ParamSpec("duration_ms", "number", required: false, "Swipe length (default 300)."),
                          ParamSpec("rate_hz", "number", required: false, "Events per second (default 120)."),
                          ParamSpec("interval_ms", "number", required: false, "Between key presses (default 80).")]
                         + Self.runParams) { p in
            let factor = try p.double("factor")
            guard factor > 0, factor.isFinite else {
                throw CommandError(code: .bad_params, message: "'factor' must be > 0")
            }
            let vertical: Bool
            switch try p.string("axis", or: "horizontal") {
            case "horizontal", "h": vertical = false
            case "vertical", "v":   vertical = true
            default: throw CommandError(code: .bad_params, message: "'axis' is horizontal or vertical")
            }
            let vm = try CommandContext.shared.requireViewModel()
            let before = vertical ? vm.blockHeight : vm.pixelsPerSecond

            let inputs: [TimedInput]
            var presses = 0
            switch try p.string("via", or: "shift_scroll") {
            case "shift_scroll":
                // The timeline's own law (@see TimelineKeyHandler, registerScrollMonitor).
                let delta = log(factor) / (vertical ? 0.012 : 0.01)
                inputs = GestureShape.trackpadSwipe(
                    dx: vertical ? 0 : delta, dy: vertical ? delta : 0,
                    durationMs: try Self.positive(p, "duration_ms", or: 300),
                    rateHz: try Self.positive(p, "rate_hz", or: 120),
                    momentum: false, decayPerMs: 0.998, flags: .maskShift)
            case "keys":
                presses = Int((log(factor) / log(1.5)).rounded())
                guard presses != 0 else {
                    throw CommandError(code: .bad_params, message: "'factor' rounds to zero presses of ×1.5")
                }
                let key = presses > 0 ? "t" : "r"
                inputs = Self.keyPresses(code: presses > 0 ? 17 : 15,
                                         characters: vertical ? key.uppercased() : key,
                                         flags: vertical ? .maskShift : [],
                                         count: abs(presses),
                                         intervalMs: try Self.positive(p, "interval_ms", or: 80),
                                         holdMs: 30)
            default:
                throw CommandError(code: .bad_params, message: "'via' is shift_scroll or keys")
            }
            guard case .object(var o) = try await Self.run(inputs, p, hover: true) else {
                return .null
            }
            let after = vertical ? vm.blockHeight : vm.pixelsPerSecond
            o["requested_factor"] = .number(factor)
            o["achieved_factor"] = .number(before > 0 ? (after / before * 1e6).rounded() / 1e6 : 0)
            if presses != 0 { o["presses"] = .int(presses) }
            return .object(o)
        }

        register("input.key",
                 summary: """
                 Presses a key (down, then up) through the app's event queue, as the keyboard \
                 would: letters, digits, punctuation, `left` `right` `up` `down` `space` `return` \
                 `escape` `delete` `tab` `home` `end` `pageup` `pagedown`. `claimed: true` in the \
                 answer means the timeline let the key through to someone else — a text field \
                 or a value box held the keyboard (@see KeyboardClaim).
                 """,
                 params: [ParamSpec("key", "string", "The key."),
                          ParamSpec("modifiers", "array<string>", required: false, "shift, cmd, alt, ctrl."),
                          ParamSpec("repeat", "int", required: false, "How many presses (default 1)."),
                          ParamSpec("interval_ms", "number", required: false, "Between presses (default 80)."),
                          ParamSpec("hold_ms", "number", required: false, "Down → up (default 30).")]
                         + Self.runParams) { p in
            let name = try p.string("key")
            guard let (code, chars) = InputSynth.keyCode(for: name) else {
                throw CommandError(code: .bad_params, message: "unknown key '\(name)'")
            }
            let flags = try InputSynth.flags(try Self.strings(p, "modifiers"))
            let count = max(1, try p.int("repeat", or: 1))
            let shifted = flags.contains(.maskShift) && name.count == 1 ? chars?.uppercased() : chars
            let inputs = Self.keyPresses(code: code, characters: shifted, flags: flags, count: count,
                                         intervalMs: try Self.positive(p, "interval_ms", or: 80),
                                         holdMs: try Self.positive(p, "hold_ms", or: 30))
            // Asked BEFORE the press, the way the monitor asks it: the timeline's key monitor
            // sees every key, and hands it on when a text field or a value box holds the keyboard.
            let claim = try Self.keyClaim(code: code, flags: flags, characters: shifted)
            guard case .object(var o) = try await Self.run(inputs, p, hover: false) else { return .null }
            o["claimed"] = .bool(claim != nil)
            o["claimed_by"] = .stringOrNull(claim)
            return .object(o)
        }

        register("input.record.start",
                 summary: """
                 Starts recording the scroll and key events the timeline receives, real or not — \
                 at the timeline's own monitors, so exactly what it sees. Do the gesture by hand, \
                 then `input.record.stop`.
                 """) { _ in
            _ = try InputSynth.timelineHost()
            InputProbe.shared.startRecording()
            return .object(["recording": .bool(true)])
        }

        register("input.record.stop",
                 summary: """
                 Stops the recording and answers the events (times in seconds from the first \
                 one), ready to hand to `input.replay` as they are.
                 """) { _ in
            guard InputProbe.shared.isRecording else {
                throw CommandError(code: .invalid_state, message: "no recording in progress")
            }
            let events = InputProbe.shared.stopRecording()
            return .object(["events": .array(events.map(\.json)), "count": .int(events.count),
                            "duration_ms": .number(((events.last?.t ?? 0) * 1_000_000).rounded() / 1000)])
        }

        register("input.replay",
                 summary: """
                 Replays recorded events (`input.record.stop`'s `events`) at their own pace — \
                 deltas, phases, inertia and modifiers as the hand produced them.
                 """,
                 params: [ParamSpec("events", "array<object>", "Recorded events."),
                          ParamSpec("speed", "number", required: false, "Time scale (default 1).")]
                         + Self.runParams) { p in
            let speed = try Self.positive(p, "speed", or: 1)
            let inputs = try p.array("events").compactMap { try InputProbe.Recorded.timedInput(from: $0) }
                .map { TimedInput(at: $0.at / speed, kind: $0.kind) }
            guard !inputs.isEmpty else {
                throw CommandError(code: .bad_params, message: "no replayable event in 'events'")
            }
            return try await Self.run(inputs, p, hover: true)
        }

        register("input.scenario",
                 summary: """
                 Runs a sequence of steps — `{"cmd": …, "params": {…}}` or `{"wait_ms": n}` — \
                 under ONE frame recording, and answers the whole report plus one per step. The \
                 steps' own measurement is turned off (they are measured from here).
                 """,
                 params: [ParamSpec("steps", "array<object>", "The steps."),
                          ParamSpec("samples", "bool", required: false, "Include every frame interval.")]) { p in
            let host = try InputSynth.timelineHost()
            let steps = try p.array("steps")
            guard !steps.isEmpty else { throw CommandError(code: .bad_params, message: "'steps' is empty") }
            let samples = try p.bool("samples", or: false)
            let whole = FrameRecording(on: host, label: "scenario")
            var perStep: [JSONValue] = []
            for (i, step) in steps.enumerated() {
                if let wait = step["wait_ms"]?.doubleValue {
                    try? await Task.sleep(for: .milliseconds(Int(wait)))
                    perStep.append(.object(["index": .int(i), "wait_ms": .number(wait)]))
                    continue
                }
                guard let name = step["cmd"]?.stringValue else {
                    throw CommandError(code: .bad_params, message: "step \(i): 'cmd' or 'wait_ms' required")
                }
                guard name != "input.scenario" else {
                    throw CommandError(code: .bad_params, message: "step \(i): nested scenario")
                }
                var params = step["params"]?.objectValue ?? [:]
                if name.hasPrefix("input.") { params["measure"] = .bool(false) }
                let rec = FrameRecording(on: host, label: "step")
                let result = try await CommandRegistry.shared.execute(name: name, params: CommandParams(params))
                perStep.append(.object(["index": .int(i), "cmd": .string(name),
                                        "frames": rec.stop(includeSamples: samples),
                                        "result": result]))
            }
            return .object(["frames": whole.stop(includeSamples: samples),
                            "steps": .array(perStep), "build": .string(Self.buildKind)])
        }

        register("input.selftest",
                 summary: """
                 Checks, route by route (cgevent / post / send), that a synthetic scroll reaches \
                 the timeline's monitors with its phases intact and really moves the view (40 pt \
                 sideways and back). Says which route `auto` will take. Run it once on a new machine \
                 or macOS.
                 """,
                 params: [ParamSpec("activate", "bool", required: false, "Bring the window to the front (default true).")]) { p in
            if try p.bool("activate", or: true) { try InputSynth.activate() }
            try? await Task.sleep(for: .milliseconds(100))
            var rows: [String: JSONValue] = [:]
            var chosen: InputSynth.Route? = nil
            for route in InputSynth.Route.allCases {
                let row = try await Self.probeRoute(route)
                rows[route.rawValue] = row
                if chosen == nil, row["ok"]?.boolValue == true { chosen = route }
            }
            Self.autoRoute = chosen
            return .object(["routes": .object(rows), "auto": .stringOrNull(chosen?.rawValue),
                            "build": .string(Self.buildKind)])
        }

        // MARK: perf.frames.*

        register("perf.frames.start",
                 summary: """
                 Starts counting the timeline's frames and the main thread's busy time, around \
                 whatever follows — a playback, a hand at the trackpad, other commands. \
                 `perf.frames.stop` answers the report.
                 """) { _ in
            let host = try InputSynth.timelineHost()
            _ = Self.frameSession?.stop()
            Self.frameSession = FrameRecording(on: host, label: "perf.frames")
            InputProbe.shared.retain()
            InputProbe.shared.resetCounters()
            return .object(["recording": .bool(true)])
        }

        register("perf.frames.stop",
                 summary: """
                 Stops `perf.frames.start` and answers: frames, the screen's own interval, frame \
                 time p50/p95/p99/max, late and dropped frames, hitch time per second, main-thread \
                 busy time per run-loop turn. No thresholds: made for comparing two runs.
                 """,
                 params: [ParamSpec("samples", "bool", required: false, "Include every frame interval.")]) { p in
            guard let session = Self.frameSession else {
                throw CommandError(code: .invalid_state, message: "perf.frames.start was not called")
            }
            Self.frameSession = nil
            InputProbe.shared.release()
            return .object(["frames": session.stop(includeSamples: try p.bool("samples", or: false)),
                            "real_input_events": .int(InputProbe.shared.realSeen),
                            "build": .string(Self.buildKind)])
        }
    }

    // MARK: - Shared machinery

    private static var frameSession: FrameRecording? = nil
    /// Set by `input.selftest`; nil = not measured yet, `auto` then means `post` — the route
    /// measured to work on 24 September 2026 (macOS 15). `cgevent` (`postToPid`) never reached
    /// the app there: nothing is delivered, no error either.
    private static var autoRoute: InputSynth.Route? = nil

    static var buildKind: String {
        #if DEBUG
        return "debug"
        #else
        return "release"
        #endif
    }

    /// The parameters every `input.*` gesture takes besides its own.
    static let runParams: [ParamSpec] = [
        ParamSpec("x", "number", required: false, "Pointer x in the visible timeline (default: centre)."),
        ParamSpec("y", "number", required: false, "Pointer y in the visible timeline (default: centre)."),
        ParamSpec("route", "string", required: false, "auto (default) | cgevent | post | send."),
        ParamSpec("activate", "bool", required: false, "Bring the window to the front first (default true)."),
        ParamSpec("hover", "bool", required: false,
                  "Lay the timeline's hover at the pointer first (default true for scroll/zoom/replay)."),
        ParamSpec("measure", "bool", required: false, "Record frames during the gesture (default true)."),
        ParamSpec("samples", "bool", required: false, "Include every frame interval in the report."),
    ]

    static let scrollParams: [ParamSpec] = [
        ParamSpec("direction", "string", required: false, "up | down | left | right (what comes into view)."),
        ParamSpec("distance_px", "number", required: false, "With `direction`, trackpad style (default 1000)."),
        ParamSpec("dx", "number", required: false, "Raw AppKit delta, instead of direction (positive = left)."),
        ParamSpec("dy", "number", required: false, "Raw AppKit delta, instead of direction (positive = up)."),
        ParamSpec("style", "string", required: false, "trackpad (default) | wheel."),
        ParamSpec("duration_ms", "number", required: false, "Fingers-on time, trackpad (default 500)."),
        ParamSpec("rate_hz", "number", required: false, "Events per second, trackpad (default 120)."),
        ParamSpec("momentum", "bool", required: false, "Add the system's inertia after the fingers lift (default false)."),
        ParamSpec("decay", "number", required: false, "Inertia decay per ms (default 0.998, AppKit's normal rate)."),
        ParamSpec("notches", "int", required: false, "Wheel style: how many notches (default 10)."),
        ParamSpec("interval_ms", "number", required: false, "Wheel style: between notches (default 30)."),
        ParamSpec("modifiers", "array<string>", required: false, "shift, cmd, alt, ctrl."),
    ]

    /// Posts a gesture and measures it. The one place every `input.*` goes through.
    static func run(_ inputs: [TimedInput], _ p: CommandParams, hover: Bool) async throws -> JSONValue {
        let vm = try CommandContext.shared.requireViewModel()
        let host = try InputSynth.timelineHost()
        if try p.bool("activate", or: true) {
            try InputSynth.activate()
        } else if host.window?.isKeyWindow != true {
            throw CommandError(code: .invalid_state,
                               message: "the timeline's window is not key (pass activate: true)")
        }
        let route = try Self.route(p)
        let point = try viewportPoint(p)
        let target = try InputSynth.target(atViewport: point)

        // Let the activation land BEFORE laying the hover: activating is asynchronous, and the
        // window server then tells the tracking area where the REAL pointer is — off the
        // timeline, a `mouseExited` that would wipe a hover laid too early. Then one more pause
        // for the hover's own redraw: it is the set-up, not the gesture.
        try? await Task.sleep(for: .milliseconds(80))
        if try p.bool("hover", or: hover) { try InputSynth.hover(atViewport: point) }
        try? await Task.sleep(for: .milliseconds(40))

        let before = try viewState()
        let probe = InputProbe.shared
        probe.retain(); defer { probe.release() }
        probe.resetCounters()
        let recording = try p.bool("measure", or: true) ? FrameRecording(on: host, label: "input") : nil

        let outcome = await InputPump.run(inputs, target: target, route: route)

        // Everything posted is in the queue: wait until the timeline has SEEN it all, then until
        // the view comes to rest — the scroll view decelerates on its own for some half a second
        // after the last event (measured: 902 → 1090 px after an 800 px swipe with no inertia
        // sent), and that tail is part of what the gesture costs.
        let deadline = Date().addingTimeInterval(2)
        while probe.syntheticSeen < outcome.posted, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(2))
        }
        let settledMs = await waitViewAtRest(host)

        let frames = recording?.stop(includeSamples: try p.bool("samples", or: false))
        _ = vm   // the view-model is only required so that no document = a clear error
        return .object([
            "route": .string(route.rawValue),
            "events_posted": .int(outcome.posted),
            "events_seen": .int(probe.syntheticSeen),
            "pump_duration_ms": .number((outcome.durationMs * 1000).rounded() / 1000),
            "pump_max_lateness_ms": .number((outcome.maxLatenessMs * 1000).rounded() / 1000),
            "settle_ms": .number(settledMs),
            // A real event reached the timeline while the gesture ran: the hand was on the
            // trackpad or the mouse moved over the view, and the measurement is not clean.
            "contaminated": .bool(probe.realSeen > 0),
            "real_events_seen": .int(probe.realSeen),
            "view_before": before,
            "view_after": try viewState(),
            "frames": frames ?? .null,
            "build": .string(buildKind),
        ])
    }

    /// Waits until the visible area and the zoom have not moved for 150 ms (4 s at most).
    /// Answers how long it took, in ms.
    static func waitViewAtRest(_ host: NSView) async -> Double {
        let vm = CommandContext.shared.viewModel
        func snapshot() -> [Double] {
            let v = host.visibleRect
            return [Double(v.minX), Double(v.minY), vm?.pixelsPerSecond ?? 0, vm?.blockHeight ?? 0]
        }
        let start = Date()
        var last = snapshot()
        var stillSince = Date()
        while Date().timeIntervalSince(start) < 4 {
            try? await Task.sleep(for: .milliseconds(16))
            let now = snapshot()
            if now != last { last = now; stillSince = Date() }
            else if Date().timeIntervalSince(stillSince) >= 0.15 { break }
        }
        return (Date().timeIntervalSince(start) * 1000).rounded()
    }

    static func route(_ p: CommandParams) throws -> InputSynth.Route {
        let name = try p.string("route", or: "auto")
        if name == "auto" { return autoRoute ?? .post }
        guard let r = InputSynth.Route(rawValue: name) else {
            throw CommandError(code: .bad_params, message: "'route' is auto, cgevent, post or send")
        }
        return r
    }

    static func viewState() throws -> JSONValue {
        let vm = try CommandContext.shared.requireViewModel()
        let host = try InputSynth.timelineHost()
        let v = host.visibleRect
        let pps = vm.pixelsPerSecond
        let r3 = { (x: Double) in (x * 1000).rounded() / 1000 }
        return .object([
            "pps": .number(r3(pps)),
            "block_height": .number(r3(vm.blockHeight)),
            "scroll_x": .number(r3(Double(v.minX))),
            "scroll_y": .number(r3(Double(v.minY))),
            "model_scroll_x": .number(r3(vm.viewScrollX)),
            "model_scroll_y": .number(r3(vm.viewScrollY)),
            "viewport_w": .number(r3(Double(v.width))),
            "viewport_h": .number(r3(Double(v.height))),
            "content_w": .number(r3(Double(host.bounds.width))),
            "content_h": .number(r3(Double(host.bounds.height))),
            "visible_time": .array([.number(r3(Double(v.minX) / pps)), .number(r3(Double(v.maxX) / pps))]),
            "window_key": .bool(host.window?.isKeyWindow ?? false),
            "app_active": .bool(NSApp.isActive),
        ])
    }

    static func viewportPoint(_ p: CommandParams) throws -> CGPoint? {
        let x = try p.optionalDouble("x"), y = try p.optionalDouble("y")
        guard x != nil || y != nil else { return nil }
        let visible = try InputSynth.timelineHost().visibleRect
        return CGPoint(x: x ?? visible.width / 2, y: y ?? visible.height / 2)
    }

    static func pointJSON(_ p: CGPoint?) -> JSONValue {
        guard let p else { return .null }
        return .object(["x": .number(Double(p.x)), "y": .number(Double(p.y))])
    }

    static func strings(_ p: CommandParams, _ key: String) throws -> [String] {
        guard let v = p.raw[key] else { return [] }
        if let s = v.stringValue { return [s] }
        guard let a = v.arrayValue else {
            throw CommandError(code: .bad_params, message: "'\(key)' must be a list of strings")
        }
        return try a.map {
            guard let s = $0.stringValue else {
                throw CommandError(code: .bad_params, message: "'\(key)' must be a list of strings")
            }
            return s
        }
    }

    static func positive(_ p: CommandParams, _ key: String, or fallback: Double) throws -> Double {
        let v = try p.double(key, or: fallback)
        guard v > 0, v.isFinite else { throw CommandError(code: .bad_params, message: "'\(key)' must be > 0") }
        return v
    }

    /// `direction` + `distance_px` → AppKit deltas, or the raw `dx`/`dy`. AppKit's sign: a
    /// positive delta reveals what is up / on the left, so "right" and "down" are negative.
    static func deltas(_ p: CommandParams) throws -> (Double, Double) {
        if let dir = try p.optionalString("direction") {
            let d = try positive(p, "distance_px", or: 1000)
            switch dir {
            case "up":    return (0, d)
            case "down":  return (0, -d)
            case "left":  return (d, 0)
            case "right": return (-d, 0)
            default: throw CommandError(code: .bad_params, message: "unknown direction '\(dir)'")
            }
        }
        let dx = try p.double("dx", or: 0), dy = try p.double("dy", or: 0)
        guard dx != 0 || dy != 0 else {
            throw CommandError(code: .bad_params, message: "'direction' (+ 'distance_px') or 'dx'/'dy' required")
        }
        return (dx, dy)
    }

    /// Who would take this key instead of the timeline, asked the way its key monitor asks
    /// (@see TimelineKeyHandler, handleKeyDown): nil = the timeline gets it.
    static func keyClaim(code: CGKeyCode, flags: CGEventFlags, characters: String?) throws -> String? {
        if NSApp.keyWindow?.firstResponder is NSTextView { return "text_field" }
        let target = try InputSynth.target(atViewport: nil)
        guard let cg = InputSynth.keyEvent(keyCode: code, down: true, flags: flags,
                                           characters: characters, target: target),
              let ns = NSEvent(cgEvent: cg) else { return nil }
        return KeyboardClaim.shared.owns(ns) ? "keyboard_claim" : nil
    }

    static func keyPresses(code: CGKeyCode, characters: String?, flags: CGEventFlags,
                           count: Int, intervalMs: Double, holdMs: Double) -> [TimedInput] {
        (0..<count).flatMap { i -> [TimedInput] in
            let t = Double(i) * intervalMs / 1000
            return [TimedInput(at: t, kind: .key(code: code, down: true, flags: flags, characters: characters)),
                    TimedInput(at: t + holdMs / 1000,
                               kind: .key(code: code, down: false, flags: flags, characters: characters))]
        }
    }

    /// One route of `input.selftest`: a 1-px trackpad scroll down then back up, and what came of it.
    private static func probeRoute(_ route: InputSynth.Route) async throws -> JSONValue {
        let host = try InputSynth.timelineHost()
        let target = try InputSynth.target(atViewport: nil)
        let probe = InputProbe.shared
        let x0 = host.visibleRect.minX
        // 40 pt towards the side there is room on (at the left edge, reveal the right: dx < 0).
        // Not less: a scroll view ignores the first few points of a gesture, and a probe that
        // small would read a working route as a dead one.
        let step: Double = x0 < 40 ? -40 : 40
        probe.startRecording()
        probe.resetCounters()
        let outcome = await InputPump.run(
            GestureShape.trackpadSwipe(dx: step, dy: 0, durationMs: 80, rateHz: 120,
                                       momentum: false, decayPerMs: 0.998, flags: []),
            target: target, route: route)
        let deadline = Date().addingTimeInterval(1)
        while probe.syntheticSeen < outcome.posted, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(2))
        }
        _ = await waitViewAtRest(host)
        let x1 = host.visibleRect.minX
        let seen = probe.stopRecording().filter(\.synthetic)
        // Put it back.
        _ = await InputPump.run(
            GestureShape.trackpadSwipe(dx: -step, dy: 0, durationMs: 80, rateHz: 120,
                                       momentum: false, decayPerMs: 0.998, flags: []),
            target: target, route: route)
        _ = await waitViewAtRest(host)

        let phases = seen.map { Int($0.phase) }
        let moved = abs(x1 - x0) > 0.25
        let phasesKept = phases.first == 1 && phases.last == 4
        let precise = seen.allSatisfy(\.precise)
        // Where AppKit places the event: without a window, the hit-test never reaches the
        // scroll view — the monitors see it, and nothing moves.
        let sample = InputSynth.scrollEvent(dx: 0, dy: 0, precise: true, phase: .mayBegin,
                                            momentum: .none, flags: [], target: target)
        let ns = sample.flatMap { NSEvent(cgEvent: $0) }
        return .object([
            "event_window": .int(ns?.window?.windowNumber ?? -1),
            "event_location_in_window": Self.pointJSON(ns?.locationInWindow),
            "timeline_window": .int(host.window?.windowNumber ?? -1),
            "wanted_location_in_window": Self.pointJSON(target.appKitWindowPoint),
            "posted": .int(outcome.posted),
            "seen_by_monitor": .int(seen.count),
            "phases": .array(phases.map { .int($0) }),
            "phases_kept": .bool(phasesKept),
            "precise": .bool(precise),
            "view_moved_px": .number(Double(x1 - x0)),
            "ok": .bool(seen.count == outcome.posted && phasesKept && precise && moved),
        ])
    }
}
