import Foundation
import AVFoundation

// MARK: - Importing a video (plan-video §2.1, §2.3, §2.4)
//
// A video file becomes a GROUP: the picture object (a `.clip` carrying a `VideoFacet`, no engine
// clip) plus one ordinary audio clip per audio track of the file — or the picture alone when the
// file has no sound. Everything happens in TWO stages, and the model is touched by the second only:
//
//   1. OFF the model — probe the file, extract every audio track into a staging folder inside the
//      project (`samples/video/.staging-<id>`, dot-named so the clean-up never lists it), verify each
//      one. Nothing is in `items`, nothing is on the undo stack; a cancel, a failure or a project
//      that changed under the import removes the staging folder and nothing else happened.
//   2. ON the main actor, in one block — move the files to `samples/video/`, `pushUndo()`, build the
//      objects, `placeClip` (which routes into an open group or the root, exactly like a dropped
//      file), `resolveOverlaps`. One undo takes the whole import back.
//
// What the user decided and this file carries out: MP4 and MOV only (any other container, and any
// codec the picture cannot be decoded with, is refused by name with no ghost object left behind);
// the original is REFERENCED, never copied; a project that was never saved is refused (the audio has
// no folder to go to); an audio track that is disabled or alternate in the file is imported MUTED;
// the dissociation is the groups' own gestures (eject, dissolve) — nothing is written for it.

/// Why an import did not happen. Every case reads as a sentence (`message`) naming the file and,
/// where it matters, the container or the codec — never "unsupported format".
enum VideoImportError: Error {
    /// The file is a video this build does not take (container, codec, unreadable, no picture).
    case refused(VideoProbe.Refusal, fileName: String)
    /// Not a video at all: an MP4/MOV holding sound only. The caller falls back on the audio path.
    case audioOnly
    /// The project has no folder yet.
    case needsSave
    /// The target group carries an instrument and takes no audio.
    case instrumentGroup
    /// Nothing was imported because it was cancelled.
    case cancelled
    /// The document changed (another project opened, a tab switched) while the audio was extracted.
    case projectChanged
    /// An audio track could not be extracted or verified.
    case extractionFailed(fileName: String, track: Int, codec: String, reason: String)

    var title: String {
        switch self {
        case .needsSave: return L("video.import.needsSave.title")
        default: return L("video.import.refused.title")
        }
    }

    var message: String {
        switch self {
        case .refused(let why, let name):
            switch why {
            case .unsupportedContainer(let ext):
                return L("video.import.refused.container", name, ext.isEmpty ? "?" : ext.uppercased())
            case .unreadable(let detail):
                return L("video.import.refused.unreadable", name, detail)
            case .undecodableCodec(let codec):
                return L("video.import.refused.codec", name, codec)
            case .emptyPicture:
                return L("video.import.refused.empty", name)
            }
        case .audioOnly: return L("video.import.refused.audioOnly")
        case .needsSave: return L("video.import.needsSave.info")
        case .instrumentGroup: return L("video.import.refused.instrumentGroup")
        case .cancelled: return L("video.import.cancelled")
        case .projectChanged: return L("video.import.projectChanged")
        case .extractionFailed(let name, let track, let codec, let reason):
            return L("video.import.failed.info", name, track, codec, reason)
        }
    }

    /// A stable machine word for the command API.
    var code: String {
        switch self {
        case .refused(let why, _):
            switch why {
            case .unsupportedContainer: return "unsupported_container"
            case .unreadable: return "unreadable"
            case .undecodableCodec: return "undecodable_codec"
            case .emptyPicture: return "empty_picture"
            }
        case .audioOnly: return "audio_only"
        case .needsSave: return "needs_save"
        case .instrumentGroup: return "instrument_group"
        case .cancelled: return "cancelled"
        case .projectChanged: return "project_changed"
        case .extractionFailed: return "extraction_failed"
        }
    }
}

/// A cancel switch the extraction polls from its own threads.
nonisolated final class VideoImportCancel: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return flag }
    func cancel() { lock.lock(); flag = true; lock.unlock() }
}

/// What an import produced, for the hand's HUD and the command API.
struct VideoImportResult {
    struct Track {
        var number: Int
        var codec: String
        /// "kept" (the M4A stream) or "wav16" / "wav24" / "wav32f".
        var written: String
        var fileName: String
        var muted: Bool
        var duration: Double
        var fallbackReason: String?
    }
    /// The object placed on the timeline: the group, or the picture itself when there is no sound.
    var rootID: UUID
    var pictureID: UUID
    var audioIDs: [UUID]
    var hasGroup: Bool
    var tracks: [Track]
    var duration: Double
    var pixelWidth: Int
    var pixelHeight: Int
    var videoCodec: String
}

extension EditViewModel {

    // MARK: - Is something running?

    var isImportingVideo: Bool { videoImportsInFlight > 0 }

    /// Asks every running import to stop. They answer `.cancelled` and clean up after themselves.
    func cancelVideoImports() {
        for c in videoImportCancels.values { c.cancel() }
    }

