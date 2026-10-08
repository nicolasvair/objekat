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
        try rejectARASource(pluginID, on: hostID, in: vm)
        guard let plugin = EditViewModel.flattenLeaves(plugins).first(where: { $0.id == pluginID }) else {
            throw CommandError(code: .not_found, message: "unknown plugin: \(pluginID.uuidString)")
        }
        return plugin
    }

    /// The ARA source of an object (Melodyne) is NOT a card of its chain: it is the clip's source, with
    /// one verb of its own — `plugin.remove`. Every other command that names a plugin (toggle, move,
    /// copy, link, drop, parameters, sidechain…) refuses its id with `invalid_state`, rather than
    /// answering "unknown plugin" for something `plugin.list` just showed.
    static func rejectARASource(_ pluginID: UUID, on hostID: UUID, in vm: EditViewModel) throws {
        guard vm.find(id: hostID)?.araSource?.plugin.id == pluginID else { return }
        throw CommandError(code: .invalid_state,
                           message: "plugin \(pluginID.uuidString) is the ARA source of the object: "
                                  + "only plugin.remove and the object.ara.* commands apply to it",
                           details: .object(["slot": .string("ara_source")]))
    }

    /// `slot: "ara_source"` entry of `plugin.list` / answer of `plugin.add`.
    static func araSourcePayload(_ source: ARASource, objectID: UUID, in vm: EditViewModel) -> JSONValue {
        var payload = pluginPayload(source.plugin)
        if case .object(var o) = payload {
            o["slot"] = .string("ara_source")
            o["ara_valid"] = .bool(vm.araSynced.contains(objectID) && vm.araSyncFailures[objectID] == nil)
            payload = .object(o)
        }
        return payload
    }

    /// The cards a transfer command aims at: the list `plugins` when it is given, and the single
    /// `plugin` otherwise — one card or a whole selection taking exactly the same three gestures
    /// (@see EditViewModel.transferPlugins). Every one of them is checked against the source host,
    /// so a command naming a card of some OTHER chain fails instead of silently doing half a job.
    static func transferTargets(_ p: CommandParams, on hostID: UUID,
                                in vm: EditViewModel) throws -> [UUID] {
        let ids = p.raw["plugins"] != nil ? try p.uuids("plugins") : [try p.uuid("plugin")]
        guard !ids.isEmpty else {
            throw CommandError(code: .bad_params, message: "'plugins' is empty")
        }
        for id in ids { try requirePlugin(id, on: hostID, in: vm) }
        return ids
    }

    /// The ENTRIES a drop command aims at: like `transferTargets`, except that an id may also be an FX
    /// link's BLOCK of the source chain (what a hand takes by the bin's header) — a block travels alone.
    static func dropTargets(_ p: CommandParams, on hostID: UUID,
                            in vm: EditViewModel) throws -> [UUID] {
        let ids = p.raw["plugins"] != nil ? try p.uuids("plugins") : [try p.uuid("plugin")]
        guard !ids.isEmpty else {
            throw CommandError(code: .bad_params, message: "'plugins' is empty")
        }
        guard let chain = vm.chainPlugins(hostID) else {
            throw CommandError(code: .not_found, message: "unknown host: \(hostID.uuidString)")
        }
        for id in ids where EditViewModel.findBlock(id, in: chain) == nil {
            try requirePlugin(id, on: hostID, in: vm)
        }
        return ids
    }

    /// The place of a drop command: `series` ("root", {"block": id} or {"voice": id, "index": n}) and `at`.
    /// No `series` = the host as a whole. An id of an FX link's block that is not a series is read as
    /// its series, so that aiming at the bin by its header id works.
    static func dropSite(_ p: CommandParams, chain: [ObjectPlugin]) throws -> PluginDropSite {
        guard let raw = p.raw["series"] else {
            if p.raw["at"] != nil { throw CommandError(code: .bad_params, message: "'at' needs a 'series'") }
            return .hostEnd
        }
        func rackBlock(_ id: UUID, in plugins: [ObjectPlugin]) -> ObjectPlugin? {
            for q in plugins {
                if q.id == id, q.rack != nil { return q }
                for s in q.childSeries { if let f = rackBlock(id, in: s) { return f } }
            }
            return nil
        }
        let location: SeriesLocation
        let count: Int
        if let name = raw.stringValue {
            guard name == "root" else {
                throw CommandError(code: .bad_params, message: "series: \"root\", {\"block\": id} or {\"voice\": id, \"index\": n}")
            }
            location = .root; count = chain.count
        } else if case .object(let o) = raw, let b = o["block"]?.stringValue {
            guard let id = UUID(uuidString: b) else {
                throw CommandError(code: .bad_params, message: "series.block: invalid UUID")
            }
            guard let block = EditViewModel.findBlock(id, in: chain), let fb = block.fxBlock else {
                throw CommandError(code: .not_found, message: "unknown block: \(id.uuidString)")
            }
            location = .block(blockID: id); count = fb.plugins.count
        } else if case .object(let o) = raw, let v = o["voice"]?.stringValue {
            guard let id = UUID(uuidString: v) else {
                throw CommandError(code: .bad_params, message: "series.voice: invalid UUID")
            }
            guard let index = o["index"]?.intValue else {
                throw CommandError(code: .bad_params, message: "series.index (the branch) required")
            }
            guard let block = rackBlock(id, in: chain), let rack = block.rack,
                  rack.voices.indices.contains(index) else {
                throw CommandError(code: .not_found, message: "unknown branch \(index) of block \(id.uuidString)")
            }
            location = .voice(blockID: id, voiceIndex: index); count = rack.voices[index].count
        } else {
            throw CommandError(code: .bad_params, message: "series: \"root\", {\"block\": id} or {\"voice\": id, \"index\": n}")
        }
        let at = try p.int("at", or: count)
        guard (0...count).contains(at) else {
            throw CommandError(code: .bad_params, message: "'at' out of range 0…\(count)")
        }
        return .series(location, index: at)
    }

    /// The modifiers a drag command's `mode` stands for: move = none, copy = ⌥, link = ⌘.
    static func dropModifiers(_ mode: String) throws -> NSEvent.ModifierFlags {
        switch mode {
        case "move": return []
        case "copy": return .option
        case "link": return .command
        default: throw CommandError(code: .bad_params, message: "mode must be move, copy or link")
        }
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

    /// `bridgeStatus`: when given (`plugin.list`), a leaf plugin also carries `sidechain` — `null`
    /// (no key) or `{source, active, reason}`, `reason` being the refusal's raw value (null = active).
    /// @see EditViewModel.bridgeStatusNow
    static func pluginPayload(_ plugin: ObjectPlugin,
                              bridgeStatus: [UUID: BridgeScope.Refusal]? = nil) -> JSONValue {
        var payload: [String: JSONValue] = [
            "id": .string(plugin.id.uuidString),
            "name": .string(plugin.name),
            "manufacturer": .string(plugin.manufacturer),
            "identifier": .string(plugin.identifier),
            "format": .string(plugin.formatName),
            "enabled": .bool(plugin.isEnabled),
            "linked": .bool(plugin.isLinked),
            "color_index": .int(plugin.colorIndex),
        ]
        // A parallel block is not a plugin: saying so keeps a script from trying to read its
        // parameters (it has no engine instance of its own).
        if plugin.isRack { payload["is_rack"] = .bool(true) }
        // An FX link's block is not a plugin either: its instances are listed under `plugins`, and
        // `plugin.set_param` & co. address THEM (they are ordinary instances, mirrors of the bin).
        if let block = plugin.fxBlock {
            payload["is_fx_block"] = .bool(true)
            payload["link"] = .string(block.linkID.uuidString)
            payload["detached"] = .bool(block.isDetached)
            payload["plugins"] = .array(block.plugins.map { pluginPayload($0, bridgeStatus: bridgeStatus) })
        }
        if let bridgeStatus, !plugin.isRack, plugin.fxBlock == nil {
            if let key = plugin.sidechain {
                let why = bridgeStatus[plugin.id]
                payload["sidechain"] = .object(["source": .string(key.sourceID.uuidString),
                                                "active": .bool(why == nil),
                                                "reason": .stringOrNull(why?.rawValue)])
            } else {
                payload["sidechain"] = .null
            }
        }
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

    // MARK: Consolidated object bakes

    /// Follows an asynchronous bake and closes the job when it is done.
    ///
    /// The view-model offers no public completion block: the render announces itself through
    /// `bakingIDs` (a lock taken before the engine call, released in its completion) and through
    /// `recomputingConsolidateIDs` for cascading re-bakes. So we watch those same flags — the ones
    /// `wait_idle` already reads — rather than instrumenting the view-model for the API alone.
    static func followBake(_ jobID: String, in vm: EditViewModel,
                           result: @escaping @MainActor () -> JSONValue) {
        Task { @MainActor in
            // Let the lock arm itself first: the render starts on a round trip through the engine,
            // and concluding "nothing in flight" on the first pass would end the job before it began.
            try? await Task.sleep(for: .milliseconds(50))
            while !vm.bakingIDs.isEmpty
                    || !vm.recomputingConsolidateIDs.isEmpty
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
            // The project the render was LAUNCHED from, frozen: a render on a copy outlives a tab switch.
            "project_name": .string(job.projectName),
            "background": .bool(job.settings.renderInBackground),
        ]
        if let failure { payload["error"] = .string(failure) }
        return .object(payload)
    }

    /// A regions export, for `export.status` and the `job.wait` result: which region of how many is
    /// under way, the progress over the whole batch, and what became of each region.
    static func exportBatchPayload(_ batch: ExportBatch, currentProgress: Double) -> JSONValue {
        let results: [JSONValue] = zip(batch.targets, batch.outcomes).map { t, o -> JSONValue in
            var status = "pending"
            var error: String? = nil
            switch o {
            case .pending:          status = "pending"
            case .running:          status = "running"
            case .done:             status = "done"
            case .failed(let m):    status = "failed"; error = m
            case .cancelled:        status = "cancelled"
            }
            let url = batch.url(for: t)
            var r: [String: JSONValue] = [
                "id": .string(t.id.uuidString),
                "name": .string(t.regionName),
                "file": .string(url.lastPathComponent),
                "path": .string(url.path),
                "start": .number(t.start),
                "end": .number(t.end),
                "status": .string(status),
            ]
            if let error { r["error"] = .string(error) }
            return .object(r)
        }
        let cur = batch.currentTarget
        return .object([
            "active": .bool(batch.isActive),
            "total": .int(batch.total),
            // 1-based index of the region under way; `total` once the batch is over.
            "current": .int(batch.isActive ? batch.current + 1 : batch.total),
            "name": .stringOrNull(cur?.regionName),
            "file": .stringOrNull(cur.map { batch.url(for: $0).lastPathComponent }),
            "progress": .number(batch.overallProgress(currentRegion: currentProgress)),
            "done": .int(batch.doneCount),
            "failed": .int(batch.failedCount),
            "cancelled": .int(batch.cancelledCount),
            "cancel_requested": .bool(batch.cancelRequested),
            "folder": .string(batch.settings.folder.path),
            "results": .array(results),
        ])
    }

    /// The loudness measured so far. A value that does not exist yet (a window that has not filled)
    /// or is silence (−infinity) is `null`: JSON has no infinity, and "nothing yet" and "silence"
    /// deserve the same honest answer.
    static func loudnessPayload(_ a: LoudnessAnalysis) -> JSONValue {
        func number(_ v: Double?) -> JSONValue {
            guard let v, v.isFinite else { return .null }
            return .number(v)
        }
        return .object([
            "integrated": number(a.integrated),
            "lra": number(a.loudnessRange),
            "true_peak": number(a.truePeakDB),
            "momentary": number(a.latestMomentary),
            "short_term": number(a.latestShortTerm),
            "momentary_max": number(a.momentaryMax),
            "short_term_max": number(a.shortTermMax),
            "blocks": .int(a.blockCount),
        ])
    }

    /// Follows an export to its end. We read the phase rather than waiting for quiescence: a
    /// render on a copy leaves the app perfectly available, so `wait_idle` would call it idle while
    /// the file does not exist yet.
    static func followExport(_ jobID: String, in vm: EditViewModel, destination: URL) {
        Task { @MainActor in
            // A regions batch counts as running between two of its regions too.
            while vm.exportJob?.isRunning == true || vm.exportBatch?.isActive == true {
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
            var result = exportPayload(job)
            if let batch = vm.exportBatch, case .object(var o) = result {
                o["batch"] = exportBatchPayload(batch, currentProgress: job.progress)
                result = .object(o)
            }
            JobRegistry.shared.finish(jobID, result: result)
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
