import AppKit
import Foundation

// MARK: - The computer keyboard as a MIDI input

/// `midi.keyboard.*`: the state of the « Computer Keyboard » input and a way to play it with no hand on a keyboard.
/// `key` goes through `EditViewModel.computerKeyboardKeyDown` — the very routing the key monitor uses — so a
/// headless test proves what the hand would get (but not the AppKit monitor's own early exits: text field, plugin
/// browser, plugin window).
extension CommandRegistry {

    func registerComputerKeyboardCommands() {

        register("midi.keyboard.status",
                 summary: """
                 The computer keyboard MIDI input (« Computer Keyboard », always listed by `input.list.midi_inputs` with \
                 `computer_keyboard: true`): `on` (whether the keys are notes), `octave` (the MIDI note under the `q` key, \
                 a multiple of 12 within 0…108; 60 = "C4" at launch), `octave_name`, `held` (the notes sounding: \
                 `[{key_code, note}]`), `device_id` (null if the engine does not list it). Session state: off at launch, \
                 kept across tabs, never saved.
                 """,
                 undo: .none) { _ in
            let vm = try CommandContext.shared.requireViewModel()
            return Self.computerKeyboardPayload(vm)
        }

        register("midi.keyboard.set",
                 summary: """
                 Turns the computer keyboard mode on or off (the transport button's twin). Off releases every sounding \
                 note. It never changes the engine's device list. Answers `midi.keyboard.status`.
                 """,
                 params: [ParamSpec("on", "bool", "true = the keys are notes (and ⇧ + letter reaches the tools).")],
                 undo: .none) { p in
            let vm = try CommandContext.shared.requireViewModel()
            vm.setComputerKeyboardMode(try p.bool("on"))
            return Self.computerKeyboardPayload(vm)
        }

        register("midi.keyboard.octave",
                 summary: """
                 Moves the keys' octave: `base` sets the MIDI note under `q` (a multiple of 12, 0…108), `delta` moves it by \
                 that many octaves (clamped). Exactly one of the two. Notes already sounding keep the pitch they started \
                 with. Answers `midi.keyboard.status`.
                 """,
                 params: [ParamSpec("base", "int", required: false, "The MIDI note under `q`: 0, 12 … 108."),
                          ParamSpec("delta", "int", required: false, "Octaves to move by (negative = down).")],
                 undo: .none) { p in
            let vm = try CommandContext.shared.requireViewModel()
            let base = try p.optionalInt("base"), delta = try p.optionalInt("delta")
            guard (base == nil) != (delta == nil) else {
                throw CommandError(code: .bad_params, message: "give exactly one of 'base' and 'delta'")
            }
            if let base {
                guard vm.setComputerKeyboardOctave(base) else {
                    throw CommandError(code: .bad_params, message: "'base' must be a multiple of 12 within 0…108")
                }
            } else if let delta {
                let target = vm.computerKeyboardOctave + delta * ComputerKeyboardMap.octaveStep
                let range = ComputerKeyboardMap.octaveRange
                vm.setComputerKeyboardOctave(min(max(target, range.lowerBound), range.upperBound))
            }
            return Self.computerKeyboardPayload(vm)
        }

        register("midi.keyboard.key",
                 summary: """
                 Presses or releases ONE physical key as the key monitor would (same router, `ComputerKeyboardMap.route`). \
                 `key_code` is the PHYSICAL code (q = 0, z = 13, s = 1 … `w` = 6 octave down, `x` = 7 octave up). \
                 `down` (default true), `repeat` (an auto-repeat, default false), `flags`: any of "cmd", "ctrl", "alt", \
                 "shift" (a held modifier hands the key back to the rest of the app). Answers `decision`: \
                 `note_on` (with `note`), `note_off` (with `note`), `octave` (with `octave`), `swallow` (ours, nothing \
                 to do) or `pass_through` (not ours: nothing happened here), plus the `midi.keyboard.status` fields.
                 """,
                 params: [ParamSpec("key_code", "int", "The physical key code."),
                          ParamSpec("down", "bool", required: false, "true = key down (default), false = key up."),
                          ParamSpec("repeat", "bool", required: false, "An auto-repeat of a key down (default false)."),
                          ParamSpec("flags", "array<string>", required: false, "Held modifiers: cmd, ctrl, alt, shift.")],
                 undo: .none) { p in
            let vm = try CommandContext.shared.requireViewModel()
            let code = try p.int("key_code")
            guard (0...0xFFFF).contains(code) else {
                throw CommandError(code: .bad_params, message: "'key_code' out of range")
            }
            let keyCode = UInt16(code)
            var flags: NSEvent.ModifierFlags = []
            if let list = p.raw["flags"] {
                let names = list.stringValue.map { [$0] } ?? list.arrayValue?.compactMap(\.stringValue) ?? []
                for name in names {
                    switch name {
                    case "cmd": flags.insert(.command)
                    case "ctrl": flags.insert(.control)
                    case "alt": flags.insert(.option)
                    case "shift": flags.insert(.shift)
                    default: throw CommandError(code: .bad_params, message: "unknown modifier '\(name)' (cmd, ctrl, alt, shift)")
                    }
                }
            }
            var result: [String: JSONValue] = [:]
            if try p.bool("down", or: true) {
                switch vm.computerKeyboardKeyDown(keyCode: keyCode, flags: flags, isRepeat: try p.bool("repeat", or: false)) {
                case .passThrough: result["decision"] = .string("pass_through")
                case .swallow: result["decision"] = .string("swallow")
                case .noteOn(_, let note):
                    result["decision"] = .string("note_on"); result["note"] = .int(note)
                case .octave(let base):
                    result["decision"] = .string("octave"); result["octave"] = .int(base)
                }
            } else if let note = vm.computerKeyboardHeld[keyCode], vm.computerKeyboardKeyUp(keyCode: keyCode) {
                result["decision"] = .string("note_off"); result["note"] = .int(note)
            } else {
                result["decision"] = .string("pass_through")
            }
            if case .object(let status) = Self.computerKeyboardPayload(vm) {
                result.merge(status) { current, _ in current }
            }
            return .object(result)
        }
    }

    @MainActor
    static func computerKeyboardPayload(_ vm: EditViewModel) -> JSONValue {
        vm.refreshMidiInputs()
        let device = vm.midiInputs.first(where: \.isComputerKeyboard)
        let held = vm.computerKeyboardHeld.sorted { $0.key < $1.key }
            .map { JSONValue.object(["key_code": .int(Int($0.key)), "note": .int($0.value)]) }
        return .object(["on": .bool(vm.computerKeyboardOn),
                        "octave": .int(vm.computerKeyboardOctave),
                        "octave_name": .string(vm.computerKeyboardOctaveName),
                        "held": .array(held),
                        "device_id": .stringOrNull(device?.id),
                        // The layout the keys are named after ("azerty" / "qwerty" / "qwertz", else null) and the
                        // name shown (family title, else the layout's own name); both depend on the machine.
                        "layout_family": .stringOrNull(KeyboardLayoutWatcher.shared.family?.rawValue),
                        "layout_name": .stringOrNull(KeyboardLayoutWatcher.shared.name)])
    }
}
