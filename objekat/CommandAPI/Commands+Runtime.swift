import Foundation

// MARK: - Quiescence, batches, jobs and measurement

/// This family is what makes a script DETERMINISTIC and MEASURABLE: without `wait_idle`, a read
/// that follows a mutation may observe an in-between state; without `batch`, N commands = N
/// rebuilds of the engine graph; without `perf.*`, one optimises blind.
extension CommandRegistry {

    func registerRuntimeCommands() {

        // MARK: wait_idle

        register("wait_idle",
                 summary: "Waits for the model's deferred work to finish.",
                 params: [ParamSpec("timeout_ms", "int", required: false, "Waiting budget (default 5000)."),
                          ParamSpec("settle_ms", "int", required: false,
                                    "Grace period after things go quiet, for the engine's deferred work (default 0).")]) { p in
            let timeout = try p.int("timeout_ms", or: 5000)
            let settle = try p.int("settle_ms", or: 0)
            return try await Quiescence.waitIdle(timeoutMs: timeout, settleMs: settle)
        }

        // MARK: batch

        register("batch",
                 summary: """
                 Runs a sequence of commands under A SINGLE undo. With coalesce=true, the \
                 flattening cache is rebuilt ONCE on the way out — but the commands in the \
                 batch then see the lane cache as it was at the START of the batch, and those \
                 that read it (duplicate, groups, auxes, MIDI, sound objects, time selection) \
                 do NOTHING without saying so. Only turn it on for a batch of pure, \
                 independent writes.
                 """,
                 params: [ParamSpec("commands", "array<object>",
                                    "{cmd, params} requests, run in order."),
                          ParamSpec("stop_on_error", "bool", required: false,
                                    "Stop at the first failure (default true)."),
                          ParamSpec("coalesce", "bool", required: false,
                                    "Coalesce item mutations (default false); only turn it on for a batch of pure, independent writes.")],
                 // The batch takes its own single undo: the bus must on no account add another.
                 undo: .handled) { p in
            let vm = try CommandContext.shared.requireViewModel()
            let entries = try p.array("commands")
            guard !entries.isEmpty else {
                throw CommandError(code: .bad_params, message: "'commands' cannot be empty")
            }
            let stopOnError = try p.bool("stop_on_error", or: true)
            // A CAUTIOUS default, settled after measuring: under coalescing, `laneEntries` is frozen
            // and any command that reads it works from a stale snapshot. Seen at runtime: a coalesced
            // `object.duplicate` returns "ok, failed=0" and duplicates nothing. And that cache is read
            // in some 100 places — selection, cut, clipboard, groups, auxes, MIDI, sound objects, solo
            // — that is, nearly every family still to come. A batch must be RIGHT by default and fast
            // on request, never the other way round: coalescing saves one cache rebuild, and costs a
            // command that lies.
            let coalesce = try p.bool("coalesce", or: false)
            return try await CommandRegistry.shared.runBatch(entries,
                                                             stopOnError: stopOnError,
                                                             coalesce: coalesce,
                                                             vm: vm)
        }

        // MARK: jobs

        register("job.status",
                 summary: "State of an asynchronous job.",
                 params: [ParamSpec("id", "string", "The identifier returned by the long-running command.")]) { p in
            try JobRegistry.shared.job(try p.string("id")).jsonObject
        }

        register("job.wait",
                 summary: "Waits for an asynchronous job to finish.",
                 params: [ParamSpec("id", "string", "Job identifier."),
                          ParamSpec("timeout_ms", "int", required: false, "Waiting budget (default 60000).")]) { p in
            let id = try p.string("id")
            let timeout = try p.int("timeout_ms", or: 60_000)
            return try await JobRegistry.shared.wait(id, timeoutMs: timeout).jsonObject
        }

        register("job.list", summary: "Every job this session knows about.") { _ in
            .object(["jobs": .array(JobRegistry.shared.allJobs().map(\.jsonObject))])
        }

        // MARK: plugins (a job — the first user of the asynchronous machinery)

        register("plugin.scan",
                 summary: "Starts the scan of the installed plugins. Returns a job_id.") { _ in
            let vm = try CommandContext.shared.requireViewModel()
            _ = try CommandContext.shared.requireEngine()
            guard !vm.isScanning else {
                throw CommandError(code: .invalid_state, message: "a scan is already running")
            }
            let jobID = JobRegistry.shared.begin(command: "plugin.scan")
            vm.scanPlugins()
            // `scanPlugins` takes no completion: it flips `isScanning`. We follow that flag — it is
            // the only end-of-scan observable without touching the view-model.
            Task { @MainActor in
                while vm.isScanning {
                    try? await Task.sleep(for: .milliseconds(100))
                }
                JobRegistry.shared.finish(jobID, result: .object([
                    "plugin_count": .int(vm.availablePlugins.count)
                ]))
            }
            return .object(["job_id": .string(jobID)])
        }

        // MARK: measurement

        register("perf.measure",
                 summary: """
                 Runs a sequence of commands and returns its timings. `model_ms` = how long \
                 the model work took; `frame_ms` = how long the main loop stayed busy \
                 afterwards (SwiftUI invalidations, relayout) — that distinction is the heart \
                 of the project's way of measuring.
                 """,
                 params: [ParamSpec("commands", "array<object>", "Sequence to measure."),
                          ParamSpec("repeat", "int", required: false, "How many repetitions (default 1)."),
                          ParamSpec("wait_idle", "bool", required: false,
                                    "Wait for quiescence between repetitions (default true).")],
                 undo: .handled) { p in
            let entries = try p.array("commands")
            guard !entries.isEmpty else {
                throw CommandError(code: .bad_params, message: "'commands' cannot be empty")
            }
            let repeats = max(1, try p.int("repeat", or: 1))
            let settle = try p.bool("wait_idle", or: true)
            return try await CommandRegistry.shared.measure(entries, repeats: repeats, settle: settle)
        }

        register("perf.census",
                 summary: "Project census: objects by type, tracks, plugins, sends, notes.") { _ in
            let vm = try CommandContext.shared.requireViewModel()
            var byKind: [String: Int] = ["clip": 0, "group": 0, "aux": 0, "midi": 0]
            var pluginCount = 0, rackCount = 0, sendCount = 0, noteCount = 0
            var instanceCount = 0, maxDepth = 0

            for entry in vm.laneEntries {
                let item = entry.item
                byKind[CommandAdapters.kindName(item), default: 0] += 1
                maxDepth = max(maxDepth, entry.depth)
                sendCount += item.sends.count
                noteCount += item.midiNotes.count
                if item.isObjectInstance { instanceCount += 1 }
                for plugin in item.plugins + item.instruments {
                    if plugin.isRack { rackCount += 1 } else { pluginCount += 1 }
                }
            }
            for stem in vm.stems { pluginCount += stem.plugins.count }

            return .object([
                "objects": .object(byKind.mapValues { .int($0) }),
                "objects_total": .int(vm.laneEntries.count),
                "max_group_depth": .int(maxDepth),
                "stems": .int(vm.stems.count),
                "object_definitions": .int(vm.objectDefinitions.count),
                "object_instances": .int(instanceCount),
                "plugins": .int(pluginCount),
                "racks": .int(rackCount),
                "sends": .int(sendCount),
                "midi_notes": .int(noteCount),
                "undo_depth": .int(vm.undoStack.count),
                // The audio graph's node count lives on the engine side and is not exposed to
                // Swift; exposing it would mean changing OBJEngineCore, which is out of scope here.
                "engine_nodes": .null,
            ])
        }
    }

