import Foundation

// MARK: - The sound card's inputs (`input.*`)

/// The card's inputs are CLOSED until `input.enable`: opening one is what makes macOS ask for the
/// microphone and what switches AirPods to the call profile, neither of which may happen at launch
/// for an app nobody has asked to record. They open on the SAME device as the output (one clock,
/// no drift) and stay open until the device changes or `input.disable`.
///
/// `input.list` describes what the engine offers — one mono input per channel, plus one stereo
/// input per declared neighbouring pair — and `input.levels` reads the peak meters. Nothing here
/// records: that comes with the recording increments.
extension CommandRegistry {

    func registerRecordCommands() {

        register("input.enable",
                 summary: """
                 Opens the inputs of the CURRENT output device (on demand — they are closed at \
                 launch). Waits for the device to settle, then answers like `input.list`. A no-op \
                 when they are already open. Under `--no-audio`, or with no device open: \
                 `invalid_state`. On a real card the first call makes macOS ask for the microphone.
                 """,
                 undo: .none) { _ in
            let engine = try CommandContext.shared.requireEngine()
            if engine.audioInputsOpen() { return Self.inputListPayload(engine) }
            let status = AudioDeviceStatus.shared
            guard status.snapshot.name != nil else {
                throw CommandError(code: .invalid_state,
                                   message: "no audio device is open (--no-audio, or the open failed)")
            }
            let before = status.generation
            if let why = engine.openAudioInputs() {
                throw CommandError(code: .engine_error, message: why)
            }
            _ = await Self.awaitDeviceSettled(from: before)
            return Self.inputListPayload(engine)
        }

        register("input.disable",
                 summary: "Closes the card's inputs again (the output keeps playing). A no-op when " +
                          "they are closed.",
                 undo: .none) { _ in
            let engine = try CommandContext.shared.requireEngine()
            guard engine.audioInputsOpen() else { return Self.inputListPayload(engine) }
            let before = AudioDeviceStatus.shared.generation
            engine.closeAudioInputs()
            _ = await Self.awaitDeviceSettled(from: before)
            return Self.inputListPayload(engine)
        }

        register("input.list",
                 summary: """
                 The card's inputs. `inputs` is what can be recorded from right now — the ENABLED \
                 devices, mono or stereo (`first` = first channel, 0-based; `count` = 1 or 2). \
                 `engine_devices` is everything the engine describes (2N - 1 for N channels: \
                 N monos then N - 1 neighbouring pairs), enabled or not. Both are empty while the \
                 inputs are closed (`open: false`), `--no-audio` included — never an error.
                 """,
                 undo: .none) { _ in
            Self.inputListPayload(try CommandContext.shared.requireEngine())
        }

        register("input.levels",
                 summary: """
                 The peak of each input channel since the PREVIOUS call, in dB (floor -120), then \
                 cleared: the first call after a quiet spell reads what happened since the last \
                 one, so poll at the rate you want to see. `channels` is per card channel, \
                 `inputs` the same peaks folded onto the enabled devices (a stereo input reports \
                 the louder of its two channels). Empty while the inputs are closed.
                 """,
                 undo: .none) { _ in
            let engine = try CommandContext.shared.requireEngine()
            let peaks = engine.audioInputPeaksDb().map { $0.doubleValue }
            let channels: [JSONValue] = peaks.enumerated().map { i, db in
                .object(["channel": .int(i), "peak_db": .number(db)])
            }
            let inputs: [JSONValue] = Self.inputDevices(engine).filter { $0.enabled }.enumerated().map { i, d in
                let span = (d.first ..< min(d.first + d.count, peaks.count)).map { peaks[$0] }
                return .object(["index": .int(i), "name": .string(d.name), "first": .int(d.first),
                                "count": .int(d.count), "peak_db": .number(span.max() ?? -120)])
            }
            return .object(["open": .bool(engine.audioInputsOpen()),
                            "channels": .array(channels), "inputs": .array(inputs)])
        }

        register("input.set_pairs",
                 summary: """
                 Declares which neighbouring channels form ONE stereo input: `pairs` lists the FIRST \
                 channel of each (0 = channels 1+2, 2 = channels 3+4). A pair consumes its two \
                 channels (their monos stop being offered), two overlapping pairs keep the lower \
                 one, a pair outside the card is ignored. `[]` goes back to all-mono. Answers like \
                 `input.list` (`pairs` = the ones in force). Engine-level for now — the project \
                 model will own this later.
                 """,
                 params: [ParamSpec("pairs", "array", "First channel of each stereo pair, 0-based.")],
                 undo: .none) { p in
            let engine = try CommandContext.shared.requireEngine()
            let values = try p.array("pairs").map { v -> NSNumber in
                guard let i = v.intValue else {
                    throw CommandError(code: .bad_params, message: "'pairs' must be a list of integers")
                }
                return NSNumber(value: i)
            }
            engine.setAudioInputStereoPairs(values)
            return Self.inputListPayload(engine)
        }
    }

    // MARK: Shared helpers

    private struct InputDevice {
        let name: String
        let first: Int
        let count: Int
        let enabled: Bool
    }

    private static func inputDevices(_ engine: OBJEngineCore) -> [InputDevice] {
        engine.audioInputDevices().compactMap { d in
            guard let name = d["name"] as? String, let first = (d["first"] as? NSNumber)?.intValue,
                  let count = (d["count"] as? NSNumber)?.intValue else { return nil }
            return InputDevice(name: name, first: first, count: count,
                               enabled: (d["enabled"] as? NSNumber)?.boolValue ?? false)
        }
    }

    private static func inputJSON(_ d: InputDevice, index: Int? = nil) -> JSONValue {
        var o: [String: JSONValue] = ["name": .string(d.name), "first": .int(d.first),
                                      "count": .int(d.count), "stereo": .bool(d.count == 2),
                                      "enabled": .bool(d.enabled)]
        if let index { o["index"] = .int(index) }
        return .object(o)
    }

    /// `input.list`'s own answer, reused by every other `input.*` command.
    @MainActor
    static func inputListPayload(_ engine: OBJEngineCore) -> JSONValue {
        let open = engine.audioInputsOpen()
        let all = inputDevices(engine)
        let names = engine.audioInputChannelNames()
        return .object([
            "open": .bool(open),
            "device": .stringOrNull(open ? AudioDeviceStatus.shared.snapshot.name : nil),
            "channels": .int(names.count),
            "channel_names": .array(names.map { .string($0) }),
            "pairs": .array(engine.audioInputStereoPairs().map { .int($0.intValue) }),
            "inputs": .array(all.filter { $0.enabled }.enumerated().map { inputJSON($1, index: $0) }),
            "engine_devices": .array(all.map { inputJSON($0) }),
        ])
    }
}
