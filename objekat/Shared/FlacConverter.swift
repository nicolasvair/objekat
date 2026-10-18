import Foundation
import AVFoundation

// MARK: - WAV → FLAC, lossless, verified
//
// ONE converter for the two places that turn a WAV into a FLAC: the EXPORT (the engine renders a
// WAV — listenable while it grows, a header rewrite every six seconds — and the FLAC is made at the
// end, exactly as the MP3 is) and the ARCHIVE of a project folder (the clean-up popover's
// "convert audio files to FLAC"). The engine never writes a FLAC for these any more: a FLAC in
// progress has no length, so nothing can be heard of it until the render is over.
//
// CoreAudio writes the FLAC (`AVAudioFile`, `kAudioFormatFLAC`), the same encoder `afconvert` uses.
//
// THE LOSSLESS RULE (the whole policy, pure, in `archivePolicy`):
//   • integer WAV, 16 or 24 bits  → FLAC of the SAME depth. Exact: the samples read back equal.
//   • floating-point WAV          → FLAC 24 bits ONLY if its peak is ≤ 0 dBFS (an integer file
//     cannot hold more: it would be clipped). Not bit-exact (a float carries more than 24 bits on
//     quiet material) but within one 24-bit step, which `verify` checks.
//   • anything else (8 or 32-bit integer, more than 8 channels, a format CoreAudio will not open
//     or encode) → left as a WAV, and said.
// NOTHING here deletes anything: the caller removes (or keeps) the original, and only after
// `verify` has read the FLAC back and found it equal to the source.
//
// Blocking and synchronous: call it off the main thread. Compiles alone (no L(), no model) —
// @see tools/test_flac_converter.swift.

