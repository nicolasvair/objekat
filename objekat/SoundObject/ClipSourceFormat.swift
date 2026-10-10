import Foundation
import AVFoundation

/// The format of the audio FILE a clip plays: its sample rate, its bit depth and whether it is
/// integer PCM, float PCM or a compressed codec. Read from the file's own header
/// (`AVAudioFile.fileFormat`), so it says what is on the disk — not what the engine decodes it to.
///
/// What it is for: a script that renders an object back to a file (the spectral editor) must hand
/// the result back at the SOURCE's rate and depth, and `object.get` had nothing to say about either.
///
/// Cached per PATH, as `ClipChannels` is and for the same reason: opening an `AVAudioFile` reads the
/// file's header, which on a network volume can block for seconds, and the answer is asked at doors
/// that must not touch the disk twice. Only a SUCCESS is remembered — a file missing now may be
/// back after a relink.
nonisolated enum ClipSourceFormat {

    enum Kind: String {
        case pcmInt = "pcm_int"
        case pcmFloat = "pcm_float"
        /// Anything that is not linear PCM (MP3, AAC, FLAC, ALAC…): it has no bit depth to report.
        case compressed
    }

    struct Info: Equatable {
        let sampleRate: Double
        /// `mBitsPerChannel` of a linear-PCM file; nil for a compressed one.
        let bitDepth: Int?
        let kind: Kind
    }

    nonisolated(unsafe) private static var known: [String: Info] = [:]
    nonisolated private static let lock = NSLock()

    /// The format of the file at `path`, or nil if it cannot be opened.
    nonisolated static func info(atPath path: String) -> Info? {
        guard !path.isEmpty else { return nil }
        lock.lock()
        if let i = known[path] { lock.unlock(); return i }
        lock.unlock()
        guard let file = try? AVAudioFile(forReading: URL(fileURLWithPath: path, isDirectory: false))
        else { return nil }
        let info = describe(file.fileFormat.streamDescription.pointee)
        lock.lock(); known[path] = info; lock.unlock()
        return info
    }

    /// The pure half: a stream description in, what the API reports out.
    nonisolated static func describe(_ asbd: AudioStreamBasicDescription) -> Info {
        guard asbd.mFormatID == kAudioFormatLinearPCM else {
            return Info(sampleRate: asbd.mSampleRate, bitDepth: nil, kind: .compressed)
        }
        let isFloat = asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0
        return Info(sampleRate: asbd.mSampleRate,
                    bitDepth: asbd.mBitsPerChannel > 0 ? Int(asbd.mBitsPerChannel) : nil,
                    kind: isFloat ? .pcmFloat : .pcmInt)
    }
}
