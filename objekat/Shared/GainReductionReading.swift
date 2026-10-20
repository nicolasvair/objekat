import Foundation

// MARK: - Reading a plugin's gain reduction off the parameter it exposes

/// A compressor or a limiter that shows its gain reduction usually PUBLISHES it as a read-only
/// parameter (@see OBJEngineCore `pluginMeterParameters:`). OBJEKAT does not measure anything of its
/// own for it: it reads that parameter, and this unit says WHICH one (by its name, unless the hand
/// chose) and WHAT it is worth in dB (from the text the plugin gives — the normalised value has no
/// unit, and only the plugin knows its range). Pure: tested alone (`tools/test_gain_reduction_reading.swift`).
nonisolated enum GainReductionReading {

    /// The candidate a plugin's bar starts on, when the hand never chose: the first whose name says
    /// "gain reduction" in one of the ways plugins spell it, else nil (no GR shown, the selector stays).
    static func defaultIndex(names: [String]) -> Int? {
        let folded = names.map { $0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) }
        // Strongest first: a name that is ONLY "GR" or says "gain reduction" beats one that merely holds "reduction".
        let tiers: [(String) -> Bool] = [
            { $0.contains("gain reduction") || $0.contains("gainreduction") || $0.contains("gain red") },
            { matchesWord("gr", in: $0) || $0.contains("g.r.") },
            { $0.contains("reduction") || $0.contains("attenuation") || $0.contains("reduc") },
            { matchesWord("comp", in: $0) && $0.contains("meter") },
        ]
        for tier in tiers {
            if let i = folded.firstIndex(where: tier) { return i }
        }
        return nil
    }

    /// True if `word` stands alone in `s` (letters around it end the match: "gr" in "GR L" but not in "grit").
    static func matchesWord(_ word: String, in s: String) -> Bool {
        var rest = s[...]
        while let r = rest.range(of: word) {
            let before = r.lowerBound == s.startIndex ? nil : s[s.index(before: r.lowerBound)]
            let after = r.upperBound == s.endIndex ? nil : s[r.upperBound]
            if !(before?.isLetter ?? false) && !(after?.isLetter ?? false) { return true }
            rest = s[r.upperBound...]
        }
        return false
    }

    /// The reduction in dB, as a MAGNITUDE (0 = none), read from the plugin's text — "-3.2 dB",
    /// "3.2", "−3,2" (a typographic minus, a decimal comma) — or nil when the text holds no number.
    /// A text that says "-inf" or "inf" is no reduction worth drawing: nil.
    static func decibels(fromText text: String) -> Double? {
        var t = text.replacingOccurrences(of: "\u{2212}", with: "-")      // −
        t = t.replacingOccurrences(of: ",", with: ".")
        var number = ""
        var started = false
        for ch in t {
            if ch.isNumber || (ch == "." && started) || ((ch == "-" || ch == "+") && !started) {
                number.append(ch)
                if ch.isNumber { started = true }
            } else if started {
                break
            } else if !(ch == " ") {
                number = ""
            }
        }
        guard started, let v = Double(number), v.isFinite else { return nil }
        return abs(v)
    }
}

/// Which read-only parameter a plugin TYPE's bar reads, remembered across sessions (a choice made
/// once for "Pro-C 2" holds for every Pro-C 2). In `UserDefaults` under `pluginGR.<format>|<identifier>`
/// = the parameter's id; under `--no-recent` / `--headless` in a dictionary that dies with the
/// process (a test never writes the user's settings — @see ScriptPanelMemory).
enum PluginMeterMemory {
    static var isEphemeral: Bool {
        let a = LaunchArguments.process
        return a.noRecentProjects || a.headless
    }
    static let prefix = "pluginGR."
    /// A remembered "none": the hand chose to show nothing.
    static let none = "-"
    nonisolated(unsafe) private static var ephemeral: [String: String] = [:]

    static func key(format: String, identifier: String) -> String { prefix + format + "|" + identifier }

    static func chosen(format: String, identifier: String) -> String? {
        let k = key(format: format, identifier: identifier)
        return isEphemeral ? ephemeral[k] : UserDefaults.standard.string(forKey: k)
    }

    static func choose(_ id: String?, format: String, identifier: String) {
        let k = key(format: format, identifier: identifier)
        if isEphemeral { ephemeral[k] = id }
        else if let id { UserDefaults.standard.set(id, forKey: k) }
        else { UserDefaults.standard.removeObject(forKey: k) }
    }
}
