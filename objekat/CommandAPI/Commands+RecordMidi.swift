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
                 "All MIDI Ins" or the harness'), `enabled`, `computer_keyboard` (true for the computer keyboard's input, always \
                 listed, second after "All MIDI Ins"). `zones` lists the MIDI recording zones: their `id`, \
                 `midi_input`, `present`, `instrument` (name or null) and whether the engine `live`ly holds its \
                 capture track (armed and able to record; the track plays nothing: arming is not hearing). Never an error: an empty list on a machine with no MIDI.
                 """,
                 undo: .none) { _ in
            let vm = try CommandContext.shared.requireViewModel()
            vm.refreshMidiInputs()
            return Self.midiInputsPayload(vm)
        }

        registerInputChainCommands()

        register("input.levels.midi_activity",
                 summary: """
                 The loudest note-on velocity (0...127) seen on each MIDI input since the PREVIOUS call, then \
                 cleared — what the row's blue activity mark shows. Only the inputs that played something appear \
                 (`activity`: {id, name, velocity, instrument_level}). `instrument_levels` lists EVERY input that \
                 carries an instrument: {id, name, instrument_level} — the level (0...1, the VU scale) at the \
                 instrument's output, which is what the row's meter shows under the blue mark; 0 while the \
                 input is not heard through it (monitor off) or silent. The call asks the engine to \
                 measure those instruments (owner `api.midi_activity`, kept), so the FIRST call answers 0: poll. \
                 Reading empties the engine's peak hold. Poll at the rate you want to see.
                 """,
                 undo: .none) { _ in
            let vm = try CommandContext.shared.requireViewModel()
            let instruments = vm.midiInputInstruments()
            vm.setMidiInstrumentMetering(owner: "api.midi_activity", ids: instruments.map { $0.instrument })
            let heard = vm.heardMidiDeviceIDs
            // One read per device, taken before anything is built from it.
            var levels: [(id: String, name: String, level: Double?)] = []
            for d in vm.midiInputs where instruments.contains(where: { $0.device == d.id }) {
                levels.append((id: d.id, name: d.name, level: vm.midiInstrumentLevel(of: d, heard: heard.contains(d.id))))
            }
            func levelJSON(_ id: String) -> JSONValue {
                guard let l = levels.first(where: { $0.id == id })?.level else { return .null }
                return .number(l)
            }
            let seen = vm.midiActivity()
            return .object([
                "activity": .array(seen.sorted { $0.key < $1.key }.map { id, v in
                    .object(["id": .string(id),
                             "name": .string(vm.midiInputs.first { $0.id == id }?.name ?? id),
                             "velocity": .int(v),
                             "instrument_level": levelJSON(id)])
                }),
                "instrument_levels": .array(levels.map { e in
                    .object(["id": .string(e.id), "name": .string(e.name),
                             "instrument_level": e.level.map { JSONValue.number($0) } ?? .null])
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

extension CommandRegistry {

    /// The payload of `input.list.midi_inputs` (and of `input.monitor` with `midi`). The devices carry what E9 added:
    /// whether they are `heard` through an instrument, the `instrument` they hold (name or null), the number of FX
    /// behind it (`fx_count`) and the `host_id` of their chain; `dormant_chains` lists the chains whose device is not there.
    @MainActor
    static func midiInputsPayload(_ vm: EditViewModel) -> JSONValue {
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
        let heard = vm.heardMidiDeviceIDs
        let present = Set(vm.midiInputs.map(\.id))
        let dormant: [JSONValue] = vm.inputChains.midi.values.compactMap { chain in
            guard !chain.isEmpty, vm.resolvedMidiInput(chain.input) == nil else { return nil }
            return .object(["host_id": .string(chain.hostID.uuidString),
                            "midi_input": .object(["id": .string(chain.input.id), "name": .string(chain.input.name)]),
                            "instrument": .stringOrNull(chain.instrument?.name),
                            "fx_count": .int(EditViewModel.flattenLeaves(chain.plugins).count)])
        }
        _ = present
        return .object([
            "midi_inputs": .array(vm.midiInputs.map { d in
                let key = vm.midiChainKey(for: d)
                let chain = key.flatMap { vm.inputChains.midi[$0] }
                return .object(["id": .string(d.id), "name": .string(d.displayName),
                                "virtual": .bool(d.isVirtual), "enabled": .bool(d.enabled),
                                "computer_keyboard": .bool(d.isComputerKeyboard),
                                "heard": .bool(heard.contains(d.id) && chain?.instrument != nil),
                                "instrument": .stringOrNull(chain?.instrument?.name),
                                "fx_count": .int(EditViewModel.flattenLeaves(chain?.plugins ?? []).count),
                                "monitor_gain_db": .number(vm.midiInputMonitorGain(d)),
                                "host_id": .stringOrNull(chain?.hostID.uuidString)])
            }),
            "zones": .array(zones),
            "dormant_chains": .array(dormant),
        ])
    }

    /// The present MIDI input `id` names, else `not_found`.
    @MainActor
    static func requireMidiDevice(_ id: String, in vm: EditViewModel) throws -> MidiInputInfo {
        vm.refreshMidiInputs()
        guard let d = vm.midiInputs.first(where: { $0.id == id }) else {
            throw CommandError(code: .not_found, message: "no such MIDI input: \(id)")
        }
        return d
    }

    func registerInputChainCommands() {

        register("input.host",
                 summary: """
                 The HOST of an input's chain (docs/plan_groupes_midi.md, E9): an id that `plugin.*` takes as `host` \
                 for the FX of a card input (`first`, `count` as in `input.set_name`) — a MIDI input (`midi`, an id \
                 from `input.list.midi_inputs`) holds ONE instrument, set by `input.set_instrument`. The chain is made \
                 (empty) if the input had none. `open` (default true) keeps the chain MOUNTED on the engine — its \
                 plugins live — even when nothing is heard through it; `open: false` lets it go (unmounted unless \
                 heard; its plugin states are kept). A chain is mounted only while its input is heard or it is open. \
                 Answers `host_id`, `kind`, `mounted`, `live` (the input exists and the chain is compiled), \
                 `plugins` (leaf count).
                 """,
                 params: [ParamSpec("first", "int", required: false, "First channel of a card input, 0-based."),
                          ParamSpec("count", "int", required: false, "1 (mono, default) or 2 (stereo pair)."),
                          ParamSpec("midi", "string", required: false, "A MIDI input id, instead of `first`."),
                          ParamSpec("open", "bool", required: false, "Keep it mounted (default true).")],
                 undo: .none) { p in
            let vm = try CommandContext.shared.requireViewModel()
            let engine = try CommandContext.shared.requireEngine()
            let open = try p.bool("open", or: true)
            let host: UUID
            let kind: String
            if let midi = try p.optionalString("midi") {
                host = vm.ensureMidiInputHost(try Self.requireMidiDevice(midi, in: vm))
                kind = "midi"
            } else {
                host = vm.ensureAudioInputHost(try Self.inputRef(p))
                kind = "audio"
            }
            if open { vm.openInputHost(host) } else { vm.closeInputHost(host) }
            let leaves = EditViewModel.flattenLeaves(vm.chainPlugins(host) ?? []).count
            return .object(["host_id": .string(host.uuidString), "kind": .string(kind),
                            "mounted": .bool(vm.mountedInputHosts.contains(host)),
                            "live": .bool(vm.compiledInputHosts.contains(host) && engine.inputHostIsLive(host.uuidString)),
                            "plugins": .int(leaves),
                            "fx_count": .int(leaves),
                            "instrument": .stringOrNull(vm.inputInstrument(host)?.name)])
        }

        register("input.strip",
                 summary: """
                 The RECTANGLES of the Inputs tab and their popup (docs/plan_groupes_midi.md). With `first` (+ `count`) \
                 or `midi` (an input id from `input.list.midi_inputs`) and `open` true (the default), opens that input's \
                 popup, as a click on its rectangle does: the chain is held mounted for as long as it is open, and a \
                 popup already open elsewhere closes. `open: false` closes it. With no input: only reads. Answers \
                 `open` (the open popup's input, or null), `host_id`, `mounted`, and `strips`: every rectangle the \
                 tab shows [{kind, first/count or id, name, selected, open, badges}]. `badges` are the sound list's \
                 (fx, fxLink, sidechainReception): a lone instrument has none. `invalid_state` for a card input the \
                 tab does not list (the card's inputs are closed). Not saved, outside the undo.
                 """,
                 params: [ParamSpec("first", "int", required: false, "First channel of a card input, 0-based."),
                          ParamSpec("count", "int", required: false, "1 (mono, default) or 2 (stereo pair)."),
                          ParamSpec("midi", "string", required: false, "A MIDI input id, instead of `first`."),
                          ParamSpec("open", "bool", required: false, "Open (default true) or close its popup.")],
                 undo: .none) { p in
            let vm = try CommandContext.shared.requireViewModel()
            let asked: RecordSource?
            if let midi = try p.optionalString("midi") {
                asked = .midi(try Self.requireMidiDevice(midi, in: vm).ref)
            } else if try p.optionalInt("first") != nil {
                let ref = try Self.inputRef(p)
                guard vm.visibleRecordInputs.contains(ref) else {
                    throw CommandError(code: .invalid_state, message: "input \(ref.first)/\(ref.count) is not listed")
                }
                asked = .audio(ref)
            } else {
                asked = nil
            }
            if let asked {
                if try p.bool("open", or: true) {
                    vm.openInputStrip = asked
                } else if vm.openInputStrip == asked {
                    vm.openInputStrip = nil
                }
            }
            @MainActor func name(_ s: RecordSource) -> String {
                switch s {
                case .audio(let r): return vm.inputName(r)
                case .midi(let r): return MidiInputResolver.resolve(r, in: vm.midiInputs)?.displayName ?? r.name
                }
            }
            @MainActor func describe(_ s: RecordSource) -> [String: JSONValue] {
                var o: [String: JSONValue] = ["name": .string(name(s))]
                switch s {
                case .audio(let r):
                    o["kind"] = .string("audio"); o["first"] = .int(r.first); o["count"] = .int(r.count)
                    o["selected"] = .bool(vm.selectedRecordInputs.contains(r))
                case .midi(let r):
                    o["kind"] = .string("midi"); o["id"] = .string(r.id)
                    o["selected"] = .bool(vm.selectedMidiInputs.contains(r.id))
                }
                o["open"] = .bool(vm.openInputStrip == s)
                o["badges"] = .array(vm.inputStripBadges(s).map { .string(String(describing: $0)) })
                return o
            }
            let strips: [RecordSource] = vm.midiInputs.map { .midi($0.ref) }
                + (vm.visibleRecordInputs.filter(\.isStereo) + vm.visibleRecordInputs.filter { !$0.isStereo }).map { .audio($0) }
            var out: [String: JSONValue] = [
                "strips": .array(strips.map { .object(describe($0)) }),
                "open": vm.openInputStrip.map { .object(describe($0)) } ?? .null,
                "host_id": .stringOrNull(vm.openInputStripHost?.uuidString),
            ]
            out["mounted"] = .bool(vm.openInputStripHost.map { vm.mountedInputHosts.contains($0) } ?? false)
            return .object(out)
        }

        register("input.set_instrument",
                 summary: """
                 Puts a virtual instrument on a MIDI input (`midi`, an input id), replacing any: it plays the notes of \
                 that input while the input is heard (`input.monitor`) — never the recording, which is taken from the \
                 device. Plugin by `identifier` or `name` (+ `format`), as `instrument.set`. One undo point. Not \
                 mounted until the input is heard or its host is open. `not_found` for an unknown input.
                 """,
                 params: [ParamSpec("midi", "string", "A MIDI input id."),
                          ParamSpec("identifier", "string", required: false, "Exact identifier."),
                          ParamSpec("name", "string", required: false, "Name, failing an identifier."),
                          ParamSpec("format", "string", required: false, "Format to settle ties.")],
                 undo: .handled) { p in
            let vm = try CommandContext.shared.requireViewModel()
            let device = try Self.requireMidiDevice(try p.string("midi"), in: vm)
            let available = try CommandAdapters.resolvePlugin(p, in: vm)
            guard available.isInstrument else {
                throw CommandError(code: .bad_params, message: "'\(available.name)' is not an instrument")
            }
            vm.setInputInstrument(device: device, available: available)
            return Self.midiInputsPayload(vm)
        }

        register("input.remove_instrument",
                 summary: "Takes the instrument off a MIDI input (`midi`); it stops being heard. One undo point. A no-op without one.",
                 params: [ParamSpec("midi", "string", "A MIDI input id.")],
                 undo: .handled) { p in
            let vm = try CommandContext.shared.requireViewModel()
            let device = try Self.requireMidiDevice(try p.string("midi"), in: vm)
            vm.removeInputInstrument(device: device)
            return Self.midiInputsPayload(vm)
        }
    }
}
