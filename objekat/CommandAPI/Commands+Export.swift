import Foundation

// MARK: - Export

/// Renders the mix to a file. The render is ASYNCHRONOUS (the engine works on its own thread):
/// `export.run` therefore returns a `job_id` rather than lying about work that isn't finished.
///
/// DEFAULTS DELIBERATELY DIFFERENT FROM THE PANEL'S. The panel offers 48 kHz 24-bit WAV, which is
/// delivery quality; the API is there first of all to CHECK — a script that renders forty
/// variants wants light files, playable at once. Hence MP3 44.1 kHz over the whole project.
///
/// The API reads NO preference: the panel, for its part, picks up the settings of the last
/// manual export (`makeExportSettings`). If a command inherited them, a script's result would
/// depend on what was ticked in the panel yesterday — a render has to be reproducible.
extension CommandRegistry {

    func registerExportCommands() {

        register("export.run",
                 summary: "Renders the mix to a file (asynchronous). Returns a job_id. "
                        + "Defaults: MP3, 44100 Hz, the whole project, in the project folder.",
                 params: [ParamSpec("path", "string", required: false,
                                    "Destination file. The extension is imposed by the "
                                    + "format. Default: <project folder>/<project name>."),
                          ParamSpec("format", "string", required: false, "mp3 (default) or wav."),
                          ParamSpec("sample_rate", "number", required: false,
                                    "44100 (default) or 48000; WAV also takes 88200 and 96000."),
                          ParamSpec("bit_depth", "int", required: false,
                                    "16 or 24 (default). WAV only."),
                          ParamSpec("dithering", "bool", required: false,
                                    "Dither noise on render (default true). WAV only."),
                          ParamSpec("range", "string", required: false,
                                    "project (default) = all the content; inout = the range between "
                                    + "the project's IN/OUT markers; regions = one file PER REGION "
                                    + "of the marker band, named after it, in `folder`."),
                          ParamSpec("scope", "string", required: false,
                                    "An alias of `range` (same values). Giving both with different "
                                    + "values is refused."),
                          ParamSpec("regions", "uuid[]", required: false,
                                    "regions scope only: the regions to render, by marker id. Absent = "
                                    + "the ones currently ticked (`export.regions`, `export.set_regions`). "
                                    + "Given, they are used as they are and the ticks are left alone."),
                          ParamSpec("folder", "string", required: false,
                                    "regions scope only: the destination FOLDER (must exist). Default: "
                                    + "the project folder. `path` is refused in this scope."),
                          ParamSpec("start", "number|string", required: false,
                                    "Start. A number = seconds; a string = 'm:ss,cc' (1:30,5) or "
                                    + "'bar:beat:tick' (3:1:0), like the panel's own "
                                    + "fields. With `end`, imposes the range and overrides "
                                    + "`range`."),
                          ParamSpec("end", "number|string", required: false, "End. See `start`."),
                          ParamSpec("set_markers", "bool", required: false,
                                    "Move the project's IN/OUT markers onto `start`/`end` too "
                                    + "(default false). The panel always does; a command "
                                    + "must not leave traces unless asked to."),
                          ParamSpec("background", "bool", required: false,
                                    "Render on a COPY of the project (default false). The copy "
                                    + "instantiates every plugin before starting — slower to "
                                    + "get going, but the app stays usable.")],
                 // An export doesn't change the project: nothing to undo.
                 undo: .none) { p in
            let vm = try CommandContext.shared.requireViewModel()
            _ = try CommandContext.shared.requireEngine()

            guard vm.exportJob?.isRunning != true, vm.exportBatch?.isActive != true else {
                throw CommandError(code: .invalid_state, message: "an export is already running")
            }

            var settings = ExportSettings()
            settings.format = try CommandAdapters.exportFormat(p)
            settings.sampleRate = try p.double("sample_rate", or: 44100)
            guard settings.format.sampleRates.contains(settings.sampleRate) else {
                throw CommandError(code: .bad_params,
                                   message: "sample rate not supported in \(settings.format.rawValue): "
                                          + "\(Int(settings.sampleRate)) Hz (expected: "
                                          + settings.format.sampleRates
                                              .map { String(Int($0)) }.joined(separator: ", ") + ")")
            }
            let depth = try p.int("bit_depth", or: 24)
            guard depth == 16 || depth == 24 else {
                throw CommandError(code: .bad_params, message: "expected bit depth: 16 or 24")
            }
            settings.bitDepth = depth
            settings.dithering = try p.optionalBool("dithering") ?? true
            settings.renderInBackground = try p.optionalBool("background") ?? false

            // The span scope. `scope` is the name the regions feature introduced; `range` is the
            // historical one. Both name the same thing.
            let scopeParam = try p.optionalString("scope")?.lowercased()
            let rangeParam = try p.optionalString("range")?.lowercased()
            if let a = scopeParam, let b = rangeParam, a != b {
                throw CommandError(code: .bad_params,
                                   message: "'scope' and 'range' name the same thing and disagree")
            }
            let scope = scopeParam ?? rangeParam ?? "project"

            // The range: both bounds or neither. Giving only one would leave the other to be
            // guessed, and a command does not guess.
            let hasStart = p.raw["start"] != nil, hasEnd = p.raw["end"] != nil

            // REGIONS: a batch of renders, one per region, into a FOLDER. It has nothing to do with
            // a single span or a single file name, so those are refused rather than ignored.
            if scope == "regions" {
                if hasStart || hasEnd {
                    throw CommandError(code: .bad_params,
                                       message: "'start'/'end' do not apply to the regions scope "
                                              + "(each region brings its own span)")
                }
                if p.raw["path"] != nil {
                    throw CommandError(code: .bad_params,
                                       message: "the regions scope writes into a folder: use 'folder', "
                                              + "not 'path'")
                }
                settings.rangeMode = .regions
                if p.raw["regions"] != nil {
                    let ids = try p.uuids("regions")
                    let known = Set(vm.exportRegions.map(\.id))
                    if let bad = ids.first(where: { !known.contains($0) }) {
                        throw CommandError(code: .not_found,
                                           message: "unknown region: \(bad.uuidString) "
                                                  + "(see export.regions)")
                    }
                    settings.regionIDs = ids
                }
                if let raw = try p.optionalString("folder") {
                    settings.folder = URL(fileURLWithPath: (raw as NSString).expandingTildeInPath,
                                          isDirectory: true)
                } else {
                    guard let folder = vm.projectFolder else {
                        throw CommandError(code: .invalid_state,
                                           message: "project not saved: give 'folder'")
                    }
                    settings.folder = folder
                }
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: settings.folder.path, isDirectory: &isDir),
                      isDir.boolValue else {
                    throw CommandError(code: .invalid_state,
                                       message: "folder not found: \(settings.folder.path)")
                }
                let targets = vm.exportRegionTargets(ids: settings.regionIDs)
                guard !targets.isEmpty else {
                    throw CommandError(code: .invalid_state,
                                       message: "no region selected (see export.regions / "
                                              + "export.set_regions)")
                }

                let jobID = JobRegistry.shared.begin(command: "export.run")
                vm.runExport(settings, persistingPreferences: false)
                // Refused before any work (unwritable folder, an overwrite turned down by the
                // dialogue policy), or every region refused: no batch under way.
                guard vm.exportBatch?.isActive == true else {
                    JobRegistry.shared.finish(jobID, result: .object(["started": .bool(false)]))
                    throw CommandError(code: .engine_error,
                                       message: "export refused — see `app.dialogs` for the reason")
                }
                CommandAdapters.followExport(jobID, in: vm, destination: settings.folder)
                return .object([
                    "job_id": .string(jobID),
                    "destination": .string(settings.folder.path),
                    "regions": .array(targets.map { t in
                        .object(["id": .string(t.id.uuidString),
                                 "name": .string(t.regionName),
                                 "file": .string(t.fileBase + "." + settings.format.fileExtension),
                                 "start": .number(t.start), "end": .number(t.end)])
                    }),
                ])
            }

            if hasStart != hasEnd {
                throw CommandError(code: .bad_params,
                                   message: "'start' and 'end' come as a pair")
            }
            if hasStart {
                let start = try CommandAdapters.exportTime(p, "start", in: vm)
                let end = try CommandAdapters.exportTime(p, "end", in: vm)
                guard end > start else {
                    throw CommandError(code: .bad_params, message: "'end' must be beyond 'start'")
                }
                settings.explicitRange = start...end
                // The panel moves the markers as soon as you type in its fields. Here it is an
                // explicit choice: we go through its own methods to inherit their guards
                // (minimum bounds, re-framing of the view).
                if try p.optionalBool("set_markers") ?? false {
                    vm.ensureExportInOutRange()
                    vm.setExportOutPoint(end)
                    vm.setExportInPoint(start)
                }
            } else {
                switch scope {
                case "project":
                    settings.rangeMode = .wholeProject
                    guard vm.projectContentEnd > 0 else {
                        throw CommandError(code: .invalid_state,
                                           message: "the project holds no object")
                    }
                case "inout":
                    settings.rangeMode = .inOut
                    guard let r = vm.loopRegion, r.upperBound > r.lowerBound else {
                        throw CommandError(code: .invalid_state,
                                           message: "no IN/OUT range set — give 'start' and "
                                                  + "'end' (with set_markers to place them)")
                    }
                default:
                    throw CommandError(code: .bad_params,
                                       message: "'range' expected: project, inout or regions")
                }
            }

            // Destination. `ExportSettings` assembles folder + name + extension: we take a full path
            // apart to stay on that single definition of the final file.
            if let raw = try p.optionalString("path") {
                let url = URL(fileURLWithPath: (raw as NSString).expandingTildeInPath)
                settings.folder = url.deletingLastPathComponent()
                settings.name = url.deletingPathExtension().lastPathComponent
            } else {
                guard let folder = vm.projectFolder else {
                    throw CommandError(code: .invalid_state,
                                       message: "project not saved: give 'path'")
                }
                settings.folder = folder
                settings.name = vm.projectName == L("project.untitled") ? L("export.defaultName") : vm.projectName
            }

            let destination = settings.destinationURL
            let jobID = JobRegistry.shared.begin(command: "export.run")
            vm.runExport(settings, persistingPreferences: false)

            // `runExport` can refuse BEFORE doing any work (unreadable folder, an overwrite turned
            // down by the dialogue policy): it then leaves a message and creates no job. Letting it
            // through would return a job_id that never came to anything.
            guard vm.exportJob != nil else {
                JobRegistry.shared.finish(jobID, result: .object(["started": .bool(false)]))
                throw CommandError(code: .engine_error,
                                   message: "export refused — see `app.dialogs` for the reason")
            }
            CommandAdapters.followExport(jobID, in: vm, destination: destination)
            return .object(["job_id": .string(jobID),
                            "destination": .string(destination.path)])
        }

