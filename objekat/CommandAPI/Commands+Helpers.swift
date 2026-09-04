import Foundation

// MARK: - Extra parameter accessors

extension CommandParams {
    /// A TRULY optional boolean: `nil` when the key is absent, which is not the same as a default.
    /// Used by the "wanted state; absent = toggle" commands, where a default would pin the value.
    func optionalBool(_ key: String) throws -> Bool? {
        raw[key] == nil ? nil : try bool(key)
    }
}

// MARK: - Shared helpers (the increment-5 families)

extension CommandAdapters {

    // MARK: Targets

    /// The objects a command with "optional ids" acts on: the given list if there is one (each
    /// identifier checked), the effective selection otherwise. `effectiveSelectedIDs` and not
    /// `selectedIDs`: a child whose group is already selected would be handled twice.
    static func targetIDs(_ p: CommandParams, in vm: EditViewModel) throws -> [UUID] {
        let ids: [UUID]
        if p.raw["ids"] != nil {
            ids = try existingIDs(try p.uuids("ids"), in: vm)
        } else {
            ids = Array(vm.effectiveSelectedIDs)
        }
        guard !ids.isEmpty else {
            throw CommandError(code: .invalid_state, message: "no target object")
        }
        return ids
    }

    static func existingStem(_ id: UUID, in vm: EditViewModel) throws -> UUID {
        guard vm.stems.contains(where: { $0.id == id }) else {
            throw CommandError(code: .not_found, message: "unknown stem: \(id.uuidString)")
        }
        return id
    }

    static func requireMIDI(_ id: UUID, in vm: EditViewModel) throws -> SoundObject {
        guard let object = vm.find(id: id), object.isMIDI else {
            throw CommandError(code: .not_found, message: "unknown MIDI clip: \(id.uuidString)")
        }
        return object
    }

    /// Anchors for a move gesture: the CURRENT positions of the objects. The reparenting methods
    /// are written for a drag (they take the previous state plus a `dt`); a command, on the other
    /// hand, drops without moving — hence these anchors taken now, and `dt = 0`.
    static func currentAnchors(_ ids: Set<UUID>,
                               in vm: EditViewModel) -> [UUID: (start: Double, lane: Int)] {
        var anchors: [UUID: (start: Double, lane: Int)] = [:]
        for id in ids {
            guard let object = vm.find(id: id) else { continue }
            anchors[id] = (start: object.startTime, lane: object.lane)
        }
        return anchors
    }

    // MARK: Sends

    /// Checks that both the sender and the aux exist, and that the second one really is an aux.
    /// SCOPE (`canRouteSend`) is deliberately not an error: laying down an out-of-scope send is
    /// legitimate — the model keeps it, silent, until a change of stem makes it routable. The
    /// commands return `routed` so that it is visible without being in the way.
    static func checkSendPair(_ objectID: UUID, _ auxID: UUID, in vm: EditViewModel) throws {
        guard vm.find(id: objectID) != nil else {
            throw CommandError(code: .not_found, message: "unknown object: \(objectID.uuidString)")
        }
        guard let aux = vm.find(id: auxID), aux.isAux else {
            throw CommandError(code: .not_found, message: "unknown aux: \(auxID.uuidString)")
        }
    }

    // MARK: Plugins

    /// A plugin can live inside a BRANCH of a parallel block: the search has to flatten the
    /// tree, the way `togglePluginEnabled` does. Looking only at the first level would report
    /// "not found" for a plugin that is perfectly there.
    @discardableResult
    static func requirePlugin(_ pluginID: UUID, on hostID: UUID,
                              in vm: EditViewModel) throws -> ObjectPlugin {
        guard let plugins = vm.chainPlugins(hostID) else {
            throw CommandError(code: .not_found, message: "unknown host: \(hostID.uuidString)")
        }
        guard let plugin = EditViewModel.flattenLeaves(plugins).first(where: { $0.id == pluginID }) else {
            throw CommandError(code: .not_found, message: "unknown plugin: \(pluginID.uuidString)")
        }
        return plugin
    }

    /// Names a catalogue entry by `identifier` (exact) or, failing that, by `name` (first
    /// match, case-insensitive), with `format` settling ties between namesakes.
    static func resolvePlugin(_ p: CommandParams, in vm: EditViewModel) throws -> AvailablePlugin {
        let format = try p.optionalString("format")
        if let identifier = try p.optionalString("identifier") {
            guard let found = vm.availablePlugins.first(where: {
                $0.identifier == identifier && (format == nil || $0.formatName == format)
            }) else {
                throw CommandError(code: .not_found,
                                   message: "plugin not in the catalogue: '\(identifier)' "
                                          + "(run plugin.scan?)")
            }
            return found
        }
        guard let name = try p.optionalString("name") else {
            throw CommandError(code: .bad_params, message: "'identifier' or 'name' required")
        }
        let needle = name.lowercased()
        guard let found = vm.availablePlugins.first(where: {
            $0.name.lowercased() == needle && (format == nil || $0.formatName == format)
        }) ?? vm.availablePlugins.first(where: {
            $0.name.lowercased().contains(needle) && (format == nil || $0.formatName == format)
        }) else {
            throw CommandError(code: .not_found,
                               message: "no plugin named '\(name)' in the catalogue "
                                      + "(\(vm.availablePlugins.count) entries)")
        }
        return found
    }

