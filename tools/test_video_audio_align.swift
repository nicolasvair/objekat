// Video import, step 1 — the audio of a movie lands on the sample where the picture says it does
// (plan-video §2.4, §9.1; V0 §9). Generates tiny MP4/MOV files that check themselves (a barcode in
// every frame, one audio impulse at a known instant), runs the real probe + extraction, then reads
// the result THROUGH THE ENGINE'S DOOR (`EngineLikeAudioReader`, the Swift replica of juce's
// CoreAudioReader) and asserts the impulse is where it was written.
//
//     cd tools && swiftc -parse-as-library \
//         ../objekat/Video/VideoAudioRule.swift ../objekat/Video/EngineLikeAudioReader.swift \
//         ../objekat/Video/VideoProbe.swift ../objekat/Video/VideoAudioExtract.swift ../objekat/Shared/Compat/CompatClock.swift \
//         make_video_fixtures.swift test_video_audio_align.swift -o /tmp/valign && /tmp/valign
//
// Exit: 0 if every assertion passes, 1 otherwise. Files live in a temporary folder, a few hundred
// kilobytes in all, deleted at the end.
//
// What it does NOT prove: the read goes through a Swift replica of the JUCE reader, not JUCE itself
// and not Tracktion's proxy path; AAC comes from one encoder (Apple's); AC-3 / MP3 / Opus have no
// encoder here, so their keep-or-fall-back path is only the generic one.

import Foundation
import AVFoundation

var fails: [String] = []
var total = 0

func check(_ label: String, _ ok: Bool, _ detail: String = "") {
    total += 1
    if ok { print("ok    " + label) }
    else { fails.append(label); print("FAIL  \(label)  \(detail)") }
}

/// Index of the largest |sample| over all channels of the first `maxFrames` frames.
func peakIndex(_ planes: [[Float]]) -> (index: Int, value: Float) {
    var best = (0, Float(0))
    for p in planes { for (i, v) in p.enumerated() where abs(v) > best.1 { best = (i, abs(v)) } }
    return best
}

func extractAll(_ url: URL, folder: URL) async -> (VideoProbe.Info, [VideoAudioExtract.Extracted])? {
    guard case .video(let info) = await VideoProbe.probe(url) else { return nil }
    let asset = AVURLAsset(url: url)
    guard let tracks = try? await asset.loadTracks(withMediaType: .audio) else { return nil }
    var out: [VideoAudioExtract.Extracted] = []
    for (i, t) in tracks.enumerated() {
        let tinfo = info.audioTracks[i]
        do {
            let e = try await VideoAudioExtract.extract(
                asset: asset, track: t, info: tinfo, baseName: "fixture", hash8: "deadbeef",
                movieDuration: info.movieDuration, folder: folder, isCancelled: { false })
            out.append(e)
        } catch { print("      extract threw: \(error)"); return nil }
    }
    return (info, out)
}

