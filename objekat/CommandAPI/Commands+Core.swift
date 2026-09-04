import Foundation
import AVFoundation

// MARK: - First family of commands

/// Every command is a hand-written ADAPTER: a stable verb on the protocol side, wired onto the
/// view-model's existing methods. Swift offers no reflection over methods, so no automatic
/// exposure is possible — and just as well: a command name is a public contract that has to
/// survive internal refactors, which a 1:1 mirror would not.
///
/// RULE: an adapter NEVER holds business logic. If it has to set the selection in order to call
/// a method that works "on the current selection", it sets it and calls — it does not
/// reimplement what the method does.
extension CommandRegistry {

    func registerCoreCommands() {

        // MARK: app

        register("app.info",
                 summary: "App version, current project, state of the audio engine.") { _ in
            let context = CommandContext.shared
            let vm = context.viewModel
            let engine = context.engine
            let bundle = Bundle.main
            var info: [String: JSONValue] = [
                "name": .string(bundle.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "objekat"),
                "version": .string(bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"),
                "build": .string(bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"),
                "api_socket": .stringOrNull(CommandServer.shared.socketPath),
                "has_document": .bool(vm != nil),
                "engine_ready": .bool(engine != nil),
                // false under `--no-recent`: that is how a harness checks, before opening its throwaway
                // projects, that the instance will not pollute "Recent Projects".
                "records_recent_projects": .bool(EditViewModel.recordsRecentProjects),
                // The interface language in force: the system's, or whatever `--language=` imposed.
                // The API's own answers stay in English whatever happens.
                "language": .string(Localization.current),
            ]
            if let vm {
                info["project_name"] = .string(vm.projectName)
                info["project_path"] = .stringOrNull(vm.projectURL?.path)
                info["dirty"] = .bool(vm.isDirty)
                info["object_count"] = .int(vm.laneEntries.count)
            }
            if let engine {
                info["playing"] = .bool(engine.isCurrentlyPlaying())
                info["sample_rate"] = .number(engine.currentSampleRate())
                info["buffer_size"] = .int(engine.currentBufferSize())
                info["output_device"] = .stringOrNull(engine.currentOutputDeviceName())
            }
            return .object(info)
        }

        // MARK: dialogues

        register("app.set_dialog_policy",
                 summary: """
                 Chooses what the app does when it has to ask a question or report \
                 something: 'ask' shows the modal (the default, the interface's own \
                 behaviour), 'assume_yes' answers yes/continue, 'assume_no' answers \
                 no/cancel. To be set at the head of a script: a modal waits for a click \
                 nobody will make, and freezes the app.
                 """,
                 params: [ParamSpec("policy", "string",
                                    "ask | assume_yes | assume_no")]) { p in
            let session = try CommandContext.shared.requireSession()
            let raw = try p.string("policy")
            guard let policy = DialogPolicy(rawValue: raw) else {
                throw CommandError(code: .bad_params,
                                   message: "unknown policy: '\(raw)' "
                                          + "(expected ask, assume_yes or assume_no)")
            }
            session.viewModel.dialogPolicy = policy
            return .object(["policy": .string(policy.rawValue)])
        }

        register("app.dialogs",
                 summary: """
                 Returns the dialogues the policy settled without showing them — otherwise \
                 removing the modals would just replace a freeze with a silence.
                 """,
                 params: [ParamSpec("clear", "bool", required: false,
                                    "Empty the journal after reading it (default false).")]) { p in
            let vm = try CommandContext.shared.requireViewModel()
            let entries = vm.dialogJournal.map { record in
                JSONValue.object(["title": .string(record.title),
                                  "info": .string(record.info),
                                  "answer": .string(record.answer),
                                  "at": .number(record.at.timeIntervalSince1970)])
            }
            if try p.bool("clear", or: false) { vm.clearDialogJournal() }
            return .object(["dialogs": .array(entries),
                            "count": .int(entries.count),
                            "policy": .string(vm.dialogPolicy.rawValue)])
        }

        // MARK: project

        register("project.new",
                 summary: "Empties the current project and starts a fresh one (without confirmation).") { _ in
            let vm = try CommandContext.shared.requireViewModel()
            // The variant WITHOUT a dialogue: `newProject()` would raise the "save first?" alert.
            // A caller who wants that guard asks `app.info` (the `dirty` field) first.
            vm.newProjectDiscardingChanges()
            return .object(["ok": .bool(true)])
        }

        register("project.open",
                 summary: "Opens a .objekat.json version file.",
                 params: [ParamSpec("path", "string", "Path to the project file.")]) { p in
            let vm = try CommandContext.shared.requireViewModel()
            let path = try p.string("path")
            guard FileManager.default.fileExists(atPath: path) else {
                throw CommandError(code: .not_found, message: "file not found: \(path)")
            }
            guard vm.loadProject(from: URL(fileURLWithPath: path)) else {
                throw CommandError(code: .invalid_state, message: "could not read the project: \(path)")
            }
            return .object(["path": .string(path), "name": .string(vm.projectName),
                            "object_count": .int(vm.laneEntries.count)])
        }

        register("project.save",
                 summary: "Saves into the active version. Fails if the project has never been saved.") { _ in
            let vm = try CommandContext.shared.requireViewModel()
            guard let url = vm.projectURL else {
                // `save()` would fall back to `saveAs()` and therefore to an NSSavePanel: unusable
                // from a script. We hand back with an instruction the caller can act on.
                throw CommandError(code: .invalid_state,
                                   message: "project never saved — use project.save_as {path}")
            }
            guard vm.writeSession(to: url) else {
                throw CommandError(code: .invalid_state, message: "could not write: \(url.path)")
            }
            return .object(["path": .string(url.path)])
        }

        register("project.save_as",
                 summary: "Saves the project to a given path (creating samples/ and waveforms/).",
                 params: [ParamSpec("path", "string", "Path of the .objekat.json file to write.")]) { p in
            let vm = try CommandContext.shared.requireViewModel()
            let path = try p.string("path")
            let url = URL(fileURLWithPath: path)
            guard vm.writeSession(to: url) else {
                throw CommandError(code: .invalid_state, message: "could not write: \(url.path)")
            }
            return .object(["path": .string(url.path), "name": .string(vm.projectName)])
        }

        register("project.get_state",
                 summary: "The current session, serialised (the same document as the project file).") { _ in
            let vm = try CommandContext.shared.requireViewModel()
            // Reuses the persistence layer's serialisation: a single definition of the document,
            // so there is no way for the API and the project file to drift apart.
            let data = try vm.encodedSession()
            return try JSONValue.decode(line: data)
        }

        register("project.schema",
                 summary: "The session format's notice: what each field of a .objekat.json "
                        + "file stands for.") { _ in
            // The same text as the one written at the head of the files (the `_readme` key): one
            // source, so the API cannot describe a format the files no longer follow.
            .object(["version": .int(SessionSchema.formatVersion),
                     "note": .array(SessionSchema.note.map { .string($0) })])
        }

        // MARK: transport

        register("transport.play",
                 summary: "Starts playback at the playhead (or at `seconds` if given).",
                 params: [ParamSpec("seconds", "number", required: false,
                                    "Starting position; default = current playhead.")]) { p in
            // Through the SESSION, and not through the engine directly: `play()` is exactly what
            // the ▶ button does — temporary solo cleared, pause forgotten, playhead reset. Driving the
            // engine over the session's head left the sound running and the screen frozen.
            let session = try CommandContext.shared.requireSession()
            if let seconds = try p.optionalDouble("seconds") {
                session.seek(to: seconds)
            }
            session.play()
            return .object(["playing": .bool(true),
                            "position": .number(session.playheadPosition)])
        }

        register("transport.stop", summary: "Stops playback.") { _ in
            let session = try CommandContext.shared.requireSession()
            session.stop()
            return .object(["playing": .bool(false),
                            "position": .number(session.playheadPosition)])
        }

        register("transport.seek",
                 summary: "Moves the cursor and the playhead.",
                 params: [ParamSpec("seconds", "number", "Position, in seconds.")]) { p in
            let session = try CommandContext.shared.requireSession()
            let seconds = try p.double("seconds")
            // The session resets cursor AND playhead in one go. The detour through `seekRequest`
            // has no reason to exist any more: it was there to ask the view to do that work, and
            // the work is no longer the view's.
            session.seek(to: seconds)
            return .object(["position": .number(session.playheadPosition)])
        }

        register("transport.state", summary: "Current playback state.") { _ in
            let session = try CommandContext.shared.requireSession()
            let vm = session.viewModel
            let engine = session.engine
            var state: [String: JSONValue] = [
                // `playing` comes from the session: it is the state the interface shows. The position,
                // on the other hand, is read from the engine — the only one that is up to date between
                // two playhead ticks.
                "playing": .bool(session.isPlaying),
                "position": .number(engine.currentPlaybackPosition()),
                // `playhead` is the DISPLAYED position — the one the session refreshes on every tick
                // and the timeline draws. It differs from `position` by at most one tick; it is the one
                // to read to know what the user sees.
                "playhead": .number(session.playheadPosition),
                "paused_at": session.pausedAt.map { JSONValue.number($0) } ?? .null,
                "cursor": .number(vm.cursorPosition),
                "tempo": .number(vm.tempo),
                "loop_enabled": .bool(vm.loopModeEnabled),
            ]
            if let region = vm.loopRegion {
                state["loop_region"] = .array([.number(region.lowerBound), .number(region.upperBound)])
            }
            return .object(state)
        }

        // MARK: selection

        register("selection.all",
                 summary: "Selects everything (contextual: the current group's children if there is one).",
                 undo: .none) { _ in
            let vm = try CommandContext.shared.requireViewModel()
            vm.selectAll()
            return CommandAdapters.selectionPayload(vm)
        }

        register("selection.clear", summary: "Empties the selection (objects and time selection).") { _ in
            let vm = try CommandContext.shared.requireViewModel()
            vm.clearSelection()
            return CommandAdapters.selectionPayload(vm)
        }

        register("selection.set",
                 summary: "Replaces the selection with the given identifiers.",
                 params: [ParamSpec("ids", "array<uuid>", "Object identifiers.")]) { p in
            let vm = try CommandContext.shared.requireViewModel()
            let ids = try p.uuids("ids")
            for id in ids where vm.find(id: id) == nil {
                throw CommandError(code: .not_found, message: "unknown object: \(id.uuidString)")
            }
            vm.selectIDs(Set(ids))
            return CommandAdapters.selectionPayload(vm)
        }

        register("selection.get", summary: "Current selection.") { _ in
            let vm = try CommandContext.shared.requireViewModel()
            return CommandAdapters.selectionPayload(vm)
        }

        // MARK: object

        register("object.list",
                 summary: "Every object, flattened: id, type, lane, position, length, name, parent.") { _ in
            let vm = try CommandContext.shared.requireViewModel()
            // `laneEntries` is the view-model's flattening cache: it already carries the display
            // lane, the absolute position, the depth and the parent.
            return .object(["objects": .array(vm.laneEntries.map(CommandAdapters.objectPayload))])
        }

        register("object.add",
                 summary: "Adds an audio clip from a file.",
                 params: [ParamSpec("path", "string", "Path to the audio file."),
                          ParamSpec("lane", "int", required: false, "Target display lane (default 0)."),
                          ParamSpec("start", "number", required: false, "Start, in seconds (default 0)."),
                          ParamSpec("duration", "number", required: false,
                                    "Length to lay down; default = the file's length.")],
                 undo: .bus) { p in
            let vm = try CommandContext.shared.requireViewModel()
            let path = try p.string("path")
            let url = URL(fileURLWithPath: path)
            guard FileManager.default.fileExists(atPath: path) else {
                throw CommandError(code: .not_found, message: "file not found: \(path)")
            }
            let fileDuration = await CommandAdapters.audioDuration(url: url)
            let duration = try p.double("duration", or: fileDuration)
            guard duration > 0 else {
                throw CommandError(code: .bad_params, message: "length is zero or negative")
            }
            let requestedStart = try p.double("start", or: 0)
            let requestedLane = try p.int("lane", or: 0)
            let start = max(0, requestedStart)
            let lane = max(0, requestedLane)
            let object = SoundObject(
                id: UUID(),
                startTime: start,
                duration: duration,
                lane: lane,
                kind: .clip(filePath: path, sourceOffset: 0, fileDuration: fileDuration,
                            speedRatio: 1.0, isReversed: false)
            )
            // The same laying-down path as a drop from the Finder: `placeClip` decides whether the
            // target lane falls INSIDE an expanded group, and `resolveOverlaps` settles overlaps.
            let placed = vm.placeClip(object, snapshot: vm.laneEntries)
            vm.resolveOverlaps(for: placed.id)
            return .object(["id": .string(placed.id.uuidString),
                            "lane": .int(placed.lane),
                            "start": .number(placed.startTime),
                            "duration": .number(placed.duration)])
        }

        register("object.remove",
                 summary: "Deletes the given objects (default: the current selection).",
                 params: [ParamSpec("ids", "array<uuid>", required: false, "Objects to delete.")],
                 undo: .bus) { p in
            let vm = try CommandContext.shared.requireViewModel()
            if p.raw["ids"] != nil {
                let ids = try CommandAdapters.existingIDs(try p.uuids("ids"), in: vm)
                vm.selectIDs(Set(ids))
            }
            let removed = vm.effectiveSelectedIDs.count
            guard removed > 0 else {
                throw CommandError(code: .invalid_state, message: "no object to delete")
            }
            vm.removeSelected()
            return .object(["removed": .int(removed)])
        }

        register("object.move",
                 summary: "Moves an object: a new lane and/or a new start.",
                 params: [ParamSpec("id", "uuid", "Object to move."),
                          ParamSpec("lane", "int", required: false, "New lane."),
                          ParamSpec("start", "number", required: false, "New start, in seconds."),
                          ParamSpec("snap", "bool", required: false,
                                    "Apply snapping (default false: exact positioning).")],
                 undo: .bus) { p in
            let vm = try CommandContext.shared.requireViewModel()
            let id = try p.uuid("id")
            guard let current = vm.find(id: id) else {
                throw CommandError(code: .not_found, message: "unknown object: \(id.uuidString)")
            }
            let lane = try p.optionalInt("lane")
            let start = try p.optionalDouble("start")
            guard lane != nil || start != nil else {
                throw CommandError(code: .bad_params, message: "'lane' or 'start' required")
            }
            let snap = try p.bool("snap", or: false)
            if let lane { vm.updateLane(id: id, lane: max(0, lane)) }
            // Always go back through `updateStartTime`, even without a change of start: it is what
            // calls `syncPosition`, the only place where the lane is pushed to the engine.
            CommandAdapters.withSnapping(snap, vm) {
                vm.updateStartTime(id: id, newStart: start ?? current.startTime)
            }
            vm.isDirty = true
            guard let moved = vm.find(id: id) else {
                throw CommandError(code: .not_found, message: "object lost during the move")
            }
            return .object(["id": .string(id.uuidString),
                            "lane": .int(moved.lane),
                            "start": .number(moved.startTime)])
        }

        register("object.set_gain",
                 summary: "Sets the gain (dB) of the given objects, absolute or relative.",
                 params: [ParamSpec("db", "number", "Value, in dB (-96…40)."),
                          ParamSpec("ids", "array<uuid>", required: false,
                                    "Target objects; default = current selection."),
                          ParamSpec("relative", "bool", required: false,
                                    "true = adds `db` to the current gain (default false).")],
                 undo: .bus) { p in
            let vm = try CommandContext.shared.requireViewModel()
            let db = Float(try p.double("db"))
            let relative = try p.bool("relative", or: false)
            let ids: [UUID]
            if p.raw["ids"] != nil {
                let requested = try p.uuids("ids")
                ids = try CommandAdapters.existingIDs(requested, in: vm)
                vm.selectIDs(Set(ids))
            } else {
                ids = Array(vm.selectedIDs)
            }
            guard !ids.isEmpty else {
                throw CommandError(code: .invalid_state, message: "no target object")
            }
            if relative {
                // `adjustVolumeDB` only exists in its "current selection" form: we set the selection
                // (done above) and call it, rather than copying out its logic for propagating to the
                // instances.
                vm.adjustVolumeDB(db)
            } else {
                for id in ids { vm.updateVolume(id: id, volume: db) }
                vm.isDirty = true
            }
            // Built in a loop (and not with `Dictionary(uniqueKeysWithValues:)`): a list of ids
            // holding a duplicate would crash the unique-keys initialiser.
            var gains: [String: JSONValue] = [:]
            for id in ids {
                if let object = vm.find(id: id) {
                    gains[id.uuidString] = .number(Double(object.volume))
                }
            }
            return .object(["count": .int(gains.count), "gains": .object(gains)])
        }

        register("object.duplicate",
                 summary: "Duplicates the given objects (default: the current selection).",
                 params: [ParamSpec("ids", "array<uuid>", required: false, "Objects to duplicate.")],
                 undo: .bus) { p in
            let vm = try CommandContext.shared.requireViewModel()
            if p.raw["ids"] != nil {
                vm.selectIDs(Set(try CommandAdapters.existingIDs(try p.uuids("ids"), in: vm)))
            }
            guard !vm.selectedIDs.isEmpty else {
                throw CommandError(code: .invalid_state, message: "no object to duplicate")
            }
            vm.duplicateSelected()
            // `duplicateSelected` leaves the copies selected: that is the useful answer.
            return .object(["ids": .array(vm.selectedIDs.map { .string($0.uuidString) }),
                            "count": .int(vm.selectedIDs.count)])
        }

        register("object.split_at",
                 summary: "Cuts the given objects at an instant.",
                 params: [ParamSpec("seconds", "number", "Instant to cut at."),
                          ParamSpec("ids", "array<uuid>", required: false,
                                    "Objects to cut; default = current selection.")],
                 // `cut` already pushes its undo (and removes it if it cut nothing).
                 undo: .handled) { p in
            let vm = try CommandContext.shared.requireViewModel()
            let t = try p.double("seconds")
            let ids: [UUID]
            if p.raw["ids"] != nil {
                ids = try CommandAdapters.existingIDs(try p.uuids("ids"), in: vm)
            } else {
                ids = Array(vm.effectiveSelectedIDs)
            }
            guard !ids.isEmpty else {
                throw CommandError(code: .invalid_state, message: "no object to cut")
            }
            vm.cut(ids: ids, atTime: t, keeping: nil)
            return .object(["ids": .array(vm.selectedIDs.map { .string($0.uuidString) }),
                            "count": .int(vm.selectedIDs.count)])
        }

        // MARK: edit

        register("edit.undo", summary: "Undoes the last gesture.", undo: .handled) { _ in
            let vm = try CommandContext.shared.requireViewModel()
            guard vm.canUndo else {
                throw CommandError(code: .invalid_state, message: "nothing to undo")
            }
            vm.undo()
            return .object(["can_undo": .bool(vm.canUndo), "can_redo": .bool(vm.canRedo)])
        }

        register("edit.redo", summary: "Redoes the undone gesture.", undo: .handled) { _ in
            let vm = try CommandContext.shared.requireViewModel()
            guard vm.canRedo else {
                throw CommandError(code: .invalid_state, message: "nothing to redo")
            }
            vm.redo()
            return .object(["can_undo": .bool(vm.canUndo), "can_redo": .bool(vm.canRedo)])
        }
    }
}

// MARK: - Helpers shared by the adapters

@MainActor
enum CommandAdapters {

    static func selectionPayload(_ vm: EditViewModel) -> JSONValue {
        var payload: [String: JSONValue] = [
            "ids": .array(vm.selectedIDs.map { .string($0.uuidString) }),
            // `effectiveSelectedIDs` leaves out objects one of whose ancestors is already selected:
            // that set is what multi-object operations really work on.
            "effective_ids": .array(vm.effectiveSelectedIDs.map { .string($0.uuidString) }),
            "count": .int(vm.selectedIDs.count),
        ]
        if let ts = vm.timeSelection {
            payload["time_selection"] = .object([
                "start": .number(ts.timeRange.lowerBound),
                "end": .number(ts.timeRange.upperBound),
                "lanes": .array(ts.lanes.sorted().map { .int($0) }),
            ])
        }
        return .object(payload)
    }

    static func objectPayload(_ entry: LaneEntry) -> JSONValue {
        let item = entry.item
        var payload: [String: JSONValue] = [
            "id": .string(item.id.uuidString),
            "kind": .string(kindName(item)),
            "name": .string(item.displayName),
            "lane": .int(item.lane),
            "display_lane": .int(entry.displayLane),
            "depth": .int(entry.depth),
            "start": .number(entry.absStart),
            "duration": .number(item.duration),
            "volume_db": .number(Double(item.volume)),
            "pan": .number(Double(item.pan)),
            "muted": .bool(item.isMuted),
            "parent": .stringOrNull(entry.parentID?.uuidString),
        ]
        if let defID = item.definitionID { payload["definition"] = .string(defID.uuidString) }
        if let stemID = item.stemID { payload["stem"] = .string(stemID.uuidString) }
        if case .clip(let filePath, _, _, _, _) = item.kind { payload["file"] = .string(filePath) }
        return .object(payload)
    }

    static func kindName(_ item: SoundObject) -> String {
        switch item.kind {
        case .clip:     return "clip"
        case .group:    return "group"
        case .aux:      return "aux"
        case .midiClip: return "midi"
        }
    }

    /// Checks that each identifier really names a live object, and returns the list unchanged.
    /// Without that filter, a made-up UUID would pass in silence and the command would report
    /// success while having done nothing.
    static func existingIDs(_ ids: [UUID], in vm: EditViewModel) throws -> [UUID] {
        for id in ids where vm.find(id: id) == nil {
            throw CommandError(code: .not_found, message: "unknown object: \(id.uuidString)")
        }
        return ids
    }

    /// Runs `body` with snapping forced to `enabled`, then puts the previous state back.
    /// `cmdKeyHeld` feeds into `effectiveSnapEnabled` (it inverts it): neutralise it too, otherwise
    /// a command issued while ⌘ is held down would give the opposite result.
    static func withSnapping(_ enabled: Bool, _ vm: EditViewModel, _ body: () -> Void) {
        let savedSnap = vm.snapEnabled
        let savedCmd = vm.cmdKeyHeld
        vm.snapEnabled = enabled
        vm.cmdKeyHeld = false
        defer { vm.snapEnabled = savedSnap; vm.cmdKeyHeld = savedCmd }
        body()
    }

    /// Length of an audio file. The same fallback to 5 s as a drop from the Finder when reading
    /// fails — the object is laid down and stays resizable, rather than rejecting the import.
    static func audioDuration(url: URL) async -> Double {
        let asset = AVURLAsset(url: url)
        do {
            let seconds = CMTimeGetSeconds(try await asset.load(.duration))
            return (seconds.isNaN || seconds <= 0) ? 5.0 : seconds
        } catch {
            return 5.0
        }
    }
}
