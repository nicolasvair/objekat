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
    }
}
