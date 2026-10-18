// WAV → FLAC converter (`Shared/FlacConverter.swift`): the lossless rule, asserted with no screen.
// The test writes its own WAVs (CoreAudio), converts, reads back and compares.
//
//     swiftc -parse-as-library ../objekat/Shared/FlacConverter.swift test_flac_converter.swift \
//         -o /tmp/flacconv && /tmp/flacconv
//
// Exit: 0 if every assertion passes, 1 otherwise.

import Foundation
import AVFoundation

var fails: [String] = []
var total = 0
func check(_ label: String, _ ok: Bool, _ detail: String = "") {
    total += 1
    if ok { print("ok    " + label) } else { fails.append(label); print("FAIL  \(label)  \(detail)") }
}

/// A WAV of `seconds` of a deterministic signal, `channels` channels, integer `bits` or float.
func writeWav(_ url: URL, channels: Int, rate: Double, seconds: Double, bits: Int, float: Bool,
              amplitude: Float, impulse: Float? = nil) throws {
    let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate,
                                   AVNumberOfChannelsKey: channels, AVLinearPCMBitDepthKey: bits,
                                   AVLinearPCMIsFloatKey: float, AVLinearPCMIsBigEndianKey: false]
    let file = try AVAudioFile(forWriting: url, settings: settings,
                               commonFormat: .pcmFormatFloat32, interleaved: false)
    let frames = AVAudioFrameCount(rate * seconds)
    let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames)!
    buf.frameLength = frames
    var seed: UInt32 = 12345
    for c in 0..<channels {
        for i in 0..<Int(frames) {
            seed = seed &* 1664525 &+ 1013904223
            let noise = (Float(seed >> 8) / Float(1 << 24) - 0.5) * 0.2
            let tone = sinf(Float(i) * 0.05 * Float(c + 1))
            buf.floatChannelData![c][i] = amplitude * (0.8 * tone + noise)
        }
    }
    if let impulse { buf.floatChannelData![0][1000] = impulse }
    try file.write(from: buf)
}

/// The source bit depth a FLAC declares, as `afinfo` prints it ("source bit depth: I16").
func declaredDepth(_ url: URL) -> Int? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/afinfo")
    p.arguments = [url.path]
    let pipe = Pipe()
    p.standardOutput = pipe
    guard (try? p.run()) != nil else { return nil }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    for line in (String(data: data, encoding: .utf8) ?? "").split(separator: "\n") where line.contains("source bit depth") {
        let digits = line.split(separator: ":").last.map { $0.filter(\.isNumber) } ?? ""
        return Int(digits)
    }
    return nil
}

func isKeep(_ plan: FlacConverter.Plan, _ match: (FlacConverter.KeepReason) -> Bool) -> Bool {
    if case .keep(let r) = plan { return match(r) }
    return false
}

@main
enum FlacConverterTest {
  static func main() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("objk-flac-\(getpid())")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let fm = FileManager.default

    // MARK: policy (pure)
    let i24 = FlacConverter.SourceInfo(channels: 2, sampleRate: 48000, frames: 10, kind: .integer(bits: 24))
    check("policy: int24 → 24", FlacConverter.archivePolicy(i24, peak: nil) == .convert(bits: 24))
    var i16 = i24; i16.kind = .integer(bits: 16)
    check("policy: int16 → 16", FlacConverter.archivePolicy(i16, peak: nil) == .convert(bits: 16))
    var i32 = i24; i32.kind = .integer(bits: 32)
    check("policy: int32 stays", isKeep(FlacConverter.archivePolicy(i32, peak: nil)) { if case .unsupportedDepth = $0 { return true }; return false })
    var i8 = i24; i8.kind = .integer(bits: 8)
    check("policy: int8 stays", isKeep(FlacConverter.archivePolicy(i8, peak: nil)) { if case .unsupportedDepth = $0 { return true }; return false })
    var fl = i24; fl.kind = .float
    check("policy: float peak 0.5 → 24", FlacConverter.archivePolicy(fl, peak: 0.5) == .convert(bits: 24))
    check("policy: float peak 1.0 → 24", FlacConverter.archivePolicy(fl, peak: 1.0) == .convert(bits: 24))
    check("policy: float peak 1.5 stays (+3.52 dB)",
          isKeep(FlacConverter.archivePolicy(fl, peak: 1.5)) { if case .floatOverFullScale(let db) = $0 { return abs(db - 3.5218) < 0.01 }; return false })
    var many = i24; many.channels = 9
    check("policy: 9 channels stay", FlacConverter.archivePolicy(many, peak: nil) == .keep(.tooManyChannels(9)))
    var empty = i24; empty.frames = 0
    check("policy: empty stays", FlacConverter.archivePolicy(empty, peak: nil) == .keep(.empty))