    // MARK: - The import

    /// Imports `url` at `baseLane` (a DISPLAY lane, the way a drop gives it) and `start` seconds.
    ///
    /// Asynchronous because the extraction is: the main actor is free meanwhile, and the document is
    /// held in place by `tabSwitchBlocker` (`isImportingVideo`). Throws `VideoImportError`; on any
    /// throw the model, the undo stack and the project folder are exactly as they were.
    @discardableResult
    func importVideo(url: URL, baseLane: Int = 0, start: Double = 0) async throws -> VideoImportResult {
        let fileName = url.lastPathComponent
        guard let projectFolder else { throw VideoImportError.needsSave }
        guard !isLoadingProject else { throw VideoImportError.projectChanged }

        // The cheap refusals first, before any byte is written.
        let info: VideoProbe.Info
        switch await VideoProbe.probe(url) {
        case .refused(let why): throw VideoImportError.refused(why, fileName: fileName)
        case .audioOnly: throw VideoImportError.audioOnly
        case .video(let i): info = i
        }
        // An instrument group takes no audio (E5): refused before any extraction.
        let lane = max(0, baseLane)
        if let gid = placementGroupID(forDisplayLane: lane, snapshot: laneEntries) {
            let probe = SoundObject(id: UUID(), startTime: start, duration: info.movieDuration, lane: 0,
                                    kind: .clip(filePath: url.path, sourceOffset: 0, fileDuration: info.movieDuration,
                                                speedRatio: 1, isReversed: false))
            if refusesAdding([probe], toGroup: gid) { throw VideoImportError.instrumentGroup }
        }

        let token = projectLoadToken
        let projectURLAtStart = projectURL
        let jobID = UUID()
        let cancel = VideoImportCancel()
        videoImportCancels[jobID] = cancel
        videoImportsInFlight += 1
        videoImportName = fileName
        videoImportFraction = 0
        defer {
            videoImportCancels[jobID] = nil
            videoImportsInFlight -= 1
            if videoImportsInFlight == 0 { videoImportName = nil; videoImportFraction = 0 }
        }

        // 1. Extract every audio track, off the model, into a staging folder of the project.
        let videoFolder = ConsolidateFolders.videoFolder(projectFolder: projectFolder)
        let staging = videoFolder.appendingPathComponent(".staging-\(jobID.uuidString)", isDirectory: true)
        var extracted: [VideoAudioExtract.Extracted] = []
        func discardStaging() { try? FileManager.default.removeItem(at: staging) }
        do {
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        } catch {
            throw VideoImportError.extractionFailed(fileName: fileName, track: 0, codec: "-", reason: error.localizedDescription)
        }
        let baseName = url.deletingPathExtension().lastPathComponent
        let hash8 = VideoAudioRule.hash8([url.path, String(info.fileSize ?? 0),
                                          String(info.modified?.timeIntervalSince1970 ?? 0)])
        let asset = AVURLAsset(url: url)
        let total = max(1, info.audioTracks.count)
        do {
            let avTracks = try await asset.loadTracks(withMediaType: .audio)
            for (i, track) in info.audioTracks.enumerated() {
                guard let avTrack = avTracks.first(where: { $0.trackID == track.trackID }) else {
                    throw VideoAudioExtract.Failure.readFailed("track \(track.number) vanished")
                }
                let done = Double(i)
                let vm = self
                let e = try await VideoAudioExtract.extract(
                    asset: asset, track: avTrack, info: track, baseName: baseName, hash8: hash8,
                    movieDuration: info.movieDuration, folder: staging,
                    isCancelled: { cancel.isCancelled },
                    progress: { f in
                        Task { @MainActor in vm.videoImportFraction = (done + f) / Double(total) }
                    })
                extracted.append(e)
            }
        } catch let f as VideoAudioExtract.Failure {
            discardStaging()
            if case .cancelled = f { throw VideoImportError.cancelled }
            let n = extracted.count
            let tr = n < info.audioTracks.count ? info.audioTracks[n] : nil
            throw VideoImportError.extractionFailed(fileName: fileName, track: tr?.number ?? 0,
                                                    codec: tr?.codec.displayName ?? "-", reason: "\(f)")
        } catch {
            discardStaging()
            let n = extracted.count
            let tr = n < info.audioTracks.count ? info.audioTracks[n] : nil
            throw VideoImportError.extractionFailed(fileName: fileName, track: tr?.number ?? 0,
                                                    codec: tr?.codec.displayName ?? "-", reason: error.localizedDescription)
        }
        if cancel.isCancelled { discardStaging(); throw VideoImportError.cancelled }

        // 2. The document must still be the one the import started in.
        guard projectLoadToken == token, projectURL == projectURLAtStart, self.projectFolder == projectFolder else {
            discardStaging()
            throw VideoImportError.projectChanged
        }

        // Move the files to their place. A file that is already there (the same video imported
        // again: the name carries the source's identity, so the content is the same) is reused.
        var finalURLs: [URL] = []
        do {
            for e in extracted {
                let dest = videoFolder.appendingPathComponent(e.url.lastPathComponent)
                if FileManager.default.fileExists(atPath: dest.path) {
                    try? FileManager.default.removeItem(at: e.url)
                } else {
                    try FileManager.default.moveItem(at: e.url, to: dest)
                }
                finalURLs.append(dest)
            }
        } catch {
            discardStaging()
            throw VideoImportError.extractionFailed(fileName: fileName, track: 0, codec: "-", reason: error.localizedDescription)
        }
        discardStaging()

        // 3. The model, in one block.
        return placeImportedVideo(info: info, baseName: baseName, extracted: extracted, files: finalURLs,
                                  baseLane: lane, start: start)
    }

