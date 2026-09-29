import Foundation

// MARK: - What a script panel remembers between two openings

/// A panel opened with `remember` starts, next time, on the values the hand last VALIDATED. The
/// memory is the APP's, generic, and the script writes nothing itself. One entry per key, a flat
/// dictionary `control id → bool | number | string`, in `UserDefaults` under `scriptPanel.<key>`
/// — with the rest of the app's own preferences.
///
/// A test never touches the real domain: under `--no-recent` or `--headless` the entries live in a
/// dictionary that dies with the process (same discretion as "Recent projects": a scenario must not
/// write into the user's settings). The behaviour is identical, so a scenario can still assert it.
enum ScriptPanelMemory {

    static var isEphemeral: Bool {
        let a = LaunchArguments.process
        return a.noRecentProjects || a.headless
    }

    static let defaultsPrefix = "scriptPanel."
    nonisolated(unsafe) private static var ephemeral: [String: [String: Any]] = [:]

    static func load(_ key: String) -> [String: JSONValue] {
        let raw: [String: Any]?
        if isEphemeral { raw = ephemeral[key] }
        else { raw = UserDefaults.standard.dictionary(forKey: defaultsPrefix + key) }
        var out: [String: JSONValue] = [:]
        for (k, v) in raw ?? [:] {
            if let s = v as? String { out[k] = .string(s) }
            else if let n = v as? NSNumber {
                // NSNumber bridges Bool and Double alike: the CF type says which one it was.
                out[k] = CFGetTypeID(n) == CFBooleanGetTypeID() ? .bool(n.boolValue) : .number(n.doubleValue)
            }
        }
        return out
    }

    static func save(_ key: String, _ values: [String: JSONValue]) {
        var raw: [String: Any] = [:]
        for (k, v) in values {
            switch v {
            case .bool(let b): raw[k] = b
            case .number(let d): raw[k] = d
            case .string(let s): raw[k] = s
            default: break
            }
        }
        if isEphemeral { ephemeral[key] = raw }
        else { UserDefaults.standard.set(raw, forKey: defaultsPrefix + key) }
    }

    static func erase(_ key: String) {
        if isEphemeral { ephemeral.removeValue(forKey: key) }
        else { UserDefaults.standard.removeObject(forKey: defaultsPrefix + key) }
    }

    /// The remembered values that still fit `controls`: same id, same kind of value, inside min/max
    /// or among the options. Anything else is ignored (a script that changed its panel between two
    /// versions must not have a stale entry rejected — or worse, applied).
    static func applicable(_ stored: [String: JSONValue], to controls: [ScriptPanelControl]) -> [String: JSONValue] {
        var out: [String: JSONValue] = [:]
        for c in controls where c.kind.holdsHandValue {
            guard let v = stored[c.id] else { continue }
            switch c.kind {
            case .bool:
                if case .bool = v { out[c.id] = v }
            case .number:
                if case .number(let d) = v, d.isFinite, d >= c.min, d <= c.max { out[c.id] = v }
            case .choice:
                if case .string(let s) = v, c.options.contains(where: { $0.id == s }) { out[c.id] = v }
            default: break
            }
        }
        return out
    }
}
