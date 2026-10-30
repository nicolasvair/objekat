import Foundation
import AVFoundation
import CoreMedia
import AudioToolbox

// MARK: - Pulling a video's audio tracks out as files of the project (plan-video §2.4)
//
// One audio track in, one file out, written into a folder the caller gives (a scratch folder of
// `samples/video/`: nothing is final until the whole import is — @see `VideoImport`). Off the main
// thread, cancellable, no model, no engine.
//
// What it writes follows `VideoAudioRule`:
//   • a KEPT stream (AAC, and AC-3 / E-AC-3 / MP3 / Opus when they verify) goes into an M4A by a
//     PASSTHROUGH export — no re-encoding — and is then VERIFIED: opened the way the engine opens a
//     file (`EngineLikeAudioReader`), its length and its first seconds must equal what
//     `AVAssetReader` decodes from the source. Any doubt falls back on a WAV;
//   • everything else is decoded and written as a WAV, PADDED with silence at the head and the tail so
//     that it begins at t = 0 and spans the whole movie.
//
// Why the verification is not optional: the source's timeline (edit list, encoder delay) and the
// engine's reading of a bare file are two different things, and the only way to know a kept stream
// lands where the picture says is to read it both ways (the MOV read directly by CoreAudio is 44 ms
// late, the same stream extracted is exact — plan-video §2.4).