        register("export.panel",
                 summary: "Opens or closes the export panel. It is what decides where a render "
                        + "SHOWS itself: with the panel open, a direct render stays in it "
                        + "(waveform, progress, listening); closed, the strip under the "
                        + "transport takes over. `export.run` never OPENS one by itself. "
                        + "While a render runs, `open: true` brings the panel back onto THAT "
                        + "render (its own settings, greyed) — the strip's Show button. "
                        + "With no interface it only sets the state (`panel_open`): no window.",
                 params: [ParamSpec("open", "bool", required: true,
                                    "true = open on the settings, false = close.")],
                 undo: .none) { p in
            let vm = try CommandContext.shared.requireViewModel()
            if try p.bool("open") {
                // A render under way: bring the panel back onto IT (the strip's "Show" button),
                // rather than opening on fresh settings and refusing with "already running".
                if vm.exportJob?.isRunning == true { vm.reopenExportPanel() } else { vm.openExportPanel() }
            } else {
                vm.exportPanelPresented = false
            }
            return .object(["open": .bool(vm.exportPanelPresented)])
        }

        register("export.status",
                 summary: "State of the running export, or of the last one to finish. "
                        + "`panel_open` says whether the export panel is showing it: a DIRECT "
                        + "render keeps the panel, a background one closes it. It is a STATE, "
                        + "not a fact about the screen: with no interface (`--headless`) "
                        + "`export.panel` sets it all the same, and no window ever appears. "
                        + "`panel_visible` is the reality: `panel_open` AND a window able to "
                        + "show it, so it is always false headless. `loudness` is what "
                        + "the render has measured so far (ITU-R BS.1770-4 / EBU R128): "
                        + "`integrated` (LUFS, gated), `lra` (LU), `true_peak` (dBTP), "
                        + "`momentary` / `short_term` (the latest windows, LUFS), "
                        + "`momentary_max` / `short_term_max`, and `blocks` (the number of 100 ms "
                        + "sub-blocks measured). A value that does not exist yet, or is "
                        + "silence (-infinity), is null. A regions export adds `batch`: "
                        + "`total`, `current` (1-based, the region under way), `name`, `file`, "
                        + "`progress` (0…1 over the whole batch) and `results` (per region: id, name, "
                        + "file, status pending|running|done|failed|cancelled, error). The top-level "
                        + "`progress`/`phase` stay those of the region under way.") { _ in
            let vm = try CommandContext.shared.requireViewModel()
            guard let job = vm.exportJob else {
                return .object(["running": .bool(false),
                                "panel_open": .bool(vm.exportPanelPresented),
                                "panel_visible": .bool(vm.exportPanelPresented && vm.hasInterface),
                                "loudness": .null])
            }
            guard case .object(var payload) = CommandAdapters.exportPayload(job) else {
                return CommandAdapters.exportPayload(job)
            }
            payload["panel_open"] = .bool(vm.exportPanelPresented)
            payload["panel_visible"] = .bool(vm.exportPanelPresented && vm.hasInterface)
            // A regions export: which region of how many, and what became of each.
            if let batch = vm.exportBatch {
                payload["batch"] = CommandAdapters.exportBatchPayload(batch, currentProgress: job.progress)
            }
            // Read from the ENGINE now, not from what the panel's timer last cached.
            vm.readExportLoudness()
            payload["loudness"] = CommandAdapters.loudnessPayload(vm.exportLoudness)
            return .object(payload)
        }