@main
enum VideoAudioAlignTest {
  static func main() async {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("objekat-video-test-\(getpid())")
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let out = root.appendingPathComponent("samples-video")
    try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

    func make(_ name: String, _ ext: String, _ spec: (inout VideoFixtureSpec) -> Void) async -> URL? {
        var s = VideoFixtureSpec(url: root.appendingPathComponent("\(name).\(ext)"))
        s.container = ext == "mov" ? .mov : .mp4
        spec(&s)
        do { try await VideoFixtures.make(s); return s.url }
        catch { check("fixture \(name).\(ext) generated", false, "\(error)"); return nil }
    }

    // MARK: 1. AAC in an MP4 with B-frames: the M4A is kept, and aligned
    if let url = await make("aac_bframes", "mp4", { s in
        s.bFrames = true
        s.audio = [.init(kind: .aac, sampleRate: 48000, channels: 2, impulseSeconds: 2.0)]
    }), let (info, ex) = await extractAll(url, folder: out), ex.count == 1 {
        let e = ex[0]
        check("AAC/MP4: probe sees one picture of 320x180 and one audio track",
              info.pixelWidth == 320 && info.pixelHeight == 180 && info.audioTracks.count == 1)
        check("AAC/MP4: codec read as AAC, starts at zero, default track",
              info.audioTracks[0].codec == .aac && info.audioTracks[0].startsAtZero && info.audioTracks[0].isDefault)
        check("AAC/MP4: nominal fps ~24", abs(info.nominalFPS - 24) < 0.5, "\(info.nominalFPS)")
        check("AAC/MP4: the stream is KEPT (m4a)", e.written == .keptStream && e.url.pathExtension == "m4a",
              "\(e.written) \(e.fallbackReason ?? "")")
        if let r = EngineLikeAudioReader(url: e.url) {
            let planes = r.read(maxFrames: Int(3 * r.sampleRate))
            let p = peakIndex(planes)
            check("AAC/MP4: impulse at 2.000 s through the engine's door (+-1 sample)",
                  abs(p.index - 96000) <= 1 && p.value > 0.3, "index \(p.index) value \(p.value)")
            check("AAC/MP4: engine length equals the movie's (+-1 frame of 1024)",
                  abs(Double(r.lengthFrames) / r.sampleRate - info.movieDuration) < 1024.0 / 48000 + 1e-3,
                  "\(Double(r.lengthFrames) / r.sampleRate) vs \(info.movieDuration)")
        } else { check("AAC/MP4: engine door opens the m4a", false) }
        // Picture: the frame shown at 2.000 s is #48, the first frame is #0 at t = 0.
        if let f48 = try? await VideoFixtures.frameIndex(url: url, at: CMTime(seconds: 2.0, preferredTimescale: 48000)),
           let f0 = try? await VideoFixtures.frameIndex(url: url, at: .zero) {
            check("AAC/MP4 B-frames: picture frame 48 at 2.000 s", f48 == 48, "got \(f48)")
            check("AAC/MP4 B-frames: picture frame 0 at t = 0", f0 == 0, "got \(f0)")
        } else { check("AAC/MP4: barcode readable", false) }
        let asset = AVURLAsset(url: url)
        if let vt = try? await asset.loadTracks(withMediaType: .video).first,
           let r = try? await vt.load(.timeRange) {
            check("AAC/MP4 B-frames: the picture's range starts at 0 (reordering delay hidden by the edit list)",
                  abs(r.start.seconds) < 1e-6, "\(r.start.seconds)")
        }
    } else { check("AAC/MP4 case ran", false) }

    // MARK: 2. AAC mono 44.1 kHz in a MOV
    if let url = await make("aac_mono_mov", "mov", { s in
        s.bFrames = false
        s.audio = [.init(kind: .aac, sampleRate: 44100, channels: 1, impulseSeconds: 1.5)]
    }), let (_, ex) = await extractAll(url, folder: out), ex.count == 1 {
        let e = ex[0]
        check("AAC mono 44.1 / MOV: kept", e.written == .keptStream, "\(e.written) \(e.fallbackReason ?? "")")
        if let r = EngineLikeAudioReader(url: e.url) {
            let p = peakIndex(r.read(maxFrames: Int(3 * r.sampleRate)))
            check("AAC mono 44.1 / MOV: impulse at 1.500 s (+-1 sample)", abs(p.index - 66150) <= 1, "index \(p.index)")
            check("AAC mono 44.1 / MOV: one channel at 44.1 kHz", r.channels == 1 && abs(r.sampleRate - 44100) < 0.5)
        } else { check("AAC mono / MOV: engine door opens the file", false) }
    } else { check("AAC mono / MOV case ran", false) }

    // MARK: 3. PCM in a MOV -> WAV at the PCM's depth, padded to the movie
    for (kind, depth, label) in [(VideoFixtureSpec.Audio.Kind.pcm16, VideoAudioRule.WavDepth.int16, "PCM16"),
                                 (.pcm24, .int24, "PCM24"), (.pcm32f, .float32, "PCM32f")] {
        if let url = await make("pcm_\(label)", "mov", { s in
            s.bFrames = false
            s.audio = [.init(kind: kind, sampleRate: 48000, channels: 2, impulseSeconds: 2.0)]
        }), let (info, ex) = await extractAll(url, folder: out), ex.count == 1 {
            let e = ex[0]
            check("\(label): written as a WAV of the same depth", e.written == .wav(depth) && e.url.pathExtension == "wav",
                  "\(e.written)")
            if let r = EngineLikeAudioReader(url: e.url) {
                let p = peakIndex(r.read(maxFrames: Int(3 * r.sampleRate)))
                check("\(label): impulse at 2.000 s EXACTLY", p.index == 96000, "index \(p.index)")
                check("\(label): WAV spans the movie (+-1 frame)",
                      abs(r.lengthFrames - Int64((info.movieDuration * 48000).rounded())) <= 1,
                      "\(r.lengthFrames) vs \(info.movieDuration * 48000)")
            } else { check("\(label): engine door opens the WAV", false) }
        } else { check("\(label) case ran", false) }
    }

    // MARK: 4. Late-start audio -> padded 16-bit WAV, still exact
    if let url = await make("aac_late", "mov", { s in
        s.bFrames = false
        s.audio = [.init(kind: .aac, sampleRate: 48000, channels: 2, impulseSeconds: 2.0, startSeconds: 1.0, seconds: 2.0)]
    }), let (info, ex) = await extractAll(url, folder: out), ex.count == 1 {
        let e = ex[0]
        check("late AAC: falls back on a 16-bit WAV", e.written == .wav(.int16), "\(e.written)")
        print("      late AAC: probe start \(info.audioTracks[0].start), fallback reason: \(e.fallbackReason ?? "none")")
        if let r = EngineLikeAudioReader(url: e.url) {
            let p = peakIndex(r.read(maxFrames: Int(3 * r.sampleRate)))
            check("late AAC: impulse at 2.000 s after padding (+-1 sample)", abs(p.index - 96000) <= 1, "index \(p.index)")
            check("late AAC: WAV spans the movie", abs(Double(r.lengthFrames) / 48000 - info.movieDuration) < 1e-3)
        } else { check("late AAC: engine door opens the WAV", false) }
    } else { check("late AAC case ran", false) }

    // MARK: 5. Short audio (ends before the picture) -> WAV padded at the tail
    if let url = await make("pcm_short", "mov", { s in
        s.bFrames = false
        s.audio = [.init(kind: .pcm16, sampleRate: 48000, channels: 1, impulseSeconds: 1.0, startSeconds: 0, seconds: 2.0)]
    }), let (info, ex) = await extractAll(url, folder: out), ex.count == 1 {
        if let r = EngineLikeAudioReader(url: ex[0].url) {
            check("short PCM: WAV padded to the movie's length", abs(Double(r.lengthFrames) / 48000 - info.movieDuration) < 1e-3,
                  "\(Double(r.lengthFrames) / 48000) vs \(info.movieDuration)")
            check("short PCM: impulse at 1.000 s", peakIndex(r.read(maxFrames: 96000)).index == 48000)
        } else { check("short PCM: engine door opens the WAV", false) }
    } else { check("short PCM case ran", false) }

    // MARK: 6. Two audio tracks, the second DISABLED -> two files, the second not a default track
    if let url = await make("two_tracks", "mov", { s in
        s.bFrames = false
        s.audio = [.init(kind: .aac, impulseSeconds: 1.0),
                   .init(kind: .pcm16, impulseSeconds: 3.0, enabled: false)]
    }), let (info, ex) = await extractAll(url, folder: out) {
        check("two tracks: both extracted", ex.count == 2 && info.audioTracks.count == 2, "\(ex.count)")
        if info.audioTracks.count == 2 {
            check("two tracks: the first is a default track, the second (disabled) is not",
                  info.audioTracks[0].isDefault && !info.audioTracks[1].isDefault,
                  "\(info.audioTracks.map { $0.isDefault })")
            check("two tracks: ranks 1 and 2", info.audioTracks[0].number == 1 && info.audioTracks[1].number == 2)
        }
        if ex.count == 2, let r0 = EngineLikeAudioReader(url: ex[0].url), let r1 = EngineLikeAudioReader(url: ex[1].url) {
            check("two tracks: each impulse where its own track wrote it",
                  abs(peakIndex(r0.read(maxFrames: 150000)).index - 48000) <= 1
                  && peakIndex(r1.read(maxFrames: 150000)).index == 144000)
            check("two tracks: distinct file names", ex[0].url != ex[1].url && ex[0].url.lastPathComponent.contains("_A1_")
                  && ex[1].url.lastPathComponent.contains("_A2_"))
        }
    } else { check("two-tracks case ran", false) }

    // MARK: 7. No audio at all
    if let url = await make("silent", "mp4", { s in s.audio = [] }),
       case .video(let info) = await VideoProbe.probe(url) {
        check("no audio: a picture, no audio tracks", info.audioTracks.isEmpty && info.pixelWidth == 320)
    } else { check("no-audio case ran", false) }

    // MARK: 8. Refusals: container, bogus content, never a ghost
    let mkv = root.appendingPathComponent("clip.mkv")
    try? Data("not a movie".utf8).write(to: mkv)
    if case .refused(.unsupportedContainer(let ext)) = await VideoProbe.probe(mkv) {
        check("MKV refused, container named", ext == "mkv")
    } else { check("MKV refused, container named", false) }
    let avi = root.appendingPathComponent("clip.avi")
    try? Data("RIFF....AVI ".utf8).write(to: avi)
    if case .refused(.unsupportedContainer(let ext)) = await VideoProbe.probe(avi) {
        check("AVI refused, container named", ext == "avi")
    } else { check("AVI refused, container named", false) }
    let fake = root.appendingPathComponent("fake.mp4")
    try? Data("this is not an mp4 at all, just text".utf8).write(to: fake)
    if case .refused(.unreadable) = await VideoProbe.probe(fake) { check("a bogus .mp4 is refused as unreadable", true) }
    else { check("a bogus .mp4 is refused as unreadable", false) }
    let missing = root.appendingPathComponent("nothing.mp4")
    if case .refused = await VideoProbe.probe(missing) { check("a missing file is refused", true) }
    else { check("a missing file is refused", false) }
    // Audio-only M4A with an accepted extension is not a video.
    if let wavURL = out.appendingPathComponent("x").deletingLastPathComponent() as URL?,
       let anyWav = try? FileManager.default.contentsOfDirectory(at: wavURL, includingPropertiesForKeys: nil)
        .first(where: { $0.pathExtension == "wav" }) {
        let asMov = root.appendingPathComponent("audio_only.mov")
        try? FileManager.default.copyItem(at: anyWav, to: asMov)
        let o = await VideoProbe.probe(asMov)
        var refused = false
        if case .refused = o { refused = true }
        if case .audioOnly = o { refused = true }
        check("a WAV renamed .mov is not imported as a video", refused)
    }

    // MARK: 9. Cancellation leaves nothing behind
    if let url = await make("cancel", "mov", { s in
        s.bFrames = false
        s.audio = [.init(kind: .pcm16, impulseSeconds: 1.0)]
    }), case .video(let info) = await VideoProbe.probe(url) {
        let asset = AVURLAsset(url: url)
        if let t = try? await asset.loadTracks(withMediaType: .audio).first {
            let cdir = root.appendingPathComponent("cancel-out")
            try? FileManager.default.createDirectory(at: cdir, withIntermediateDirectories: true)
            do {
                _ = try await VideoAudioExtract.extract(asset: asset, track: t, info: info.audioTracks[0], baseName: "c",
                                                        hash8: "00000000", movieDuration: info.movieDuration,
                                                        folder: cdir, isCancelled: { true })
                check("cancelled extraction throws", false)
            } catch let f as VideoAudioExtract.Failure {
                let left = (try? FileManager.default.contentsOfDirectory(atPath: cdir.path)) ?? ["?"]
                check("cancelled extraction throws .cancelled and leaves no file", f == .cancelled && left.isEmpty, "\(f) \(left)")
            } catch { check("cancelled extraction throws .cancelled", false, "\(error)") }
        }
    }

    print("\n\(total - fails.count)/\(total) passed")
    if !fails.isEmpty {
        print("FAILURES:")
        for f in fails { print(" - \(f)") }
        exit(1)
    }
  }
}