nonisolated enum VideoAudioExtract {

    /// How a track was written.
    enum Written: Equatable, Sendable {
        case keptStream            // an M4A, the original compressed stream
        case wav(VideoAudioRule.WavDepth)
    }

    struct Extracted: Equatable, Sendable {
        var url: URL
        var written: Written
        /// The file's length in seconds, as the engine will read it.
        var duration: Double
        var sampleRate: Double
        var channels: Int
        /// Why a kept stream was NOT kept (verification failed, export refused), for the import journal.
        var fallbackReason: String?
    }

    enum Failure: Error, Equatable, Sendable {
        case cancelled
        case readFailed(String)
        case writeFailed(String)
    }

    /// Verification tolerance on decoded samples, an AAC decoder's own determinism plus float noise.
    static let sampleTolerance: Float = 2e-3
    /// A kept stream's first decoded sample must sit at the movie's zero within this many seconds.
    static let firstSampleTolerance = 0.001
    /// How much of the head is compared sample by sample.
    static let verifySeconds = 10.0

    // MARK: Entry

    /// Extracts `track` of `asset` into `folder`, named `<baseName>_A<n>_<hash8>.<m4a|wav>`.
    /// `movieDuration` is what a WAV is padded to. `isCancelled` is polled between buffers.
    /// `progress` receives 0…1.
    static func extract(asset: AVURLAsset, track: AVAssetTrack, info: VideoProbe.AudioTrack,
                        baseName: String, hash8: String, movieDuration: Double, folder: URL,
                        isCancelled: @escaping @Sendable () -> Bool,
                        progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> Extracted {
        let layout = await channelLayoutData(track: track, channels: info.channels)
        var fallbackReason: String?
        var choice = VideoAudioRule.choice(for: info.codec, startsAtZero: info.startsAtZero)
        if !info.startsAtZero, info.codec.isKeepable {
            fallbackReason = "the track starts at \(String(format: "%.3f", info.start)) s, not 0: a stream cannot be padded"
        }

        if choice.isKept {
            let name = VideoAudioRule.fileName(baseName: baseName, trackNumber: info.number, hash8: hash8, ext: "m4a")
            let dest = folder.appendingPathComponent(name)
            switch await keepStream(asset: asset, track: track, info: info, layout: layout, to: dest, isCancelled: isCancelled) {
            case .success(let e):
                progress(1)
                return e
            case .failure(let why):
                if isCancelled() { throw Failure.cancelled }
                try? FileManager.default.removeItem(at: dest)
                fallbackReason = why.description
                choice = VideoAudioRule.fallback
            }
        }
        guard case .wav(let depth) = choice else { throw Failure.writeFailed("no output chosen") }
        let name = VideoAudioRule.fileName(baseName: baseName, trackNumber: info.number, hash8: hash8, ext: "wav")
        let dest = folder.appendingPathComponent(name)
        do {
            var e = try await writeWAV(asset: asset, track: track, info: info, layout: layout, depth: depth,
                                       movieDuration: movieDuration, to: dest,
                                       isCancelled: isCancelled, progress: progress)
            e.fallbackReason = fallbackReason
            return e
        } catch {
            // A half-written file must never stay behind (cancel, read failure, full disk).
            try? FileManager.default.removeItem(at: dest)
            throw error
        }
    }

    // MARK: Keeping the stream

    /// A passthrough export of the track alone into an M4A, then the verification. `.failure` carries
    /// the reason for the journal.
    private static func keepStream(asset: AVURLAsset, track: AVAssetTrack, info: VideoProbe.AudioTrack,
                                   layout: Data?, to dest: URL,
                                   isCancelled: @escaping @Sendable () -> Bool) async -> Swift.Result<Extracted, KeepFailure> {
        try? FileManager.default.removeItem(at: dest)
        let composition = AVMutableComposition()
        guard let target = composition.addMutableTrack(withMediaType: .audio,
                                                       preferredTrackID: kCMPersistentTrackID_Invalid),
              let range = try? await track.load(.timeRange) else {
            return .failure(KeepFailure("could not build the extraction composition"))
        }
        do { try target.insertTimeRange(range, of: track, at: .zero) }
        catch { return .failure(KeepFailure("insert: \(error.localizedDescription)")) }
        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
            return .failure(KeepFailure("no passthrough export session"))
        }
        guard session.supportedFileTypes.contains(.m4a) else {
            return .failure(KeepFailure("the stream cannot be kept in an M4A (\(info.codec.displayName))"))
        }
        // Cancelling polls on a side task: the export call itself cannot be interrupted otherwise.
        let watcher = Task.detached {
            while !Task.isCancelled {
                if isCancelled() { session.cancelExport(); return }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        do { try await session.export(to: dest, as: .m4a) }
        catch {
            watcher.cancel()
            return .failure(KeepFailure("export: \(error.localizedDescription)"))
        }
        watcher.cancel()
        if isCancelled() { return .failure(KeepFailure("cancelled")) }

        // The verification.
        return await Task.detached(priority: .utility) { () -> Swift.Result<Extracted, KeepFailure> in
            guard let reader = EngineLikeAudioReader(url: dest) else {
                return .failure(KeepFailure("the engine's reader cannot open the extracted file"))
            }
            guard let ref = decodeReference(asset: asset, track: track, info: info, layout: layout,
                                            maxFrames: Int(verifySeconds * info.sampleRate) + 1) else {
                return .failure(KeepFailure("the source's own decode failed"))
            }
            // The track's REAL first sample, on the movie's clock. A late start hidden in an edit list does
            // not show in the track's time range, and an M4A cannot carry a leading silence: such a stream
            // would play early by that much, with every sample matching. (A WAV is padded instead.)
            guard ref.firstPTS < firstSampleTolerance else {
                return .failure(KeepFailure("the first sample is at \(String(format: "%.3f", ref.firstPTS)) s, not 0"))
            }
            guard reader.channels == ref.channels else {
                return .failure(KeepFailure("channel count differs (\(reader.channels) vs \(ref.channels))"))
            }
            guard abs(reader.sampleRate - info.sampleRate) < 0.5 else {
                return .failure(KeepFailure("sample rate differs (\(reader.sampleRate) vs \(info.sampleRate))"))
            }
            // Length: what the engine believes must equal what the source decodes to.
            if reader.lengthFrames != ref.totalFrames {
                return .failure(KeepFailure("length differs (engine \(reader.lengthFrames), source \(ref.totalFrames))"))
            }
            let mine = reader.read(maxFrames: ref.planes[0].count)
            guard mine.count == ref.channels, mine[0].count == ref.planes[0].count else {
                return .failure(KeepFailure("the engine's reader returned a short read"))
            }
            var worst: Float = 0
            for c in 0..<ref.channels {
                let a = mine[c], b = ref.planes[c]
                for i in 0..<b.count { worst = max(worst, abs(a[i] - b[i])) }
            }
            guard worst <= sampleTolerance else {
                return .failure(KeepFailure("samples differ by up to \(worst): the stream is not aligned"))
            }
            return .success(Extracted(url: dest, written: .keptStream,
                                      duration: Double(reader.lengthFrames) / reader.sampleRate,
                                      sampleRate: reader.sampleRate, channels: reader.channels,
                                      fallbackReason: nil))
        }.value
    }

    struct KeepFailure: Error, Equatable, Sendable, CustomStringConvertible {
        let description: String
        init(_ d: String) { description = d }
    }

    // MARK: Reference decode

    struct Decoded {
        var planes: [[Float]]
        var channels: Int
        /// The decode's FULL length in frames (counted past `maxFrames`).
        var totalFrames: Int64
        /// The first buffer's timestamp, seconds (what a WAV is padded at the head by).
        var firstPTS: Double
    }

    /// Decodes the first `maxFrames` frames with `AVAssetReader` and COUNTS the rest: the reference
    /// everything is compared with (the picture's clock sees this timeline). Synchronous; call from a
    /// detached task.
    static func decodeReference(asset: AVURLAsset, track: AVAssetTrack, info: VideoProbe.AudioTrack,
                                layout: Data?, maxFrames: Int) -> Decoded? {
        let settings = readerSettings(info: info, layout: layout)
        guard let reader = try? AVAssetReader(asset: asset) else { return nil }
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        out.alwaysCopiesSampleData = false
        guard reader.canAdd(out) else { return nil }
        reader.add(out)
        guard reader.startReading() else { return nil }
        let ch = max(1, info.channels)
        var planes = [[Float]](repeating: [], count: ch)
        var total: Int64 = 0
        var first = -1.0
        while let sb = out.copyNextSampleBuffer() {
            let n = CMSampleBufferGetNumSamples(sb)
            guard n > 0 else { continue }
            if first < 0 { first = CMSampleBufferGetPresentationTimeStamp(sb).seconds }
            let kept = max(0, min(n, maxFrames - planes[0].count))
            if kept > 0, !appendDeinterleaved(sb, frames: n, keep: kept, channels: ch, into: &planes) { return nil }
            total += Int64(n)
        }
        guard reader.status == .completed else { return nil }
        return Decoded(planes: planes, channels: ch, totalFrames: total, firstPTS: max(0, first))
    }

    /// The channel layout of a track with more than two channels (a reader needs it to decode them),
    /// as the bytes `AVChannelLayoutKey` takes; nil for mono and stereo.
    static func channelLayoutData(track: AVAssetTrack, channels: Int) async -> Data? {
        guard channels > 2, let fd = (try? await track.load(.formatDescriptions))?.first else { return nil }
        var size = 0
        guard let layout = CMAudioFormatDescriptionGetChannelLayout(fd, sizeOut: &size), size > 0 else { return nil }
        return Data(bytes: layout, count: size)
    }

    /// The reader's output settings: 32-bit float, interleaved, at the file's own rate and channel count.
    private static func readerSettings(info: VideoProbe.AudioTrack, layout: Data?) -> [String: Any] {
        var s: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVSampleRateKey: info.sampleRate,
            AVNumberOfChannelsKey: info.channels,
        ]
        if let layout { s[AVChannelLayoutKey] = layout }
        return s
    }

    /// Splits the interleaved float32 of a sample buffer into per-channel arrays.
    private static func appendDeinterleaved(_ sb: CMSampleBuffer, frames n: Int, keep: Int, channels ch: Int,
                                            into planes: inout [[Float]]) -> Bool {
        guard let bb = CMSampleBufferGetDataBuffer(sb) else { return false }
        var length = 0
        var pointer: UnsafeMutablePointer<CChar>?
        guard CMBlockBufferGetDataPointer(bb, atOffset: 0, lengthAtOffsetOut: nil,
                                          totalLengthOut: &length, dataPointerOut: &pointer) == kCMBlockBufferNoErr,
              let pointer, length >= n * ch * MemoryLayout<Float>.size else { return false }
        pointer.withMemoryRebound(to: Float.self, capacity: n * ch) { p in
            for c in 0..<ch {
                planes[c].reserveCapacity(planes[c].count + keep)
                for i in 0..<keep { planes[c].append(p[i * ch + c]) }
            }
        }
        return true
    }

    // MARK: Writing a WAV

    /// Decodes the whole track and writes it as a WAV of `depth`, padded so that frame 0 is t = 0 and
    /// the file spans `movieDuration` (never shorter than the audio itself).
    private static func writeWAV(asset: AVURLAsset, track: AVAssetTrack, info: VideoProbe.AudioTrack,
                                 layout: Data?, depth: VideoAudioRule.WavDepth, movieDuration: Double, to dest: URL,
                                 isCancelled: @escaping @Sendable () -> Bool,
                                 progress: @escaping @Sendable (Double) -> Void) async throws -> Extracted {
        try? FileManager.default.removeItem(at: dest)
        return try await Task.detached(priority: .utility) { () throws -> Extracted in
            let rate = info.sampleRate
            let ch = max(1, info.channels)
            guard rate > 0 else { throw Failure.readFailed("the track has no sample rate") }
            let settings = readerSettings(info: info, layout: layout)
            guard let reader = try? AVAssetReader(asset: asset) else { throw Failure.readFailed("no reader") }
            let out = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
            out.alwaysCopiesSampleData = false
            guard reader.canAdd(out) else { throw Failure.readFailed("the track cannot be read") }
            reader.add(out)
            guard reader.startReading() else {
                throw Failure.readFailed(reader.error?.localizedDescription ?? "startReading failed")
            }

            var fileSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: rate,
                AVNumberOfChannelsKey: ch,
                AVLinearPCMBitDepthKey: depth.bits,
                AVLinearPCMIsFloatKey: depth.isFloat,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ]
            if let layout { fileSettings[AVChannelLayoutKey] = layout }
            let file: AVAudioFile
            do { file = try AVAudioFile(forWriting: dest, settings: fileSettings,
                                        commonFormat: .pcmFormatFloat32, interleaved: false) }
            catch { throw Failure.writeFailed(error.localizedDescription) }
            let format = file.processingFormat

            let targetFrames = Int64((max(movieDuration, info.start + info.duration) * rate).rounded())
            var written: Int64 = 0
            let chunk = 16384

            func writeSilence(_ frames: Int64) throws {
                var left = frames
                while left > 0 {
                    let n = Int(min(Int64(chunk), left))
                    guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n)) else {
                        throw Failure.writeFailed("no buffer")
                    }
                    buf.frameLength = AVAudioFrameCount(n)
                    for c in 0..<ch { memset(buf.floatChannelData![c], 0, n * MemoryLayout<Float>.size) }
                    do { try file.write(from: buf) } catch { throw Failure.writeFailed(error.localizedDescription) }
                    left -= Int64(n)
                    written += Int64(n)
                }
            }

            while let sb = out.copyNextSampleBuffer() {
                if isCancelled() { reader.cancelReading(); throw Failure.cancelled }
                let n = CMSampleBufferGetNumSamples(sb)
                guard n > 0 else { continue }
                // Where this buffer lands on the movie's clock: silence for a gap, a trim for an overlap.
                let pts = CMSampleBufferGetPresentationTimeStamp(sb).seconds
                let at = Int64((max(0, pts) * rate).rounded())
                var skip = 0
                if at > written { try writeSilence(at - written) }
                else if at < written { skip = Int(min(Int64(n), written - at)) }
                let usable = n - skip
                guard usable > 0 else { continue }
                var planes = [[Float]](repeating: [], count: ch)
                guard appendDeinterleaved(sb, frames: n, keep: n, channels: ch, into: &planes) else {
                    throw Failure.readFailed("unreadable sample buffer")
                }
                guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(usable)) else {
                    throw Failure.writeFailed("no buffer")
                }
                buf.frameLength = AVAudioFrameCount(usable)
                for c in 0..<ch {
                    _ = planes[c].withUnsafeBufferPointer { src in
                        memcpy(buf.floatChannelData![c], src.baseAddress! + skip, usable * MemoryLayout<Float>.size)
                    }
                }
                do { try file.write(from: buf) } catch { throw Failure.writeFailed(error.localizedDescription) }
                written += Int64(usable)
                progress(min(1, Double(written) / Double(max(1, targetFrames))))
            }
            if reader.status == .failed {
                throw Failure.readFailed(reader.error?.localizedDescription ?? "read failed")
            }
            if written < targetFrames { try writeSilence(targetFrames - written) }
            progress(1)
            return Extracted(url: dest, written: .wav(depth), duration: Double(written) / rate,
                             sampleRate: rate, channels: ch, fallbackReason: nil)
        }.value
    }
}
