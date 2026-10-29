import Foundation

// MARK: - The audio device family

/// `audio.status` reads the SAME `AudioDeviceStatus` the window's subtitle reads (@see
/// `EditViewModel.updateWindowSubtitle`) — a script can never be told something the title bar
/// does not also show. `audio.devices` lists what the engine offers; the three `audio.set_*`
/// touch the REAL hardware through the engine's existing setters (never
/// `AudioOutputDevice.shared` — a script must not write the user's persisted choice) and wait
/// for `AudioDeviceStatus.generation` to move before answering, so a caller never reads a
/// half-applied change.
extension CommandRegistry {

    func registerAudioCommands() {

        register("audio.status",
                 summary: """
                 The audio device really in use — cached (what the title bar shows) alongside \
                 `live` (read from the engine at this instant), so a script can prove the two \
                 agree. `device: null` means no output device is OPEN (--no-audio, or the open \
                 failed) — never a lie about a device that merely isn't playing.
                 """,
                 undo: .none) { _ in
            Self.audioStatusPayload()
        }

        register("audio.devices",
                 summary: "The engine's output devices, sample rates and buffer sizes — " +
                          "re-scanned live, so a device freshly plugged in is already there.",
                 undo: .none) { _ in
            let engine = try CommandContext.shared.requireEngine()
            return .object([
                "outputs": .array(engine.availableOutputDevices().map { .string($0) }),
                "sample_rates": .array(engine.availableSampleRates().map { .number($0.doubleValue) }),
                "buffer_sizes": .array(engine.availableBufferSizes().map { .int($0.intValue) }),
            ])
        }

        register("audio.set_buffer_size",
                 summary: "Sets the CURRENT device's buffer size (latency). Touches the real " +
                          "hardware and rewrites ~/Library/objekat/Settings.xml.",
                 params: [ParamSpec("frames", "int", "One of `audio.devices.buffer_sizes`.")],
                 undo: .none) { p in
            let engine = try CommandContext.shared.requireEngine()
            let frames = try p.int("frames")
            let available = engine.availableBufferSizes().map { $0.intValue }
            guard available.contains(frames) else {
                throw CommandError(code: .bad_params,
                                   message: "frames \(frames) not in the device's available " +
                                            "list \(available)")
            }
            let before = AudioDeviceStatus.shared.generation
            engine.setBufferSize(frames)
            let settled = await Self.awaitDeviceSettled(from: before)
            return Self.audioStatusPayload(settled: settled)
        }

        register("audio.set_sample_rate",
                 summary: "Sets the CURRENT device's nominal sample rate — for the WHOLE " +
                          "system (CoreAudio), not only for OBJEKAT. Touches the real hardware " +
                          "and rewrites ~/Library/objekat/Settings.xml.",
                 params: [ParamSpec("hz", "number", "One of `audio.devices.sample_rates`.")],
                 undo: .none) { p in
            let engine = try CommandContext.shared.requireEngine()
            let hz = try p.double("hz")
            let available = engine.availableSampleRates().map { $0.doubleValue }
            guard available.contains(hz) else {
                throw CommandError(code: .bad_params,
                                   message: "hz \(hz) not in the device's available list \(available)")
            }
            let before = AudioDeviceStatus.shared.generation
            engine.setSampleRate(hz)
            let settled = await Self.awaitDeviceSettled(from: before)
            return Self.audioStatusPayload(settled: settled)
        }

        register("audio.set_device",
                 summary: "Switches the output device. Touches the real hardware and rewrites " +
                          "~/Library/objekat/Settings.xml. The new card keeps the sample rate it " +
                          "already runs at (`rate_decision: adopt`); only a rate unusable for " +
                          "OBJEKAT (outside 22.05-192 kHz, or not offered by the card) is " +
                          "changed (`fallback`, `device_rate_before` says what it was).",
                 params: [ParamSpec("name", "string", "One of `audio.devices.outputs`.")],
                 undo: .none) { p in
            let engine = try CommandContext.shared.requireEngine()
            let name = try p.string("name")
            guard engine.availableOutputDevices().contains(name) else {
                throw CommandError(code: .bad_params,
                                   message: "'\(name)' not in the device's available list")
            }
            let before = AudioDeviceStatus.shared.generation
            engine.setOutputDevice(name)
            let settled = await Self.awaitDeviceSettled(from: before)
            return Self.audioStatusPayload(settled: settled)
        }

        // MARK: The virtual card (--virtual-audio)

        register("audio.virtual.status",
                 summary: """
                 The virtual sound card (`--virtual-audio`): its configuration, what each input \
                 carries right now, and `loopback_delay` — the frames between an output sample \
                 leaving the callback and coming back on a `loopback` input (two buffers plus the \
                 announced latencies). `{ "active": false }` on a normal launch.
                 """,
                 undo: .none) { _ in
            let engine = try CommandContext.shared.requireEngine()
            return JSONValue.fromFoundation(engine.virtualAudioStatus())
        }

        register("audio.virtual.set_input",
                 summary: """
                 Chooses what input `channel` of the virtual card carries: `silence` (the default), \
                 `sine` (`frequency` Hz at `amplitude`, phase-continuous), `impulse` (one sample of \
                 `amplitude` every `period` seconds, the first at once) or `loopback` (the output's \
                 first channel, delayed by `audio.virtual.status.loopback_delay`). Only exists \
                 under `--virtual-audio`; the real card is never touched.
                 """,
                 params: [ParamSpec("channel", "int", "0-based input channel of the virtual card."),
                          ParamSpec("signal", "string", "silence | sine | impulse | loopback."),
                          ParamSpec("frequency", "number", required: false, "sine only, Hz. Default 440."),
                          ParamSpec("amplitude", "number", required: false, "Linear, 0...1. Default 0.5."),
                          ParamSpec("period", "number", required: false, "impulse only, seconds. Default 1.")],
                 undo: .none) { p in
            let engine = try CommandContext.shared.requireEngine()
            guard OBJEngineCore.isVirtualAudio() else {
                throw CommandError(code: .invalid_state,
                                   message: "the virtual card is not active (launch with --virtual-audio)")
            }
            let channel = try p.int("channel")
            let signal = try p.string("signal")
            let frequency = try p.double("frequency", or: 440)
            let amplitude = try p.double("amplitude", or: 0.5)
            let period = try p.double("period", or: 1)
            guard frequency > 0, frequency <= 96_000 else {
                throw CommandError(code: .bad_params, message: "frequency \(frequency) outside (0, 96000] Hz")
            }
            guard amplitude >= 0, amplitude <= 4 else {
                throw CommandError(code: .bad_params, message: "amplitude \(amplitude) outside 0...4")
            }
            guard period >= 0.001 else {
                throw CommandError(code: .bad_params, message: "period \(period) under 0.001 s")
            }
            if let why = engine.setVirtualInputChannel(channel, signal: signal, frequency: frequency,
                                                       amplitude: amplitude, period: period) {
                throw CommandError(code: .bad_params, message: why)
            }
            return JSONValue.fromFoundation(engine.virtualAudioStatus())
        }
    }

