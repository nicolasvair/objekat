// Video fixtures that check themselves (plan-video §9.1) — a library file, compiled WITH the test that
// needs it (`test_video_audio_align.swift`, later the scenarios' own generator), no dependency but
// AVFoundation.
//
// Every picture frame carries its own NUMBER as a 16-bit barcode (black / white 8-pixel blocks, top
// left), so a test reads the exact frame index back with no human eye; every audio track carries ONE
// impulse at a known instant, so a test reads the exact sample back. What a file holds is entirely
// described by a `VideoFixtureSpec`; nothing is random.

import Foundation
import AVFoundation
import CoreMedia
import AudioToolbox

struct VideoFixtureSpec {
    struct Audio {
        enum Kind { case aac, pcm16, pcm24, pcm32f }
        var kind: Kind = .aac
        var sampleRate: Double = 48000
        var channels: Int = 2
        /// The impulse's instant on the MOVIE's clock, seconds.
        var impulseSeconds: Double = 2.0
        /// The movie-clock instant of the track's first sample (an audio that starts after the picture).
        var startSeconds: Double = 0
        /// Length of the audio itself; nil = up to the end of the movie.
        var seconds: Double? = nil
        /// Written as a DISABLED track (`tkhd` flag clear).
        var enabled: Bool = true
    }
    var url: URL
    var container: AVFileType = .mp4
    var fps: Int = 24
    var seconds: Double = 4
    var width = 320
    var height = 180
    var codec: AVVideoCodecType = .h264
    var bFrames = true
    var audio: [Audio] = []
}

enum VideoFixtures {

    enum FixtureError: Error { case writer(String) }

