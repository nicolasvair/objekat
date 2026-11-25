import Foundation
import SwiftUI
import Perception

@MainActor
@Perceptible
final class ObjekatPreferences {
    static let shared = ObjekatPreferences()

    /// The sound library's root folder.
    ///
    /// The persisted key was renamed along with the property (when the code moved to English);
    /// `init` reads the old one one last time, otherwise the panel would come back empty after
    /// the update.
    var soundLibraryFolder: String {
        didSet { UserDefaults.standard.set(soundLibraryFolder, forKey: Self.soundLibraryFolderKey) }
    }

    private static let soundLibraryFolderKey = "pref.soundLibraryFolder"
    /// The old name. To be removed when nobody comes from a version that wrote it any more.
    private static let legacySoundLibraryFolderKey = "pref.sonoth\u{00E8}queFolder"

    /// Command API: opens a UNIX socket taking named commands in JSON-lines (driving by script, by
    /// a language model, or automated tests). OFF by default — while it is, no socket is created
    /// and nothing listens.
    var apiEnabled: Bool {
        didSet {
            UserDefaults.standard.set(apiEnabled, forKey: "pref.apiEnabled")
            applyAPIPreference()
        }
    }

    /// Journal de diagnostic (@see Shared/DiagLog.swift) : écrit ce que l'app fait, pour comprendre un
    /// crash ou un problème après coup. OFF par défaut. L'effet est immédiat au basculement : le journal
    /// s'ouvre ou se ferme sur-le-champ. Au lancement, c'est `main.swift` qui l'allume (avant le moteur).
    /// `--diag-log` l'allume pour CE lancement sans toucher à la préférence enregistrée ; en `--headless`
    /// il en est la seule porte.
    var diagnosticLog: Bool {
        didSet {
            UserDefaults.standard.set(diagnosticLog, forKey: Self.diagnosticLogKey)
            applyDiagnosticPreference()
        }
    }
    static let diagnosticLogKey = "pref.diagnosticLog"

    private init() {
        soundLibraryFolder = UserDefaults.standard.string(forKey: Self.soundLibraryFolderKey)
            ?? UserDefaults.standard.string(forKey: Self.legacySoundLibraryFolderKey)
            ?? ""
        // `--api` forces it on for THIS launch without touching the persisted setting: that is what
        // a test harness does, and it has no business changing the user's preferences.
        apiEnabled = Self.apiForcedByLaunchArgument
            || UserDefaults.standard.bool(forKey: "pref.apiEnabled")
        diagnosticLog = Diag.shouldStartAtLaunch(
            preference: UserDefaults.standard.bool(forKey: Self.diagnosticLogKey))
    }

    /// Aligne le journal réel sur la préférence (à chaque bascule ; le lancement a déjà fait le sien).
    func applyDiagnosticPreference() {
        if diagnosticLog {
            guard Diag.start() else { return }
            Diag.log(.proj, "journal activé")
            if let vm = CommandContext.shared.viewModel {
                Diag.setProject(name: vm.projectName, path: vm.projectURL?.path)
            }
        } else {
            Diag.stop(reason: "journal désactivé")
        }
    }

    // MARK: - Launch arguments

    static var apiForcedByLaunchArgument: Bool {
        CommandLine.arguments.contains("--api")
    }

    /// `--socket=<path>` (the recommended form) or `--socket <path>`: an explicit socket path
    /// (several instances side by side, or a socket in a throwaway test folder).
    /// Default: `CommandServer`'s own.
    ///
    /// ⚠️ PREFER THE JOINED FORM `--socket=/path`, and that is an AppKit trap, not a matter of
    /// taste. `NSUserDefaults` builds its argument domain by PAIRING each token starting with
    /// '-' with the next one. On `--api --socket /path`, the pair formed is (-api, --socket)
    /// and '/path' is left ORPHANED; AppKit then takes that leftover for a file to open, so it
    /// opens no 'untitled' window… and the `.onAppear` that starts the server never runs. The
    /// symptom seen: the app running, with no window and no API, without a single message.
    /// `--socket=/path` makes a single token: nothing orphaned, and the form composes with the
    /// increment-4 arguments.
    static var socketPathFromLaunchArguments: String? {
        let arguments = CommandLine.arguments
        if let joined = arguments.first(where: { $0.hasPrefix("--socket=") }) {
            let path = String(joined.dropFirst("--socket=".count))
            return path.isEmpty ? nil : path
        }
        guard let index = arguments.firstIndex(of: "--socket"),
              index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }

    /// Aligns the server's real state with the preference. Called at startup and on every flip
    /// of the checkbox.
    func applyAPIPreference() {
        let server = CommandServer.shared
        if apiEnabled {
            guard !server.isRunning else { return }
            do {
                try server.start(socketPath: Self.socketPathFromLaunchArguments
                                 ?? CommandServer.defaultSocketPath)
            } catch {
                NSLog("[API] could not start: %@", String(describing: error))
            }
        } else {
            server.stop()
        }
    }
}

struct PreferencesView: View {
    @State private var prefs = ObjekatPreferences.shared

    var body: some View { WithPerceptionTracking { perceivedBody } }

    @ViewBuilder private var perceivedBody: some View {
        Form {
            Section(L("prefs.api.section")) {
                Toggle(L("prefs.api.enable"), isOn: $prefs.apiEnabled)
                Text(descriptionAPI)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .groupedFormStyleCompat()
        .padding()
        .frame(width: 380, height: 280)
    }

    private var descriptionAPI: String {
        if prefs.apiEnabled, let path = CommandServer.shared.socketPath {
            return L("prefs.api.listening", path)
        }
        return L("prefs.api.description")
    }
}
