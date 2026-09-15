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
            payload["fade_in_curve"] = .string(item.fadeInCurve.shape.rawValue)
            payload["fade_out_curve"] = .string(item.fadeOutCurve.shape.rawValue)
            payload["fade_in_bend"] = .number(item.fadeInCurve.amount)
            payload["fade_out_bend"] = .number(item.fadeOutCurve.amount)
            payload["infinite"] = .bool(item.isInfiniteBus)
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
                            "fade_out": .number(object.fadeOut),
                            "fade_in_curve": .string(object.fadeInCurve.shape.rawValue),
                            "fade_out_curve": .string(object.fadeOutCurve.shape.rawValue),
                            "fade_in_bend": .number(object.fadeInCurve.amount),
                            "fade_out_bend": .number(object.fadeOutCurve.amount)])
        }

        register("object.set_fade_curve",
                 summary: "Sets the SHAPE of the fades: a FAMILY — linear | convex | concave | "
                        + "sCurve | sCurveInverse — and a BEND, 0…1, saying how far the curve "
                        + "leaves the straight line (0 = straight whatever the family, 1 = the "
                        + "full shape). Independent of the fades' length — a shape set on an "
                        + "object with no fade shows up the moment one is pulled.",
                 params: [ParamSpec("id", "uuid", "Target object."),
                          ParamSpec("in", "string", required: false, "Fade-in family."),
                          ParamSpec("out", "string", required: false, "Fade-out family."),
                          ParamSpec("in_bend", "number", required: false,
                                    "Fade-in bend 0…1 (default 1 with a family, else unchanged)."),
                          ParamSpec("out_bend", "number", required: false,
                                    "Fade-out bend 0…1 (default 1 with a family, else unchanged).")],
                 undo: .bus) { p in
            let vm = try CommandContext.shared.requireViewModel()
            let id = try p.uuid("id")
            guard let current = vm.find(id: id) else {
                throw CommandError(code: .not_found, message: "unknown object: \(id.uuidString)")
            }
            // A family with no bend means the FULL shape — the shorthand the five fixed shapes
            // used to be. A bend with no family bends the family already there, which is what
            // lets a script sweep one curve open without naming it again at every step.
            func curve(_ key: String, _ existing: FadeCurve) throws -> FadeCurve? {
                let bendKey = key + "_bend"
                let hasShape = p.raw[key] != nil, hasBend = p.raw[bendKey] != nil
                guard hasShape || hasBend else { return nil }
                var shape = existing.shape
                if hasShape {
                    let name = try p.string(key)
                    guard let s = FadeShape(rawValue: name) else {
                        throw CommandError(code: .bad_params,
                                           message: "'\(key)': expected one of "
                                                  + FadeShape.allCases.map(\.rawValue).joined(separator: ", "))
                    }
                    shape = s
                }
                let bend = try hasBend ? p.double(bendKey) : (hasShape ? 1 : existing.amount)
                guard bend >= 0, bend <= 1 else {
                    throw CommandError(code: .bad_params, message: "'\(bendKey)': expected 0…1")
                }
                return FadeCurve(shape: shape, amount: bend)
            }
            let cIn = try curve("in", current.fadeInCurve)
            let cOut = try curve("out", current.fadeOutCurve)
            guard cIn != nil || cOut != nil else {
                throw CommandError(code: .bad_params, message: "'in' or 'out' required")
            }
            vm.updateFadeCurve(id: id, fadeIn: cIn, fadeOut: cOut)
            guard let object = vm.find(id: id) else {
                throw CommandError(code: .not_found, message: "object lost")
            }
            return .object(["id": .string(id.uuidString),
                            "fade_in_curve": .string(object.fadeInCurve.shape.rawValue),
                            "fade_out_curve": .string(object.fadeOutCurve.shape.rawValue),
                            "fade_in_bend": .number(object.fadeInCurve.amount),
                            "fade_out_bend": .number(object.fadeOutCurve.amount)])
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
                 params: [ParamSpec("pan", "number", "Position -1…1, written as given (no detent)."),
                          ParamSpec("ids", "array<uuid>", required: false,
                                    "Target objects; default = current selection.")],
                 undo: .bus) { p in
            let vm = try CommandContext.shared.requireViewModel()
            let pan = Float(try p.double("pan")).clamped(to: -1...1)
            let ids = try CommandAdapters.targetIDs(p, in: vm)
            for id in ids { vm.updatePan(id: id, pan: pan) }
            return .object(["count": .int(ids.count), "pan": .number(Double(pan))])
        }

        register("object.adjust_pan",
                 summary: "Moves the pan BY a delta rather than setting it — the path the "
                        + "continuous gestures take (the Pan tool, the inspector's box, the ±0.1 "
                        + "arrows, the wheel). Every object's result clicks onto the nearest tenth, "
                        + "however many are held: the detent is unconditional and answers neither "
                        + "to the snap nor to ⌘. Absolute setting, and exact: object.set_pan.",
                 params: [ParamSpec("by", "number", "Travel, added to the current pan."),
                          ParamSpec("ids", "array<uuid>", required: false,
                                    "Target objects; default = current selection.")],
                 undo: .bus) { p in
            let vm = try CommandContext.shared.requireViewModel()
            let delta = Float(try p.double("by"))
            let ids = try CommandAdapters.targetIDs(p, in: vm)
            let anchors = Dictionary(uniqueKeysWithValues:
                ids.compactMap { vm.find(id: $0) }.map { ($0.id, $0.pan) })
            vm.applyPanDelta(delta, from: anchors)
            let pans = ids.compactMap { vm.find(id: $0) }.map { JSONValue.number(Double($0.pan)) }
            return .object(["count": .int(ids.count), "pans": .array(pans)])
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

        register("object.set_infinite",
                 summary: "Turns the INFINITE on or off for an aux or a group: a bus with no start "
                        + "and no end, running the length of the project. Top level only. Turning "
                        + "it on gives the bus a row of ITS OWN, inserted just below — a "
                        + "full-width band would cover whatever shared its row — so the lane in "
                        + "the answer is not always the one it set off from.",
                 params: [ParamSpec("id", "uuid", "Target object (an aux or a group)."),
                          ParamSpec("on", "bool", required: false, "Wanted state; absent = toggle.")],
                 // `setObjectInfinite` pushes its own undo, and pushes none when nothing changes.
                 undo: .handled) { p in
            let vm = try CommandContext.shared.requireViewModel()
            let id = try p.uuid("id")
            guard let object = vm.find(id: id) else {
                throw CommandError(code: .not_found, message: "unknown object: \(id.uuidString)")
            }
            guard object.canBeInfinite else {
                throw CommandError(code: .invalid_state,
                                   message: "only an aux or a group can be infinite")
            }
            // Asked HERE rather than left to the model: `setObjectInfinite` answers a child of a
            // group with an alert, and an alert is a window — which is precisely what a headless
            // instance must never open (@see the windowless mode).
            guard vm.items.contains(where: { $0.id == id }) else {
                throw CommandError(code: .invalid_state,
                                   message: "an infinite bus is top level only")
            }
            let wanted = try p.optionalBool("on") ?? !object.isInfinite
            vm.setObjectInfinite(id: id, on: wanted)
            guard let after = vm.find(id: id) else {
                throw CommandError(code: .not_found, message: "object lost")
            }
            return .object(["id": .string(id.uuidString),
                            "infinite": .bool(after.isInfiniteBus),
                            "lane": .int(after.lane)])
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
            // A crop moves an edge, and a crossfade is made of edges: the zone follows, exactly as
            // it does under the hand (@see withCrossfadeRefit).
            vm.withCrossfadeRefit(around: [id]) {
                vm.updateDuration(id: id, duration: duration)
            }
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
            vm.withCrossfadeRefit(around: [id]) {
                vm.updateTrim(id: id, newStart: start, newDuration: duration)
            }
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
