import Foundation
import AppKit

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
                 that read it (duplicate, groups, auxes, MIDI, consolidated objects, time selection) \
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
            // in some 100 places — selection, cut, clipboard, groups, auxes, MIDI, consolidated objects, solo
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

        register("perf.audio_probe",
                 summary: "DIAGNOSTIC (app launched with OBJ_AUDIO_PROBE=1): 'reset' clears the "
                        + "per-block record of the final mix, 'mark' timestamps a label, 'dump' "
                        + "writes it all as CSV to 'path'.",
                 params: [ParamSpec("action", "string", "reset | mark | dump"),
                          ParamSpec("label", "string", required: false, "For 'mark'."),
                          ParamSpec("path", "string", required: false, "For 'dump'.")]) { p in
            let vm = try CommandContext.shared.requireViewModel()
            guard let engine = vm.engine else {
                throw CommandError(code: .invalid_state, message: "no engine")
            }
            switch try p.string("action") {
            case "reset": return .object(["ok": .bool(engine.audioProbeReset())])
            case "mark":  engine.audioProbeMark(try p.string("label")); return .object(["ok": .bool(true)])
            case "dump":  return .object(["ok": .bool(engine.audioProbeDump(toPath: try p.string("path")))])
            default: throw CommandError(code: .bad_params, message: "reset | mark | dump")
            }
        }

        register("perf.census",
                 summary: """
                 Project census: objects by type, tracks, plugins, sends, notes — plus `regimes`, \
                 which regime the timeline's VISIBLE blocks were last drawn in (batched Canvas or \
                 rich SwiftUI view, @see `Shared/TimelineRegimeMeter.swift`). Zero in headless mode: \
                 nothing is drawn there.
                 """,
                 params: [ParamSpec("reset", "bool", required: false,
                                    "Zero the cumulative regime counters (`passes`, `canvas_draws`) first "
                                  + "(default false).")]) { p in
            let vm = try CommandContext.shared.requireViewModel()
            if try p.bool("reset", or: false) { TimelineRegimeMeter.reset() }
            let regimes = TimelineRegimeMeter.snapshot()
            var byKind: [String: Int] = ["clip": 0, "group": 0, "aux": 0, "midi": 0]
            var pluginCount = 0, rackCount = 0, sendCount = 0, noteCount = 0
            var instanceCount = 0, maxDepth = 0

            for entry in vm.laneEntries {
                let item = entry.item
                byKind[CommandAdapters.kindName(item), default: 0] += 1
                maxDepth = max(maxDepth, entry.depth)
                sendCount += item.sends.count
                noteCount += item.midiNotes.count
                if item.isConsolidateInstance { instanceCount += 1 }
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
                "object_definitions": .int(vm.consolidateDefinitions.count),
                "object_instances": .int(instanceCount),
                "plugins": .int(pluginCount),
                "racks": .int(rackCount),
                "sends": .int(sendCount),
                "midi_notes": .int(noteCount),
                "undo_depth": .int(vm.undoStack.count),
                // Cumulative since launch: writes of `items` and O(N) rebuilds of the lane entries
                // (a gesture's cost, readable with no screen: take the difference around it).
                "items_writes": .int(vm.itemsWriteCount),
                "lane_entries_rebuilds": .int(vm.laneEntriesRebuildCount),
                // How the timeline's visible blocks were last drawn. `clips_rich` counts every
                // block that is not a group and kept a SwiftUI view (an aux and a MIDI clip
                // always do); `groups_canvas` counts the groups the Canvas draws (the others, and
                // every group under the Debug A/B switch, are `groups_rich`), while
                // `group_bands_canvas` counts the open groups whose bands the Canvas draws.
                "regimes": .object([
                    "clips_canvas": .int(regimes.clipsCanvas),
                    "clips_rich": .int(regimes.clipsRich),
                    "groups_canvas": .int(regimes.groupsCanvas),
                    "groups_rich": .int(regimes.groupsRich),
                    "group_bands_canvas": .int(regimes.groupBandsCanvas),
                    "group_bands_rich": .int(regimes.groupBandsRich),
                    "passes": .int(regimes.passes),
                    "canvas_draws": .int(regimes.canvasDraws),
                    // WHY the rich blocks are rich: one reason per block (the first rule that
                    // sent it there), every key present even at 0, summing to
                    // `clips_rich + groups_rich`.
                    "rich_reasons": .object(Dictionary(uniqueKeysWithValues:
                        RichReason.allCases.map { ($0.key, JSONValue.int(regimes.richReasons[$0.rawValue])) })),
                    // The element count of each unconditional `ForEach` layer of the timeline's
                    // body (last pass) and their sum: the SwiftUI subtrees that layer set pays for.
                    "foreach_layers": .object(regimes.layerElements.mapValues { .int($0) }),
                    "foreach_total": .int(regimes.layerElements.values.reduce(0, +)),
                ]),
                // The audio graph's node count lives on the engine side and is not exposed to
                // Swift; exposing it would mean changing OBJEngineCore, which is out of scope here.
                "engine_nodes": .null,
            ])
        }

        // MARK: waveform cache

        register("perf.waveforms",
                 summary: """
                 The waveform cache's counters (@see `Shared/WaveformCacheMeter.swift`) — \
                 computed once per file or per region, never per sample, so reading this costs \
                 nothing the cache was not already paying. Answers even with no project open: \
                 the counters are process-wide statics, not a view-model's.
                 """,
                 params: [ParamSpec("reset", "bool", required: false,
                                    "Zero the counters first (default false).")],
                 undo: .none) { p in
            if try p.bool("reset", or: false) { WaveformCacheMeter.reset() }
            let stats = WaveformCacheMeter.snapshot()
            let vm = CommandContext.shared.viewModel
            return .object([
                "mipmaps_computed": .int(stats.mipmapsComputed),
                "mipmap_compute_seconds": .number(stats.mipmapComputeSeconds),
                "mipmaps_read_from_disk": .int(stats.mipmapsReadFromDisk),
                "disk_read_seconds": .number(stats.diskReadSeconds),
                "stereo_mipmaps": .int(stats.stereoMipmaps),
                "mipmaps_written": .int(stats.mipmapsWritten),
                "bytes_written": .int(stats.bytesWritten),
                "region_decodes": .int(stats.regionsDecoded),
                "region_decode_seconds": .number(stats.regionDecodeSeconds),
                "region_evictions": .int(stats.regionsEvicted),
                "peak_bytes_in_memory": .int(stats.peakBytesInMemory),
                "region_bytes_in_memory": .int(stats.regionBytesInMemory),
                "in_flight": .int(stats.inFlight),
                "peak_concurrency": .int(stats.peakConcurrency),
                "densities": .array(WaveformCache.effectiveDensitiesPerSecond.map { .number($0) }),
                "sample_mode_threshold": .number(WaveformCache.sampleModeThreshold),
                "format_version": .int(Int(WaveformCache.formatVersion)),
                "waveforms_dir": .stringOrNull(vm?.waveformsFolder?.path),
            ])
        }

        register("waveform.preload",
                 summary: """
                 Computes the waveforms of every file the CURRENT project names, whether or not \
                 their blocks are on screen — the only door a script has onto the peaks, since \
                 `ensureWaveformsLoaded` is driven by what the Canvas draws and nothing headless \
                 has one. `available: false` means this instance has no interface (`--headless`): \
                 that is the guard against measuring an empty cache and concluding there is \
                 nothing to fix.
                 """,
                 undo: .none) { _ in
            let vm = try CommandContext.shared.requireViewModel()
            guard let preload = vm.preloadWaveforms else {
                return .object(["available": .bool(false), "paths": .int(0)])
            }
            let paths = Array(vm.referencedAudioPaths)
            preload(paths)
            return .object(["available": .bool(true), "paths": .int(paths.count)])
        }

        #if DEBUG
        // MARK: debug (spike, @see plan_titlebar_audio_device.md §4a)

        register("debug.titlebar",
                 summary: """
                 DEBUG. Every NSTextField found in the window's title-bar chrome, with its frame \
                 in WINDOW coordinates — used to measure whether NSWindow.subtitle draws inline \
                 to the right of the title or stacked below it, on this toolbar-less window \
                 (§4a). Also the grey audio-device LABEL's own frame, colour and hidden state, \
                 and the title field's frame it is laid beside (§4b) — `window_subtitle` itself \
                 stays empty since 4b, by design. Empty/null in headless mode (no window).
                 """,
                 undo: .none) { _ in
            let vm = try CommandContext.shared.requireViewModel()
            let fields = vm.debugTitlebarTextFields()
            let label = vm.debugAudioDeviceLabel()
            func rect(_ r: CGRect?) -> JSONValue {
                guard let r else { return .null }
                return .object(["x": .number(r.origin.x), "y": .number(r.origin.y),
                                 "width": .number(r.width), "height": .number(r.height)])
            }
            return .object([
                "window_title": .stringOrNull(vm.titledWindow?.title),
                "window_subtitle": .stringOrNull(vm.titledWindow?.subtitle),
                "all_windows": .array(NSApp.windows.map {
                    .object(["title": .string($0.title), "visible": .bool($0.isVisible),
                             "titled": .bool($0.styleMask.contains(.titled))])
                }),
                "fields": .array(fields.map {
                    .object(["value": .string($0.value), "x": .number($0.x), "y": .number($0.y),
                             "width": .number($0.width), "height": .number($0.height)])
                }),
                "title_field_frame": rect(label.titleFrame),
                "label_frame": rect(label.labelFrame),
                "label_hidden": label.labelHidden.map { .bool($0) } ?? .null,
                "label_color": .stringOrNull(label.labelColor),
                "label_text": .stringOrNull(label.labelText),
                "label_truncated": label.labelTruncated.map { .bool($0) } ?? .null,
            ])
        }

        register("debug.resize_window",
                 summary: """
                 DEBUG. Sets the document window's frame width (and, optionally, height) — the \
                 only way a script can drive the narrow-window / trailing-edge behaviour of the \
                 audio-device label (@see plan_titlebar_audio_device.md §4b) without a hand on \
                 the window. `invalid_state` with no window (headless).
                 """,
                 params: [ParamSpec("width", "number", "New frame width, in points."),
                          ParamSpec("height", "number", required: false,
                                    "New frame height; kept if omitted.")],
                 undo: .none) { p in
            let vm = try CommandContext.shared.requireViewModel()
            guard let window = vm.titledWindow else {
                throw CommandError(code: .invalid_state, message: "no window (headless)")
            }
            let width = try p.double("width")
            let height = try p.double("height", or: window.frame.height)
            var frame = window.frame
            frame.size = NSSize(width: width, height: height)
            window.setFrame(frame, display: true)
            return .object(["width": .number(window.frame.width),
                             "height": .number(window.frame.height)])
        }

        register("debug.force_rich_blocks",
                 summary: """
                 DEBUG. The "everything rich" A/B switch of the Canvas work (@see \
                 `Shared/DebugRenderSwitches.swift`): `enabled: true` forces every SELECTED clip \
                 back onto its rich SwiftUI view, EVERY group block onto `GroupBlockView`, AND the \
                 bands of the open groups back onto their SwiftUI layers; `false` draws them in the batched Canvas (production). VOLATILE — it writes nothing \
                 into the user's settings; the persistent form is the preference \
                 `objekat.debug.forceRichBlocks`, read at launch. Answers the previous and the \
                 current value. Not present in Release builds.
                 """,
                 params: [ParamSpec("enabled", "bool", "true = rich views for selected clips, group blocks and open groups' bands.")],
                 undo: .none) { p in
            let enabled = try p.bool("enabled")
            let was = DebugRenderSwitches.shared.forceRichBlocks
            DebugRenderSwitches.shared.forceRichBlocks = enabled
            return .object(["was": .bool(was), "enabled": .bool(enabled)])
        }

        register("debug.force_rich_tools",
                 summary: """
                 DEBUG. The A/B switch of the tools' Canvas work (@see \
                 `Shared/DebugRenderSwitches.swift`): `enabled: true` puts EVERY block back on its \
                 rich SwiftUI view under the Volume / Pan / Aux tools (and the old Stem rule: a clip \
                 rich only when selected AND hovered); `false` (production) keeps a block rich only \
                 when it is aimed at or cut by a viewport edge, and draws the tool's overlay in the \
                 batched Canvas for the others. VOLATILE — it writes nothing into the user's \
                 settings; the persistent form is the preference `objekat.debug.forceRichTools`, \
                 read at launch. Answers the previous and the current value. Not present in \
                 Release builds.
                 """,
                 params: [ParamSpec("enabled", "bool", "true = rich views for every block under a tool.")],
                 undo: .none) { p in
            let enabled = try p.bool("enabled")
            let was = DebugRenderSwitches.shared.forceRichTools
            DebugRenderSwitches.shared.forceRichTools = enabled
            return .object(["was": .bool(was), "enabled": .bool(enabled)])
        }

        register("debug.set_opt_held",
                 summary: """
                 DEBUG. Sets the view model's `optKeyHeld`, the state the timeline reads to flip a \
                 move under way between MOVING and ⌥-COPYING without a mouse movement. A synthetic \
                 event cannot press the hardware ⌥ (the drag handlers read `NSEvent.modifierFlags`), \
                 so this is the one door a script has onto the ⌥-copy's ghosts: start an \
                 `input.drag` with `release: false`, call this with `held: true`, read \
                 `perf.census`, then `held: false` and `input.release`. Answers the previous and \
                 the current value. Not present in Release builds.
                 """,
                 params: [ParamSpec("held", "bool", "true = ⌥ considered pressed.")],
                 undo: .none) { p in
            let held = try p.bool("held")
            let vm = try CommandContext.shared.requireViewModel()
            let was = vm.optKeyHeld
            vm.optKeyHeld = held
            return .object(["was": .bool(was), "held": .bool(held)])
        }

        register("debug.force_rich_previews",
                 summary: """
                 DEBUG. The A/B switch of the previews' Canvas work (@see \
                 `Shared/RenderPreferences.swift`): `enabled: true` puts the gestures' previews \
                 (move, trim, resize, fade, spill, loop-bound drag) back onto the rich SwiftUI \
                 views — the regime from before the Canvas drew them; `false` (production) draws \
                 them in the batched Canvas. VOLATILE — it writes nothing into the user's \
                 settings; the persistent form, which Release builds read too, is the preference \
                 `objekat.timeline.richPreviews`, read at launch. Answers the previous and the \
                 current value. Not present in Release builds.
                 """,
                 params: [ParamSpec("enabled", "bool", "true = rich views for the blocks a gesture is previewing.")],
                 undo: .none) { p in
            let enabled = try p.bool("enabled")
            let was = RenderPreferences.shared.richPreviews
            RenderPreferences.shared.richPreviews = enabled
            return .object(["was": .bool(was), "enabled": .bool(enabled)])
        }
        #endif
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

    /// Min / median / p95 / p99 / max / mean. The median rather than the mean alone: a first
    /// cold iteration (waveform caches, plugins to instantiate) crushes the mean and would hide
    /// the steady state, the only one worth comparing between two versions. The tail
    /// percentiles are nearest-rank (@see FrameStats), meaningful from a few dozen repeats.
    private static func statistics(_ samples: [Double]) -> JSONValue {
        guard !samples.isEmpty else { return .null }
        let sorted = samples.sorted()
        let median = sorted.count % 2 == 1
            ? sorted[sorted.count / 2]
            : (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
        return .object([
            "min": .number((sorted.first ?? 0).rounded(toPlaces: 3)),
            "median": .number(median.rounded(toPlaces: 3)),
            "p95": .number((FrameStats.percentile(sorted, 95) ?? 0).rounded(toPlaces: 3)),
            "p99": .number((FrameStats.percentile(sorted, 99) ?? 0).rounded(toPlaces: 3)),
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
