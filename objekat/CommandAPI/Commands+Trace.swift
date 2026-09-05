import Foundation

// MARK: - Plugin traces
//
// The command side of `docs/objekat-capture-trace.md`. It matters more than most: a trace can be
// judged with NO SCREEN AND NO EARS — the whole feature is measurements, and the report a
// capture returns says everything the panel would show. So the verification these commands make
// possible is not a poor substitute for listening, it is the actual verification.
//
// The one that has no equivalent in the interface is `plugin.trace.use`: forcing a slot onto its
// trace on a machine that HAS the plugin is the only way to compare, in the same session, what
// the plugin does against what its trace does. Export once, force, export again, null the two.

extension CommandRegistry {

    func registerTraceCommands() {

        register("plugin.trace.capture",
                 summary: "Captures the trace of a plugin: what it does to the signal it currently "
                        + "receives, frozen so the session plays without it. Two or three offline "
                        + "renders — returns a job_id.",
                 params: [ParamSpec("host", "uuid", "Object or stem carrying the chain."),
                          ParamSpec("plugin", "uuid", "Plugin to trace."),
                          ParamSpec("pre_roll", "number", required: false,
                                    "Seconds of silence before the region (default 2, the spec's minimum)."),
                          ParamSpec("tail", "number", required: false,
                                    "Seconds captured after the region, for releases and tails (default 5)."),
                          ParamSpec("use", "bool", required: false,
                                    "Switch the slot onto its trace straight away, even though the "
                                  + "plugin is installed here (default false).")],
                 // Not `.bus`: the capture is asynchronous, so the undo point the bus pushes
                 // would land before two or three renders' worth of nothing, and the model
                 // change it is meant to bracket happens long after the command returned.
                 undo: .none) { p in
            let vm = try CommandContext.shared.requireViewModel()
            _ = try CommandContext.shared.requireEngine()
            let host = try p.uuid("host")
            let pluginID = try p.uuid("plugin")
            let plugin = try CommandAdapters.requirePlugin(pluginID, on: host, in: vm)

            guard !plugin.isRack else {
                throw CommandError(code: .invalid_state,
                                   message: "a parallel block is not a plugin: trace its branches")
            }
            guard vm.tracesFolder != nil else {
                throw CommandError(code: .invalid_state,
                                   message: "save the project first: a trace needs a folder to live in")
            }
            guard !vm.isCapturingTrace else {
                throw CommandError(code: .invalid_state, message: "a trace capture is already running")
            }

            let preRoll = try p.double("pre_roll", or: 2.0)
            let tail = try p.double("tail", or: 5.0)
            let use = try p.bool("use", or: false)

            let jobID = JobRegistry.shared.begin(command: "plugin.trace.capture")
            vm.captureTrace(hostID: host, pluginID: pluginID,
                            preRoll: preRoll,
                            tail: tail,
                            forced: use,
                            // The report goes back in the job's result; `notify` would only add
                            // a line to the dialogue journal saying the same thing again.
                            reportsToUser: false) { report in
                let ok = report["ok"] as? Bool ?? false
                if ok {
                    JobRegistry.shared.finish(jobID, result: CommandAdapters.tracePayload(report))
                } else {
                    JobRegistry.shared.fail(jobID, error: CommandError(
                        code: .engine_error,
                        message: report["message"] as? String
                              ?? report["error"] as? String ?? "the capture failed",
                        details: CommandAdapters.tracePayload(report)))
                }
            }

            return .object(["job_id": .string(jobID),
                            "host": .string(host.uuidString),
                            "plugin": .string(pluginID.uuidString)])
        }

        register("plugin.trace.status",
                 summary: "Where the running capture has got to (0…1), or that none is running.") { _ in
            let vm = try CommandContext.shared.requireViewModel()
            guard let id = vm.capturingTracePluginID else {
                return .object(["running": .bool(false)])
            }
            vm.refreshTraceProgress()
            return .object(["running": .bool(true),
                            "plugin": .string(id.uuidString),
                            "progress": .number(vm.traceProgress)])
        }

        register("plugin.trace.cancel",
                 summary: "Stops the running capture (the engine gives up at the next block).",
                 undo: .none) { _ in
            let vm = try CommandContext.shared.requireViewModel()
            guard vm.isCapturingTrace else {
                throw CommandError(code: .invalid_state, message: "no trace capture running")
            }
            vm.cancelTraceCapture()
            return .object(["cancelled": .bool(true)])
        }

        register("plugin.trace.info",
                 summary: "What a slot's trace holds: the model's reference, and the header read "
                        + "back from the file itself.",
                 params: [ParamSpec("host", "uuid", "Carrying host."),
                          ParamSpec("plugin", "uuid", "Target plugin.")]) { p in
            let vm = try CommandContext.shared.requireViewModel()
            let host = try p.uuid("host")
            let pluginID = try p.uuid("plugin")
            let plugin = try CommandAdapters.requirePlugin(pluginID, on: host, in: vm)

            guard let ref = plugin.trace else {
                return .object(["plugin": .string(pluginID.uuidString), "traced": .bool(false)])
            }

            var payload: [String: JSONValue] = [
                "plugin":              .string(pluginID.uuidString),
                "traced":              .bool(true),
                "file":                .string(ref.fileName),
                "captured_at":         .number(ref.capturedAt.timeIntervalSince1970),
                "plugin_name":         .string(ref.pluginName),
                "sample_rate":         .number(ref.sampleRate),
                "num_channels":        .int(ref.numChannels),
                "num_samples":         .int(ref.numSamples),
                "region_start":        .number(ref.regionStart),
                "region_end":          .number(ref.regionEnd),
                "multiplicative_only": .bool(ref.multiplicativeOnly),
                "linked":              .bool(ref.linked),
                "non_deterministic":   .bool(ref.nonDeterministic),
                "validation_peak_db":  .number(ref.validationPeakDb),
                "input_hash":          .string(ref.inputHash),
                // An empty fingerprint is not an omission: it means the capture found the
                // upstream itself irreproducible, and refused to promise a check it cannot make.
                "verifiable":          .bool(ref.isVerifiable),
                "forced":              .bool(ref.forced),
                "in_use":              .bool(vm.playsFromTrace(plugin)),
                "plugin_installed":    .bool(vm.isPluginInstalled(plugin)),
                "health":              .string((vm.traceHealth(plugin, on: host) ?? ref.health).rawValue),
            ]

            if let url = vm.traceURL(ref) {
                payload["path"] = .string(url.path)
                payload["exists"] = .bool(FileManager.default.fileExists(atPath: url.path))
                if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                   let bytes = attributes[.size] as? Int {
                    payload["bytes"] = .int(bytes)
                }
                if let engine = CommandContext.shared.engine,
                   let header = engine.readTraceHeader(url.path) as? [String: Any] {
                    payload["header"] = CommandAdapters.tracePayload(header)
                }
            }

            return .object(payload)
        }

        register("plugin.trace.verify",
                 summary: "Renders the input again and compares its fingerprint with the one the "
                        + "trace carries — the REAL staleness check, as against the cheap "
                        + "continuous one behind `health`. Costs a capture. Returns a job_id.",
                 params: [ParamSpec("host", "uuid", "Carrying host."),
                          ParamSpec("plugin", "uuid", "Target plugin.")],
                 undo: .none) { p in
            let vm = try CommandContext.shared.requireViewModel()
            _ = try CommandContext.shared.requireEngine()
            let host = try p.uuid("host")
            let pluginID = try p.uuid("plugin")
            let plugin = try CommandAdapters.requirePlugin(pluginID, on: host, in: vm)

            guard let ref = plugin.trace else {
                throw CommandError(code: .invalid_state, message: "this plugin has no trace")
            }
            guard ref.isVerifiable else {
                throw CommandError(code: .invalid_state,
                                   message: "this trace carries no fingerprint: its upstream was "
                                          + "not reproducible when it was captured, so staleness "
                                          + "cannot be checked")
            }

            let jobID = JobRegistry.shared.begin(command: "plugin.trace.verify")
            vm.verifyTrace(hostID: host, pluginID: pluginID) { report in
                if report["ok"] as? Bool == true {
                    JobRegistry.shared.finish(jobID, result: CommandAdapters.tracePayload(report))
                } else {
                    JobRegistry.shared.fail(jobID, error: CommandError(
                        code: .engine_error,
                        message: report["message"] as? String
                              ?? report["error"] as? String ?? "the verification failed",
                        details: CommandAdapters.tracePayload(report)))
                }
            }
            return .object(["job_id": .string(jobID)])
        }

        register("plugin.trace.use",
                 summary: "Plays a slot from its trace, or back from its plugin. Where the plugin "
                        + "is missing the trace is used anyway — this only settles the case where "
                        + "both are available.",
                 params: [ParamSpec("host", "uuid", "Carrying host."),
                          ParamSpec("plugin", "uuid", "Target plugin."),
                          ParamSpec("forced", "bool", "true = the trace, false = the plugin.")],
                 undo: .bus) { p in
            let vm = try CommandContext.shared.requireViewModel()
            let host = try p.uuid("host")
            let pluginID = try p.uuid("plugin")
            let plugin = try CommandAdapters.requirePlugin(pluginID, on: host, in: vm)

            guard plugin.trace != nil else {
                throw CommandError(code: .invalid_state, message: "this plugin has no trace")
            }
            let forced = try p.bool("forced")
            vm.setTraceForced(hostID: host, pluginID: pluginID, forced: forced)

            let after = try CommandAdapters.requirePlugin(pluginID, on: host, in: vm)
            return .object(["plugin": .string(pluginID.uuidString),
                            "forced": .bool(forced),
                            "in_use": .bool(vm.playsFromTrace(after))])
        }

        register("plugin.trace.clear",
                 summary: "Drops a slot's trace (the file stays, and becomes an orphan that plugin.trace.purge collects). The plugin comes back.",
                 params: [ParamSpec("host", "uuid", "Carrying host."),
                          ParamSpec("plugin", "uuid", "Target plugin.")],
                 undo: .bus) { p in
            let vm = try CommandContext.shared.requireViewModel()
            let host = try p.uuid("host")
            let pluginID = try p.uuid("plugin")
            let plugin = try CommandAdapters.requirePlugin(pluginID, on: host, in: vm)

            guard plugin.trace != nil else {
                throw CommandError(code: .invalid_state, message: "this plugin has no trace")
            }
            vm.clearTrace(hostID: host, pluginID: pluginID)
            return .object(["plugin": .string(pluginID.uuidString), "traced": .bool(false)])
        }

        register("plugin.trace.list",
                 summary: "Every traced slot in the project, plus the trace files nothing "
                        + "references any more and what they weigh.") { _ in
            let vm = try CommandContext.shared.requireViewModel()

            var entries: [JSONValue] = []
            func note(_ hostID: UUID, _ hostName: String, _ plugins: [ObjectPlugin]) {
                for p in EditViewModel.flattenLeaves(plugins) {
                    guard let ref = p.trace else { continue }
                    entries.append(.object([
                        "host":       .string(hostID.uuidString),
                        "host_name":  .string(hostName),
                        "plugin":     .string(p.id.uuidString),
                        "name":       .string(p.name),
                        "file":       .string(ref.fileName),
                        "in_use":     .bool(vm.playsFromTrace(p)),
                        "health":     .string((vm.traceHealth(p, on: hostID) ?? ref.health).rawValue),
                    ]))
                }
            }
            func walk(_ objects: [SoundObject]) {
                for o in objects {
                    note(o.id, o.displayName, o.plugins)
                    note(o.id, o.displayName, o.instruments)
                    if case .group(let children, _) = o.kind { walk(children) }
                }
            }
            walk(vm.items)
            for stem in vm.stems { note(stem.id, stem.name, stem.plugins) }

            let orphans = vm.orphanTraces()
            return .object([
                "traces": .array(entries),
                "count": .int(entries.count),
                "orphans": .array(orphans.map { .object(["path": .string($0.url.path),
                                                         "bytes": .int($0.bytes)]) }),
                "orphan_bytes": .int(orphans.reduce(0) { $0 + $1.bytes }),
            ])
        }

        register("plugin.trace.purge",
                 summary: "Deletes the trace files nothing references any more. A trace is heavy; "
                        + "nothing else removes them.",
                 undo: .none) { _ in
            let vm = try CommandContext.shared.requireViewModel()
            let purged = vm.purgeOrphanTraces()
            return .object(["deleted": .int(purged.count), "bytes": .int(purged.bytes)])
        }
    }
}

extension CommandAdapters {

    /// Turns the engine's report (or a trace header) into JSON, keeping its keys. Every value the
    /// engine hands over is a number, a bool or a string — a straight walk is enough, and it
    /// means a field added engine-side reaches scripts without a line here.
    static func tracePayload(_ report: [String: Any]) -> JSONValue {
        var out: [String: JSONValue] = [:]
        for (key, value) in report {
            switch value {
            case let n as NSNumber:
                // `as? Bool` is NOT usable to tell a flag from a number here: Swift's NSNumber
                // bridging answers yes to any 0 or 1, so `num_channels: 1` would arrive in a
                // script as `true`. The encoding the number was BUILT with is the only thing
                // that knows, and NSNumber keeps it.
                switch String(cString: n.objCType) {
                case "c", "B": out[key] = .bool(n.boolValue)
                case "f", "d": out[key] = .number(n.doubleValue)
                default:       out[key] = .int(n.intValue)
                }
            case let s as String: out[key] = .string(s)
            default:              out[key] = .string(String(describing: value))
            }
        }
        return .object(out)
    }
}