        register("export.loudness",
                 summary: "The loudness CURVES of the render (or of the last one to finish), cut down to "
                        + "at most `points` samples evenly spread over its 100 ms sub-blocks: "
                        + "`times` (s, the instant each window ENDS), `momentary` (400 ms), "
                        + "`short_term` (3 s) and `integrated` (the gated value as it stood at "
                        + "that instant), all in LUFS. A curve is null where its window has not "
                        + "filled yet or where it is silence. `summary` is the same object as "
                        + "`export.status.loudness`.",
                 params: [ParamSpec("points", "int", required: false,
                                    "How many samples at most (default 200, 1 … 5000).")]) { p in
            let vm = try CommandContext.shared.requireViewModel()
            guard vm.exportJob != nil else {
                throw CommandError(code: .invalid_state, message: "no export to measure")
            }
            let points = try p.int("points", or: 200)
            guard (1...5000).contains(points) else {
                throw CommandError(code: .bad_params, message: "points must be 1 … 5000")
            }
            vm.readExportLoudness()
            let a = vm.exportLoudness
            let c = a.curves(points: points)
            func series(_ v: [Double?]) -> JSONValue {
                .array(v.map { $0.map { .number($0) } ?? .null })
            }
            return .object([
                "blocks": .int(a.blockCount),
                "duration": .number(a.duration),
                "times": .array(c.times.map { .number($0) }),
                "momentary": series(c.momentary),
                "short_term": series(c.shortTerm),
                "integrated": series(c.integrated),
                "summary": CommandAdapters.loudnessPayload(a),
            ])
        }

