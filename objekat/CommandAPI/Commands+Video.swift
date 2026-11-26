import Foundation
import QuartzCore

// MARK: - Video (plan-video §8 V1)

/// `video.import` — the scriptable twin of dropping an MP4/MOV on the timeline. The rules (what is
/// taken, what each audio track becomes on disk, the group it lays down) are those of
/// `EditViewModel.importVideo`, the very function the drop calls.
extension CommandRegistry {

    func registerVideoCommands() {

        register("video.import",
                 summary: "Imports an MP4 or MOV video as a GROUP: the picture object (no sound of its own) "
                        + "plus one audio clip per audio track of the file (an alternate or disabled track "
                        + "comes in MUTED). A file with no sound lands as the picture alone. The original "
                        + "is referenced, never copied; the audio is extracted into samples/video/ of the "
                        + "project (which must have been saved). Anything else than MP4/MOV, or a picture "
                        + "codec that cannot be decoded, is refused by name and leaves nothing behind. One undo.",
                 params: [ParamSpec("path", "string", "Path of the video file."),
                          ParamSpec("lane", "int", required: false, "Target display lane (default 0)."),
                          ParamSpec("start", "number", required: false, "Start, in seconds (default 0).")],
                 // The method pushes its OWN undo point, once, when the model is finally touched: the
                 // extraction runs before it and must leave no empty point behind when it fails.
                 undo: .handled) { p in
            let vm = try CommandContext.shared.requireViewModel()
            let path = try p.string("path")
            guard FileManager.default.fileExists(atPath: path) else {
                throw CommandError(code: .not_found, message: "file not found: \(path)")
            }
            let lane = max(0, try p.int("lane", or: 0))
            let start = max(0, try p.double("start", or: 0))
            do {
                let r = try await vm.importVideo(url: URL(fileURLWithPath: path), baseLane: lane, start: start)
                let tracks: [JSONValue] = r.tracks.map { t in
                    .object(["track": .int(t.number), "codec": .string(t.codec), "written": .string(t.written),
                             "file": .string(t.fileName), "muted": .bool(t.muted),
                             "duration": .number(t.duration),
                             "fallback_reason": .stringOrNull(t.fallbackReason)])
                }
                return .object(["id": .string(r.rootID.uuidString),
                                "picture_id": .string(r.pictureID.uuidString),
                                "audio_ids": .array(r.audioIDs.map { .string($0.uuidString) }),
                                "group": .bool(r.hasGroup),
                                "duration": .number(r.duration),
                                "width": .int(r.pixelWidth), "height": .int(r.pixelHeight),
                                "video_codec": .string(r.videoCodec),
                                "audio_tracks": .array(tracks),
                                "parent": .stringOrNull(vm.parentGroup(for: r.rootID)?.id.uuidString)])
            } catch let e as VideoImportError {
                let code: CommandError.Code
                switch e {
                case .cancelled, .projectChanged, .needsSave, .instrumentGroup: code = .invalid_state
                case .refused, .audioOnly: code = .bad_params
                case .extractionFailed: code = .engine_error
                }
                // The hand's alert would be the wrong place to say it: a script gets the answer.
                throw CommandError(code: code, message: e.message,
                                   details: .object(["reason": .string(e.code)]))
            }
        }

        // MARK: V1 — the picture: probe, layers, still, clock

        register("video.probe",
                 summary: "Reads a video file WITHOUT importing it: container, picture size and codec, "
                        + "frame rate, durations, audio tracks. A file OBJEKAT would refuse answers "
                        + "'refused' with the reason (the one video.import gives); an audio file answers "
                        + "'audio_only'.",
                 params: [ParamSpec("path", "string", "Path of the file.")]) { p in
            let path = try p.string("path")
            guard FileManager.default.fileExists(atPath: path) else {
                throw CommandError(code: .not_found, message: "file not found: \(path)")
            }
            switch await VideoProbe.probe(URL(fileURLWithPath: path)) {
            case .audioOnly:
                return .object(["kind": .string("audio_only")])
            case .refused(let why):
                let (code, detail): (String, String)
                switch why {
                case .unsupportedContainer(let e): (code, detail) = ("unsupported_container", e)
                case .unreadable(let d): (code, detail) = ("unreadable", d)
                case .undecodableCodec(let c): (code, detail) = ("undecodable_codec", c)
                case .emptyPicture: (code, detail) = ("empty_picture", "")
                }
                return .object(["kind": .string("refused"), "reason": .string(code), "detail": .string(detail)])
            case .video(let i):
                let tracks: [JSONValue] = i.audioTracks.map { t in
                    .object(["track": .int(t.number), "codec": .string(String(describing: t.codec)),
                             "sample_rate": .number(t.sampleRate), "channels": .int(t.channels),
                             "start": .number(t.start), "duration": .number(t.duration),
                             "default": .bool(t.isDefault), "language": .stringOrNull(t.language)])
                }
                return .object(["kind": .string("video"),
                                "movie_duration": .number(i.movieDuration),
                                "picture_start": .number(i.pictureStart),
                                "picture_duration": .number(i.pictureDuration),
                                "width": .int(i.pixelWidth), "height": .int(i.pixelHeight),
                                "fps": .number(i.nominalFPS), "video_codec": .string(i.videoCodec),
                                "file_size": i.fileSize.map { .number(Double($0)) } ?? .null,
                                "audio_tracks": .array(tracks)])
            }
        }

        register("video.layers",
                 summary: "The pictures visible at a timeline instant, BOTTOM first (the order they are composed in), "
                        + "at most two, the front-most last. Each carries the object, its file, the instant of the "
                        + "FILE it shows and the rate it advances at. The very resolver the preview and "
                        + "video.render_frame use. No window, no player: usable headless.",
                 params: [ParamSpec("t", "number", required: false,
                                    "Timeline seconds (default: the displayed position, i.e. the cursor when stopped).")]) { p in
            let session = try CommandContext.shared.requireSession()
            let vm = session.viewModel
            let t = try p.optionalDouble("t") ?? session.displayedPosition
            let index = vm.videoObjectIndex
            let layers = VideoResolver.layers(at: t, in: index)
            return .object(["t": .number(t),
                            "pictures": .int(index.entries.count),
                            "layers": .array(layers.map { l in
                                .object(["object_id": .string(l.objectID.uuidString),
                                         "file": .string(l.filePath),
                                         "source_time": .number(l.sourceTime),
                                         "rate": .number(l.rate),
                                         "reversed": .bool(l.isReversed),
                                         "fps": .number(l.nominalFPS),
                                         "opacity": .number(l.opacity)])
                            })])
        }

        register("video.render_frame",
                 summary: "Renders the picture at a timeline instant into a PNG, through the SAME graph as the preview "
                        + "(resolver, exact frames, CoreImage composer): black background, each layer fitted and "
                        + "centred, bottom to top. Usable headless — it opens no window and touches neither the "
                        + "preview's players nor the clock. With no picture at that instant the frame is black "
                        + "(layers: 0). The size defaults to that of the front-most picture's file.",
                 params: [ParamSpec("time", "number", "Timeline seconds."),
                          ParamSpec("path", "string", "Where to write the PNG."),
                          ParamSpec("width", "int", required: false, "Pixels (default: the picture's)."),
                          ParamSpec("height", "int", required: false, "Pixels (default: the picture's).")]) { p in
            let session = try CommandContext.shared.requireSession()
            let vm = session.viewModel
            let t = try p.double("time")
            let path = try p.string("path")
            guard let composer = session.videoPreview.composer else {
                throw CommandError(code: .engine_error, message: "no Metal device")
            }
            let layers = VideoResolver.layers(at: t, in: vm.videoObjectIndex)
            var width = 1280, height = 720
            if let front = layers.last, let size = vm.find(id: front.objectID)?.video?.pixelSize {
                width = size.width; height = size.height
            }
            width = try p.optionalInt("width") ?? width
            height = try p.optionalInt("height") ?? height
            guard width >= 16, height >= 16, width <= 8192, height <= 8192 else {
                throw CommandError(code: .bad_params, message: "width and height must be between 16 and 8192")
            }
            let url = URL(fileURLWithPath: path)
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            // Decoding exact frames takes tens of milliseconds each: away from the main actor.
            let size = CGSize(width: width, height: height)
            let outcome: (written: Bool, shown: Int, seconds: Double) = await Task.detached(priority: .userInitiated) {
                let t0 = CACurrentMediaTime()
                guard let r = VideoPlayerEngine.renderStill(layers: layers, size: size, composer: composer),
                      let image = r.image else { return (false, 0, CACurrentMediaTime() - t0) }
                let ok = VideoComposer.writePNG(image, to: url)
                return (ok, r.shown, CACurrentMediaTime() - t0)
            }.value
            guard outcome.written else {
                throw CommandError(code: .engine_error, message: "could not render or write \(path)")
            }
            return .object(["path": .string(path), "width": .int(width), "height": .int(height),
                            "time": .number(t),
                            "layers": .int(layers.count), "decoded": .int(outcome.shown),
                            "seconds": .number(outcome.seconds)])
        }

        register("video.clock",
                 summary: "The picture's clock: what the audio engine says is audible, the output latency taken off, "
                        + "the anchor the display extrapolates from, and the preview's counters. One sample is taken "
                        + "at the call. 'av_offset' (seconds; positive = the picture shown is moved FORWARD) sets the "
                        + "project's A/V offset for this run (not saved in V1).",
                 params: [ParamSpec("av_offset", "number", required: false, "Sets the A/V offset, seconds.")]) { p in
            let session = try CommandContext.shared.requireSession()
            let preview = session.videoPreview
            let clock = preview.clock
            if let o = try p.optionalDouble("av_offset") { clock.avOffsetSeconds = o }
            clock.tick()
            let r = clock.snapshot()
            let now = CACurrentMediaTime()
            let stats = preview.displayStats
            return .object(["playing": .bool(clock.lastPlaying),
                            "audible": .number(clock.lastAudible),
                            "output_latency": .number(clock.lastLatency),
                            "av_offset": .number(clock.avOffsetSeconds),
                            "anchor_position": .number(r.position),
                            "anchor_advancing": .bool(r.advancing),
                            "epoch": .int(Int(truncatingIfNeeded: r.epoch)),
                            "position_now": .number(r.position(atHost: now)),
                            "clock_running": .bool(clock.isRunning),
                            "preview_open": .bool(preview.isOpen),
                            "players": .int(preview.engine.activeSlotCount),
                            "ticks": .int(stats?.ticks ?? 0),
                            "presented": .int(stats?.presented ?? 0),
                            "skipped": .int(stats?.skipped ?? 0)])
        }

        register("video.preview",
                 summary: "Shows, hides or toggles the preview window. Under --headless there is no window: it "
                        + "answers open: false and does nothing.",
                 params: [ParamSpec("action", "string", required: false, "show | hide | toggle (default toggle).")]) { p in
            let session = try CommandContext.shared.requireSession()
            let preview = session.videoPreview
            let window = VideoPreviewWindow.shared
            switch try p.string("action", or: "toggle") {
            case "show": window.show(preview)
            case "hide": window.close()
            case "toggle": window.toggle(preview)
            default: throw CommandError(code: .bad_params, message: "action must be show, hide or toggle")
            }
            return .object(["open": .bool(preview.isOpen)])
        }

        register("video.import_status",
                 summary: "Whether a video import is running, and how far its audio extraction has got.") { _ in
            let vm = try CommandContext.shared.requireViewModel()
            return .object(["running": .bool(vm.isImportingVideo),
                            "count": .int(vm.videoImportsInFlight),
                            "file": .stringOrNull(vm.videoImportName),
                            "fraction": .number(vm.videoImportFraction)])
        }

        register("video.import_cancel",
                 summary: "Stops every running video import; each answers 'cancelled' and leaves nothing behind.") { _ in
            let vm = try CommandContext.shared.requireViewModel()
            let n = vm.videoImportCancels.count
            vm.cancelVideoImports()
            return .object(["cancelled": .int(n)])
        }
    }
}
