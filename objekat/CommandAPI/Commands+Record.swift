import Foundation

// MARK: - The sound card's inputs (`input.*`)

/// The card's inputs are CLOSED until `input.enable`: opening one is what makes macOS ask for the
/// microphone and what switches AirPods to the call profile, neither of which may happen at launch
/// for an app nobody has asked to record. They open on the SAME device as the output (one clock,
/// no drift) and stay open until the device changes or `input.disable`.
///
/// `input.list` describes what the engine offers — one mono input per channel, plus one stereo
/// input per declared neighbouring pair — and `input.levels` reads the peak meters. Nothing here
/// records: that is `rec.start` / `rec.stop` below.
extension CommandRegistry {

    func registerRecordCommands() {

        register("input.enable",
                 summary: """
                 Opens the inputs of the CURRENT output device (on demand — they are closed at \
                 launch). Waits for the device to settle, then answers like `input.list`. A no-op \
                 when they are already open. Under `--no-audio`, or with no device open: \
                 `invalid_state`. When the card's inputs are a SEPARATE device (AirPods: speaker and \
                 microphone are two devices with one name): `invalid_state` too, with \
                 `details.reason = "inputs_on_separate_device"`, before anything is touched. On a real \
                 card the first call makes macOS ask for the microphone.
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
                // The inputs are a separate device (AirPods): a state of the card, refused before
                // anything was touched — the output keeps playing as it was.
                if why == OBJInputsSeparateDeviceReason {
                    throw CommandError(code: .invalid_state, message: why,
                                       details: .object(["reason": .string("inputs_on_separate_device")]))
                }
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
                 N monos then N - 1 neighbouring pairs), enabled or not. `record_inputs` is what the \
                 Inputs tab lists — every declared pair, then every mono — with the project's \
                 `name` for each (`custom` when one was typed), whether it is `monitored` and its `monitor_gain_db`. All are \
                 empty while the inputs are closed (`open: false`), `--no-audio` included — never an \
                 error.
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
                 channel of each (0 = channels 1+2, 2 = channels 3+4). A paired channel KEEPS its mono \
                 (the monos always stay offered), and pairs may OVERLAP (0 and 1 = channels 1+2 and 2+3: both stereo inputs \
                 exist, channel 2 is read by each), a pair outside the card is ignored. `[]` goes \
                 back to all-mono. Answers like `input.list` (`pairs` = the ones in force). The pairs \
                 are kept IN THE PROJECT (`recordInputs`), outside the undo, and mark it modified. \
                 While the inputs are closed they are kept as given: a pair the card cannot hold is \
                 simply not offered. `invalid_state` while a recording is running (as for `input.pair` \
                 and `input.unpair`).
                 """,
                 params: [ParamSpec("pairs", "array", "First channel of each stereo pair, 0-based.")],
                 undo: .none) { p in
            let vm = try CommandContext.shared.requireViewModel()
            try Self.refuseWhileRecording(vm)
            let values = try p.array("pairs").map { v -> Int in
                guard let i = v.intValue else {
                    throw CommandError(code: .bad_params, message: "'pairs' must be a list of integers")
                }
                return i
            }
            vm.setInputPairs(values)
            return Self.inputListPayload(try CommandContext.shared.requireEngine())
        }

        register("input.pair",
                 summary: "Reads channels `first` and `first + 1` (0-based) as ONE stereo input, next to the " +
                          "pairs already declared. A no-op when it exists already. `invalid_state` while a recording " +
                          "is running. Answers like `input.list`.",
                 params: [ParamSpec("first", "int", "First channel of the pair, 0-based.")],
                 undo: .none) { p in
            let vm = try CommandContext.shared.requireViewModel()
            try Self.refuseWhileRecording(vm)
            let first = try p.int("first")
            guard first >= 0 else { throw CommandError(code: .bad_params, message: "'first' must be >= 0") }
            vm.pairInputs(first: first)
            return Self.inputListPayload(try CommandContext.shared.requireEngine())
        }

        register("input.unpair",
                 summary: "Takes the stereo pair that starts on channel `first` (0-based) apart: its two monos " +
                          "are offered again (unless another pair holds them). The names are kept. `invalid_state` " +
                          "while a recording is running.",
                 params: [ParamSpec("first", "int", "First channel of the pair, 0-based.")],
                 undo: .none) { p in
            let vm = try CommandContext.shared.requireViewModel()
            try Self.refuseWhileRecording(vm)
            vm.unpairInputs(first: try p.int("first"))
            return Self.inputListPayload(try CommandContext.shared.requireEngine())
        }

        register("input.set_name",
                 summary: """
                 Names an input (`first`, `count` 1 = mono or 2 = stereo pair, 0-based). An empty name \
                 goes back to the default ("In 3" / "In 1-2"). Kept in the project, outside the undo; \
                 the project is marked modified. Works whether or not the inputs are open.
                 """,
                 params: [ParamSpec("first", "int", "First channel, 0-based."),
                          ParamSpec("count", "int", required: false, "1 (mono, default) or 2 (stereo pair)."),
                          ParamSpec("name", "string", "The name; empty = the default.")],
                 undo: .none) { p in
            let vm = try CommandContext.shared.requireViewModel()
            let ref = try Self.inputRef(p)
            vm.renameInput(ref, to: try p.string("name", or: ""))
            return Self.inputListPayload(try CommandContext.shared.requireEngine())
        }

        register("input.select",
                 summary: """
                 Selects rows of the Inputs tab, as the hand does: `inputs` lists them [{first, count?}]                  (`count` 1 = mono, the default, or 2 = stereo pair), REPLACING the selection; `[]` empties                  it. Only inputs the tab lists right now can be selected (`record_inputs` of `input.list`):                  `invalid_state` while the card's inputs are closed, `bad_params` for an input that is                  not listed. The selection is the session's (outside the undo, not saved); it is what ⌘R                  renames when the Inputs list holds the keyboard. Answers like `input.selection`.
                 """,
                 params: [ParamSpec("inputs", "array<object>", "The rows to select, [{first, count?}]; [] = none.")],
                 undo: .none) { p in
            let vm = try CommandContext.shared.requireViewModel()
            var refs = Set<InputRef>()
            for (k, e) in try p.array("inputs").enumerated() {
                guard let first = e["first"]?.intValue, first >= 0,
                      [1, 2].contains(e["count"]?.intValue ?? 1) else {
                    throw CommandError(code: .bad_params,
                                       message: "inputs[\(k)]: needs 'first' >= 0 and 'count' 1 or 2")
                }
                refs.insert(InputRef(first: first, count: e["count"]?.intValue ?? 1))
            }
            if !refs.isEmpty {
                let listed = Set(vm.visibleRecordInputs)
                guard !listed.isEmpty else {
                    throw CommandError(code: .invalid_state, message: "the card's inputs are closed")
                }
                if let missing = refs.sorted().first(where: { !listed.contains($0) }) {
                    throw CommandError(code: .bad_params,
                                       message: "input \(missing.first)/\(missing.count) is not listed")
                }
            }
            vm.selectedRecordInputs = refs
            return Self.inputSelectionPayload(vm)
        }

        register("input.selection",
                 summary: "The Inputs tab's selected rows, in the tab's order: `inputs` [{first, count, stereo, name}] " +
                          "and `count`. Read-only; `input.select` sets it.",
                 undo: .none) { _ in
            Self.inputSelectionPayload(try CommandContext.shared.requireViewModel())
        }

        register("input.monitor",
                 summary: """
                 Hears an input (`on` true) or stops hearing it (`on` false) in the mix, through a hidden \
                 track that the project does not see: the app's solo does not silence it. `first`, `count` \
                 as in `input.set_name`. `invalid_state` when the inputs are closed or the input does \
                 not exist. Not saved, and not the project's: monitoring survives a project change or a tab \
                 switch, and stops when the inputs close, when the card changes or when the pair \
                 heard is taken apart. Answers like `input.list` (`monitored`). With `midi` (a MIDI input \
                 id) instead of `first`: hears the MIDI input through its instrument (`invalid_state` when it \
                 has none or is not listed); answers like `input.list.midi_inputs`.
                 """,
                 params: [ParamSpec("first", "int", required: false, "First channel, 0-based."),
                          ParamSpec("count", "int", required: false, "1 (mono, default) or 2 (stereo pair)."),
                          ParamSpec("midi", "string", required: false, "A MIDI input id, instead of `first`."),
                          ParamSpec("on", "bool", "Hear it or not.")],
                 undo: .none) { p in
            let vm = try CommandContext.shared.requireViewModel()
            if let midi = try p.optionalString("midi") {
                let device = try Self.requireMidiDevice(midi, in: vm)
                if let why = vm.setMidiInputMonitor(device, on: try p.bool("on")) {
                    throw CommandError(code: .invalid_state, message: why)
                }
                return Self.midiInputsPayload(vm)
            }
            let ref = try Self.inputRef(p)
            if let why = vm.setInputMonitor(ref, on: try p.bool("on")) {
                throw CommandError(code: .invalid_state, message: why)
            }
            return Self.inputListPayload(try CommandContext.shared.requireEngine())
        }

        register("input.set_monitor_gain",
                 summary: """
                 Sets the LISTENING level of an input in dB (`db`, held to -24...+24, the synoptic's gain \
                 range; `first`, `count` as in `input.set_name`): a true gain on the input's hidden \
                 track, heard whether or not the input is monitored (it only matters while it is). Only the \
                 listening moves: a recording is taken BEFORE it, the file is the same whatever it is. \
                 `invalid_state` when the inputs are closed or the input does not exist. Not saved, and \
                 forgotten when the inputs close or the input stops existing. Answers like `input.list` \
                 (`monitor_gain_db`).
                 """,
                 params: [ParamSpec("first", "int", "First channel, 0-based."),
                          ParamSpec("count", "int", required: false, "1 (mono, default) or 2 (stereo pair)."),
                          ParamSpec("db", "number", "The level in dB.")],
                 undo: .none) { p in
            let vm = try CommandContext.shared.requireViewModel()
            let ref = try Self.inputRef(p)
            if let why = vm.setInputMonitorGain(ref, db: try p.double("db")) {
                throw CommandError(code: .invalid_state, message: why)
            }
            return Self.inputListPayload(try CommandContext.shared.requireEngine())
        }

        registerRecordZoneCommands()
        registerRecordMidiCommands()
    }