    // MARK: real files
    for (name, ch, rate, bits) in [("s24", 2, 48000.0, 24), ("s16", 2, 44100.0, 16),
                                   ("m24", 1, 96000.0, 24), ("s24_88", 2, 88200.0, 24)] {
        let wav = dir.appendingPathComponent("\(name).wav"), flac = dir.appendingPathComponent("\(name).flac")
        try writeWav(wav, channels: ch, rate: rate, seconds: 3, bits: bits, float: false, amplitude: 0.7)
        let out = FlacConverter.archive(source: wav, destination: flac)
        if case .converted(let b, let before, let after) = out {
            check("\(name): converted at \(bits)", b == bits)
            check("\(name): smaller", after > 0 && after < before, "\(before) → \(after)")
        } else { check("\(name): converted", false, "\(out)") }
        check("\(name): bit-exact", (try? FlacConverter.verify(source: wav, flac: flac, tolerance: 0)) != nil)
        let f = try AVAudioFile(forReading: flac)
        check("\(name): flac rate/channels/length", f.fileFormat.sampleRate == rate && Int(f.fileFormat.channelCount) == ch && f.length == Int64(rate * 3), "\(f.fileFormat)")
        check("\(name): declares \(bits) bits", declaredDepth(flac) == bits, "\(String(describing: declaredDepth(flac)))")
        check("\(name): original untouched", fm.fileExists(atPath: wav.path))
        check("\(name): no temp left", ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).allSatisfy { !$0.hasPrefix(".objekat-flac-") })
    }

    // float, under full scale → 24
    let fq = dir.appendingPathComponent("fq.wav"), fqf = dir.appendingPathComponent("fq.flac")
    try writeWav(fq, channels: 2, rate: 48000, seconds: 3, bits: 32, float: true, amplitude: 0.5)
    if case .converted(let b, _, _) = FlacConverter.archive(source: fq, destination: fqf) {
        check("float 0.5: → FLAC 24", b == 24)
        check("float 0.5: declares 24 bits", declaredDepth(fqf) == 24, "\(String(describing: declaredDepth(fqf)))")
        check("float 0.5: within one 24-bit step", (try? FlacConverter.verify(source: fq, flac: fqf, tolerance: FlacConverter.step24)) != nil)
    } else { check("float 0.5: converted", false) }

    // float, over full scale → stays, nothing written
    let fh = dir.appendingPathComponent("fh.wav"), fhf = dir.appendingPathComponent("fh.flac")
    try writeWav(fh, channels: 2, rate: 48000, seconds: 3, bits: 32, float: true, amplitude: 0.5, impulse: 2.0)
    let outH = FlacConverter.archive(source: fh, destination: fhf)
    var overOK = false
    if case .kept(.floatOverFullScale(let db)) = outH { overOK = abs(db - 6.02) < 0.05 }
    check("float 2.0: kept (+6.02 dB)", overOK, "\(outH)")
    check("float 2.0: no flac written", !fm.fileExists(atPath: fhf.path))

    // the dry run says what archive would do, writing nothing
    check("plan: int24 → convert 24", FlacConverter.plan(of: dir.appendingPathComponent("s24.wav")) == .convert(bits: 24))
    check("plan: int16 → convert 16", FlacConverter.plan(of: dir.appendingPathComponent("s16.wav")) == .convert(bits: 16))
    check("plan: float 0.5 → convert 24", FlacConverter.plan(of: fq) == .convert(bits: 24))
    check("plan: float 2.0 → keep",
          isKeep(FlacConverter.plan(of: fh)) { if case .floatOverFullScale = $0 { return true }; return false })

    // a file already standing at the destination is never overwritten, unless it is the same sound
    let ex = dir.appendingPathComponent("ex.wav"), exf = dir.appendingPathComponent("ex.flac")
    try writeWav(ex, channels: 2, rate: 48000, seconds: 1, bits: 24, float: false, amplitude: 0.6)
    check("existing: first conversion", { if case .converted = FlacConverter.archive(source: ex, destination: exf) { return true }; return false }())
    let before = try Data(contentsOf: exf)
    check("existing: same sound is reused", { if case .converted = FlacConverter.archive(source: ex, destination: exf) { return true }; return false }())
    check("existing: file left as it was", (try? Data(contentsOf: exf)) == before)
    check("existing: no temp left", ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).allSatisfy { !$0.hasPrefix(".objekat-flac-") })
    let other = dir.appendingPathComponent("other.wav"), otherf = dir.appendingPathComponent("other.flac")
    try writeWav(other, channels: 2, rate: 48000, seconds: 1, bits: 24, float: false, amplitude: 0.3)
    try fm.copyItem(at: exf, to: otherf)           // a DIFFERENT sound under the destination's name
    let outOther = FlacConverter.archive(source: other, destination: otherf)
    check("existing: a different sound is refused", { if case .kept(.encodeFailed) = outOther { return true }; return false }(), "\(outOther)")
    check("existing: the different file is untouched", (try? Data(contentsOf: otherf)) == before)

    // unreadable
    let junk = dir.appendingPathComponent("junk.wav"); try Data([1, 2, 3]).write(to: junk)
    var junkOK = false
    if case .kept(.unreadable) = FlacConverter.archive(source: junk, destination: dir.appendingPathComponent("junk.flac")) { junkOK = true }
    check("junk: kept as unreadable", junkOK)

    // verify catches a difference
    let a = dir.appendingPathComponent("a.wav"), b = dir.appendingPathComponent("b.wav")
    try writeWav(a, channels: 2, rate: 48000, seconds: 1, bits: 24, float: false, amplitude: 0.5)
    try writeWav(b, channels: 2, rate: 48000, seconds: 1, bits: 24, float: false, amplitude: 0.5, impulse: 0.9)
    check("verify: detects one differing sample", (try? FlacConverter.verify(source: a, flac: b, tolerance: 0)) == nil)

    print(fails.isEmpty ? "ALL PASS (\(total))" : "\(fails.count) FAILED of \(total)")
    exit(fails.isEmpty ? 0 : 1)
  }
}
