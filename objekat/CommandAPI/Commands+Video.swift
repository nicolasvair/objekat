import Foundation

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