    // MARK: - Running a batch

    fileprivate func runBatch(_ entries: [JSONValue],
                              stopOnError: Bool,
                              coalesce: Bool,
                              vm: EditViewModel) async throws -> JSONValue {
        // Depth measured AFTER the push (and not before): `pushUndo` caps the stack at 50 and can
        // therefore drop an entry off the bottom — the depth from before would then be off by one,
        // and the overwrite below would carry away the batch's own undo.
        vm.pushUndo()
        let depthWithBatchEntry = vm.undoStack.count

        var results: [JSONValue] = []
        var firstError: CommandError? = nil

        func runAll() async {
            for (index, entry) in entries.enumerated() {
                guard firstError == nil || !stopOnError else { break }
                do {
                    guard let name = entry["cmd"]?.stringValue else {
                        throw CommandError(code: .bad_params,
                                           message: "command \(index): field 'cmd' required")
                    }
                    guard name != "batch" else {
                        throw CommandError(code: .invalid_state, message: "nested batch not allowed")
                    }
                    let value = try await execute(name: name, params: Self.params(of: entry))
                    results.append(.object(["index": .int(index), "cmd": .string(name),
                                            "ok": .bool(true), "result": value]))
                } catch {
                    let commandError = CommandError.wrap(error)
                    if firstError == nil { firstError = commandError }
                    results.append(.object(["index": .int(index), "ok": .bool(false),
                                            "error": commandError.jsonObject]))
                }
            }
        }

        // The sub-commands take no undo of their own: the batch carries a single one.
        suppressUndo = true
        defer { suppressUndo = false }

        if coalesce {
            // `batchItemsMutation` only accepts a SYNCHRONOUS closure; the commands are
            // asynchronous. So we collect first, keeping the coalescing where it really pays off:
            // the lane cache is rebuilt only once, on the way out.
            vm.beginCoalescedItemsMutation()
            await runAll()
            vm.endCoalescedItemsMutation()
        } else {
            await runAll()
        }

        // Overwrites the intermediate undos pushed by sub-commands that handle their own (cut,
        // paste, group operations): only the batch's must remain, the one taken before anything.
        if vm.undoStack.count > depthWithBatchEntry {
            vm.undoStack.removeSubrange(depthWithBatchEntry...)
        }
        vm.redoStack = []

        if let firstError, stopOnError {
            throw CommandError(code: firstError.code,
                               message: firstError.message,
                               details: .object(["results": .array(results)]))
        }
        return .object(["results": .array(results),
                        "count": .int(results.count),
                        "failed": .int(results.filter { $0["ok"]?.boolValue == false }.count)])
    }

