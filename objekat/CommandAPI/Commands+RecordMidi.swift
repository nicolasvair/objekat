import Foundation

// MARK: - The MIDI inputs (`input.list.midi_inputs`, `input.levels.midi_activity`, `midi.virtual.*`)

/// The MIDI counterpart of the card's inputs. The devices are Tracktion's (physical ones, "All MIDI Ins", and
/// under `--virtual-midi` one in-process device a client feeds); they exist whether or not the audio inputs
/// are open. Recording from them is `rec.*` (a zone with a MIDI input), unchanged.
extension CommandRegistry {

    func registerRecordMidiCommands() {

        register("input.list.midi_inputs",
                 summary: """
                 The MIDI inputs the engine offers, "All MIDI Ins" (`all_midi_in`) first: `id` (Tracktion's, what \
                 `rec.drop` / `rec.assign` take as `midi`), `name`, `virtual` (a software device, like \
                 "All MIDI Ins" or the harness'), `enabled`. `zones` lists the MIDI recording zones: their `id`, \
                 `midi_input`, `present`, `instrument` (name or null) and whether the engine `live`ly plays it \
                 (armed and able to record). Never an error: an empty list on a machine with no MIDI.
                 """,
                 undo: .none) { _ in
            let vm = try CommandContext.shared.requireViewModel()
            vm.refreshMidiInputs()
            let live = Set(vm.engine?.midiZonesLive() ?? [])
            var zones: [JSONValue] = []
            @MainActor func walk(_ items: [SoundObject]) {
                for item in items {
                    if let ref = item.recordMidiInput {
                        zones.append(.object([
                            "id": .string(item.id.uuidString),
                            "midi_input": .object(["id": .string(ref.id), "name": .string(vm.midiInputName(ref))]),
                            "present": .bool(vm.resolvedMidiInput(ref) != nil),
                            "instrument": .stringOrNull(item.instruments.first?.name),
                            "live": .bool(live.contains(item.id.uuidString)),
                        ]))
                    }
                    if case .group(let children, _) = item.kind { walk(children) }
                }
            }
            walk(vm.items)
            return .object([
                "midi_inputs": .array(vm.midiInputs.map { d in
                    .object(["id": .string(d.id), "name": .string(d.id == MidiInputResolver.allInputsID
                                                                    ? L("midi.all_inputs") : d.name),
                             "virtual": .bool(d.isVirtual), "enabled": .bool(d.enabled)])
                }),
                "zones": .array(zones),
            ])
        }

        register("input.levels.midi_activity",
                 summary: """
                 The loudest note-on velocity (0...127) seen on each MIDI input since the PREVIOUS call, then \
                 cleared — what the row's activity bar shows. Only the inputs that played something appear \
                 (`activity`: {id, name, velocity}). Poll at the rate you want to see.
                 """,
                 undo: .none) { _ in
            let vm = try CommandContext.shared.requireViewModel()
            let seen = vm.midiActivity()
            return .object(["activity": .array(seen.sorted { $0.key < $1.key }.map { id, v in
                .object(["id": .string(id),
                         "name": .string(vm.midiInputs.first { $0.id == id }?.name ?? id),
                         "velocity": .int(v)])
            })])
        }

        register("midi.virtual.status",
                 summary: """
                 The virtual MIDI input (`--virtual-midi`): `{active, device_id, name, sent, pending}` — `sent` the \
                 events delivered so far, `pending` those still waiting for their `delay_ms`. `{ "active": false }` \
                 on a normal launch.
                 """,
                 undo: .none) { _ in
            let engine = try CommandContext.shared.requireEngine()
            return JSONValue.fromFoundation(engine.virtualMidiStatus())
        }

        register("midi.virtual.send",
                 summary: """
                 Plays events into the virtual MIDI input (`--virtual-midi`; the real devices are never touched). \
                 `events`: [{kind: "on"|"off"|"cc", note, velocity?, channel?, delay_ms?}] — each event is sent \
                 `delay_ms` (default 0) from now, so a whole phrase can be scheduled in one call. For "cc", `note` \
                 is the controller number (64 = sustain pedal) and `velocity` its value. What goes to the virtual \
                 device also reaches "All MIDI Ins", as a physical device's would. `device` (a MIDI input id) \
                 sends to another device instead. Answers `midi.virtual.status`.
                 """,
                 params: [ParamSpec("events", "array<object>", "The events."),
                          ParamSpec("device", "string", required: false, "A MIDI input id; default = the virtual one.")],
                 undo: .none) { p in
            let engine = try CommandContext.shared.requireEngine()
            guard OBJEngineCore.isVirtualMidi() else {
                throw CommandError(code: .invalid_state,
                                   message: "the virtual MIDI input is not active (launch with --virtual-midi)")
            }
            var events: [[String: Any]] = []
            for (k, e) in try p.array("events").enumerated() {
                guard let kind = e["kind"]?.stringValue, ["on", "off", "cc"].contains(kind),
                      let note = e["note"]?.intValue else {
                    throw CommandError(code: .bad_params,
                                       message: "events[\(k)]: needs kind 'on', 'off' or 'cc' and an integer 'note'")
                }
                var d: [String: Any] = ["kind": kind, "note": note]
                if let v = e["velocity"]?.intValue { d["velocity"] = v }
                if let c = e["channel"]?.intValue { d["channel"] = c }
                if let t = e["delay_ms"]?.doubleValue { d["delay_ms"] = t }
                events.append(d)
            }
            guard !events.isEmpty else { throw CommandError(code: .bad_params, message: "'events' is empty") }
            if let why = engine.sendVirtualMidiEvents(events, device: try p.optionalString("device") ?? "") {
                throw CommandError(code: .bad_params, message: why)
            }
            return JSONValue.fromFoundation(engine.virtualMidiStatus())
        }
    }
}
