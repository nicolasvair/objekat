import Foundation

/// Pure helpers for reading and displaying a tempo (BPM) value with up to `decimals` decimal
/// places. Two fields in the app follow the exact same rules and both go through this type:
/// the project's tempo (`App/TransportView.swift`) and the "BPM of the wav" field in the
/// synoptic (`Inspector/Synoptic/SynopticView.AudioFileZoneView`).
///
/// The separator TYPED can be a comma or a dot (AZERTY needs the comma); the separator SHOWN
/// is always a dot.
enum TempoText {
    static let decimals = 4

    /// Rounds a value to `decimals` decimal places. Applied every time a tempo is nudged or
    /// typed, so that e.g. `127.02 + 0.1` lands on exactly `127.12` and not on
    /// `127.11999999999999`.
    static func rounded(_ value: Double) -> Double {
        let factor = pow(10.0, Double(decimals))
        return (value * factor).rounded() / factor
    }

    private static let formatter: NumberFormatter = {
        let f = NumberFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.numberStyle = .decimal
        f.usesGroupingSeparator = false
        f.decimalSeparator = "."
        f.minimumIntegerDigits = 1
        f.minimumFractionDigits = 0
        f.maximumFractionDigits = decimals
        f.roundingMode = .halfUp
        return f
    }()

    /// "127" for a whole number, "127.02" for 127.020, up to 4 decimal places, always with a
    /// dot, never a trailing zero beyond what is needed.
    static func display(_ value: Double) -> String {
        formatter.string(from: NSNumber(value: rounded(value))) ?? String(format: "%.0f", value)
    }

    /// Parses a user-typed tempo: trims whitespace, accepts `,` as the decimal separator, and
    /// only accepts digits plus at most one separator — rejects "1e2", "12.3.4", letters, an
    /// empty string. Accepts a leading or trailing dot ("127." → 127, ",5" → 0.5).
    static func parse(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let normalized = trimmed.replacingOccurrences(of: ",", with: ".")

        var seenDot = false
        for ch in normalized {
            if ch == "." {
                if seenDot { return nil }
                seenDot = true
            } else if !ch.isNumber {
                return nil
            }
        }

        var toParse = normalized
        if toParse.hasSuffix(".") { toParse.removeLast() }
        guard !toParse.isEmpty, let value = Double(toParse) else { return nil }
        return value
    }
}