    /// The pairing is fixed while a recording runs (changing it would stop the take and lose it).
    /// `invalid_state`, like `project.new` during a recording. @see EditViewModel.inputPairsLocked
    static func refuseWhileRecording(_ vm: EditViewModel) throws {
        guard !vm.inputPairsLocked else {
            throw CommandError(code: .invalid_state,
                               message: "a recording is running: the stereo pairs cannot change until it stops")
        }
    }

    // MARK: Recording zones (`rec.*`)

    /// A zone is a GROUP with a `recordInput`; these commands are the doors of the drop, the assignment and
    /// the arming (nothing records yet: that is the next increment). The state they read and write is the
    /// view model's (@see EditViewModel+RecordZones).
    func registerRecordZoneCommands() {

        register("rec.drop",
                 summary: """
                 Drops the input (`first`, `count`) on the timeline at display lane `lane` and instant \
                 `time` — exactly what releasing a row of the Inputs tab there does, the same planner \
                 (RecordZonePlanner). A MIDI input: `midi` (its id, see `input.list.midi_inputs`) in place of \
                 `first`. SEVERAL inputs: `inputs` [{first, count?} | {midi}] in place of `first` — one \
                 lane per input, downwards from `lane` in the order given, each with its own end, the \
                 refusal of one lane refusing the lot, ONE undo point; the answer is then `applied`, \
                 `refused` and `drops` (one `outcome` object per lane, with its `lane` and `group`). On empty room: a new empty group named after the input, from `time` \
                 for 40 % of the view (`visible_secs` is the view's width in seconds, default 100) or up \
                 to the next object of the lane, at least max(1 s, 24 px). Over the time selection: the \
                 selection's in/out. Over a group that can record: the input is assigned to it. Over a \
                 clip, or a group that cannot record (infinite, looping, consolidated), or with less room \
                 than the floor: refused. In an open group's sub-lane the zone is a sub-group. `time` is \
                 NOT snapped (the hand's gesture snaps; the machine's door is exact). `dry_run` plans \
                 without changing anything. One undo point for a change, none for a refusal. \
                 `outcome`: create | assign | refuse (`reason` says why).
                 """,
                 params: [ParamSpec("first", "int", required: false, "First channel of the input, 0-based."),
                          ParamSpec("count", "int", required: false, "1 (mono, default) or 2 (stereo pair)."),
                          ParamSpec("midi", "string", required: false, "A MIDI input id, instead of first / count."),
                          ParamSpec("inputs", "array<object>", required: false,
                                    "Several inputs [{first, count?} | {midi}], instead of first / count."),
                          ParamSpec("lane", "int", "Display lane under the cursor."),
                          ParamSpec("time", "number", "Instant under the cursor, seconds."),
                          ParamSpec("visible_secs", "number", required: false,
                                    "Width of the view in seconds (default 100)."),
                          ParamSpec("dry_run", "bool", required: false, "Plan only.")],
                 undo: .handled) { p in
            let vm = try CommandContext.shared.requireViewModel()
            let lane = try p.int("lane")
            guard lane >= 0 else { throw CommandError(code: .bad_params, message: "'lane' must be >= 0") }
            let time = try p.double("time")
            let visible = try p.double("visible_secs", or: 100)
            let pps = vm.pixelsPerSecond
            if p.raw["inputs"] != nil {
                var refs: [RecordSource] = []
                for (k, e) in try p.array("inputs").enumerated() {
                    if let id = e["midi"]?.stringValue {
                        refs.append(.midi(try Self.midiRef(id: id, vm: vm)))
                        continue
                    }
                    guard let first = e["first"]?.intValue, first >= 0,
                          [1, 2].contains(e["count"]?.intValue ?? 1) else {
                        throw CommandError(code: .bad_params,
                                           message: "inputs[\(k)]: needs 'midi', or 'first' >= 0 and 'count' 1 or 2")
                    }
                    refs.append(.audio(InputRef(first: first, count: e["count"]?.intValue ?? 1)))
                }
                guard !refs.isEmpty else { throw CommandError(code: .bad_params, message: "'inputs' is empty") }
                if try p.bool("dry_run", or: false) {
                    let plans = vm.planRecordDrops(count: refs.count, displayLane: lane, time: time,
                                                   visibleSpanSecs: visible, pixelsPerSecond: pps)
                    return Self.recordPlansJSON(plans, groups: [], lane: lane, applied: false)
                }
                let r = vm.dropRecordSources(refs, displayLane: lane, time: time, visibleSpanSecs: visible,
                                             pixelsPerSecond: pps)
                return Self.recordPlansJSON(r.plans, groups: r.groups, lane: lane,
                                            applied: !RecordZonePlanner.isRefused(r.plans))
            }
            let source: RecordSource = try p.optionalString("midi").map { .midi(try Self.midiRef(id: $0, vm: vm)) }
                ?? .audio(try Self.inputRef(p))
            if try p.bool("dry_run", or: false) {
                let plan = vm.planRecordDrop(displayLane: lane, time: time, visibleSpanSecs: visible,
                                             pixelsPerSecond: pps)
                return Self.recordPlanJSON(plan, group: nil, applied: false)
            }
            let r = vm.dropRecordSources([source], displayLane: lane, time: time, visibleSpanSecs: visible,
                                         pixelsPerSecond: pps)
            return Self.recordPlanJSON(r.plans[0], group: r.groups[0], applied: !r.plans[0].isRefusal)
        }

        register("rec.assign",
                 summary: """
                 Gives the group `group` the input (`first`, `count`) it will record, or takes it away when \
                 `first` is absent. Refused (`invalid_state`) for a group that cannot record (infinite, \
                 looping, consolidated) and for anything that is not a group, and while a recording is \
                 running (`invalid_state`: the zone's input is frozen at the press, like the stereo pairs). \
                 One undo point, none when nothing changes. Taking the input away disarms the zone. A MIDI \
                 input: `midi` (an id from `input.list.midi_inputs`) in place of `first`; a zone has ONE source, \
                 the new one replaces the other kind (and a MIDI zone's instrument goes with its MIDI input).
                 """,
                 params: [ParamSpec("group", "uuid", "The group."),
                          ParamSpec("midi", "string", required: false, "A MIDI input id, instead of first / count."),
                          ParamSpec("first", "int", required: false, "First channel; absent = clear."),
                          ParamSpec("count", "int", required: false, "1 (mono, default) or 2 (stereo pair).")],
                 undo: .handled) { p in
            let vm = try CommandContext.shared.requireViewModel()
            let id = try p.uuid("group")
            guard let item = vm.find(id: id) else {
                throw CommandError(code: .not_found, message: "unknown object: \(id.uuidString)")
            }
            let source: RecordSource? = try p.optionalString("midi").map { .midi(try Self.midiRef(id: $0, vm: vm)) }
                ?? (try p.optionalInt("first") == nil ? nil : .audio(Self.inputRef(p)))
            guard item.isGroup, EditViewModel.isRecordableZone(item) else {
                throw CommandError(code: .invalid_state,
                                   message: "only a finite, non-looping, non-consolidated group can record")
            }
            guard !vm.isRecording else {
                throw CommandError(code: .invalid_state,
                                   message: "a recording is running: the zone's input cannot change until it stops")
            }
            vm.assignRecordSource(source, toGroup: id)
            return Self.recordStatusJSON(vm)
        }

        register("rec.set_take_mode",
                 summary: """
                 Sets what a NEW take does to the takes already in a recording zone: `mode` "mute" (the default: \
                 the previous takes crossing the zone's window are muted when the recording starts) or "add" \
                 (nothing is muted, the older takes stay audible). `group` (one zone) or `groups` (several: the \
                 hand's rule when the zone shown is part of the selection — ONE undo point for all). A zone is a \
                 group that can record (finite, non-looping, non-consolidated), with or without an input; \
                 anything else is refused (`invalid_state`) and NOTHING is changed. Saved in the project \
                 (`recordTakeMode`, absent = "mute"). One undo point, none when no zone changes. A recording \
                 under way keeps the mode read at the press. In both modes the new take goes on the TOP lane of \
                 the zone and the older ones down by one.
                 """,
                 params: [ParamSpec("group", "uuid", required: false, "One zone."),
                          ParamSpec("groups", "array<uuid>", required: false, "Several zones."),
                          ParamSpec("mode", "string", "\"mute\" or \"add\".")],
                 undo: .handled) { p in
            let vm = try CommandContext.shared.requireViewModel()
            guard p.raw["group"] != nil || p.raw["groups"] != nil else {
                throw CommandError(code: .bad_params, message: "'group' or 'groups' required")
            }
            let ids = try p.raw["groups"] != nil ? p.uuids("groups") : [p.uuid("group")]
            guard let mode = RecordTakeMode(rawValue: try p.string("mode")) else {
                throw CommandError(code: .bad_params, message: "'mode' must be \"mute\" or \"add\"")
            }
            for id in ids {
                guard let item = vm.find(id: id) else {
                    throw CommandError(code: .not_found, message: "unknown object: \(id.uuidString)")
                }
                guard EditViewModel.isRecordableZone(item) else {
                    throw CommandError(code: .invalid_state,
                                       message: "only a finite, non-looping, non-consolidated group is a recording zone")
                }
            }
            guard vm.setRecordTakeMode(mode, groups: ids) else {
                throw CommandError(code: .invalid_state, message: "no recording zone given")
            }
            return Self.recordStatusJSON(vm)
        }

        register("rec.arm",
                 summary: """
                 Arms (`on` true) or disarms a recording zone. Arming is SESSION state: not saved, not in the \
                 undo, forgotten by a new project or an opening. Refused (`invalid_state`) when the group has \
                 no input, when its input is not on the card (or the inputs are closed — `input.enable`) \
                 and for a group that cannot record. Several zones can be armed, on the same input too. \
                 `groups` (instead of `group`) acts on several zones at once, as a click on the [ o ] of a \
                 selected zone does: the ones that cannot take the change (no input, input absent, cannot \
                 record, unknown id) are passed over without an error and listed in `ignored`; \
                 `invalid_state` only when none of them could.
                 """,
                 params: [ParamSpec("group", "uuid", required: false, "The group."),
                          ParamSpec("groups", "array<uuid>", required: false,
                                    "Several groups, all taken to the state `on`; the ones that cannot are ignored."),
                          ParamSpec("on", "bool", "Armed or not.")],
                 undo: .none) { p in
            let vm = try CommandContext.shared.requireViewModel()
            let on = try p.bool("on")
            if p.raw["groups"] != nil {
                let ids = try p.uuids("groups")
                let refused = vm.setArmed(ids: ids, on: on)
                if !ids.isEmpty, refused.count == Set(ids).count, on {
                    throw CommandError(code: .invalid_state,
                                       message: refused[ids[0]] ?? "no zone can be armed")
                }
                guard case .object(var status) = Self.recordStatusJSON(vm) else { return Self.recordStatusJSON(vm) }
                status["ignored"] = .array(ids.filter { refused[$0] != nil }.map { .string($0.uuidString) })
                return .object(status)
            }
            let id = try p.uuid("group")
            if let why = vm.setArmed(id, on: on) {
                throw CommandError(code: .invalid_state, message: why)
            }
            return Self.recordStatusJSON(vm)
        }

        register("rec.status",
                 summary: """
                 The recording zones. `zones`: every group with an input — `id`, `name`, `input` \
                 ({first, count}), `input_present` (the card has it), `armed`, `take_mode` ("mute" or \
                 "add", see `rec.set_take_mode`). `armed`: the ids of the \
                 zones armed AND still able to record. `can_record`: the transport's record button is live \
                 (something armed, and `project_saved`). `recording`: a recording is under way, \
                 `recording_start` the instant it was pressed at (null otherwise). `progress`: while recording, the \
                 red block of each zone as the timeline draws it — `group`, `lane` (the display lane the take \
                 will land on; the zone's own row if it is closed), `start`, `end` (press to playhead, inside the \
                 zone's window; a zone the head has not reached is absent). `last_takes`: what the last recording \
                 gave (see `rec.stop`).
                 """,
                 undo: .none) { _ in
            Self.recordStatusJSON(try CommandContext.shared.requireViewModel())
        }

        register("rec.start",
                 summary: """
                 Records the inputs of the ARMED zones, like the transport's record button: stopped, it plays \
                 and records from the cursor (or from `seconds`); playing, it punches in at the current \
                 position. One file per input in `<project>/samples/rec/`, shared by the zones armed on it. In \
                 the zone's default take mode ("mute", @see rec.set_take_mode) the previous takes the new one \
                 will replace (the unmuted children crossing a zone's window) are MUTED at once — except when \
                 the press is already past the window's end — in the undo point of the take; a recording that \
                 gives nothing gives them back. In the "add" mode nothing is muted. The new take goes on the TOP \
                 lane of the zone, the older ones down by one. \
                 `invalid_state` when nothing is armed, the project is not saved, the inputs are closed or a \
                 recording is already under way. A seek, `transport.stop` or `rec.stop` ends it.
                 """,
                 params: [ParamSpec("seconds", "number", required: false,
                                    "Where to start when stopped; default = the cursor."),
                          ParamSpec("debug_stall_ms", "int", required: false,
                                    "TEST: keeps the main thread busy that many ms once the take has started, "
                                    + "before giving the run loop back (a main thread late for the engine's "
                                    + "deferred bookkeeping). Default 0. Max 5000.")],
                 undo: .none) { p in
            let session = try CommandContext.shared.requireSession()
            let vm = session.viewModel
            let stall = try p.optionalInt("debug_stall_ms") ?? 0
            guard stall >= 0, stall <= 5000 else {
                throw CommandError(code: .bad_params, message: "debug_stall_ms \(stall) outside 0...5000")
            }
            guard vm.canRecord else {
                throw CommandError(code: .invalid_state,
                                   message: vm.armedRecordZones.isEmpty ? "no zone is armed"
                                                                        : "the project has not been saved")
            }
            if !session.isPlaying, let seconds = try p.optionalDouble("seconds") { session.seek(to: seconds) }
            vm.engine?.debugRecordStallMs = stall
            defer { vm.engine?.debugRecordStallMs = 0 }
            if let why = session.startRecording() {
                throw CommandError(code: .invalid_state, message: why)
            }
            return Self.recordStatusJSON(vm)
        }

        register("rec.stop",
                 summary: """
                 Ends the recording (and playback). Each armed zone receives its take; the answer is `rec.status`, whose `last_takes` lists them \
                 (`group`, `object`, `path`, `start`, `duration`, `source_offset`, `lane`, `outside_window`, \
                 `muted` = the previous takes muted). All of it is ONE undo point. `invalid_state` when not \
                 recording.
                 """,
                 undo: .handled) { _ in
            let session = try CommandContext.shared.requireSession()
            guard session.viewModel.isRecording else {
                throw CommandError(code: .invalid_state, message: "not recording")
            }
            session.stop()
            return Self.recordStatusJSON(session.viewModel)
        }
    }

