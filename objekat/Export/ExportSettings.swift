import Foundation

// The settings of an export: what the export panel edits, and what `EditViewModel.runExport`
// consumes. Purely declarative — no rendering logic here.
// @see EditViewModel+Export, ExportPanelView

struct ExportSettings: Equatable {

    /// The range to render. `inOut` picks up the timeline's I/O markers (`loopRegion`), which the
    /// export panel edits in place: setting the export MOVES the markers, and that is intended.
    enum TimeRangeMode: String, CaseIterable, Identifiable {
        case wholeProject, inOut
        var id: String { rawValue }
        var label: String {
            switch self {
            case .wholeProject: return L("export.range.wholeProject")
            case .inOut:        return L("export.range.inOut")
            }
        }
    }

    enum FileFormat: String, CaseIterable, Identifiable {
        case wav, mp3
        var id: String { rawValue }
        var label: String { self == .wav ? "WAV" : "MP3" }
        var fileExtension: String { rawValue }

        /// The sample rates offered. MP3 (MPEG-1 Layer III) only knows 32 / 44.1 / 48 kHz — offering
        /// 88.2 or 96 kHz would make no sense, the encoder would resample.
        var sampleRates: [Double] {
            self == .wav ? [44100, 48000, 88200, 96000] : [44100, 48000]
        }
    }

    /// The MP3 bitrate: 320 kbit/s constant, the format's maximum. No setting — that is the
    /// quality one expects from a mix export.
    static let mp3BitrateKbps = 320

    var rangeMode: TimeRangeMode = .wholeProject
    /// The unit of the IN/OUT fields: seconds (`.time`) or bar:beat:tick (`.bpm`). It picks up the
    /// timeline's grid mode the first time the panel opens, then the last choice made — and NEVER
    /// changes it back: switching unit to type an export does not touch the project's own display.
    /// @see EditViewModel+Export
    var timeFieldMode: GridMode = .time
    /// Render on a COPY of the Edit (the app stays usable, but the clone instantiates every AU in
    /// the project before starting) or DIRECTLY on the project (immediate start, playback suspended
    /// for the length of the render). @see OBJEngineCore `exportMixToFileAsync:…onEditCopy:`
    var renderInBackground: Bool = false
    /// MP3 44.1 kHz by default — the MP3 bitrate is pinned at 320 kbit/s (see `mp3BitrateKbps`).
    /// Most exports are there to LISTEN to what has just been made, not to deliver: a light file,
    /// immediately playable anywhere, is the right default. WAV is one click away, and the last
    /// format used wins from the second export on (@see makeExportSettings).
    /// The same default as the `export.run` command, so panel and script render the same thing.
    var format: FileFormat = .mp3
    var sampleRate: Double = 44100
    /// WAV bit depth: 16 or 24 bits. Not applicable to MP3, where the intermediate render is
    /// always floating point.
    var bitDepth: Int = 24
    /// Dither on render, INDEPENDENT of the bit depth: one may want 16 bits without dither noise
    /// (material still to be processed) as well as 24 bits with it. Not applicable to MP3, whose
    /// intermediate render is floating point — nothing is quantised there.
    var dithering: Bool = true
    /// Destination folder — the project's folder by default (@see EditViewModel+Export).
    var folder: URL = FileManager.default.homeDirectoryForCurrentUser
    var name: String = "Export"
    /// An imposed range, in seconds, short-circuiting `rangeMode`. The panel does not use it — it
    /// edits the I/O markers, and that is intended. The API, on the other hand, has to be able to
    /// export a range WITHOUT moving the user's markers: a script has no business leaving traces
    /// in the project to render a file. @see EditViewModel.exportTimeRange
    var explicitRange: ClosedRange<Double>? = nil

    /// The final file, extension included.
    var destinationURL: URL {
        let base = name.isEmpty ? "Export" : name
        return folder.appendingPathComponent(base).appendingPathExtension(format.fileExtension)
    }

    /// Brings the settings back into the chosen format's domain (called after a change of
    /// format): a 96 kHz rate kept from a WAV export must not survive the switch to MP3.
    /// passage en MP3.
    mutating func clampToFormat() {
        if !format.sampleRates.contains(sampleRate) {
            sampleRate = format.sampleRates.contains(48000) ? 48000 : (format.sampleRates.first ?? 48000)
        }
        if bitDepth != 16 && bitDepth != 24 { bitDepth = 24 }
    }

    /// A short label for a sample rate: '44.1 kHz', '96 kHz'.
    static func sampleRateLabel(_ hz: Double) -> String {
        let k = hz / 1000
        let s = k == k.rounded() ? String(format: "%.0f", k) : String(format: "%.1f", k)
        return s.replacingOccurrences(of: ".", with: ",") + " kHz"
    }
}

// MARK: - The state of a running export

/// A live export: its phase, its progress, its destination. Carried by the view-model for the
/// whole length of the render (which runs in the background — the app stays usable) and read by
/// the progress bar under the transport bar.
struct ExportJob: Equatable {
    enum Phase: Equatable {
        /// The engine copies the Edit and INSTANTIATES every plugin in the project, on the main
        /// thread: the interface really is frozen during that time (a few seconds on a large
        /// project). Hence this separate phase, shown BEFORE the freeze begins and with no
        /// numbered progress — there is none to give, but at least one knows it is working.
        /// @see EditViewModel.runExport
        case preparing
        case rendering      // the engine renders the mix into a temporary wave
        case encoding       // libmp3lame converts that wave into MP3
        case finished       // done: the bar offers to reveal the file
        case failed(String) // the error message shown in the bar
    }

    var phase: Phase = .preparing
    /// 0…1. In MP3, the render takes the first 80 per cent and the encoding the last 20:
    /// a single bar for two steps, with no going backwards.
    var progress: Double = 0
    var destination: URL
    var settings: ExportSettings

    var isRunning: Bool { phase == .preparing || phase == .rendering || phase == .encoding }

    /// True while no numbered progress exists: the bar spins instead of filling.
    var isIndeterminate: Bool { phase == .preparing }

    var statusLabel: String {
        switch phase {
        case .preparing: return L("export.phase.preparing")
        case .rendering: return L("export.phase.rendering")
        case .encoding:  return L("export.phase.encoding")
        case .finished:  return L("export.phase.finished")
        case .failed:    return L("export.phase.failed")
        }
    }
}
