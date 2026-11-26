import Foundation

// MARK: - What an imported video's audio track becomes on disk (plan-video §2.4)
//
// A pure rule, with no AVFoundation, no model and no disk behind it, so that it compiles alone and
// is asserted with no screen (`tools/test_video_audio_rule.swift`) like `FolderImport` or
// `ConsolidateFolders`. It decides the FIRST choice for one audio track of a video file; the
// import (`VideoAudioExtract`) carries that choice out and falls back on a WAV when a kept stream
// fails its verification.
//
// The user's decisions it encodes:
//   • AAC beginning at t = 0 → the stream is KEPT, in an M4A, without re-encoding;
//   • PCM → a WAV at the PCM's own depth (16, 24, 32-bit float);
//   • AC-3, E-AC-3, MP3, Opus → the stream is kept IF decoding and alignment are verified at import,
//     otherwise a 16-bit WAV;
//   • anything else, or an AAC that does not begin at 0 → a 16-bit WAV.
//
// A WAV is PADDED with silence at the head and the tail so that it starts at t = 0 and covers the
// whole picture (an M4A cannot be, which is why a kept stream must already start at 0).

nonisolated enum VideoAudioRule {

    /// The compression family of an audio track, as the import reads it from the file.
    enum Codec: Equatable, Sendable {
        case aac
        case ac3
        case eac3
        case mp3
        case opus
        /// Linear PCM: `bits` per sample (8, 16, 24, 32, 64), `isFloat` for the floating-point forms.
        case pcm(bits: Int, isFloat: Bool)
        /// Anything else (ALAC, FLAC, Vorbis, a codec nobody planned): decoded, never kept.
        case other(String)

        /// A human name for the messages (the codec is NAMED in a refusal, never "unsupported").
        var displayName: String {
            switch self {
            case .aac: return "AAC"
            case .ac3: return "AC-3"
            case .eac3: return "E-AC-3"
            case .mp3: return "MP3"
            case .opus: return "Opus"
            case .pcm(let bits, let isFloat): return isFloat ? "PCM \(bits)-bit float" : "PCM \(bits)-bit"
            case .other(let s): return s
            }
        }

        /// A compressed stream this rule may KEEP in an M4A (verified by the import).
        var isKeepable: Bool {
            switch self {
            case .aac, .ac3, .eac3, .mp3, .opus: return true
            case .pcm, .other: return false
            }
        }
    }

    /// The depth of a WAV written by the import.
    enum WavDepth: Int, Equatable, Sendable {
        case int16 = 16
        case int24 = 24
        case float32 = 32

        var bits: Int { rawValue }
        var isFloat: Bool { self == .float32 }
        /// The depth tag used in file names and in the API.
        var label: String { self == .float32 ? "32f" : String(rawValue) }
    }

    /// What the import tries first for one track.
    enum Choice: Equatable, Sendable {
        /// Keep the compressed stream in an M4A (to be verified after extraction).
        case keepStream
        /// Decode and write a WAV at this depth, padded to start at 0 and cover the picture.
        case wav(WavDepth)

        var isKept: Bool { if case .keepStream = self { return true }; return false }
    }

    /// The first choice for a track. `startsAtZero`: the track's first sample is at t = 0 once the
    /// file's edit list is applied (an AAC's encoder delay is not a start offset: the container trims
    /// it, which is the very thing the extraction verification proves).
    static func choice(for codec: Codec, startsAtZero: Bool) -> Choice {
        switch codec {
        case .aac, .ac3, .eac3, .mp3, .opus:
            return startsAtZero ? .keepStream : .wav(.int16)
        case .pcm(let bits, let isFloat):
            return .wav(pcmDepth(bits: bits, isFloat: isFloat))
        case .other:
            return .wav(.int16)
        }
    }

    /// The WAV depth a PCM track is written at: its own, 8 bits widened to 16, and 32-bit INTEGER
    /// narrowed to 24 (a 32-bit float WAV would not hold it exactly either way; 24 bits is what the
    /// 32-bit integer of a camera really carries) — plan-video §2.4, marked [S].
    static func pcmDepth(bits: Int, isFloat: Bool) -> WavDepth {
        if isFloat { return .float32 }
        switch bits {
        case ...16: return .int16
        case 17...24: return .int24
        default: return .int24
        }
    }

    /// The fallback after a kept stream failed its verification, or for a track with no better option.
    static let fallback: Choice = .wav(.int16)

    // MARK: Names

    /// `samples/video/<name>_A<n>_<hash8>.<ext>`: the object's name (sanitised), the audio track's
    /// 1-based rank in the file, and eight hex digits of the source's identity (path, size, date) so
    /// that two files sharing a name never collide and the same file imported twice reuses nothing
    /// by accident. `ext` is `m4a` or `wav`.
    static func fileName(baseName: String, trackNumber: Int, hash8: String, ext: String) -> String {
        "\(sanitized(baseName))_A\(trackNumber)_\(hash8).\(ext)"
    }

    /// A file name part: no path separator, no control character, no leading dot, at most 60 characters.
    static func sanitized(_ name: String) -> String {
        var s = name.unicodeScalars.map { u -> Character in
            switch u {
            case "/", ":", "\\", "\0": return "-"
            default: return u.value < 32 ? "-" : Character(u)
            }
        }.map(String.init).joined()
        while s.hasPrefix(".") { s.removeFirst() }
        s = s.trimmingCharacters(in: .whitespaces)
        if s.count > 60 { s = String(s.prefix(60)).trimmingCharacters(in: .whitespaces) }
        return s.isEmpty ? "video" : s
    }

    /// Eight hex digits, a stable FNV-1a (64-bit) fold of the strings given — not a security hash,
    /// only a name disambiguator that must not change between runs (`String.hashValue` does).
    static func hash8(_ parts: [String]) -> String {
        var h: UInt64 = 0xcbf29ce484222325
        for part in parts {
            for b in part.utf8 { h ^= UInt64(b); h = h &* 0x100000001b3 }
            h ^= 0xff; h = h &* 0x100000001b3
        }
        return String(format: "%08x", UInt32(truncatingIfNeeded: h ^ (h >> 32)))
    }
}