    /// The answer of a drop of several inputs: one plan per lane (`recordPlanJSON`'s, plus the `lane`).
    @MainActor
    private static func recordPlansJSON(_ plans: [RecordZonePlanner.Plan], groups: [UUID?], lane: Int,
                                        applied: Bool) -> JSONValue {
        let drops = plans.enumerated().map { i, plan -> JSONValue in
            guard case .object(var o) = recordPlanJSON(plan, group: i < groups.count ? groups[i] : nil,
                                                       applied: applied) else { return .null }
            o["lane"] = .int(lane + i)
            return .object(o)
        }
        return .object(["applied": .bool(applied), "refused": .bool(RecordZonePlanner.isRefused(plans)),
                        "drops": .array(drops)])
    }

    @MainActor
    private static func recordPlanJSON(_ plan: RecordZonePlanner.Plan, group: UUID?, applied: Bool) -> JSONValue {
        var o: [String: JSONValue] = ["applied": .bool(applied)]
        switch plan {
        case .create(let start, let end, let parent):
            o["outcome"] = .string("create")
            o["start"] = .number(start)
            o["end"] = .number(end)
            o["parent"] = .stringOrNull(parent?.uuidString)
        case .assign(let id):
            o["outcome"] = .string("assign")
            o["target"] = .string(id.uuidString)
        case .refuse(let why):
            o["outcome"] = .string("refuse")
            o["reason"] = .string(why.rawValue)
        }
        o["group"] = .stringOrNull(group?.uuidString)
        return .object(o)
    }

