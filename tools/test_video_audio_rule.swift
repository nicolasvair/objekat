// "What an imported video's audio becomes on disk" — the pure rule (plan-video §2.4), asserted with
// no screen, no file and no AVFoundation. `VideoAudioRule` has nothing behind it, hence it compiles
// and runs alone.
//
//     swiftc -parse-as-library \
//         ../objekat/Video/VideoAudioRule.swift test_video_audio_rule.swift \
//         -o /tmp/vrule && /tmp/vrule
//
// Exit: 0 if every assertion passes, 1 otherwise.

import Foundation

var fails: [String] = []
var total = 0

func check(_ label: String, _ ok: Bool, _ detail: String = "") {
    total += 1
    if ok { print("ok    " + label) }
    else { fails.append(label); print("FAIL  \(label)  \(detail)") }
}

@main
enum VideoAudioRuleTest {
  static func main() {
    typealias R = VideoAudioRule

    // MARK: First choice per codec
    check("AAC starting at 0 is kept", R.choice(for: .aac, startsAtZero: true) == .keepStream)
    check("AAC NOT starting at 0 becomes a 16-bit WAV (a stream cannot be padded)",
          R.choice(for: .aac, startsAtZero: false) == .wav(.int16))
    for (name, c) in [("AC-3", R.Codec.ac3), ("E-AC-3", .eac3), ("MP3", .mp3), ("Opus", .opus)] {
        check("\(name) starting at 0 is kept (to be verified)", R.choice(for: c, startsAtZero: true) == .keepStream)
        check("\(name) not at 0 -> WAV16", R.choice(for: c, startsAtZero: false) == .wav(.int16))
    }
    check("other codec -> WAV16", R.choice(for: .other("ALAC"), startsAtZero: true) == .wav(.int16))

    // MARK: PCM depths
    check("PCM 16 -> WAV16", R.choice(for: .pcm(bits: 16, isFloat: false), startsAtZero: true) == .wav(.int16))
    check("PCM 24 -> WAV24", R.choice(for: .pcm(bits: 24, isFloat: false), startsAtZero: true) == .wav(.int24))
    check("PCM 32 float -> WAV32f", R.choice(for: .pcm(bits: 32, isFloat: true), startsAtZero: true) == .wav(.float32))
    check("PCM 64 float -> WAV32f", R.choice(for: .pcm(bits: 64, isFloat: true), startsAtZero: true) == .wav(.float32))
    check("PCM 8 -> WAV16 (widened)", R.pcmDepth(bits: 8, isFloat: false) == .int16)
    check("PCM 32 integer -> WAV24 (narrowed)", R.pcmDepth(bits: 32, isFloat: false) == .int24)
    check("PCM 20 -> WAV24", R.pcmDepth(bits: 20, isFloat: false) == .int24)
    check("PCM start offset is irrelevant (a WAV is padded)",
          R.choice(for: .pcm(bits: 24, isFloat: false), startsAtZero: false) == .wav(.int24))
    check("fallback is WAV16", R.fallback == .wav(.int16))

    // MARK: Keepability and names
    check("AAC is keepable", R.Codec.aac.isKeepable)
    check("PCM is not keepable", !R.Codec.pcm(bits: 16, isFloat: false).isKeepable)
    check("other is not keepable", !R.Codec.other("x").isKeepable)
    check("codec names are specific", R.Codec.eac3.displayName == "E-AC-3"
          && R.Codec.pcm(bits: 24, isFloat: false).displayName == "PCM 24-bit"
          && R.Codec.pcm(bits: 32, isFloat: true).displayName == "PCM 32-bit float")
    check("depth labels", R.WavDepth.int16.label == "16" && R.WavDepth.float32.label == "32f" && R.WavDepth.int24.bits == 24)

    // MARK: File names
    check("file name layout", R.fileName(baseName: "Film", trackNumber: 2, hash8: "0123abcd", ext: "m4a") == "Film_A2_0123abcd.m4a")
    check("a separator never reaches the name", !R.sanitized("a/b:c\\d").contains("/")
          && !R.sanitized("a/b:c\\d").contains(":") && !R.sanitized("a/b:c\\d").contains("\\"))
    check("no leading dot", !R.sanitized("..hidden").hasPrefix("."))
    check("empty -> video", R.sanitized("") == "video" && R.sanitized("...") == "video")
    check("long names are cut to 60", R.sanitized(String(repeating: "x", count: 200)).count == 60)
    check("accents survive", R.sanitized("Épée été") == "Épée été")

    // MARK: hash8
    let h1 = R.hash8(["/a/b.mp4", "123", "2026"])
    check("hash8 is 8 hex digits", h1.count == 8 && h1.allSatisfy { $0.isHexDigit })
    check("hash8 is stable", h1 == R.hash8(["/a/b.mp4", "123", "2026"]))
    check("hash8 depends on every part", h1 != R.hash8(["/a/b.mp4", "124", "2026"]) && h1 != R.hash8(["/a/c.mp4", "123", "2026"]))
    check("hash8 separates parts (no concatenation collision)", R.hash8(["ab", "c"]) != R.hash8(["a", "bc"]))

    print("\n\(total - fails.count)/\(total) passed")
    if !fails.isEmpty {
        print("FAILURES:")
        for f in fails { print(" - \(f)") }
        exit(1)
    }
  }
}
