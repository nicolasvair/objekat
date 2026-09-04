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
                                    + "the project's IN/OUT markers."),
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

            guard vm.exportJob?.isRunning != true else {
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

            // The range: both bounds or neither. Giving only one would leave the other to be
            // guessed, and a command does not guess.
            let hasStart = p.raw["start"] != nil, hasEnd = p.raw["end"] != nil
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
                switch try p.string("range", or: "project").lowercased() {
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
                                       message: "'range' expected: project or inout")
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

        register("export.status",
                 summary: "State of the running export, or of the last one to finish.") { _ in
            let vm = try CommandContext.shared.requireViewModel()
            guard let job = vm.exportJob else { return .object(["running": .bool(false)]) }
            return CommandAdapters.exportPayload(job)
        }

        register("export.cancel",
                 summary: "Cancels the running export (the engine stops at the next block).",
                 undo: .none) { _ in
            let vm = try CommandContext.shared.requireViewModel()
            guard vm.exportJob?.isRunning == true else {
                throw CommandError(code: .invalid_state, message: "no export running")
            }
            vm.cancelExport()
            return .object(["cancelled": .bool(true)])
        }
    }
}
