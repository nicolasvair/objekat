import Foundation

/// Launch arguments, read once and read back everywhere.
///
/// ⚠️ THE JOINED FORM `--key=value` IS MANDATORY for anything that takes a value. `NSUserDefaults`
/// builds its argument domain by PAIRING each token starting with '-' with the next one: on
/// `--headless --project /a.json`, the pair formed is (-headless, --project) and '/a.json' is
/// left ORPHANED. AppKit takes that leftover for a file to open and then opens no window — the
/// app runs, mute and with no interface. The spaced form is still tolerated for `--socket`
/// (compatibility), but nothing new should rely on it.
///
/// `nonisolated` is explicit: the target builds with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`,
/// which would tie these accessors to the main actor for no reason. They only read an immutable
/// `[String]`, and they are read BEFORE any actor exists — `Localization.applyLaunchOverride`
/// runs from `main.swift` before the first interface is built.
nonisolated struct LaunchArguments: Sendable {

    /// THIS process's arguments, readable from anywhere. A `static let` is initialised lazily, so it
    /// is safe even very early — unlike the `launchArguments` global in `main.swift`, which is only
    /// worth something once its line has run.
    static let process = LaunchArguments()

    let raw: [String]

    init(_ raw: [String] = CommandLine.arguments) { self.raw = raw }

    func flag(_ name: String) -> Bool { raw.contains("--\(name)") }

    /// `--key=value` first; `--key value` as a fallback.
    func value(_ name: String) -> String? {
        if let joined = raw.first(where: { $0.hasPrefix("--\(name)=") }) {
            let v = String(joined.dropFirst("--\(name)=".count))
            return v.isEmpty ? nil : v
        }
        guard let i = raw.firstIndex(of: "--\(name)"), i + 1 < raw.count else { return nil }
        let next = raw[i + 1]
        return next.hasPrefix("--") ? nil : next
    }

    var headless: Bool { flag("headless") }
    var noAudio: Bool { flag("no-audio") }

    /// Writes NOTHING into "Recent Projects" during this launch. A test opens and saves throwaway
    /// projects: without this, the user's list fills up with temporary folders and pushes their
    /// real projects out (it only keeps 10). Applies with or without a window — trying something
    /// by hand deserves the same discretion as an automated harness.
    var noRecentProjects: Bool { flag("no-recent") }
    var projectPath: String? { value("project") }
    var execPath: String? { value("exec") }

    /// Forces the interface language for THIS launch: `fr`, `en` or `es`. Without it, the app
    /// follows the system language. Nothing is persisted — @see `Localization.applyLaunchOverride`.
    var language: String? { value("language") }
}