    /// Builds the objects and lays them down in ONE gesture (one undo point). Main actor, synchronous.
    private func placeImportedVideo(info: VideoProbe.Info, baseName: String,
                                    extracted: [VideoAudioExtract.Extracted], files: [URL],
                                    baseLane: Int, start: Double) -> VideoImportResult {
        var picture = SoundObject(
            id: UUID(), startTime: start + info.pictureStart, duration: info.pictureDuration, lane: 0,
            volume: 0, pan: 0,
            kind: .clip(filePath: info.url.path, sourceOffset: info.pictureStart,
                        fileDuration: info.movieDuration, speedRatio: 1, isReversed: false))
        picture.fileSize = info.fileSize
        picture.video = VideoFacet(pixelSize: VideoSize(width: info.pixelWidth, height: info.pixelHeight),
                                   nominalFPS: info.nominalFPS)

        var audio: [SoundObject] = []
        var tracks: [VideoImportResult.Track] = []
        for (i, e) in extracted.enumerated() {
            let t = info.audioTracks[i]
            let file = files[i]
            var clip = SoundObject(
                id: UUID(), startTime: start, duration: e.duration, lane: i + 1,
                volume: 0, pan: 0,
                kind: .clip(filePath: file.path, sourceOffset: 0, fileDuration: e.duration,
                            speedRatio: 1, isReversed: false))
            clip.fileSize = Self.fileSize(atPath: file.path)
            // A disabled or alternate track is there, and silent: the user un-mutes the one he wants.
            clip.isMuted = !t.isDefault
            audio.append(clip)
            let written: String
            switch e.written {
            case .keptStream: written = "kept"
            case .wav(let d): written = "wav" + d.label
            }
            tracks.append(.init(number: t.number, codec: t.codec.displayName, written: written,
                                fileName: file.lastPathComponent, muted: clip.isMuted,
                                duration: e.duration, fallbackReason: e.fallbackReason))
        }

        var root: SoundObject
        if audio.isEmpty {
            root = picture
            root.startTime = start + info.pictureStart
            root.lane = baseLane
        } else {
            picture.lane = 0
            root = SoundObject(id: UUID(), startTime: start, duration: info.movieDuration, lane: baseLane,
                               label: baseName.isEmpty ? nil : baseName,
                               kind: .group(children: [picture] + audio, isExpanded: false))
        }

        pushUndo()
        engine?.beginPlaybackEdit()
        let snapshot = laneEntries
        let placed = placeClip(root, snapshot: snapshot)
        resolveOverlaps(for: placed.id)
        engine?.endPlaybackEdit()
        isDirty = true
        return VideoImportResult(rootID: placed.id, pictureID: picture.id, audioIDs: audio.map(\.id),
                                 hasGroup: !audio.isEmpty, tracks: tracks, duration: info.movieDuration,
                                 pixelWidth: info.pixelWidth, pixelHeight: info.pixelHeight,
                                 videoCodec: info.videoCodec)
    }

    // MARK: - From the hand

    /// The drop's door: imports each video, saying what went wrong in an alert (once per file), and
    /// returns the files that were NOT videos (an audio-only MP4/MOV, anything else) for the ordinary
    /// audio path. Videos are laid on successive lanes from `baseLane`.
    func importDroppedVideos(_ urls: [URL], baseLane: Int, start: Double) async -> [URL] {
        var rest: [URL] = []
        var lane = baseLane
        for url in urls {
            guard Self.isVideoDropCandidate(url) else { rest.append(url); continue }
            do {
                try await importVideo(url: url, baseLane: lane, start: start)
                lane += 1
            } catch VideoImportError.audioOnly {
                rest.append(url)        // an audio-only MP4/MOV is just a sound
            } catch VideoImportError.cancelled {
                continue
            } catch let e as VideoImportError {
                notify(e.title, e.message)
            } catch {
                notify(L("video.import.refused.title"), error.localizedDescription)
            }
        }
        return rest
    }

    /// An extension that says "this is a video": the two taken, and the ones named in a refusal.
    nonisolated static func isVideoDropCandidate(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return VideoProbe.acceptedExtensions.contains(ext) || VideoProbe.refusedVideoExtensions.contains(ext)
    }
}