    // MARK: - Measurement

    fileprivate func measure(_ entries: [JSONValue], repeats: Int, settle: Bool) async throws -> JSONValue {
        var modelSamples: [Double] = []
        var frameSamples: [Double] = []
        var lastResults: [JSONValue] = []

        for _ in 0..<repeats {
            if settle { _ = try? await Quiescence.waitIdle(timeoutMs: 10_000) }

            var results: [JSONValue] = []
            let t0 = CFAbsoluteTimeGetCurrent()
            for entry in entries {
                guard let name = entry["cmd"]?.stringValue else {
                    throw CommandError(code: .bad_params, message: "field 'cmd' required")
                }
                let value = try await execute(name: name, params: Self.params(of: entry))
                results.append(value)
            }
            let t1 = CFAbsoluteTimeGetCurrent()

            // FRAME TIME — we hand control back to the main loop and measure how long it takes to
            // come back. That delay is everything the loop had to do because of the mutation:
            // observation invalidations, SwiftUI layout and rendering. It is a measure of how busy
            // the main thread is, not a frame counter — the project has no access to the window's
            // CADisplayLink from this layer.
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
            let t2 = CFAbsoluteTimeGetCurrent()

            modelSamples.append((t1 - t0) * 1000)
            frameSamples.append((t2 - t1) * 1000)
            lastResults = results
        }

        return .object([
            "repeat": .int(repeats),
            "model_ms": Self.statistics(modelSamples),
            "frame_ms": Self.statistics(frameSamples),
            "total_ms": Self.statistics(zip(modelSamples, frameSamples).map(+)),
            "last_results": .array(lastResults),
        ])
    }

    /// Min / median / max / mean. The median rather than the mean alone: a first cold
    /// iteration (waveform caches, plugins to instantiate) crushes the mean and would hide
    /// the steady state, the only one worth comparing between two versions.
    private static func statistics(_ samples: [Double]) -> JSONValue {
        guard !samples.isEmpty else { return .null }
        let sorted = samples.sorted()
        let median = sorted.count % 2 == 1
            ? sorted[sorted.count / 2]
            : (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
        return .object([
            "min": .number((sorted.first ?? 0).rounded(toPlaces: 3)),
            "median": .number(median.rounded(toPlaces: 3)),
            "max": .number((sorted.last ?? 0).rounded(toPlaces: 3)),
            "mean": .number((samples.reduce(0, +) / Double(samples.count)).rounded(toPlaces: 3)),
            "samples": .array(samples.map { .number($0.rounded(toPlaces: 3)) }),
        ])
    }
}

private extension Double {
    /// Display rounding: a measurement in milliseconds means nothing beyond the micron.
    func rounded(toPlaces places: Int) -> Double {
        let factor = pow(10.0, Double(places))
        return (self * factor).rounded() / factor
    }
}
