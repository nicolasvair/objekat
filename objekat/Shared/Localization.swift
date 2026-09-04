import Foundation

/// Interface text, resolved in the app's language.
///
/// The keys are SYMBOLIC (`export.panel.title`) and not the sentence itself. The catalogue
/// `Resources/Localizable.xcstrings` carries the languages side by side, and the source code no
/// longer holds a single visible sentence: translating means editing the catalogue, never the `.swift`.
///
/// A key missing from the catalogue renders AS IT IS on screen (`export.panel.title` would show
/// up in the panel). That is deliberate: an oversight is seen at a glance instead of hiding
/// behind a silent fallback to another language.
///
/// `nonisolated` is explicit: the target builds with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`,
/// and some texts are computed off the main actor (error descriptions, the MP3 encoder). Reading
/// from a bundle is safe from any thread.
///
/// - Parameters:
///   - key: the symbolic key.
///   - arguments: values to inject into a `%@`, `%d`… format. With no argument the string is
///     returned literally — so a text holding a '%' is never eaten by `String(format:)`.
nonisolated func L(_ key: String, _ arguments: CVarArg...) -> String {
    let format = Localization.bundle.localizedString(forKey: key, value: nil, table: nil)
    return arguments.isEmpty ? format : String(format: format, arguments: arguments)
}

/// The "singular / plural" variant: looks up `key.one` or `key.other` depending on `count`.
///
/// No `.stringsdict`: the three shipped languages have only two forms, and TWO KEYS CAN BE READ
/// BY EYE in the catalogue where a compiled plural rule can only be checked by running the app.
/// A language with three forms would mean coming back here — a price knowingly paid.
///
/// `count` only picks the form: if it must ALSO be displayed, it is passed again in
/// `arguments` (`Ln("x.count", n, n)`).
nonisolated func Ln(_ key: String, _ count: Int, _ arguments: CVarArg...) -> String {
    let format = Localization.bundle.localizedString(forKey: key + (count == 1 ? ".one" : ".other"),
                                                     value: nil, table: nil)
    return arguments.isEmpty ? format : String(format: format, arguments: arguments)
}

/// Choosing the language at launch.
///
/// By default: the system's, through the normal macOS mechanism (the `.lproj` folders the
/// catalogue generates). A system language outside the three falls back to English, the
/// development language.
/// `--language=fr|en|es` forces the language for ONE launch. It is a testing tool — see
/// `docs/command_api.md` — and it writes NOTHING into the user's settings: the argument domain
/// of `NSUserDefaults` is volatile, it dies with the process. A home-made equivalent of
/// `-AppleLanguages '(es)'`, plus an explicit bundle, because CFBundle may have frozen its
/// language before the first line of `main.swift` runs.
enum Localization {

    /// The languages we ship. Any new language is added here AND in the catalogue.
    nonisolated static let supported = ["fr", "en", "es"]

    /// The fallback language when the system asks for one we do not speak.
    nonisolated static let fallback = "en"

    /// Where to read the texts: `Bundle.main` unless `--language=` named an `.lproj`.
    nonisolated(unsafe) private(set) static var bundle: Bundle = .main

    /// The code actually in force, as returned by `app.info`.
    nonisolated(unsafe) private(set) static var current: String =
        Bundle.main.preferredLocalizations.first ?? Localization.fallback

    /// To be called BEFORE any interface is built — so very early in `main.swift`.
    nonisolated static func applyLaunchOverride(_ arguments: LaunchArguments) {
        guard let code = arguments.language, supported.contains(code) else { return }

        // The native path, for everything that does not go through `L()`: system menus, AppKit
        // panels, date formats.
        var domain = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        domain["AppleLanguages"] = [code]
        UserDefaults.standard.setVolatileDomain(domain, forName: UserDefaults.argumentDomain)

        // And the explicit bundle, which depends on no cache at all.
        if let path = Bundle.main.path(forResource: code, ofType: "lproj"),
           let lproj = Bundle(path: path) {
            bundle = lproj
        }
        current = code
    }
}

/// A deliberately empty label — `TextField(noLabel, text:)`, `Picker(noLabel, selection:)`.
///
/// SwiftUI's initialisers take a `LocalizedStringKey`, so a bare `""` gets HARVESTED by Xcode's
/// string extraction and lands in the catalogue as an empty key nobody can translate. Passing a
/// `String` picks the `StringProtocol` overload instead: same empty label on screen, nothing in
/// the catalogue. Same reasoning as `Text(verbatim:)` for a glyph or a number.
let noLabel = ""