nonisolated enum FlacConverter {

    // MARK: What a source is

    enum SampleKind: Equatable, Sendable {
        case integer(bits: Int)
        case float
    }

    struct SourceInfo: Equatable, Sendable {
        var channels: Int
        var sampleRate: Double
        var frames: Int64
        var kind: SampleKind
    }

    /// FLAC carries at most eight channels.
    static let maxChannels = 8

    /// One 24-bit step, the tolerance of a float → 24-bit conversion (the rounding is half a step;
    /// a peak at exactly +1.0 is clipped by one step, the integer range stopping at 1 − 2⁻²³).
    static let step24: Float = 1.0 / 8_388_608.0

    // MARK: The policy (pure)

    /// Why a file stays a WAV.
    enum KeepReason: Equatable, Sendable {
        /// A floating-point wave whose peak goes past 0 dBFS (the FLAC would clip it).
        case floatOverFullScale(peakDB: Double)
        case tooManyChannels(Int)
        /// A bit depth FLAC does not take losslessly here (8, 32-bit integer…).
        case unsupportedDepth(String)
        case unreadable(String)
        case empty
        /// The encoder refused, or the FLAC written did not read back equal.
        case encodeFailed(String)
    }

    /// What to do with a source whose `info` is known and, for a float one, whose `peak` is.
    enum Plan: Equatable, Sendable {
        case convert(bits: Int)
        case keep(KeepReason)
    }

    static func archivePolicy(_ info: SourceInfo, peak: Float?) -> Plan {
        if info.frames <= 0 { return .keep(.empty) }
        if info.channels < 1 { return .keep(.unreadable("no channel")) }
        if info.channels > maxChannels { return .keep(.tooManyChannels(info.channels)) }
        switch info.kind {
        case .integer(let bits):
            return (bits == 16 || bits == 24) ? .convert(bits: bits)
                                              : .keep(.unsupportedDepth("\(bits)-bit integer"))
        case .float:
            guard let peak else { return .keep(.unreadable("peak unknown")) }
            // ≤ 0 dBFS, with the one-step slack a sample at exactly +1.0 deserves.
            if peak <= 1.0 + step24 { return .convert(bits: 24) }
            return .keep(.floatOverFullScale(peakDB: 20 * log10(Double(peak))))
        }
    }

    // MARK: Reading a source

    enum Failure: Error, Equatable {
        case unreadable(String)
        case writeFailed(String)
        case mismatch(String)
        case cancelled
    }

    static func inspect(_ url: URL) throws -> SourceInfo {
        let file: AVAudioFile
        do { file = try AVAudioFile(forReading: url) }
        catch { throw Failure.unreadable(error.localizedDescription) }
        let asbd = file.fileFormat.streamDescription.pointee
        let isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        let isPCM = asbd.mFormatID == kAudioFormatLinearPCM
        // A compressed file (MP3, AAC…) has no PCM depth: it is not ours to convert.
        guard isPCM else { throw Failure.unreadable("not linear PCM") }
        return SourceInfo(channels: Int(file.fileFormat.channelCount),
                          sampleRate: file.fileFormat.sampleRate,
                          frames: file.length,
                          kind: isFloat ? .float : .integer(bits: Int(asbd.mBitsPerChannel)))
    }

    private static let chunk: AVAudioFrameCount = 65_536

    /// The largest absolute sample of `url` (linear, 1.0 = 0 dBFS).
    static func peak(of url: URL, isCancelled: () -> Bool = { false }) throws -> Float {
        let file: AVAudioFile
        do { file = try AVAudioFile(forReading: url) }
        catch { throw Failure.unreadable(error.localizedDescription) }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunk) else {
            throw Failure.unreadable("no buffer")
        }
        var peak: Float = 0
        while file.framePosition < file.length {
            if isCancelled() { throw Failure.cancelled }
            do { try file.read(into: buffer, frameCount: chunk) }
            catch { throw Failure.unreadable(error.localizedDescription) }
            if buffer.frameLength == 0 { break }
            guard let data = buffer.floatChannelData else { throw Failure.unreadable("no float data") }
            for c in 0..<Int(buffer.format.channelCount) {
                let p = data[c]
                for i in 0..<Int(buffer.frameLength) { peak = max(peak, abs(p[i])) }
            }
        }
        return peak
    }

    // MARK: Writing and verifying

    /// Writes `source` to `destination` as a FLAC of `bits` (16 or 24). The destination is
    /// replaced. `progress` receives 0…1.
    static func convert(source: URL, destination: URL, bits: Int,
                        progress: (Double) -> Void = { _ in },
                        isCancelled: () -> Bool = { false }) throws {
        precondition(bits == 16 || bits == 24, "FLAC is written at 16 or 24 bits")
        let input: AVAudioFile
        do {
            // The depth CoreAudio's FLAC encoder declares follows the CLIENT format, not the
            // `AVLinearPCMBitDepthKey` alone: fed with float32 it writes 24 bits whatever is asked
            // (measured: a 16-bit WAV came out `I24`, lossless but a third larger). A 16-bit file is
            // therefore read as int16, which is exact, and written from int16.
            input = bits == 16
                ? try AVAudioFile(forReading: source, commonFormat: .pcmFormatInt16, interleaved: false)
                : try AVAudioFile(forReading: source)
        } catch { throw Failure.unreadable(error.localizedDescription) }
        let format = input.processingFormat
        let total = max(1, input.length)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else {
            throw Failure.unreadable("no buffer")
        }
        try? FileManager.default.removeItem(at: destination)
        var output: AVAudioFile? = nil
        do {
            output = try AVAudioFile(forWriting: destination,
                                     settings: [AVFormatIDKey: kAudioFormatFLAC,
                                                AVSampleRateKey: format.sampleRate,
                                                AVNumberOfChannelsKey: Int(format.channelCount),
                                                AVLinearPCMBitDepthKey: bits],
                                     commonFormat: format.commonFormat,
                                     interleaved: format.isInterleaved)
            while input.framePosition < input.length {
                if isCancelled() { throw Failure.cancelled }
                try input.read(into: buffer, frameCount: chunk)
                if buffer.frameLength == 0 { break }
                try output?.write(from: buffer)
                progress(Double(input.framePosition) / Double(total))
            }
        } catch let failure as Failure {
            output = nil
            try? FileManager.default.removeItem(at: destination)
            throw failure
        } catch {
            output = nil
            try? FileManager.default.removeItem(at: destination)
            throw Failure.writeFailed(error.localizedDescription)
        }
        output = nil          // closes the file: the encoder flushes its last frames here
    }

    /// Reads `flac` back and compares it with `source`, frame for frame: same length, same rate,
    /// same channel count, and every sample equal within `tolerance` (0 = bit-exact, which is what
    /// an integer source must give). Throws `mismatch` at the first difference.
    static func verify(source: URL, flac: URL, tolerance: Float,
                       isCancelled: () -> Bool = { false }) throws {
        let a: AVAudioFile, b: AVAudioFile
        do { a = try AVAudioFile(forReading: source); b = try AVAudioFile(forReading: flac) }
        catch { throw Failure.mismatch("unreadable: \(error.localizedDescription)") }
        guard a.length == b.length else { throw Failure.mismatch("length \(a.length) ≠ \(b.length)") }
        guard a.fileFormat.sampleRate == b.fileFormat.sampleRate,
              a.fileFormat.channelCount == b.fileFormat.channelCount else {
            throw Failure.mismatch("format")
        }
        guard let ba = AVAudioPCMBuffer(pcmFormat: a.processingFormat, frameCapacity: chunk),
              let bb = AVAudioPCMBuffer(pcmFormat: b.processingFormat, frameCapacity: chunk) else {
            throw Failure.mismatch("no buffer")
        }
        var position: Int64 = 0
        while position < a.length {
            if isCancelled() { throw Failure.cancelled }
            do { try a.read(into: ba, frameCount: chunk); try b.read(into: bb, frameCount: chunk) }
            catch { throw Failure.mismatch("read: \(error.localizedDescription)") }
            guard ba.frameLength == bb.frameLength, ba.frameLength > 0 else {
                throw Failure.mismatch("short read at \(position)")
            }
            guard let da = ba.floatChannelData, let db = bb.floatChannelData else {
                throw Failure.mismatch("no float data")
            }
            for c in 0..<Int(ba.format.channelCount) {
                for i in 0..<Int(ba.frameLength) where abs(da[c][i] - db[c][i]) > tolerance {
                    throw Failure.mismatch("sample \(position + Int64(i)) channel \(c): \(da[c][i]) ≠ \(db[c][i])")
                }
            }
            position += Int64(ba.frameLength)
        }
    }

    // MARK: The whole archive gesture for ONE file

    enum Outcome: Equatable, Sendable {
        /// `destination` was written and VERIFIED; the original is untouched (the caller decides).
        case converted(bits: Int, bytesBefore: Int64, bytesAfter: Int64)
        case kept(KeepReason)
    }

    /// Inspects, applies the lossless rule, converts into a temporary beside `destination`, verifies
    /// it, and only then moves it to `destination`. Never touches `source`. A failure of any step
    /// leaves no file behind and answers `.kept(.encodeFailed(…))`. A file that already stands at
    /// `destination` is never overwritten: if it reads back equal to `source` it is reused as it
    /// is, otherwise the answer is `.kept(.encodeFailed(…))`.
    static func archive(source: URL, destination: URL,
                        isCancelled: () -> Bool = { false }) -> Outcome {
        let info: SourceInfo
        do { info = try inspect(source) }
        catch { return .kept(.unreadable(describe(error))) }
        var peak: Float?
        if info.kind == .float {
            do { peak = try self.peak(of: source, isCancelled: isCancelled) }
            catch { return .kept(.unreadable(describe(error))) }
        }
        let bits: Int
        switch archivePolicy(info, peak: peak) {
        case .keep(let reason): return .kept(reason)
        case .convert(let b):   bits = b
        }
        let fm = FileManager.default
        let tolerance = info.kind == .float ? step24 : 0
        let temp = destination.deletingLastPathComponent()
            .appendingPathComponent(".objekat-flac-\(UUID().uuidString.prefix(8)).flac")
        do {
            try convert(source: source, destination: temp, bits: bits, isCancelled: isCancelled)
            try verify(source: source, flac: temp, tolerance: tolerance, isCancelled: isCancelled)
            if fm.fileExists(atPath: destination.path) {
                // Never overwrite what is not ours: a file already there is acceptable only if it
                // IS this same sound (an earlier archive, another version of the folder).
                do { try verify(source: source, flac: destination, tolerance: tolerance, isCancelled: isCancelled) }
                catch Failure.cancelled { throw Failure.cancelled }
                catch { throw Failure.mismatch("a different file already has the name \(destination.lastPathComponent)") }
                try? fm.removeItem(at: temp)
            } else {
                try fm.moveItem(at: temp, to: destination)
            }
        } catch {
            try? fm.removeItem(at: temp)
            return .kept(.encodeFailed(describe(error)))
        }
        func size(_ u: URL) -> Int64 {
            ((try? fm.attributesOfItem(atPath: u.path))?[.size] as? NSNumber)?.int64Value ?? 0
        }
        return .converted(bits: bits, bytesBefore: size(source), bytesAfter: size(destination))
    }

    /// What `archive` WOULD do with `source`, writing nothing (a dry run): the same inspection and
    /// the same peak reading, then the policy.
    static func plan(of source: URL, isCancelled: () -> Bool = { false }) -> Plan {
        let info: SourceInfo
        do { info = try inspect(source) }
        catch { return .keep(.unreadable(describe(error))) }
        var peak: Float?
        if info.kind == .float {
            do { peak = try self.peak(of: source, isCancelled: isCancelled) }
            catch { return .keep(.unreadable(describe(error))) }
        }
        return archivePolicy(info, peak: peak)
    }

    private static func describe(_ error: Error) -> String {
        switch error {
        case Failure.unreadable(let s), Failure.writeFailed(let s), Failure.mismatch(let s): return s
        case Failure.cancelled: return "cancelled"
        default: return error.localizedDescription
        }
    }
}
