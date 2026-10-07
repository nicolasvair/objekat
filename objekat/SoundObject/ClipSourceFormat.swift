import Foundation
import AVFoundation
import AudioToolbox

/// How an audio file is STORED — its sample rate, its bit depth and whether it is integer PCM,
/// float PCM or a compressed format — read from the DISK once per path and remembered, exactly as
/// `ClipChannels` does for the channel count (same reasons: opening an `AVAudioFile` reads the
/// header, which on a network volume can block, and the answer is asked at doors that run often).
///
/// It exists for the third-party scripts that must write a file "like the source" (a spectral
/// edit that hands back a 16-bit file for a 16-bit source and never invents resolution): `object.get`
/// reports it for a clip (`source_sample_rate`, `source_bit_depth`, `source_format`).
///
/// It is the file's OWN format (`AVAudioFile.fileFormat`), not the processing format AVFoundation
/// decodes to (always 32-bit float): the latter would say "float 32" for every file.
nonisolated enum ClipSourceFormat {

    /// What a script needs to know about a stored file.
    struct Info: Equatable, Sendable {
        /// The file's own sample rate, in Hz.
        let sampleRate: Double
        /// Bits per sample for linear PCM (int or float); nil for a compressed format, which has
        /// no sample depth to speak of.
        let bitDepth: Int?
        /// `pcm_int`, `pcm_float` or `compressed`.
        let kind: String
    }

    nonisolated(unsafe) private static var known: [String: Info] = [:]
    nonisolated private static let lock = NSLock()

    /// The stored format of the file at `path`, or nil if it cannot be opened. Only a SUCCESS is
    /// remembered: a file that is missing now may be back after a relink.
    nonisolated static func info(atPath path: String) -> Info? {
        guard !path.isEmpty else { return nil }
        lock.lock()
        if let i = known[path] { lock.unlock(); return i }
        lock.unlock()
        guard let file = try? AVAudioFile(forReading: URL(fileURLWithPath: path, isDirectory: false))
        else { return nil }
        let i = describe(file.fileFormat)
        lock.lock(); known[path] = i; lock.unlock()
        return i
    }

    /// Pure: a stream description in, the three facts out.
    nonisolated static func describe(_ format: AVAudioFormat) -> Info {
        let asbd = format.streamDescription.pointee
        guard asbd.mFormatID == kAudioFormatLinearPCM else {
            return Info(sampleRate: format.sampleRate, bitDepth: nil, kind: "compressed")
        }
        let isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        return Info(sampleRate: format.sampleRate,
                    bitDepth: asbd.mBitsPerChannel > 0 ? Int(asbd.mBitsPerChannel) : nil,
                    kind: isFloat ? "pcm_float" : "pcm_int")
    }
}