    @MainActor
    private static func recordStatusJSON(_ vm: EditViewModel) -> JSONValue {
        var zones: [JSONValue] = []
        func walk(_ items: [SoundObject]) {
            for item in items {
                if let midi = item.recordMidiInput {
                    zones.append(.object([
                        "id": .string(item.id.uuidString),
                        "name": .string(vm.displayName(of: item)),
                        "source": .string("midi"),
                        "midi_input": .object(["id": .string(midi.id), "name": .string(vm.midiInputName(midi))]),
                        "input_present": .bool(vm.resolvedMidiInput(midi) != nil),
                        "recordable": .bool(EditViewModel.isRecordableZone(item)),
                        "armed": .bool(vm.armedRecordZones.contains(item.id)),
                        "input_prefix": .stringOrNull(vm.recordZoneInputPrefix(of: item)),
                        "take_mode": .string(vm.recordTakeMode(of: item.id).rawValue),
                        "instrument": item.instruments.first.map { .object(["id": .string($0.id.uuidString),
                                                                            "name": .string($0.name),
                                                                            "identifier": .string($0.identifier)]) } ?? .null,
                    ]))
                }
                if let ref = item.recordInput {
                    zones.append(.object([
                        "source": .string("audio"),
                        "id": .string(item.id.uuidString),
                        "name": .string(vm.displayName(of: item)),
                        "input": .object(["first": .int(ref.first), "count": .int(ref.count)]),
                        "input_present": .bool(vm.isRecordInputPresent(ref)),
                        "recordable": .bool(EditViewModel.isRecordableZone(item)),
                        "armed": .bool(vm.armedRecordZones.contains(item.id)),
                        "input_prefix": .stringOrNull(vm.recordZoneInputPrefix(of: item)),
                        "take_mode": .string(vm.recordTakeMode(of: item.id).rawValue),
                    ]))
                }
                if case .group(let children, _) = item.kind { walk(children) }
            }
        }
        walk(vm.items)
        return .object(["zones": .array(zones),
                        "armed": .array(vm.armedRecordZones.map { .string($0.uuidString) }),
                        "can_record": .bool(vm.canRecord),
                        "project_saved": .bool(vm.projectURL != nil),
                        "recording": .bool(vm.isRecording),
                        "recording_start": vm.recordingStartTime.map { .number($0) } ?? .null,
                        "progress": .array(vm.recordProgressBlocks(head: vm.engine?.currentPlaybackPosition() ?? 0).map { b in
                            .object(["group": .string(b.group.uuidString), "lane": .int(b.displayLane),
                                     "start": .number(b.start), "end": .number(b.end)])
                        }),
                        "last_takes": .array(vm.lastRecordingTakes.map { t in
                            .object(["group": .string(t.group.uuidString), "object": .string(t.object.uuidString),
                                     "path": .string(t.path), "start": .number(t.start),
                                     "duration": .number(t.duration), "source_offset": .number(t.sourceOffset),
                                     "lane": .int(t.lane), "outside_window": .bool(t.outsideWindow),
                                     "muted": .array(t.muted.map { .string($0.uuidString) }),
                                     "source": .string(t.path.isEmpty ? "midi" : "audio"),
                                     "notes": t.path.isEmpty ? Self.takeNotesJSON(vm, t.object) : .array([])])
                        })])
    }