        register("export.preview",
                 summary: "What the panel shows OF a render while it runs: how far the waveform "
                        + "has grown (the engine's tap) and how much of the file can already be "
                        + "listened to (what the writer has flushed to disk). The two are "
                        + "different numbers — the render runs ahead of the flush. "
                        + "`output_device` is the sound card the listening goes out on, read "
                        + "back from the listening engine's own AudioUnit. `listen` (optional) "
                        + "starts (true, from the beginning) or stops (false) the listening — "
                        + "the machine's door onto the listen button, and it really plays.",
                 params: [ParamSpec("listen", "bool", required: false,
                                    "true = start listening from 0, false = stop.")]) { p in
            let vm = try CommandContext.shared.requireViewModel()
            guard let job = vm.exportJob else {
                throw CommandError(code: .invalid_state, message: "no export to show")
            }
            if let listen = try p.optionalBool("listen") {
                if listen {
                    vm.exportAudition.start(source: job.previewSource, from: 0)
                } else {
                    vm.exportAudition.stop()
                }
            }
            // Read from the ENGINE and from the FILE, not from what the panel's timer last
            // cached: a command that only echoed the display could not prove the display right.
            vm.readExportPeaks()
            vm.exportAudition.probe(source: job.previewSource, force: true)
            let peaks = vm.exportPeaks
            let filled = peaks.count / 2
            let loudest = peaks.map { abs($0) }.max() ?? 0
            return .object([
                "peaks_filled": .number(Double(filled)),
                "peaks_total": .number(Double(EditViewModel.exportPeakResolution)),
                "peak_amplitude": .number(Double(loudest)),
                "audible_seconds": .number(vm.exportAudition.availableDuration),
                "rendered_duration": .number(job.renderedDuration),
                "source": .string(job.previewSource.path),
                "listening": .bool(vm.exportAudition.isPlaying),
                "output_device": .stringOrNull(vm.exportAudition.outputDeviceName()),
            ])
        }

