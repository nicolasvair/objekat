import Foundation

// MARK: - The trace of a plugin
//
// What a plugin does to ONE precise signal, frozen so that the session stays portable on a
// machine where the plugin is absent: `y[n] = g[n]·x[n] + d[n]`, sample by sample.
//
// The heavy part — the two run-length encoded signals — lives in a `.objtrace` file beside the
// session. What the model carries is this reference: enough to show the slot's state, to tell a
// stale trace from a fresh one, and to decide whether the chain should play the plugin or its
// trace. The engine reads the file; nothing here ever holds the samples.
//
// @see docs/objekat-capture-trace.md

/// What a traced slot is worth, at a glance. Ordered from best to worst: the signal view colours
/// the badge from this, and the report reads from it.
enum PluginTraceHealth: String, Codable {
    /// The reconstruction is exact and the input is still the one that was captured.
    case exact
    /// Exact enough to use, with a residual worth naming.
    case acceptable
    /// A residual above −120 dBFS: almost always a fractional alignment. Usable, but say so.
    case problem
    /// Something upstream changed since the capture: the reconstruction is no longer guaranteed.
    case stale
    /// The trace was captured on a plugin that holds randomness. One performance is frozen — it
    /// is not a defect, but it is a change of behaviour and the user has to know.
    case frozen
}

struct PluginTraceRef: Codable, Equatable {

    /// The file's name inside the project's `traces/` folder. A name and not a path: a trace
    /// travels with the project, so there is nothing absolute to record. @see EditViewModel.tracesFolder
    var fileName: String

    var capturedAt: Date
    /// The name the plugin carried when it was captured — what the slot shows once the plugin
    /// itself is no longer there to be asked.
    var pluginName: String

    var sampleRate: Double
    var numChannels: Int
    var numSamples: Int
    var regionStart: Double
    var regionEnd: Double

    var multiplicativeOnly: Bool
    var linked: Bool
    /// The plugin held randomness: no null-input pass was run, and one performance is frozen.
    var nonDeterministic: Bool

    /// The peak of the validation residual, in dBFS.
    var validationPeakDb: Double
    /// The fingerprint of the input signal. EMPTY when the capture could not take one — an
    /// upstream that is not itself reproducible has no stable input to fingerprint, and
    /// staleness can then never be detected. @see `isVerifiable`.
    var inputHash: String

    /// Play this slot from its trace even though the plugin IS installed here.
    ///
    /// Not a convenience: it is the only way to exercise the restitution on a machine that has
    /// the plugin, and therefore the only way a headless test can compare "the plugin" against
    /// "its trace" in the same session. It is also what a user reaches for to hear what a
    /// collaborator will hear.
    var forced: Bool = false

    /// The trace can be checked for staleness at all. Without a fingerprint we can never say
    /// that the input still matches, so we never claim it does.
    var isVerifiable: Bool { !inputHash.isEmpty }

    /// The health of the trace ON ITS OWN — before asking whether the input still matches.
    /// `stale` is decided by the view-model, which alone knows the current signal.
    var health: PluginTraceHealth {
        if nonDeterministic { return .frozen }
        if validationPeakDb < -250 { return .exact }
        if validationPeakDb < -120 { return .acceptable }
        return .problem
    }

    var duration: Double { regionEnd - regionStart }

    enum CodingKeys: String, CodingKey {
        case fileName, capturedAt, pluginName, sampleRate, numChannels, numSamples,
             regionStart, regionEnd, multiplicativeOnly, linked, nonDeterministic,
             validationPeakDb, inputHash, forced
    }

    init(fileName: String, capturedAt: Date, pluginName: String, sampleRate: Double,
         numChannels: Int, numSamples: Int, regionStart: Double, regionEnd: Double,
         multiplicativeOnly: Bool, linked: Bool, nonDeterministic: Bool,
         validationPeakDb: Double, inputHash: String, forced: Bool = false) {
        self.fileName = fileName
        self.capturedAt = capturedAt
        self.pluginName = pluginName
        self.sampleRate = sampleRate
        self.numChannels = numChannels
        self.numSamples = numSamples
        self.regionStart = regionStart
        self.regionEnd = regionEnd
        self.multiplicativeOnly = multiplicativeOnly
        self.linked = linked
        self.nonDeterministic = nonDeterministic
        self.validationPeakDb = validationPeakDb
        self.inputHash = inputHash
        self.forced = forced
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        fileName = try c.decode(String.self, forKey: .fileName)
        capturedAt = try c.decodeIfPresent(Date.self, forKey: .capturedAt) ?? Date()
        pluginName = try c.decodeIfPresent(String.self, forKey: .pluginName) ?? ""
        sampleRate = try c.decodeIfPresent(Double.self, forKey: .sampleRate) ?? 0
        numChannels = try c.decodeIfPresent(Int.self, forKey: .numChannels) ?? 0
        numSamples = try c.decodeIfPresent(Int.self, forKey: .numSamples) ?? 0
        regionStart = try c.decodeIfPresent(Double.self, forKey: .regionStart) ?? 0
        regionEnd = try c.decodeIfPresent(Double.self, forKey: .regionEnd) ?? 0
        multiplicativeOnly = try c.decodeIfPresent(Bool.self, forKey: .multiplicativeOnly) ?? false
        linked = try c.decodeIfPresent(Bool.self, forKey: .linked) ?? false
        nonDeterministic = try c.decodeIfPresent(Bool.self, forKey: .nonDeterministic) ?? false
        validationPeakDb = try c.decodeIfPresent(Double.self, forKey: .validationPeakDb) ?? 0
        inputHash = try c.decodeIfPresent(String.self, forKey: .inputHash) ?? ""
        forced = try c.decodeIfPresent(Bool.self, forKey: .forced) ?? false
    }

    /// Builds a reference from the report the engine returns at the end of a capture.
    ///
    /// Everything numeric goes through `NSNumber`: the report crosses from Objective-C, where
    /// every number is one, and asking for `Double` on a value that happened to bridge as `Int`
    /// silently yields nil — that is, a zero where a sample rate should be.
    init?(report: [String: Any], fileName: String) {
        guard report["ok"] as? Bool == true else { return nil }

        func number(_ key: String) -> NSNumber? { report[key] as? NSNumber }

        self.init(fileName: fileName,
                  capturedAt: Date(),
                  pluginName: report["plugin"] as? String ?? "",
                  sampleRate: number("sample_rate")?.doubleValue ?? 0,
                  numChannels: number("num_channels")?.intValue ?? 0,
                  numSamples: number("num_samples")?.intValue ?? 0,
                  regionStart: number("region_start")?.doubleValue ?? 0,
                  regionEnd: number("region_end")?.doubleValue ?? 0,
                  multiplicativeOnly: report["multiplicative_only"] as? Bool ?? false,
                  linked: report["linked"] as? Bool ?? false,
                  nonDeterministic: report["non_deterministic"] as? Bool ?? false,
                  validationPeakDb: number("validation_peak_db")?.doubleValue ?? 0,
                  inputHash: report["input_hash"] as? String ?? "")
    }
}
