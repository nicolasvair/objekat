import AppKit

/// What the timeline's own monitors see, for the navigation commands.
///
/// Called on the FIRST line of the timeline's scroll and key monitors (@see TimelineKeyHandler) —
/// not from a monitor of its own: the order AppKit calls local monitors in is not documented, and
/// a monitor that ran after the timeline's would miss every event the timeline swallows (a
/// ⇧-scroll, a `t`). Sitting at the same door is the only way to see exactly what it sees.
///
/// Costs one Bool test per event while nothing listens.
@MainActor
final class InputProbe {

    static let shared = InputProbe()
    private init() {}

    /// A recorded event, in a form that can be replayed (`input.replay`) and read (JSON).
    struct Recorded {
        var t: Double                 // seconds from the start of the recording
        let type: String              // "scroll" | "keyDown" | "keyUp" | "flags"
        var dx = 0.0, dy = 0.0
        var precise = false
        var phase: Int64 = 0, momentum: Int64 = 0
        var flags: UInt64 = 0
        var keyCode: UInt16 = 0
        var characters: String? = nil
        var synthetic = false
    }

    private var listeners = 0
    private var recording: [Recorded]? = nil
    private var recordStart: TimeInterval = 0

    /// Counters since `resetCounters`.
    private(set) var syntheticSeen = 0
    private(set) var realSeen = 0
    private(set) var lastSyntheticUptime: TimeInterval = 0

    var isActive: Bool { listeners > 0 || recording != nil }

    func retain() { listeners += 1 }
    func release() { listeners = max(0, listeners - 1) }

    func resetCounters() { syntheticSeen = 0; realSeen = 0 }

    // MARK: The hook

    /// Hook of the timeline monitors. Never changes the event.
    func observe(_ event: NSEvent) {
        guard isActive else { return }
        let synthetic = InputSynth.isSynthetic(event)
        if synthetic {
            syntheticSeen += 1
            lastSyntheticUptime = ProcessInfo.processInfo.systemUptime
        } else if event.type != .flagsChanged {
            // A modifier change is not a contamination: a ⇧ still held from the terminal is not
            // an input into the timeline.
            realSeen += 1
        }
        guard recording != nil else { return }
        // The device's own date when there is one (a real event's is the hardware's), else now.
        let when = event.timestamp > 0 ? event.timestamp : ProcessInfo.processInfo.systemUptime
        recording?.append(Self.record(event, t: when - recordStart, synthetic: synthetic))
    }

    private static func record(_ e: NSEvent, t: Double, synthetic: Bool) -> Recorded {
        var r: Recorded
        switch e.type {
        case .scrollWheel:
            r = Recorded(t: t, type: "scroll")
            r.dx = Double(e.scrollingDeltaX); r.dy = Double(e.scrollingDeltaY)
            r.precise = e.hasPreciseScrollingDeltas
            r.phase = e.cgEvent?.getIntegerValueField(.scrollWheelEventScrollPhase) ?? 0
            r.momentum = e.cgEvent?.getIntegerValueField(.scrollWheelEventMomentumPhase) ?? 0
        case .keyDown, .keyUp:
            r = Recorded(t: t, type: e.type == .keyDown ? "keyDown" : "keyUp")
            r.keyCode = e.keyCode
            r.characters = e.charactersIgnoringModifiers
        default:
            r = Recorded(t: t, type: "flags")
        }
        r.flags = e.cgEvent?.flags.rawValue ?? 0
        r.synthetic = synthetic
        return r
    }

    // MARK: Recording

    func startRecording() {
        recording = []
        recordStart = ProcessInfo.processInfo.systemUptime
    }

    /// Stops and hands back what was recorded, times rebased on the first event.
    func stopRecording() -> [Recorded] {
        let out = recording ?? []
        recording = nil
        guard let t0 = out.first?.t else { return [] }
        return out.map { var r = $0; r.t -= t0; return r }
    }

    var isRecording: Bool { recording != nil }
}

extension InputProbe.Recorded {

    var json: JSONValue {
        var o: [String: JSONValue] = ["t": .number((t * 1_000_000).rounded() / 1_000_000),
                                      "type": .string(type), "flags": .int(Int(flags))]
        if type == "scroll" {
            o["dx"] = .number(dx); o["dy"] = .number(dy)
            o["precise"] = .bool(precise)
            o["phase"] = .int(Int(phase)); o["momentum"] = .int(Int(momentum))
        } else if type != "flags" {
            o["key_code"] = .int(Int(keyCode))
            o["characters"] = .stringOrNull(characters)
        }
        if synthetic { o["synthetic"] = .bool(true) }
        return .object(o)
    }

    /// The inverse of `json`, for `input.replay`. Flag-only events are dropped: a replayed key
    /// carries its own modifiers.
    static func timedInput(from v: JSONValue) throws -> TimedInput? {
        guard let t = v["t"]?.doubleValue, let type = v["type"]?.stringValue else {
            throw CommandError(code: .bad_params, message: "a recorded event needs 't' and 'type'")
        }
        let flags = CGEventFlags(rawValue: UInt64(v["flags"]?.doubleValue ?? 0))
        switch type {
        case "scroll":
            let phase = InputSynth.ScrollPhase(rawValue: Int64(v["phase"]?.doubleValue ?? 0)) ?? .none
            let momentum = InputSynth.MomentumPhase(rawValue: Int64(v["momentum"]?.doubleValue ?? 0)) ?? .none
            return TimedInput(at: t, kind: .scroll(dx: v["dx"]?.doubleValue ?? 0,
                                                   dy: v["dy"]?.doubleValue ?? 0,
                                                   precise: v["precise"]?.boolValue ?? true,
                                                   phase: phase, momentum: momentum, flags: flags))
        case "keyDown", "keyUp":
            return TimedInput(at: t, kind: .key(code: CGKeyCode(v["key_code"]?.doubleValue ?? 0),
                                                down: type == "keyDown", flags: flags,
                                                characters: v["characters"]?.stringValue))
        default:
            return nil
        }
    }
}
