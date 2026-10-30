import Foundation
import AVFoundation
import CoreMedia
import AudioToolbox

// MARK: - Reading what a video file is, before anything enters the project
//
// The probe of an import (plan-video §2.3, step 1): it touches NO model, NO engine and NO project
// folder. It says whether the file is a video OBJEKAT takes (MP4 or MOV, a picture that really
// decodes) and, if so, what it holds — the picture's size and clock, and one record per audio track.
// A refusal carries the reason in structured form (the app words it, in the three languages); the
// codec is NAMED, never "not supported", and nothing is created for a refused file.
//
// `AVFoundation` only (decision of 30 October 2026: no FFmpeg). A track AVFoundation lists is not
// necessarily one it can decode (plan-video §3.2), so the picture's first frame is really decoded here.

nonisolated enum VideoProbe {

    /// The containers taken. Everything else is refused at the door, by its extension, before any
    /// read: an MKV or a WebM is not something AVFoundation can open at all.
    static let acceptedExtensions: Set<String> = ["mp4", "mov"]

    /// True for a file whose extension says MP4 or MOV (the only candidates for the video import).
    static func isVideoContainerCandidate(_ url: URL) -> Bool {
        acceptedExtensions.contains(url.pathExtension.lowercased())
    }

    /// Extensions OBJEKAT recognises as a video but refuses (named in the message). Not exhaustive:
    /// any other unknown extension is simply "not an audio or video file OBJEKAT takes".
    static let refusedVideoExtensions: Set<String> = [
        "mkv", "webm", "avi", "flv", "wmv", "mpg", "mpeg", "ts", "m2ts", "mts", "vob", "m4v", "3gp", "3g2",
        "ogv", "mxf", "dv", "rm", "divx",
    ]

    enum Refusal: Error, Equatable, Sendable {
        /// A video container OBJEKAT does not take (MKV, WebM, AVI…): the extension, lowercased.
        case unsupportedContainer(String)
        /// AVFoundation cannot open the file at all (damaged, not really an MP4/MOV, empty).
        case unreadable(String)
        /// A picture track whose codec cannot be decoded here. `codec` names it.
        case undecodableCodec(codec: String)
        /// A video file with a picture of no length or no frame.
        case emptyPicture
    }

    /// One audio track of the file.
    struct AudioTrack: Equatable, Sendable {
        /// 1-based rank among the file's audio tracks (what `_A<n>` in the extracted name says).
        var number: Int
        var trackID: Int32
        var codec: VideoAudioRule.Codec
        var sampleRate: Double
        var channels: Int
        /// The track's time range, in the movie's timeline, edit list applied.
        var start: Double
        var duration: Double
        /// Its first sample is at t = 0 (within half a sample).
        var startsAtZero: Bool
        /// Enabled for playback by default. False for a disabled track and for an ALTERNATE one the
        /// player does not select: such a track is imported MUTED (decision of 30 October 2026).
        var isDefault: Bool
        var language: String?
    }

    struct Info: Equatable, Sendable {
        var url: URL
        /// The movie's duration, seconds (the group's window).
        var movieDuration: Double
        /// The picture track's time range in the movie's timeline (usually 0 + the movie duration).
        var pictureStart: Double
        var pictureDuration: Double
        /// The DISPLAY size, the track's transform (a rotated phone video) applied.
        var pixelWidth: Int
        var pixelHeight: Int
        /// Indicative only: the real clock comes from the picture's timestamps.
        var nominalFPS: Double
        var videoCodec: String
        var audioTracks: [AudioTrack]
        /// The file's size in bytes (what relink uses to tell two homonyms apart).
        var fileSize: Int64?
        /// The file's modification date, for the identity hash of the extracted names.
        var modified: Date?
    }

    enum Outcome: Equatable, Sendable {
        /// A video OBJEKAT takes.
        case video(Info)
        /// A readable MP4/MOV with no picture: an audio file, laid down by the ordinary audio path.
        case audioOnly
        case refused(Refusal)
    }

    // MARK: The probe

    /// Reads `url`. Never throws: every failure is an `Outcome.refused`. Decodes the picture's first
    /// frame, so it takes tens of milliseconds, off the main thread.
    nonisolated static func probe(_ url: URL) async -> Outcome {
        let ext = url.pathExtension.lowercased()
        guard acceptedExtensions.contains(ext) else {
            return .refused(.unsupportedContainer(ext))
        }
        let asset = AVURLAsset(url: url)
        let duration: CMTime
        let videoTracks: [AVAssetTrack]
        let audioTracks: [AVAssetTrack]
        do {
            guard try await asset.load(.isReadable) else { return .refused(.unreadable("not readable")) }
            duration = try await asset.load(.duration)
            videoTracks = try await asset.loadTracks(withMediaType: .video)
            audioTracks = try await asset.loadTracks(withMediaType: .audio)
        } catch {
            return .refused(.unreadable(error.localizedDescription))
        }
        let movieSeconds = duration.isNumeric ? duration.seconds : 0

        // The first ENABLED picture track (V1 shows one picture); a file whose picture tracks are all
        // disabled has no picture to show.
        var pictureTrack: AVAssetTrack?
        for t in videoTracks where (try? await t.load(.isEnabled)) ?? true { pictureTrack = t; break }
        guard let vt = pictureTrack else {
            return audioTracks.isEmpty ? .refused(.unreadable("no track")) : .audioOnly
        }

        let range: CMTimeRange
        let natural: CGSize
        let transform: CGAffineTransform
        let fps: Float
        let formats: [CMFormatDescription]
        do {
            range = try await vt.load(.timeRange)
            natural = try await vt.load(.naturalSize)
            transform = try await vt.load(.preferredTransform)
            fps = try await vt.load(.nominalFrameRate)
            formats = try await vt.load(.formatDescriptions)
        } catch {
            return .refused(.unreadable(error.localizedDescription))
        }
        let codecName = formats.first.map { videoCodecName(CMFormatDescriptionGetMediaSubType($0)) } ?? "?"
        guard range.duration.isNumeric, range.duration.seconds > 0, natural.width > 0, natural.height > 0 else {
            return .refused(.emptyPicture)
        }
        // Does the picture really decode? One frame, through the same reader family the player uses.
        guard await firstFrameDecodes(asset: asset, track: vt) else {
            return .refused(.undecodableCodec(codec: codecName))
        }

        let displayed = natural.applying(transform)
        let infos = await audioTrackInfos(audioTracks, asset: asset)
        var size: Int64?
        var modified: Date?
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) {
            size = (attrs[.size] as? NSNumber)?.int64Value
            modified = attrs[.modificationDate] as? Date
        }
        return .video(Info(
            url: url,
            movieDuration: max(movieSeconds, range.start.seconds + range.duration.seconds),
            pictureStart: range.start.isNumeric ? max(0, range.start.seconds) : 0,
            pictureDuration: range.duration.seconds,
            pixelWidth: Int(abs(displayed.width).rounded()),
            pixelHeight: Int(abs(displayed.height).rounded()),
            nominalFPS: Double(fps),
            videoCodec: codecName,
            audioTracks: infos,
            fileSize: size,
            modified: modified))
    }

    // MARK: Decoding one frame

    /// True when the picture track yields a first decoded frame.
    nonisolated static func firstFrameDecodes(asset: AVAsset, track: AVAssetTrack) async -> Bool {
        await Task.detached(priority: .utility) { () -> Bool in
            guard let reader = try? AVAssetReader(asset: asset) else { return false }
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            ])
            output.alwaysCopiesSampleData = false
            guard reader.canAdd(output) else { return false }
            reader.add(output)
            guard reader.startReading() else { return false }
            let ok = output.copyNextSampleBuffer() != nil
            reader.cancelReading()
            return ok
        }.value
    }

    // MARK: Audio tracks

    nonisolated static func audioTrackInfos(_ tracks: [AVAssetTrack], asset: AVAsset) async -> [AudioTrack] {
        // Enabled FOR PLAYBACK: the player item resolves alternate groups and disabled tracks the way a
        // viewer would hear them. Read through an item, not the asset, for that reason.
        let playable = await playbackEnabledTrackIDs(asset: asset)
        var out: [AudioTrack] = []
        for (i, t) in tracks.enumerated() {
            let formats = (try? await t.load(.formatDescriptions)) ?? []
            let range = (try? await t.load(.timeRange)) ?? .zero
            let enabled = (try? await t.load(.isEnabled)) ?? true
            let lang = try? await t.load(.extendedLanguageTag)
            guard let fd = formats.first else { continue }
            let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fd)?.pointee
            let rate = asbd?.mSampleRate ?? 0
            let start = range.start.isNumeric ? range.start.seconds : 0
            let isDefault = enabled && (playable?.contains(t.trackID) ?? true)
            out.append(AudioTrack(
                number: i + 1,
                trackID: t.trackID,
                codec: audioCodec(of: fd),
                sampleRate: rate,
                channels: Int(asbd?.mChannelsPerFrame ?? 0),
                start: start,
                duration: range.duration.isNumeric ? range.duration.seconds : 0,
                startsAtZero: rate > 0 ? abs(start) < 0.5 / rate : abs(start) < 1e-6,
                isDefault: isDefault,
                language: lang))
        }
        return out
    }

    /// The track ids a player enables by default, or nil when that cannot be read (then `isEnabled`
    /// alone decides). Waits for the item to be ready, bounded.
    @MainActor static func playbackEnabledTrackIDs(asset: AVAsset) async -> Set<Int32>? {
        let item = AVPlayerItem(asset: asset)
        let deadline = ContinuousClock.now + .seconds(3)
        while item.status == .unknown, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        guard item.status == .readyToPlay else { return nil }
        var ids = Set<Int32>()
        for t in item.tracks where t.isEnabled {
            if let id = t.assetTrack?.trackID { ids.insert(id) }
        }
        return ids
    }

    // MARK: Codec names

    nonisolated static func audioCodec(of fd: CMFormatDescription) -> VideoAudioRule.Codec {
        let sub = CMFormatDescriptionGetMediaSubType(fd)
        guard let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fd)?.pointee else {
            return .other(fourCC(sub))
        }
        switch asbd.mFormatID {
        case kAudioFormatMPEG4AAC, kAudioFormatMPEG4AAC_HE, kAudioFormatMPEG4AAC_HE_V2,
             kAudioFormatMPEG4AAC_LD, kAudioFormatMPEG4AAC_ELD, kAudioFormatMPEG4AAC_ELD_SBR,
             kAudioFormatMPEG4AAC_ELD_V2, kAudioFormatMPEG4AAC_Spatial:
            return .aac
        case kAudioFormatAC3, kAudioFormatAES3: return asbd.mFormatID == kAudioFormatAC3 ? .ac3 : .other("AES3")
        case kAudioFormatEnhancedAC3: return .eac3
        case kAudioFormatMPEGLayer3: return .mp3
        case kAudioFormatOpus: return .opus
        case kAudioFormatLinearPCM:
            let isFloat = asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0
            return .pcm(bits: Int(asbd.mBitsPerChannel), isFloat: isFloat)
        default:
            return .other(fourCC(asbd.mFormatID))
        }
    }

    /// A readable name for a picture codec's four-character code.
    nonisolated static func videoCodecName(_ sub: FourCharCode) -> String {
        switch sub {
        case kCMVideoCodecType_H264: return "H.264"
        case kCMVideoCodecType_HEVC, kCMVideoCodecType_HEVCWithAlpha: return "HEVC"
        case kCMVideoCodecType_AppleProRes422, kCMVideoCodecType_AppleProRes422HQ,
             kCMVideoCodecType_AppleProRes422LT, kCMVideoCodecType_AppleProRes422Proxy,
             kCMVideoCodecType_AppleProRes4444, kCMVideoCodecType_AppleProRes4444XQ:
            return "ProRes"
        case kCMVideoCodecType_AppleProResRAW, kCMVideoCodecType_AppleProResRAWHQ: return "ProRes RAW"
        case kCMVideoCodecType_JPEG, kCMVideoCodecType_JPEG_OpenDML: return "MJPEG"
        case kCMVideoCodecType_MPEG4Video: return "MPEG-4 Part 2"
        case kCMVideoCodecType_MPEG2Video: return "MPEG-2"
        case kCMVideoCodecType_MPEG1Video: return "MPEG-1"
        case kCMVideoCodecType_DolbyVisionHEVC: return "Dolby Vision HEVC"
        case kCMVideoCodecType_AV1: return "AV1"
        case kCMVideoCodecType_VP9: return "VP9"
        case kCMVideoCodecType_DVCNTSC, kCMVideoCodecType_DVCPAL, kCMVideoCodecType_DVCProPAL,
             kCMVideoCodecType_DVCPro50NTSC, kCMVideoCodecType_DVCPro50PAL, kCMVideoCodecType_DVCPROHD720p60,
             kCMVideoCodecType_DVCPROHD720p50, kCMVideoCodecType_DVCPROHD1080i60,
             kCMVideoCodecType_DVCPROHD1080i50, kCMVideoCodecType_DVCPROHD1080p30,
             kCMVideoCodecType_DVCPROHD1080p25:
            return "DV"
        default: return fourCC(sub)
        }
    }

    nonisolated static func fourCC(_ v: UInt32) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((v >> UInt32($0)) & 0xff) }
        let printable = bytes.allSatisfy { $0 >= 32 && $0 < 127 }
        return printable ? String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespaces)
                         : String(format: "0x%08x", v)
    }
}