        // MARK: Regions scope — the picker's two doors

        register("export.regions",
                 summary: "The regions the `regions` export scope works on: every region of the "
                        + "marker band (hidden rows included, flagged `lane_visible`; marks carried by "
                        + "objects are not regions), in start-time order, with whether it is ticked "
                        + "and the file it would write. `file_name` (with its extension) is null for "
                        + "an unticked region; names are made unique among the TICKED ones only. "
                        + "`warnings` may hold empty_name, duplicate_name, file_exists. Read-only.",
                 params: [ParamSpec("format", "string", required: false,
                                    "mp3 (default) or wav — decides the extension of `file_name`."),
                          ParamSpec("folder", "string", required: false,
                                    "The destination folder `file_exists` is checked against. Default: "
                                    + "the project folder; without one, file_exists is never reported.")]) { p in
            let vm = try CommandContext.shared.requireViewModel()
            var settings = ExportSettings()
            settings.format = try CommandAdapters.exportFormat(p)
            let folder: URL? = try p.optionalString("folder").map {
                URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true)
            } ?? vm.projectFolder
            if let folder { settings.folder = folder }

            let names = vm.exportRegionFileNames
            let warnings: [UUID: [ExportRegionWarning]] = folder == nil
                ? [:] : vm.exportRegionWarnings(names: names, settings: settings)
            let entries = vm.exportRegions
            return .object([
                "count": .int(entries.count),
                "selected_count": .int(entries.filter { vm.isExportRegionSelected($0.id) }.count),
                "folder": .stringOrNull(folder?.path),
                "regions": .array(entries.map { e -> JSONValue in
                    let selected = vm.isExportRegionSelected(e.id)
                    var o: [String: JSONValue] = [
                        "id": .string(e.id.uuidString),
                        "lane": .string(e.laneID.uuidString),
                        "lane_name": .string(e.laneName),
                        "lane_visible": .bool(e.laneVisible),
                        "name": .string(e.name),
                        "start": .number(e.start),
                        "end": .number(e.end),
                        "duration": .number(e.duration),
                        "number": .int(e.number),
                        "selected": .bool(selected),
                        "file_name": .null,
                        "warnings": .array((warnings[e.id] ?? []).map { .string($0.rawValue) }),
                    ]
                    if selected, let a = names[e.id] {
                        o["file_name"] = .string(a.base + "." + settings.format.fileExtension)
                    }
                    return .object(o)
                }),
            ])
        }

        register("export.set_regions",
                 summary: "Ticks or unticks regions for the `regions` export scope — what the picker's "
                        + "checkboxes and its Select all / Select none / Invert buttons do. The ticks "
                        + "live in the session (memory), not in the project file. `action`: select, "
                        + "deselect (both take `regions`), only (ticks exactly `regions`), all, none, "
                        + "invert. Answers with the ticked ids.",
                 params: [ParamSpec("action", "string", "select | deselect | only | all | none | invert."),
                          ParamSpec("regions", "uuid[]", required: false,
                                    "The regions concerned (select, deselect, only).")],
                 undo: .none) { p in
            let vm = try CommandContext.shared.requireViewModel()
            let action = try p.string("action").lowercased()
            switch action {
            case "all":    vm.selectAllExportRegions()
            case "none":   vm.selectNoExportRegions()
            case "invert": vm.invertExportRegions()
            case "select", "deselect", "only":
                let ids = try p.uuids("regions")
                let known = Set(vm.exportRegions.map(\.id))
                if let bad = ids.first(where: { !known.contains($0) }) {
                    throw CommandError(code: .not_found, message: "unknown region: \(bad.uuidString)")
                }
                if action == "only" { vm.selectNoExportRegions() }
                for id in ids { vm.setExportRegion(id, selected: action != "deselect") }
            default:
                throw CommandError(code: .bad_params,
                                   message: "'action' expected: select, deselect, only, all, none or invert")
            }
            let ticked = vm.selectedExportRegions
            return .object(["selected_count": .int(ticked.count),
                            "selected": .array(ticked.map { .string($0.id.uuidString) })])
        }

        register("object.render_isolated",
                 summary: "Renders ONE object, just the object, to a wav file (asynchronous). Returns a "
                        + "job_id. The file holds everything that belongs to the object — its own plugins, "
                        + "gain and pan, fades, window, speed, and its content for a group or MIDI object — "
                        + "and nothing around it: no parent group's chain, no stem, no master, no aux or "
                        + "sends. Laid back at the same start, the file is iso with the object as it "
                        + "sounded alone. Unlike `export.run`, it does not render the mix.",
                 params: [ParamSpec("id", "uuid", "Object to render (clip, group or MIDI; not an aux "
                                    + "nor an infinite bus)."),
                          ParamSpec("path", "string", "Destination wav (written as is, overwritten)."),
                          ParamSpec("start", "number", required: false,
                                    "Start in seconds (default: the object's start)."),
                          ParamSpec("end", "number", required: false,
                                    "End in seconds (default: start + duration). The range is written "
                                    + "to the sample, with no tail margin."),
                          ParamSpec("sample_rate", "number", required: false, "Default 48000."),
                          ParamSpec("bit_depth", "int", required: false,
                                    "16 or 24 (default; written as an integer wav).")],
                 // A render reads the project, never writes it.
                 undo: .none) { p in
            let vm = try CommandContext.shared.requireViewModel()
            let engine = try CommandContext.shared.requireEngine()
            let id = try p.uuid("id")
            guard let object = vm.find(id: id) else {
                throw CommandError(code: .not_found, message: "unknown object: \(id.uuidString)")
            }
            guard !object.isAux, !object.isInfiniteBus else {
                throw CommandError(code: .invalid_state,
                                   message: "a bus (aux or infinite group) has no span to render")
            }
            let path = try p.string("path")
            guard !path.isEmpty else {
                throw CommandError(code: .bad_params, message: "'path' must not be empty")
            }
            let start = try p.optionalDouble("start") ?? object.startTime
            let end = try p.optionalDouble("end") ?? (object.startTime + object.duration)
            guard end > start else {
                throw CommandError(code: .bad_params, message: "'end' must be after 'start'")
            }
            let sampleRate = try p.double("sample_rate", or: 48000)
            guard sampleRate >= 8000, sampleRate <= 192000 else {
                throw CommandError(code: .bad_params, message: "'sample_rate' out of range")
            }
            let depth = try p.int("bit_depth", or: 24)
            guard depth == 16 || depth == 24 else {
                throw CommandError(code: .bad_params, message: "expected bit depth: 16 or 24")
            }
            let jobID = JobRegistry.shared.begin(command: "object.render_isolated")
            engine.renderObjectAlone(toFileAsync: id.uuidString, filePath: path,
                                     start: start, end: end,
                                     sampleRate: sampleRate, bitDepth: depth) { ok in
                Task { @MainActor in
                    if ok {
                        JobRegistry.shared.finish(jobID, result: .object([
                            "path": .string(path), "start": .number(start), "end": .number(end),
                            "sample_rate": .number(sampleRate), "bit_depth": .int(depth)]))
                    } else {
                        JobRegistry.shared.fail(jobID, error: CommandError(
                            code: .engine_error, message: "the isolated render failed (see the log)"))
                    }
                }
            }
            return .object(["job_id": .string(jobID)])
        }

        register("export.cancel",
                 summary: "Cancels the running export (the engine stops at the next block). A regions "
                        + "export stops cleanly: the region under way is interrupted, the following "
                        + "ones are never started (status `cancelled`), those already written stay.",
                 undo: .none) { _ in
            let vm = try CommandContext.shared.requireViewModel()
            guard vm.exportJob?.isRunning == true || vm.exportBatch?.isActive == true else {
                throw CommandError(code: .invalid_state, message: "no export running")
            }
            vm.cancelExport()
            return .object(["cancelled": .bool(true)])
        }
    }
}