    static func barcodeFrame(index: Int, width: Int, height: Int, pool: CVPixelBufferPool) -> CVPixelBuffer? {
        var pb: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
        guard let pb else { return nil }
        CVPixelBufferLockBaseAddress(pb, [])
        let base = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self)
        let bpr = CVPixelBufferGetBytesPerRow(pb)
        for y in 0..<height {
            for x in 0..<width {
                var v: UInt8 = 128
                if y < 16 && x < 16 * 8 { v = (index >> (x / 8)) & 1 == 1 ? 255 : 0 }
                let p = base + y * bpr + x * 4
                p[0] = v; p[1] = v; p[2] = v; p[3] = 255
            }
        }
        CVPixelBufferUnlockBaseAddress(pb, [])
        return pb
    }

    private final class Feed {
        let input: AVAssetWriterInput
        let spec: VideoFixtureSpec.Audio
        let total: Int          // frames of audio to write
        let startFrame: Int     // movie-clock frame of the first sample
        var pos = 0
        var done = false
        var desc: CMAudioFormatDescription?
        init(input: AVAssetWriterInput, spec: VideoFixtureSpec.Audio, movieSeconds: Double) {
            self.input = input; self.spec = spec
            startFrame = Int((spec.startSeconds * spec.sampleRate).rounded())
            let len = spec.seconds ?? (movieSeconds - spec.startSeconds)
            total = Int((len * spec.sampleRate).rounded())
            var asbd = AudioStreamBasicDescription(
                mSampleRate: spec.sampleRate, mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                mBytesPerPacket: UInt32(4 * spec.channels), mFramesPerPacket: 1,
                mBytesPerFrame: UInt32(4 * spec.channels), mChannelsPerFrame: UInt32(spec.channels),
                mBitsPerChannel: 32, mReserved: 0)
            CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil,
                                           magicCookieSize: 0, magicCookie: nil, extensions: nil,
                                           formatDescriptionOut: &desc)
        }
    }

    static func make(_ s: VideoFixtureSpec) async throws {
        try? FileManager.default.removeItem(at: s.url)
        let w = try AVAssetWriter(outputURL: s.url, fileType: s.container)
        var comp: [String: Any] = [AVVideoAllowFrameReorderingKey: s.bFrames, AVVideoMaxKeyFrameIntervalKey: 48]
        if s.codec == .h264 && s.bFrames { comp[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel }
        let vi = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: s.codec, AVVideoWidthKey: s.width, AVVideoHeightKey: s.height,
            AVVideoCompressionPropertiesKey: comp])
        vi.expectsMediaDataInRealTime = false
        let ad = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: vi, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: s.width, kCVPixelBufferHeightKey as String: s.height])
        w.add(vi)

        var feeds: [Feed] = []
        for a in s.audio {
            var settings: [String: Any]
            switch a.kind {
            case .aac:
                settings = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: a.sampleRate,
                            AVNumberOfChannelsKey: a.channels, AVEncoderBitRateKey: 64000 * a.channels]
            case .pcm16, .pcm24, .pcm32f:
                let bits = a.kind == .pcm16 ? 16 : (a.kind == .pcm24 ? 24 : 32)
                settings = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: a.sampleRate,
                            AVNumberOfChannelsKey: a.channels, AVLinearPCMBitDepthKey: bits,
                            AVLinearPCMIsFloatKey: a.kind == .pcm32f, AVLinearPCMIsBigEndianKey: false,
                            AVLinearPCMIsNonInterleaved: false]
            }
            let ai = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
            ai.expectsMediaDataInRealTime = false
            ai.marksOutputTrackAsEnabled = a.enabled
            w.add(ai)
            feeds.append(Feed(input: ai, spec: a, movieSeconds: s.seconds))
        }
        guard w.startWriting() else { throw FixtureError.writer(w.error?.localizedDescription ?? "startWriting") }
        w.startSession(atSourceTime: .zero)

        let frames = Int((s.seconds * Double(s.fps)).rounded())
        var vf = 0
        let chunk = 4800
        while vf < frames || feeds.contains(where: { !$0.done }) {
            var progressed = false
            for f in feeds where !f.done && f.input.isReadyForMoreMediaData {
                if f.pos >= f.total { f.input.markAsFinished(); f.done = true; continue }
                let n = min(chunk, f.total - f.pos)
                let ch = f.spec.channels
                var samples = [Float](repeating: 0, count: n * ch)
                let impulseFrame = Int((f.spec.impulseSeconds * f.spec.sampleRate).rounded()) - f.startFrame
                if impulseFrame >= f.pos && impulseFrame < f.pos + n {
                    for c in 0..<ch { samples[(impulseFrame - f.pos) * ch + c] = 0.9 }
                }
                let bytes = n * 4 * ch
                var bb: CMBlockBuffer?
                CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes,
                                                   blockAllocator: nil, customBlockSource: nil, offsetToData: 0,
                                                   dataLength: bytes, flags: 0, blockBufferOut: &bb)
                samples.withUnsafeBytes { _ = CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: bb!, offsetIntoDestination: 0, dataLength: bytes) }
                var sb: CMSampleBuffer?
                let pts = CMTime(value: CMTimeValue(f.startFrame + f.pos), timescale: CMTimeScale(f.spec.sampleRate))
                CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: bb!, formatDescription: f.desc!,
                                                                     sampleCount: n, presentationTimeStamp: pts,
                                                                     packetDescriptions: nil, sampleBufferOut: &sb)
                f.input.append(sb!)
                f.pos += n
                progressed = true
            }
            if vf < frames, vi.isReadyForMoreMediaData, let pool = ad.pixelBufferPool,
               let pb = barcodeFrame(index: vf, width: s.width, height: s.height, pool: pool) {
                ad.append(pb, withPresentationTime: CMTime(value: CMTimeValue(vf), timescale: CMTimeScale(s.fps)))
                vf += 1
                progressed = true
                if vf >= frames { vi.markAsFinished() }
            }
            if !progressed { try await Task.sleep(nanoseconds: 200_000) }
        }
        await w.finishWriting()
        if w.status != .completed { throw FixtureError.writer(w.error?.localizedDescription ?? "not completed") }
    }

    /// The frame index the barcode of the picture shown at `time` says (exact decode, no tolerance).
    static func frameIndex(url: URL, at time: CMTime) async throws -> Int {
        let asset = AVURLAsset(url: url)
        let g = AVAssetImageGenerator(asset: asset)
        g.requestedTimeToleranceBefore = .zero
        g.requestedTimeToleranceAfter = .zero
        g.appliesPreferredTrackTransform = true
        let (img, _) = try await g.image(at: time)
        let w = img.width, h = img.height
        var px = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        var idx = 0
        for bit in 0..<16 where px[(8 * w + bit * 8 + 4) * 4] > 128 { idx |= 1 << bit }
        return idx
    }
}