    /// The notes of a MIDI take, as the model holds them (beats relative to the take; negative = handle).
    @MainActor
    private static func takeNotesJSON(_ vm: EditViewModel, _ id: UUID) -> JSONValue {
        guard let take = vm.find(id: id), case .midiClip(let notes, _) = take.kind else { return .array([]) }
        return .array(notes.map { n in
            .object(["pitch": .int(n.pitch), "start_beat": .number(n.startBeat),
                     "length_beats": .number(n.lengthBeats), "velocity": .int(n.velocity)])
        })
    }

    /// A MIDI input id given by a client, as a project reference (the id must be one the engine lists).
    @MainActor
    static func midiRef(id: String, vm: EditViewModel) throws -> MidiInputRef {
        guard let d = vm.midiInputs.first(where: { $0.id == id }) else {
            throw CommandError(code: .not_found, message: "unknown MIDI input: \(id) (see input.list.midi_inputs)")
        }
        return d.ref
    }

    static func inputRef(_ p: CommandParams) throws -> InputRef {
        let first = try p.int("first")
        let count = try p.int("count", or: 1)
        guard first >= 0, count == 1 || count == 2 else {
            throw CommandError(code: .bad_params, message: "'first' must be >= 0 and 'count' 1 or 2")
        }
        return InputRef(first: first, count: count)
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

    /// The Inputs tab's selection, in the tab's order (every pair, then every mono).
    @MainActor
    static func inputSelectionPayload(_ vm: EditViewModel) -> JSONValue {
        let chosen = vm.visibleRecordInputs.filter { vm.selectedRecordInputs.contains($0) }
        return .object([
            "count": .int(chosen.count),
            "inputs": .array(chosen.map { ref in
                .object(["first": .int(ref.first), "count": .int(ref.count), "stereo": .bool(ref.isStereo),
                         "name": .string(vm.inputName(ref))])
            }),
        ])
    }

    /// `input.list`'s own answer, reused by every other `input.*` command.
    @MainActor
    static func inputListPayload(_ engine: OBJEngineCore) -> JSONValue {
        let open = engine.audioInputsOpen()
        let all = inputDevices(engine)
        let names = engine.audioInputChannelNames()
        return .object([
            "open": .bool(open),
            "inputs_separate": .bool(!open && AudioDeviceStatus.shared.snapshot.inputsSeparate),
            "device": .stringOrNull(open ? AudioDeviceStatus.shared.snapshot.name : nil),
            "channels": .int(names.count),
            "channel_names": .array(names.map { .string($0) }),
            "pairs": .array(engine.audioInputStereoPairs().map { .int($0.intValue) }),
            "inputs": .array(all.filter { $0.enabled }.enumerated().map { inputJSON($1, index: $0) }),
            "engine_devices": .array(all.map { inputJSON($0) }),
            "record_inputs": recordInputsJSON(),
        ])
    }

    /// What the Inputs tab lists — every pair, then every mono — with the NAME the project
    /// gives each (`custom` = a name was typed, else the default) and whether it is being heard.
    /// Empty while the inputs are closed (the card's channels are unknown).
    @MainActor
    private static func recordInputsJSON() -> JSONValue {
        guard let vm = CommandContext.shared.viewModel else { return .array([]) }
        let heard = Set(vm.monitoredInputs)
        return .array(vm.visibleRecordInputs.map { ref in
            .object(["first": .int(ref.first), "count": .int(ref.count), "stereo": .bool(ref.isStereo),
                     "name": .string(vm.inputName(ref)),
                     "custom": .bool(vm.recordInputs.customName(for: ref) != nil),
                     "monitored": .bool(heard.contains(ref)),
                     "monitor_gain_db": .number(vm.inputMonitorGain(ref)),
                     // The FX chain on the input (E9): its host id (null until one was made) and how many plugins it holds.
                     "host_id": .stringOrNull(vm.audioInputHostID(ref)?.uuidString),
                     "fx_count": .int(EditViewModel.flattenLeaves(vm.inputChains.audio[ref.key]?.plugins ?? []).count)])
        })
    }
}