    static func pluginPayload(_ plugin: ObjectPlugin) -> JSONValue {
        var payload: [String: JSONValue] = [
            "id": .string(plugin.id.uuidString),
            "name": .string(plugin.name),
            "manufacturer": .string(plugin.manufacturer),
            "identifier": .string(plugin.identifier),
            "format": .string(plugin.formatName),
            "enabled": .bool(plugin.isEnabled),
            "linked": .bool(plugin.isLinked),
        ]
        // A parallel block is not a plugin: saying so keeps a script from trying to read its
        // parameters (it has no engine instance of its own).
        if plugin.isRack { payload["is_rack"] = .bool(true) }
        if let group = plugin.linkGroupID { payload["link_group"] = .string(group.uuidString) }
        return .object(payload)
    }

    // MARK: MIDI

    static func notePayload(_ note: MidiNote) -> JSONValue {
        .object(["id": .string(note.id.uuidString),
                 "pitch": .int(note.pitch),
                 "start_beat": .number(note.startBeat),
                 "length_beats": .number(note.lengthBeats),
                 "velocity": .int(note.velocity)])
    }

    // MARK: Sound object bakes

    /// Follows an asynchronous bake and closes the job when it is done.
    ///
    /// The view-model offers no public completion block: the render announces itself through
    /// `bakingIDs` (a lock taken before the engine call, released in its completion) and through
    /// `recomputingDefinitionIDs` for cascading re-bakes. So we watch those same flags — the ones
    /// `wait_idle` already reads — rather than instrumenting the view-model for the API alone.
    static func followBake(_ jobID: String, in vm: EditViewModel,
                           result: @escaping @MainActor () -> JSONValue) {
        Task { @MainActor in
            // Let the lock arm itself first: the render starts on a round trip through the engine,
            // and concluding "nothing in flight" on the first pass would end the job before it began.
            try? await Task.sleep(for: .milliseconds(50))
            while !vm.bakingIDs.isEmpty
                    || !vm.recomputingDefinitionIDs.isEmpty
                    || vm.isCascadingRebake {
                try? await Task.sleep(for: .milliseconds(50))
            }
            JobRegistry.shared.finish(jobID, result: result())
        }
    }
}

// MARK: - Export

extension CommandAdapters {

    /// The requested format, with a message that NAMES the accepted values: a script that writes
    /// "aiff" should learn what exists, not merely that its word is wrong.
    static func exportFormat(_ p: CommandParams) throws -> ExportSettings.FileFormat {
        let raw = try p.string("format", or: "mp3").lowercased()
        guard let format = ExportSettings.FileFormat(rawValue: raw) else {
            throw CommandError(code: .bad_params,
                               message: "unknown format: '\(raw)' (expected: "
                                      + ExportSettings.FileFormat.allCases
                                          .map(\.rawValue).joined(separator: ", ") + ")")
        }
        return format
    }

    static func exportPayload(_ job: ExportJob) -> JSONValue {
        var phase = "finished"
        var failure: String? = nil
        switch job.phase {
        case .preparing: phase = "preparing"
        case .rendering: phase = "rendering"
        case .encoding:  phase = "encoding"
        case .finished:  phase = "finished"
        case .failed(let message): phase = "failed"; failure = message
        }
        var payload: [String: JSONValue] = [
            "running": .bool(job.isRunning),
            "phase": .string(phase),
            "progress": .number(job.progress),
            "destination": .string(job.destination.path),
            "format": .string(job.settings.format.rawValue),
            "sample_rate": .number(job.settings.sampleRate),
        ]
        if let failure { payload["error"] = .string(failure) }
        return .object(payload)
    }

    /// Follows an export to its end. We read the phase rather than waiting for quiescence: a
    /// render on a copy leaves the app perfectly available, so `wait_idle` would call it idle while
    /// the file does not exist yet.
    static func followExport(_ jobID: String, in vm: EditViewModel, destination: URL) {
        Task { @MainActor in
            while vm.exportJob?.isRunning == true {
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard let job = vm.exportJob else {
                // The status bar clears itself after a while: if we arrive after it, the file on disk
                // is the only witness left.
                let exists = FileManager.default.fileExists(atPath: destination.path)
                JobRegistry.shared.finish(jobID, result: .object([
                    "phase": .string(exists ? "finished" : "unknown"),
                    "destination": .string(destination.path),
                ]))
                return
            }
            JobRegistry.shared.finish(jobID, result: exportPayload(job))
        }
    }
}

extension CommandAdapters {

    /// An export bound. A number is in SECONDS; a string follows one of the two notations used by
    /// the panel's fields, told apart by how many ':' it holds:
    ///   '90', '1:30', '1:30,5'  → clock time (ExportTimecode);
    ///   '3:1:0'                 → bar:beat:tick (MusicalTimecode).
    /// Refusing the string would force every musical script to redo the conversion on its own,
    /// with the project tempo — that is, to get it wrong one day.
    static func exportTime(_ p: CommandParams, _ key: String, in vm: EditViewModel) throws -> Double {
        // Read the raw JSON, NOT `optionalDouble`: that one throws on a string instead of
        // returning nil, and here a string is a perfectly valid form.
        guard let raw = p.raw[key] else {
            throw CommandError(code: .bad_params, message: "parameter '\(key)' required")
        }
        if let seconds = raw.doubleValue { return seconds }
        guard let text = raw.stringValue else {
            throw CommandError(code: .bad_params,
                               message: "parameter '\(key)': a number of seconds or a time "
                                      + "string was expected")
        }
        let musical = text.filter { $0 == ":" }.count == 2
        let parsed = musical
            ? MusicalTimecode.seconds(text, tempo: vm.tempo, beatsPerBar: vm.timeSigNumerator)
            : ExportTimecode.seconds(text)
        guard let value = parsed, value >= 0 else {
            throw CommandError(code: .bad_params,
                               message: "parameter '\(key)': unreadable time ('\(text)'). "
                                      + "Expected: seconds, 'm:ss,cc' or 'bar:beat:tick'")
        }
        return value
    }
}
