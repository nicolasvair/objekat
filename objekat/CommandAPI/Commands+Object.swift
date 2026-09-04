import Foundation

// MARK: - Object attributes (fades, speed, direction, pan, mute, name, bounds)

/// These commands round out `object.*` from `Commands+Core`: they neither create nor move
/// anything, they set. All go through the view-model's `update…` methods, which push the value
/// to the engine as well as the model — writing into `items` directly would leave audio behind.
extension CommandRegistry {

    func registerObjectCommands() {

        register("object.get",
                 summary: "Detail of an object: position, bounds, mix, fades, plugins, sends.",
                 params: [ParamSpec("id", "uuid", "Target object.")]) { p in
            let vm = try CommandContext.shared.requireViewModel()
            let id = try p.uuid("id")
            guard let entry = vm.laneEntries.first(where: { $0.item.id == id }) else {
                throw CommandError(code: .not_found, message: "unknown object: \(id.uuidString)")
            }
            let item = entry.item
            guard var payload = CommandAdapters.objectPayload(entry).objectValue else {
                throw CommandError(code: .internal_error, message: "object not serialisable")
            }
            payload["fade_in"] = .number(item.fadeIn)
            payload["fade_out"] = .number(item.fadeOut)
            payload["source_offset"] = .number(item.sourceOffset)
            payload["file_duration"] = .number(item.fileDuration)
            payload["speed"] = .number(item.speedRatio)
            payload["reversed"] = .bool(item.isReversed)
            payload["plugins"] = .array(item.plugins.map(CommandAdapters.pluginPayload))
            payload["instruments"] = .array(item.instruments.map(CommandAdapters.pluginPayload))
            payload["sends"] = .array(item.sends.map { send in
                .object(["aux": .string(send.auxID.uuidString),
                         "level_db": .number(Double(send.levelDb)),
                         "enabled": .bool(send.enabled)])
            })
            if item.isMIDI {
                payload["midi_notes"] = .int(item.midiNotes.count)
                payload["midi_length_beats"] = .number(item.midiLengthBeats)
            }
            return .object(payload)
        }

        register("object.rename",
                 summary: "Renames an object (its instances follow).",
                 params: [ParamSpec("id", "uuid", "Target object."),
                          ParamSpec("name", "string", "New name; empty = default name.")],
                 undo: .handled) { p in
            let vm = try CommandContext.shared.requireViewModel()
            let id = try p.uuid("id")
            guard vm.find(id: id) != nil else {
                throw CommandError(code: .not_found, message: "unknown object: \(id.uuidString)")
            }
            vm.renameObject(id: id, label: try p.string("name"))
            return .object(["id": .string(id.uuidString),
                            "name": .string(vm.find(id: id)?.displayName ?? "")])
        }

        register("object.set_fade",
                 summary: "Sets the fade in and/or fade out (seconds).",
                 params: [ParamSpec("id", "uuid", "Target object."),
                          ParamSpec("in", "number", required: false, "Fade in."),
                          ParamSpec("out", "number", required: false, "Fade out.")],
                 undo: .bus) { p in
            let vm = try CommandContext.shared.requireViewModel()
            let id = try p.uuid("id")
            guard vm.find(id: id) != nil else {
                throw CommandError(code: .not_found, message: "unknown object: \(id.uuidString)")
            }
            let fadeIn = try p.optionalDouble("in")
            let fadeOut = try p.optionalDouble("out")
            guard fadeIn != nil || fadeOut != nil else {
                throw CommandError(code: .bad_params, message: "'in' or 'out' required")
            }
            // In first, then out: `updateFadeOut` bounds the out by what is left after the in.
            // The other way round would make the result depend on the order of the parameters.
            if let fadeIn { vm.updateFadeIn(id: id, fadeIn: max(0, fadeIn)) }
            if let fadeOut { vm.updateFadeOut(id: id, fadeOut: max(0, fadeOut)) }
            guard let object = vm.find(id: id) else {
                throw CommandError(code: .not_found, message: "object lost")
            }
            return .object(["id": .string(id.uuidString),
                            "fade_in": .number(object.fadeIn),
                            "fade_out": .number(object.fadeOut)])
        }

        register("object.set_speed",
                 summary: "Varispeed of an audio clip (0.0625…16). Speeding up shortens the clip.",
                 params: [ParamSpec("id", "uuid", "Target clip."),
                          ParamSpec("ratio", "number", "Speed ratio (1 = normal).")],
                 undo: .bus) { p in
            let vm = try CommandContext.shared.requireViewModel()
            let id = try p.uuid("id")
            guard let object = vm.find(id: id), object.isClip else {
                throw CommandError(code: .not_found, message: "unknown audio clip: \(id.uuidString)")
            }
            vm.updateSpeed(id: id, ratio: try p.double("ratio"))
            guard let after = vm.find(id: id) else {
                throw CommandError(code: .not_found, message: "object lost")
            }
            return .object(["id": .string(id.uuidString),
                            "speed": .number(after.speedRatio),
                            // The length is trimmed by whatever follows on the lane: returning it saves
                            // the script from reading it back to learn what it actually got.
                            "duration": .number(after.duration)])
        }

        register("object.set_reversed",
                 summary: "Plays an audio clip backwards.",
                 params: [ParamSpec("id", "uuid", "Target clip."),
                          ParamSpec("reversed", "bool", required: false, "Wanted state; absent = toggle.")],
                 undo: .bus) { p in
            let vm = try CommandContext.shared.requireViewModel()
            let id = try p.uuid("id")
            guard let object = vm.find(id: id), object.isClip else {
                throw CommandError(code: .not_found, message: "unknown audio clip: \(id.uuidString)")
            }
            let reversed = try p.bool("reversed", or: !object.isReversed)
            vm.updateReversed(id: id, reversed: reversed)
            return .object(["id": .string(id.uuidString), "reversed": .bool(reversed)])
        }

        register("object.set_loop",
                 summary: "Loops the content of an audio clip, group or MIDI clip beyond its "
                        + "window. On first turning it on, the IN/OUT bounds are set to the "
                        + "current size (see object.set_loop_range to adjust them afterwards).",
                 params: [ParamSpec("id", "uuid", "Target object."),
                          ParamSpec("enabled", "bool", required: false, "Wanted state; absent = toggle.")],
                 undo: .bus) { p in
            let vm = try CommandContext.shared.requireViewModel()
            let id = try p.uuid("id")
            guard let object = vm.find(id: id), object.canLoop else {
                throw CommandError(code: .not_found, message: "unknown loopable object: \(id.uuidString)")
            }
            let enabled = try p.bool("enabled", or: !object.loopEnabled)
            vm.updateLoopEnabled(id: id, enabled: enabled)
            return .object(["id": .string(id.uuidString), "loop": .bool(enabled)])
        }

        register("object.set_loop_range",
                 summary: "Moves the IN/OUT bounds of the repeating pattern (the loop must "
                        + "already be on, via object.set_loop). Seconds LOCAL to the object (0 = "
                        + "its own start, the same reference as its length); for an audio clip "
                        + "only, they may go beyond [0, duration] (a sampler-style loop point, "
                        + "inside the source file).",
                 params: [ParamSpec("id", "uuid", "Target object (loop already on)."),
                          ParamSpec("start", "number", "IN bound, in seconds local to the object."),
                          ParamSpec("end", "number", "OUT bound, in seconds local to the object.")],
                 undo: .bus) { p in
            let vm = try CommandContext.shared.requireViewModel()
            let id = try p.uuid("id")
            guard let object = vm.find(id: id), object.canLoop else {
                throw CommandError(code: .not_found, message: "unknown loopable object: \(id.uuidString)")
            }
            guard object.loopEnabled else {
                throw CommandError(code: .invalid_state, message: "loop not turned on — object.set_loop first")
            }
            let start = try p.double("start")
            let end = try p.double("end")
            guard end > start else {
                throw CommandError(code: .bad_params, message: "'end' must come after 'start'")
            }
            vm.updateLoopRange(id: id, start: start, end: end)
            return .object(["id": .string(id.uuidString),
                            "loop_start": .number(start), "loop_end": .number(end)])
        }

        register("object.set_pan",
                 summary: "Pan (-1 left … +1 right).",
                 params: [ParamSpec("pan", "number", "Position -1…1."),
                          ParamSpec("ids", "array<uuid>", required: false,
                                    "Target objects; default = current selection.")],
                 undo: .bus) { p in
            let vm = try CommandContext.shared.requireViewModel()
            let pan = Float(try p.double("pan")).clamped(to: -1...1)
            let ids = try CommandAdapters.targetIDs(p, in: vm)
            for id in ids { vm.updatePan(id: id, pan: pan) }
            return .object(["count": .int(ids.count), "pan": .number(Double(pan))])
        }

        register("object.set_mute",
                 summary: "Mutes or unmutes objects.",
                 params: [ParamSpec("muted", "bool", required: false, "Wanted state; absent = toggle."),
                          ParamSpec("ids", "array<uuid>", required: false,
                                    "Target objects; default = current selection.")],
                 undo: .bus) { p in
            let vm = try CommandContext.shared.requireViewModel()
            let ids = try CommandAdapters.targetIDs(p, in: vm)
            let wanted = try p.optionalBool("muted")
            for id in ids {
                guard let object = vm.find(id: id) else { continue }
                // `toggleMute` is the only path that also mutes on the engine side: we flip
                // only what is not already in the requested state.
                if object.isMuted != (wanted ?? !object.isMuted) { vm.toggleMute(id: id) }
            }
            var states: [String: JSONValue] = [:]
            for id in ids { states[id.uuidString] = .bool(vm.find(id: id)?.isMuted ?? false) }
            return .object(["count": .int(ids.count), "muted": .object(states)])
        }

        register("object.set_duration",
                 summary: "Changes an object's length (right-hand edge).",
                 params: [ParamSpec("id", "uuid", "Target object."),
                          ParamSpec("duration", "number", "New length, in seconds.")],
                 undo: .bus) { p in
            let vm = try CommandContext.shared.requireViewModel()
            let id = try p.uuid("id")
            guard vm.find(id: id) != nil else {
                throw CommandError(code: .not_found, message: "unknown object: \(id.uuidString)")
            }
            let duration = try p.double("duration")
            guard duration > 0 else {
                throw CommandError(code: .bad_params, message: "length is zero or negative")
            }
            vm.updateDuration(id: id, duration: duration)
            return .object(["id": .string(id.uuidString),
                            "duration": .number(vm.find(id: id)?.duration ?? duration)])
        }

        register("object.trim",
                 summary: "Trims a clip: a new start AND a new length in one gesture "
                        + "(non-destructive, the source content does not move).",
                 params: [ParamSpec("id", "uuid", "Target object."),
                          ParamSpec("start", "number", "New start, in seconds."),
                          ParamSpec("duration", "number", "New length, in seconds.")],
                 undo: .bus) { p in
            let vm = try CommandContext.shared.requireViewModel()
            let id = try p.uuid("id")
            guard vm.find(id: id) != nil else {
                throw CommandError(code: .not_found, message: "unknown object: \(id.uuidString)")
            }
            let start = max(0, try p.double("start"))
            let duration = try p.double("duration")
            guard duration > 0 else {
                throw CommandError(code: .bad_params, message: "length is zero or negative")
            }
            vm.updateTrim(id: id, newStart: start, newDuration: duration)
            guard let after = vm.find(id: id) else {
                throw CommandError(code: .not_found, message: "object lost")
            }
            return .object(["id": .string(id.uuidString),
                            "start": .number(after.startTime),
                            "duration": .number(after.duration)])
        }

        register("object.set_source_offset",
                 summary: "Slips the content of a clip inside its window.",
                 params: [ParamSpec("id", "uuid", "Target clip."),
                          ParamSpec("offset", "number", "Offset into the source file, in seconds.")],
                 undo: .bus) { p in
            let vm = try CommandContext.shared.requireViewModel()
            let id = try p.uuid("id")
            guard let object = vm.find(id: id), object.isClip else {
                throw CommandError(code: .not_found, message: "unknown audio clip: \(id.uuidString)")
            }
            vm.setSourceOffset(id: id, to: try p.double("offset"))
            return .object(["id": .string(id.uuidString),
                            "source_offset": .number(vm.find(id: id)?.sourceOffset ?? 0)])
        }
    }
}
