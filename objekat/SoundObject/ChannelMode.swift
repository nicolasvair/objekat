import Foundation
import AVFoundation

/// Which channel(s) of a STEREO audio clip are heard — a non-destructive choice made at playback,
/// per clip, the file never touched.
///
/// - `lr`: the clip as it is (the default; the key is not even written to a session).
/// - `l`: the LEFT channel alone, on both sides.
/// - `r`: the RIGHT channel alone, on both sides.
/// - `c`: the mono sum `(L + R) / 2`, on both sides.
///
/// It only exists for a clip of EXACTLY two channels (@see `ClipChannels`): a mono file has no
/// second channel to choose and three or more are not a pair. The choice acts on the SOURCE — the
/// engine puts it at the head of the clip's chain, before the effects, so a compressor sees the
/// channel that was kept and not the stereo it came from (@see OBJChannelModePlugin.h).
nonisolated enum ChannelMode: String, Codable, CaseIterable, Sendable {
    case lr, l, r, c

    /// The engine's integer code, mirrored in `ObjChannelModePlugin::Mode`. Fixed for good: it is
    /// written into the plugin's state.
    var engineCode: Int {
        switch self {
        case .lr: return 0
        case .l:  return 1
        case .r:  return 2
        case .c:  return 3
        }
    }

    /// True for every mode but the default — what decides whether the engine carries a plugin at
    /// all, and whether a session writes the key.
    var isActive: Bool { self != .lr }
}

/// How many channels an audio file holds, read from the DISK once per path and remembered.
///
/// Why a cache, and why this one: the answer is asked at doors that must not touch the disk
/// twice — the inspector's body (re-evaluated at every selection), the command API, the drawing's
/// decision of how to fold a waveform. Opening an `AVAudioFile` reads the file's header, which on
/// a network volume can block for seconds, so the answer is remembered per PATH (a relink or a
/// replaced source gives another path and so another entry). `nil` = the file cannot be read
/// (missing, unsupported): callers treat it as "not stereo", never as an error.
enum ClipChannels {
    nonisolated(unsafe) private static var known: [String: Int] = [:]
    nonisolated private static let lock = NSLock()

    /// The channel count of the file at `path`, or nil if it cannot be opened. Only a SUCCESS is
    /// remembered: a file that is missing now may be back after a relink, and must be read again.
    nonisolated static func count(atPath path: String) -> Int? {
        guard !path.isEmpty else { return nil }
        lock.lock()
        if let n = known[path] { lock.unlock(); return n }
        lock.unlock()
        guard let file = try? AVAudioFile(forReading: URL(fileURLWithPath: path, isDirectory: false))
        else { return nil }
        let n = Int(file.processingFormat.channelCount)
        lock.lock(); known[path] = n; lock.unlock()
        return n
    }

    /// True iff the file at `path` has EXACTLY two channels.
    nonisolated static func isStereo(atPath path: String) -> Bool { count(atPath: path) == 2 }
}
