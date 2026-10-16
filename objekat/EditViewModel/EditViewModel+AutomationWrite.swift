import Foundation

// Writing automation LIVE — the session behind the band's pencil (@see AutomationBandView,
// `AutomationWritePencil`) and behind the wheel over it (@see TimelineKeyHandler).
//
// The arithmetic is not here: `AutomationTouchWrite` (pure, asserted with no screen) decides what
// the curve becomes. This file only owns the TIME: a 30 Hz tick reads the playhead, hands the
// hand's current value to the writer at that instant, lays the result into the model and pushes
// that ONE curve to the engine — so the parameter is HEARD moving while it is written, at the
// tick's rate (~30 Hz; the engine itself re-reads a curve on a 10 ms timer, @see
// AutomationCurveSource). The provisional hold the writer adds ahead of the playhead is what keeps
// the engine's render-ahead on the hand's value between two ticks.
//
// Rules worth knowing:
//   • NOTHING happens while the transport is stopped: the pencil is drawn disabled, and a press or
//     a wheel notch there is refused (`beginAutomationWrite` answers false). Writing "at the
//     playhead" has no meaning when the playhead does not move.
//   • ONE undo point per gesture, pushed LAZILY at the first sample actually written — a press
//     that ends before the first tick, or outside the object's window, leaves no empty undo step.
//     The wheel's gesture is the notches less than `valueScrollUndoGap` apart, as everywhere else.
//   • The transport stopping, or the object vanishing, ENDS the session as a release would.
//   • Times are the band's: relative to `origin`, the instant the band's x = 0 reads as (the
//     object's start; the timeline's zero for an infinite bus — @see AutomationRowOnScreen.origin).

/// The row a live write is aimed at — the one observed slice the band reads to light its pencil.
struct AutomationWriteTarget: Equatable {
    let objectID: UUID
    let param: ParamRef
}

/// A live write in progress. Outside observation (driven at 30 Hz): only `automationWriteTarget`
/// is observed.
final class AutomationWriteSession {
    enum Source { case drag, wheel }

    let target: AutomationWriteTarget
    let origin: Double
    let source: Source
    var writer: AutomationTouchWrite
    /// The value the hand is holding right now, written at every tick.
    var handValue: Float
    /// The value the curve had at the playhead when the gesture began — the drag's anchor.
    let startValue: Float
    var undoPushed = false
    var lastWheelTime: TimeInterval
    var timer: Timer?

    init(target: AutomationWriteTarget, origin: Double, source: Source,
         writer: AutomationTouchWrite, startValue: Float, now: TimeInterval) {
        self.target = target
        self.origin = origin
        self.source = source
        self.writer = writer
        self.startValue = startValue
        self.handValue = startValue
        self.lastWheelTime = now
    }
}

extension EditViewModel {

    /// The tick's period: ~30 Hz, the rate at which the written curve reaches the engine.
    static let automationWriteInterval: TimeInterval = 1.0 / 30

    /// A wheel write ends after this much silence — the wheel's own undo gap (@see
    /// TimelineView.valueScrollUndoGap, the same 0.5 s).
    static let automationWriteWheelIdle: TimeInterval = 0.5

    /// True while the pencil can write: the transport is PLAYING. Paused or stopped, it cannot.
    var canWriteAutomation: Bool { isTransportPlaying }

    /// The value the parameter holds where its curve says nothing — its static value, the plugin's
    /// own current value, or the neutral one.
    func automationWriteDefault(_ param: ParamRef, on object: SoundObject) -> Float {
        if let v = automationStaticValue(param, on: object) { return v }
        if case .plugin(let pluginKey, let paramID) = param,
           let v = pluginCurrentValue(pluginKey: pluginKey, paramID: paramID) { return v }
        return param.neutralValue
    }