    // MARK: Shared helpers

    /// `audio.status`'s own answer, reused by every `set_*` (with `settled` added). `cached` is
    /// `AudioDeviceStatus.shared` — the exact snapshot the title bar shows; `live` is read from
    /// the engine RIGHT NOW, so a script can assert the two agree instead of taking it on trust.
    @MainActor
    private static func audioStatusPayload(settled: Bool? = nil) -> JSONValue {
        let status = AudioDeviceStatus.shared
        let s = status.snapshot
        var obj: [String: JSONValue] = [
            "device": .stringOrNull(s.name),
            "type": .stringOrNull(s.type),
            "sample_rate": .number(s.sampleRate),
            "buffer_size": .int(s.bufferSize),
            "output_channels": .int(s.outputChannels),
            "running": .bool(s.running),
            "rate_decision": .string(s.rateDecision.apiName),
            "device_rate_before": .number(s.deviceRateBeforeDecision),
            "text": .string(status.text),
            "generation": .int(status.generation),
            // The grey LABEL's own displayed string (@see `TitleBarDeviceLabel`, 4b) — never
            // `window.subtitle` itself, which 4a's measurement retired to always-empty: the
            // subtitle fuses onto the title's own field with no way to grey only its own half.
            "window_subtitle": .stringOrNull(CommandContext.shared.viewModel?.displayedAudioDeviceText),
        ]
        if let engine = CommandContext.shared.engine {
            let live = engine.audioDeviceSnapshot()
            obj["live"] = .object([
                "device": .stringOrNull(live.deviceName),
                "type": .stringOrNull(live.deviceType),
                "sample_rate": .number(live.sampleRate),
                "buffer_size": .int(live.bufferSize),
                "output_channels": .int(live.outputChannels),
                "running": .bool(live.running),
                "rate_decision": .string(SampleRateDecision(raw: live.rateDecision).apiName),
                "device_rate_before": .number(live.deviceRateBeforeDecision),
            ])
        } else {
            obj["live"] = .null
        }
        if let settled { obj["settled"] = .bool(settled) }
        return .object(obj)
    }

    /// Polls `AudioDeviceStatus.generation` (the same 20 ms interval as `Quiescence.waitIdle`)
    /// until it moves past `before`, up to 3 s. `false` on timeout — the caller answers with
    /// whatever the snapshot currently says rather than throwing: the device setter itself did
    /// not fail, only the confirmation took too long (a device that needs more time to restart).
    @MainActor
    private static func awaitDeviceSettled(from before: Int, timeoutMs: Int = 3000) async -> Bool {
        let started = ContinuousClock.now
        let budget = Duration.milliseconds(timeoutMs)
        while AudioDeviceStatus.shared.generation == before {
            guard ContinuousClock.now - started < budget else { return false }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return true
    }
}
