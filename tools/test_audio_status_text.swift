// The audio-status line in the window's title bar — the arithmetic behind it, asserted with no
// screen. `AudioStatusText` (`Shared/AudioStatusText.swift`) has no model behind it at all,
// which is why it can be compiled and run alone, exactly like `CutSelection` before it.
//
//     swiftc -parse-as-library \
//         ../objekat/Shared/AudioStatusText.swift test_audio_status_text.swift \
//         -o /tmp/ast && /tmp/ast
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
enum AudioStatusTextTest {
  static func main() {

    // MARK: - shortRate

    check("44100 Hz -> 44.1k", AudioStatusText.shortRate(44100) == "44.1k")
    check("48000 Hz -> 48k",   AudioStatusText.shortRate(48000) == "48k")
    check("88200 Hz -> 88.2k", AudioStatusText.shortRate(88200) == "88.2k")
    check("96000 Hz -> 96k",   AudioStatusText.shortRate(96000) == "96k")
    check("176400 Hz -> 176.4k", AudioStatusText.shortRate(176400) == "176.4k")
    check("192000 Hz -> 192k", AudioStatusText.shortRate(192000) == "192k")
    check("22050 Hz -> 22.05k", AudioStatusText.shortRate(22050) == "22.05k")
    // Pinned: %.2f rounds 11.025 up to 11.03 on this platform (the double for 11025.0/1000 sits
    // fractionally above 11.025) — a fact of the C library, not a choice, so it is pinned rather
    // than asserted "either way".
    check("11025 Hz -> 11.03k", AudioStatusText.shortRate(11025) == "11.03k")

    check("0 Hz -> empty",        AudioStatusText.shortRate(0) == "")
    check("negative Hz -> empty", AudioStatusText.shortRate(-1) == "")
    check("NaN -> empty",         AudioStatusText.shortRate(.nan) == "")
    check("+inf -> empty",        AudioStatusText.shortRate(.infinity) == "")

    // No float noise: a rate one ULP off 44100 must still read as a clean "44.1k".
    check("44100.0000001 Hz -> 44.1k, no float noise",
          AudioStatusText.shortRate(44100.0000001) == "44.1k")

    // MARK: - line

    check("full line",
          AudioStatusText.line(name: "MOTU M2", sampleRate: 48000, bufferSize: 512,
                                running: true, none: "No audio device", stopped: "stopped")
            == "MOTU M2 — 48k — 512")

    check("nil name -> none exactly, no dashes",
          AudioStatusText.line(name: nil, sampleRate: 48000, bufferSize: 512,
                                running: true, none: "No audio device", stopped: "stopped")
            == "No audio device")

    check("empty name -> none exactly",
          AudioStatusText.line(name: "", sampleRate: 48000, bufferSize: 512,
                                running: true, none: "No audio device", stopped: "stopped")
            == "No audio device")

    check("running == false appends stopped at the end",
          AudioStatusText.line(name: "MOTU M2", sampleRate: 48000, bufferSize: 512,
                                running: false, none: "No audio device", stopped: "stopped")
            == "MOTU M2 — 48k — 512 — stopped")

    check("buffer 0 is omitted, not printed as 0",
          AudioStatusText.line(name: "MOTU M2", sampleRate: 48000, bufferSize: 0,
                                running: true, none: "No audio device", stopped: "stopped")
            == "MOTU M2 — 48k")

    check("rate 0 is omitted, not printed as 0",
          AudioStatusText.line(name: "MOTU M2", sampleRate: 0, bufferSize: 512,
                                running: true, none: "No audio device", stopped: "stopped")
            == "MOTU M2 — 512")

    check("rate AND buffer 0: just the name",
          AudioStatusText.line(name: "MOTU M2", sampleRate: 0, bufferSize: 0,
                                running: true, none: "No audio device", stopped: "stopped")
            == "MOTU M2")

    check("a name containing ' — ' is kept verbatim",
          AudioStatusText.line(name: "Aggregate — Built-in", sampleRate: 48000, bufferSize: 512,
                                running: true, none: "No audio device", stopped: "stopped")
            == "Aggregate — Built-in — 48k — 512")

    print("\n\(total - fails.count)/\(total) passed")
    if !fails.isEmpty {
        print("FAILURES:")
        for f in fails { print(" - \(f)") }
        exit(1)
    }
  }
}
