import Foundation

/// What the engine decided about the card's own sample rate — the Swift mirror of
/// `OBJRateDecisionKind` (`Shared/OBJSampleRatePolicy.h`), raw values included, since
/// `OBJAudioDeviceSnapshot.rateDecision` carries the raw number.
///
/// OBJEKAT ADOPTS the rate the card already runs at and only moves it when it is unusable (out of
/// [22.05 ; 192] kHz, or not in the list the card offers) — it never imposes the rate of the last
/// session.
enum SampleRateDecision: Int, Equatable {
    /// The card's rate is taken as it is.
    case adopt = 0
    /// The card's rate was unusable and the card was switched to another one it offers.
    case fallback = 1
    /// Unusable, and nothing better on offer: kept.
    case outOfRangeKept = 2
    /// No output device open, so nothing was decided.
    case unknown = 3

    /// The API's own spelling (`audio.status.rate_decision`).
    var apiName: String {
        switch self {
        case .adopt: return "adopt"
        case .fallback: return "fallback"
        case .outOfRangeKept: return "out_of_range"
        case .unknown: return "unknown"
        }
    }

    init(raw: Int) { self = SampleRateDecision(rawValue: raw) ?? .unknown }
}

/// A snapshot of the audio device actually open in the engine — the Swift-side mirror of
/// `OBJAudioDeviceSnapshot`, kept as plain `Equatable` data so `AudioDeviceStatus.refresh()` can
/// tell "nothing changed" from a real change and write only on the latter (@see the memory note
/// "Polls qui repeignent à vide").
struct AudioDeviceSnapshot: Equatable {
    var name: String?
    var type: String?
    var sampleRate: Double
    var bufferSize: Int
    var outputChannels: Int
    var running: Bool
    /// What the sample-rate policy decided (@see `SampleRateDecision`) and the rate the card had
    /// BEFORE it — the one that was refused, for `.fallback` and `.outOfRangeKept`.
    var rateDecision: SampleRateDecision = .unknown
    var deviceRateBeforeDecision: Double = 0

    static let none = AudioDeviceSnapshot(name: nil, type: nil, sampleRate: 0, bufferSize: 0,
                                          outputChannels: 0, running: false)
}

/// The audio device truly in use, shared by the window's title and by `audio.status` — the SAME
/// object, so neither can say something the other contradicts.
///
/// Attached once per process, from `ObjekatSession.start()` (idempotent: a second `attach` simply
/// re-arms the callback and reads once more), and refreshed only when
/// `OBJEngineCore.onAudioDeviceChanged` fires — never on a timer. `refresh()` writes `snapshot`
/// ONLY IF it actually differs from what is already there, so a change message that turns out to
/// carry nothing new touches no observable and repaints nothing — the rule "Polls qui repeignent
/// à vide" applies here even though this is not a poll.
@MainActor
@Observable
final class AudioDeviceStatus {
    static let shared = AudioDeviceStatus()

    private(set) var snapshot: AudioDeviceSnapshot = .none

    /// Bumped on every WRITE to `snapshot` (never on a no-op refresh, hence never on idle
    /// churn). `audio.status.set_*` waits on it moving; a test asserts it does NOT move when
    /// nothing about the device actually changed.
    private(set) var generation = 0

    var text: String {
        AudioStatusText.line(name: snapshot.name, sampleRate: snapshot.sampleRate,
                              bufferSize: snapshot.bufferSize, running: snapshot.running,
                              none: L("audio.device.none"), stopped: L("audio.status.stopped"))
    }

    /// Called right after every WRITE (never after a no-op refresh) — the title bar's own hook,
    /// so it re-lays itself exactly when there is something new to show.
    @ObservationIgnored var onChange: (() -> Void)?

    @ObservationIgnored private weak var engine: OBJEngineCore?
    @ObservationIgnored private var pendingConfirmations = 0

    private init() {}

    func attach(_ engine: OBJEngineCore) {
        self.engine = engine
        engine.onAudioDeviceChanged = { [weak self] in
            MainActor.assumeIsolated { self?.refresh() }
        }
        // Covers the startup message that may have fired (device restored from Settings.xml)
        // before this callback existed.
        refresh()
    }

    func refresh() {
        guard let engine else { return }
        let live = engine.audioDeviceSnapshot()
        let next = AudioDeviceSnapshot(name: live.deviceName, type: live.deviceType,
                                       sampleRate: live.sampleRate, bufferSize: live.bufferSize,
                                       outputChannels: live.outputChannels, running: live.running,
                                       rateDecision: SampleRateDecision(raw: live.rateDecision),
                                       deviceRateBeforeDecision: live.deviceRateBeforeDecision)
        guard next != snapshot else { return }
        snapshot = next
        generation &+= 1
        onChange?()

        // The restart gap: an external rate/buffer change stops the device then starts it again
        // some ~100 ms apart — coalesced most of the time, but not guaranteed to be. Landing on
        // "stopped" schedules ONE deferred re-read, bounded (at most 5 in a row, reset the moment
        // a running snapshot is seen) rather than becoming a steady poll: once running — or truly
        // dead — nothing more is scheduled, and a device really stopped keeps showing so.
        if next.running {
            pendingConfirmations = 0
        } else if pendingConfirmations < 5 {
            pendingConfirmations += 1
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.refresh()
            }
        }
    }
}
