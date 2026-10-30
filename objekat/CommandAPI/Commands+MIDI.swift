import Foundation

// MARK: - MIDI

/// Notes are counted in BEATS from the start of the clip, never in seconds: it is the only unit
/// that survives a tempo change. The conversion, should a script need it, is done with the
/// `tempo` returned by `transport.state`.
extension CommandRegistry {

    func registerMIDICommands() {

        register("midi.create_clip",
                 summary: "Creates an empty MIDI clip over a time window and a lane.",
                 params: [ParamSpec("start", "number", "Start, in seconds."),
                          ParamSpec("end", "number", "End, in seconds."),
                          ParamSpec("lane", "int", required: false, "Display lane (default 0).")],
                 undo: .handled) { p in
            let vm = try CommandContext.shared.requireViewModel()
            let start = max(0, try p.double("start"))
            let end = try p.double("end")
            guard end > start else {
                throw CommandError(code: .bad_params, message: "'end' must come after 'start'")
            }
            let lane = max(0, try p.int("lane", or: 0))
            let selection = TimeSelection(timeRange: start...end, lanes: [lane])
            vm.createMidiClipFromTimeSelection(selection)
            // `createMidiClip` leaves the selection on the clip it created: that is its only output.
            guard let id = vm.selectedIDs.first, vm.find(id: id)?.isMIDI == true else {
                throw CommandError(code: .invalid_state, message: "no MIDI clip created")
            }
            return .object(["id": .string(id.uuidString),
                            "length_beats": .number(vm.find(id: id)?.midiLengthBeats ?? 0)])
        }

        register("midi.list_notes",
                 summary: "The notes of a MIDI clip.",
                 params: [ParamSpec("id", "uuid", "Target MIDI clip.")]) { p in
            let vm = try CommandContext.shared.requireViewModel()
            let id = try p.uuid("id")
            let clip = try CommandAdapters.requireMIDI(id, in: vm)
            return .object(["id": .string(id.uuidString),
                            "length_beats": .number(clip.midiLengthBeats),
                            "notes": .array(clip.midiNotes.map(CommandAdapters.notePayload)),
                            "count": .int(clip.midiNotes.count)])
        }

        register("midi.add_note",
                 summary: "Adds a note to a MIDI clip.",
                 params: [ParamSpec("id", "uuid", "Target MIDI clip."),
                          ParamSpec("pitch", "int", "Pitch 0…127 (60 = middle C)."),
                          ParamSpec("start_beat", "number", "Start, in beats from the clip."),
                          ParamSpec("length_beats", "number", "Length, in beats."),
                          ParamSpec("velocity", "int", required: false, "Velocity 0…127 (default 100).")],
                 undo: .handled) { p in
            let vm = try CommandContext.shared.requireViewModel()
            let id = try p.uuid("id")
            let before = Set(try CommandAdapters.requireMIDI(id, in: vm).midiNotes.map(\.id))
            vm.addMidiNote(toObject: id,
                           pitch: try p.int("pitch"),
                           startBeat: try p.double("start_beat"),
                           lengthBeats: try p.double("length_beats"),
                           velocity: try p.int("velocity", or: 100))
            guard let added = vm.find(id: id)?.midiNotes.first(where: { !before.contains($0.id) }) else {
                throw CommandError(code: .invalid_state, message: "note not added")
            }
            return .object(["id": .string(id.uuidString), "note": CommandAdapters.notePayload(added)])
        }

        register("midi.delete_notes",
                 summary: "Deletes notes from a MIDI clip (a single undo).",
                 params: [ParamSpec("id", "uuid", "Target MIDI clip."),
                          ParamSpec("note_ids", "array<uuid>", "Notes to delete.")],
                 undo: .handled) { p in
            let vm = try CommandContext.shared.requireViewModel()
            let id = try p.uuid("id")
            let clip = try CommandAdapters.requireMIDI(id, in: vm)
            let wanted = Set(try p.uuids("note_ids"))
            let existing = Set(clip.midiNotes.map(\.id))
            let unknown = wanted.subtracting(existing)
            guard unknown.isEmpty else {
                throw CommandError(code: .not_found,
                                   message: "unknown note: \(unknown.first!.uuidString)")
            }
            vm.deleteMidiNotes(fromObject: id, noteIDs: wanted)
            return .object(["id": .string(id.uuidString), "removed": .int(wanted.count)])
        }

        register("midi.update_note",
                 summary: "Changes a note: pitch, start, length and/or velocity.",
                 params: [ParamSpec("id", "uuid", "Target MIDI clip."),
                          ParamSpec("note_id", "uuid", "Target note."),
                          ParamSpec("pitch", "int", required: false, "New pitch 0…127."),
                          ParamSpec("start_beat", "number", required: false, "New start, in beats."),
                          ParamSpec("length_beats", "number", required: false, "New length, in beats."),
                          ParamSpec("velocity", "int", required: false, "New velocity 0…127.")],
                 // `updateMidiNote` pushes no undo: it is the drag path, whose state
                 // `beginMidiNoteEdit` has already captured. Here the bus plays that part.
                 undo: .bus) { p in
            let vm = try CommandContext.shared.requireViewModel()
            let id = try p.uuid("id")
            let clip = try CommandAdapters.requireMIDI(id, in: vm)
            let noteID = try p.uuid("note_id")
            guard clip.midiNotes.contains(where: { $0.id == noteID }) else {
                throw CommandError(code: .not_found, message: "unknown note: \(noteID.uuidString)")
            }
            let pitch = try p.optionalInt("pitch")
            let startBeat = try p.optionalDouble("start_beat")
            let lengthBeats = try p.optionalDouble("length_beats")
            let velocity = try p.optionalInt("velocity")
            guard pitch != nil || startBeat != nil || lengthBeats != nil || velocity != nil else {
                throw CommandError(code: .bad_params,
                                   message: "at least one of pitch / start_beat / length_beats / velocity")
            }
            vm.updateMidiNote(inObject: id, noteID: noteID) { note in
                if let pitch { note.pitch = pitch.clamped(to: 0...127) }
                if let startBeat { note.startBeat = startBeat }
                if let lengthBeats { note.lengthBeats = max(0.01, lengthBeats) }
                if let velocity { note.velocity = velocity.clamped(to: 0...127) }
            }
            guard let after = vm.find(id: id)?.midiNotes.first(where: { $0.id == noteID }) else {
                throw CommandError(code: .not_found, message: "note lost")
            }
            return .object(["id": .string(id.uuidString), "note": CommandAdapters.notePayload(after)])
        }

        register("midi.transpose",
                 summary: "Transposes notes (default: the current note selection).",
                 params: [ParamSpec("semitones", "int", "Offset, in semitones."),
                          ParamSpec("note_ids", "array<uuid>", required: false,
                                    "Target notes; default = current note selection."),
                          ParamSpec("follow_window", "bool", required: false,
                                    "Make the piano-roll window follow (default false).")],
                 undo: .handled) { p in
            let vm = try CommandContext.shared.requireViewModel()
            let delta = try p.int("semitones")
            guard delta != 0 else {
                throw CommandError(code: .bad_params, message: "'semitones' cannot be zero")
            }
            if p.raw["note_ids"] != nil {
                // `transposeSelectedMidiNotes` works on the note selection: we set it, exactly as the
                // piano roll would before calling the same method.
                vm.selectedMidiNoteIDs = Set(try p.uuids("note_ids"))
            }
            let count = vm.selectedMidiNoteIDs.count
            guard count > 0 else {
                throw CommandError(code: .invalid_state, message: "no target note")
            }
            vm.transposeSelectedMidiNotes(bySemitones: delta,
                                          followWindow: try p.bool("follow_window", or: false))
            return .object(["transposed": .int(count), "semitones": .int(delta)])
        }

        #if DEBUG
        // MARK: debug (E0 of plan_groupes_midi.md: engine proof, no production code)

        register("debug.mount_instrument",
                 summary: """
                 DEBUG. Mounts a virtual instrument on the ENGINE side of ANY object (a group included),                  straight through `OBJEngineCore.setInstrument` — the model is NOT touched (no `instruments`                  entry, no undo point, nothing in the project file) and the view-model's guard that keeps an                  instrument off a group's container is bypassed on purpose. It is the experiment of                  `tools/scenario_group_midi_proof.py`: does a MIDI clip placed in a group play through the                  instrument mounted on the group's container? Plugin by `identifier` or `name` (+ `format`),                  as `instrument.set`. Answers `plugin_key` (the engine's key for the instance). Not present                  in Release builds.
                 """,
                 params: [ParamSpec("id", "uuid", "Object whose container receives the instrument."),
                          ParamSpec("identifier", "string", required: false, "Exact identifier."),
                          ParamSpec("name", "string", required: false, "Name, failing an identifier."),
                          ParamSpec("format", "string", required: false, "Format to settle ties.")],
                 undo: .none) { p in
            let vm = try CommandContext.shared.requireViewModel()
            let engine = try CommandContext.shared.requireEngine()
            let id = try p.uuid("id")
            guard vm.find(id: id) != nil else {
                throw CommandError(code: .not_found, message: "unknown object: \(id.uuidString)")
            }
            let available = try CommandAdapters.resolvePlugin(p, in: vm)
            let info: [String: Any] = ["pluginKey": UUID().uuidString,
                                       "identifier": available.identifier,
                                       "format": available.formatName,
                                       "name": available.name]
            guard let key = engine.setInstrument(info, forObjectID: id.uuidString, stateXML: nil) else {
                throw CommandError(code: .engine_error,
                                   message: "the engine could not mount '\(available.name)' on \(id.uuidString)")
            }
            return .object(["id": .string(id.uuidString), "plugin_key": .string(key)])
        }

        register("debug.unmount_instrument",
                 summary: "DEBUG. Takes off the instrument `debug.mount_instrument` (or the engine) holds on an object, engine side only. Answers `removed`.",
                 params: [ParamSpec("id", "uuid", "Object whose container loses its instrument.")],
                 undo: .none) { p in
            let engine = try CommandContext.shared.requireEngine()
            let id = try p.uuid("id")
            engine.removeInstrument(forObjectID: id.uuidString)
            return .object(["id": .string(id.uuidString)])
        }

        register("debug.midi_mute",
                 summary: """
                 DEBUG. Sets (or, with no `muted`, only reads) the NATIVE mute of the `te::MidiClip` behind a MIDI                  object — `OBJEngineCore.setMidiClipMuted:forID:` — which the engine reads in real time                  (`LiveClipLevel`) and which is NOT the fader the model drives for a clip with an instrument.                  Engine side only: the model, the undo stack and the dirty flag are not touched. Answers                  `engine_muted` as read BACK from the clip, and `found` (false: no MIDI clip under that id).                  Not present in Release builds.
                 """,
                 params: [ParamSpec("id", "uuid", "MIDI object."),
                          ParamSpec("muted", "bool", required: false, "Omitted: read only.")],
                 undo: .none) { p in
            let engine = try CommandContext.shared.requireEngine()
            let id = try p.uuid("id")
            if let muted = try p.optionalBool("muted") {
                engine.setMidiClipMuted(muted, forID: id.uuidString)
            }
            let found = engine.hasMidiClip(forID: id.uuidString)
            return .object(["id": .string(id.uuidString),
                            "found": .bool(found),
                            "engine_muted": .bool(found && engine.isMidiClipMuted(forID: id.uuidString))])
        }

        register("debug.input_host",
                 summary: """
                 DEBUG. Drives the ENGINE's input chains (E8 of plan_groupes_midi.md) directly — the model, the \
                 undo stack and the project file are not touched. `op`: `register_audio` (`host`, `first`, \
                 `count`), `register_midi` (`host`, `device`), `unregister` (`host`), `live` (`host`), \
                 `add_plugin` (`host`, plugin by `identifier`/`name` + `format`: compiles ONE plugin as the whole \
                 FX chain of an audio host; answers `plugin`), `set_instrument` (`host`, plugin as above: mounts \
                 the instrument of a MIDI host; answers `plugin_key`), `midi_monitor` (`device`, `on`; answers \
                 `error` when refused), `monitors` (the MIDI devices heard through a chain). Answers `live` and \
                 `monitors` throughout. Not present in Release builds.
                 """,
                 params: [ParamSpec("op", "string", "See the summary."),
                          ParamSpec("host", "string", required: false, "Host id (any uuid)."),
                          ParamSpec("first", "int", required: false, "First channel of an audio input."),
                          ParamSpec("count", "int", required: false, "1 (mono) or 2 (stereo)."),
                          ParamSpec("device", "string", required: false, "MIDI input id."),
                          ParamSpec("on", "bool", required: false, "midi_monitor."),
                          ParamSpec("identifier", "string", required: false, "Plugin identifier."),
                          ParamSpec("name", "string", required: false, "Plugin name."),
                          ParamSpec("format", "string", required: false, "Plugin format.")],
                 undo: .none) { p in
            let vm = try CommandContext.shared.requireViewModel()
            let engine = try CommandContext.shared.requireEngine()
            let op = try p.string("op")
            let host = try p.optionalString("host") ?? ""
            var extra: [String: JSONValue] = [:]
            switch op {
            case "register_audio":
                let ok = engine.registerAudioInputHost(host, first: try p.int("first"), count: try p.int("count", or: 1))
                extra["registered"] = .bool(ok)
            case "register_midi":
                extra["registered"] = .bool(engine.registerMidiInputHost(host, device: try p.string("device")))
            case "unregister":
                engine.unregisterInputHost(host)
            case "add_plugin", "set_instrument":
                let available = try CommandAdapters.resolvePlugin(p, in: vm)
                let key = UUID().uuidString
                if op == "set_instrument" {
                    let info: [String: Any] = ["pluginKey": key, "identifier": available.identifier,
                                               "format": available.formatName, "name": available.name]
                    guard let k = engine.setInstrument(info, forObjectID: host, stateXML: nil) else {
                        throw CommandError(code: .engine_error, message: "the engine could not mount the instrument on host \(host)")
                    }
                    extra["plugin_key"] = .string(k)
                } else {
                    let spec: [[String: Any]] = [["id": key, "kind": "plugin", "identifier": available.identifier,
                                                  "format": available.formatName, "name": available.name, "enabled": true]]
                    let failed = engine.compileUserRack(forObjectID: host, tree: spec, sendChains: []) as? [String] ?? []
                    extra["plugin"] = .string(key)
                    extra["failed"] = .array(failed.map { .string($0) })
                }
            case "midi_monitor":
                let why = engine.setMidiInputMonitor(try p.bool("on"), device: try p.string("device"))
                extra["error"] = why.map { .string($0) } ?? .null
            case "live", "monitors":
                break
            default:
                throw CommandError(code: .bad_params, message: "unknown op '\(op)'")
            }
            extra["live"] = .bool(!host.isEmpty && engine.inputHostIsLive(host))
            extra["monitors"] = .array(engine.midiInputMonitors().map { .string($0) })
            return .object(extra)
        }

        register("debug.transport_loop",
                 summary: """
                 DEBUG. Sets the TRANSPORT's loop region and its mode on the view-model — what ⌘L and the \
                 transport bar's button do — since the public API has no door onto it (`transport.state` only \
                 reads it). The playhead tick arms the engine loop when playback ENTERS the region. \
                 `enabled: false` switches the mode off. Not present in Release builds.
                 """,
                 params: [ParamSpec("start", "number", required: false, "Region start, seconds."),
                          ParamSpec("end", "number", required: false, "Region end, seconds."),
                          ParamSpec("enabled", "bool", required: false, "Loop mode (default true).")],
                 undo: .none) { p in
            let vm = try CommandContext.shared.requireViewModel()
            if p.raw["start"] != nil || p.raw["end"] != nil {
                let a = try p.double("start"), b = try p.double("end")
                guard b > a else { throw CommandError(code: .bad_params, message: "'end' must come after 'start'") }
                vm.loopRegion = a...b
            }
            vm.loopModeEnabled = try p.bool("enabled", or: true)
            return .object(["enabled": .bool(vm.loopModeEnabled),
                            "region": vm.loopRegion.map { .array([.number($0.lowerBound), .number($0.upperBound)]) } ?? .null])
        }
        #endif
    }
}