    /// Opens a live write on one row. `origin` = the absolute instant of the row's zero, `maxT` =
    /// the band's length (relative seconds; writing outside 0…maxT records nothing). Returns false
    /// — and does nothing — when the transport is not playing.
    @discardableResult
    func beginAutomationWrite(objectID: UUID, param: ParamRef, origin: Double, maxT: Double,
                              source: AutomationWriteSession.Source) -> Bool {
        endAutomationWrite()
        guard canWriteAutomation, let engine, let obj = find(id: objectID) else { return false }
        let original = obj.automation.first(where: { $0.param == param })?.points ?? []
        let def = automationWriteDefault(param, on: obj)
        let writer = AutomationTouchWrite(original: original, range: param.valueRange,
                                          bounds: 0...max(0, maxT), defaultValue: def)
        // The value under the playhead: the gesture starts THERE, so pressing makes no jump.
        let tNow = engine.currentPlaybackPosition() - origin
        let start = AutomationCurveMath.value(at: tNow, in: original.sorted { $0.t < $1.t },
                                              default: def)
        let session = AutomationWriteSession(
            target: AutomationWriteTarget(objectID: objectID, param: param),
            origin: origin, source: source, writer: writer, startValue: start,
            now: ProcessInfo.processInfo.systemUptime)
        automationWrite = session
        automationWriteTarget = session.target
        let timer = Timer(timeInterval: Self.automationWriteInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.automationWriteTick() }
        }
        // `.common`: the tick must go on while the mouse is held down (event tracking).
        RunLoop.main.add(timer, forMode: .common)
        session.timer = timer
        automationWriteTick()      // the press itself writes: touch holds the value from here
        return true
    }

    /// The drag's value: the hand's absolute value for the row (clamped by the writer).
    func setAutomationWriteValue(_ v: Float) {
        automationWrite?.handValue = v
    }

    /// One wheel event over a pencil: opens (or continues) a wheel write on that row and moves its
    /// value by `steps` wheel steps (@see automationWheelStepValue). Returns false when the
    /// transport is not playing (the caller lets the event through).
    @discardableResult
    func automationWriteWheel(objectID: UUID, param: ParamRef, origin: Double, maxT: Double,
                              steps: Int) -> Bool {
        let target = AutomationWriteTarget(objectID: objectID, param: param)
        if automationWrite?.target != target || automationWrite?.source != .wheel {
            guard beginAutomationWrite(objectID: objectID, param: param, origin: origin,
                                       maxT: maxT, source: .wheel) else { return false }
        }
        guard let s = automationWrite else { return false }
        s.lastWheelTime = ProcessInfo.processInfo.systemUptime
        if steps != 0 {
            let r = param.valueRange
            s.handValue = (s.handValue + Float(steps) * Self.automationWheelStepValue(param))
                .clamped(to: r)
            automationWriteTick()
        }
        return true
    }

    /// Ends the live write: the curve keeps what was written, without the provisional hold, and
    /// every curve of the object is pushed once (which also settles the engine's bookkeeping of
    /// plugin curves, @see pushAutomation). Idempotent.
    func endAutomationWrite() {
        guard let s = automationWrite else { return }
        s.timer?.invalidate()
        s.timer = nil
        automationWrite = nil
        automationWriteTarget = nil
        guard s.writer.hasWritten, find(id: s.target.objectID) != nil else { return }
        layAutomationWrite(s, holding: false)
        pushAutomation(s.target.objectID)
    }

    /// One tick: the hand's value at the playhead, into the writer, into the model, to the engine.
    func automationWriteTick() {
        guard let s = automationWrite else { return }
        guard let engine, isTransportPlaying, find(id: s.target.objectID) != nil else {
            endAutomationWrite(); return
        }
        if s.source == .wheel,
           ProcessInfo.processInfo.systemUptime - s.lastWheelTime > Self.automationWriteWheelIdle {
            endAutomationWrite(); return
        }
        let t = engine.currentPlaybackPosition() - s.origin
        guard s.writer.write(t: t, v: s.handValue) else { return }   // outside the window
        if !s.undoPushed {
            pushUndo()
            // Points are addressed by storage index: the curve is about to be rebuilt wholesale.
            clearAutomationPointSelection()
            s.undoPushed = true
        }
        let created = layAutomationWrite(s, holding: true)
        guard let obj = find(id: s.target.objectID) else { return }
        if created {
            // The row's first point: a send at -∞ has no engine plugin yet (@see
            // addAutomationPoint), and a plugin curve enters the push's bookkeeping.
            if case .send(let auxID) = s.target.param {
                syncSendEngine(objectID: s.target.objectID, auxID: auxID)
            }
            pushAutomation(obj)
        } else {
            pushAutomationCurve(s.target.param, on: obj)
        }
    }

    /// Writes the writer's current curve into the model. Returns true if the row had to be CREATED.
    @discardableResult
    private func layAutomationWrite(_ s: AutomationWriteSession, holding: Bool) -> Bool {
        let pts = s.writer.points(holding: holding)
        let param = s.target.param
        var created = false
        update(id: s.target.objectID) { obj in
            if let i = obj.automation.firstIndex(where: { $0.param == param }) {
                obj.automation[i].points = pts
            } else if !pts.isEmpty {
                obj.automation.append(AutomationLane(param: param, points: pts))
                created = true
            }
        }
        isDirty = true
        return created
    }

    /// Pushes ONE curve of an object — the live write's push, at the tick's rate. The full
    /// `pushAutomation` pushes every curve of the object (and sweeps the stale plugin ones); a
    /// write that touches one row has no reason to pay for the others thirty times a second.
    func pushAutomationCurve(_ ref: ParamRef, on object: SoundObject) {
        guard let engine, let t = Self.engineTarget(for: ref) else { return }
        engine.setAutomationCurve(engineCurvePoints(ref, on: object),
                                  forObject: object.id.uuidString,
                                  target: t.target,
                                  targetKey: t.key,
                                  paramID: t.paramID)
    }
}
