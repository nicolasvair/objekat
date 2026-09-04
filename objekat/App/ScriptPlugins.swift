import Foundation
import Observation

// MARK: - A third-party script's manifest

/// A 'script' is NOT run inside the app: it is a separate process that connects to the command
/// socket like any other client. That choice is structural, not a convenience — embedding an
/// interpreter would put third-party code in the thread that drives the audio engine, where an
/// exception, an infinite loop or an unlucky allocation would cost the sound. Here, the worst a
/// script can do is die: the app only notices through the exit code.
///
/// Location: `~/Library/Application Support/Objekat/Plugins/<name>/manifest.json`.
struct ScriptPluginManifest: Codable, Sendable {

    /// The displayed name. Failing that, the folder's name.
    var name: String?
    var description: String?
    var version: String?

    /// The executable to launch, a path RELATIVE to the script's folder. An absolute path, or one
    /// that climbs back up (`..`), is refused: the manifest describes its own folder, it has no
    /// business naming a binary elsewhere on the machine.
    var executable: String

    /// Arguments common to every menu entry.
    var arguments: [String]?

    /// The API commands the script needs. Checked against the registry at load time: an entry
    /// whose command is missing is shown GREYED OUT with the reason, rather than leaving the user
    /// to discover the incompatibility through a failure in the middle of the work.
    var requires: [String]?

    /// Menu entries. Absent ⇒ a single entry, carrying the script's name.
    var menu: [MenuEntry]?

    struct MenuEntry: Codable, Sendable {
        var title: String
        /// Arguments added to the manifest's own, to tell the entries apart.
        var arguments: [String]?
    }
}

/// A loaded script: its manifest, its folder, and whatever may be keeping it from running.
struct ScriptPlugin: Identifiable, Sendable {
    let id = UUID()
    let folder: URL
    let manifest: ScriptPluginManifest

    var displayName: String { manifest.name ?? folder.lastPathComponent }

    /// Non-nil = the script cannot run, and here is why (shown as a tooltip).
    var unavailableReason: String?

    var isAvailable: Bool { unavailableReason == nil }

    var entries: [ScriptPluginManifest.MenuEntry] {
        if let menu = manifest.menu, !menu.isEmpty { return menu }
        return [.init(title: displayName, arguments: nil)]
    }

    func arguments(for entry: ScriptPluginManifest.MenuEntry) -> [String] {
        (manifest.arguments ?? []) + (entry.arguments ?? [])
    }
}

// MARK: - Registry

/// Discovers the scripts at launch and launches them on demand.
///
/// `@Observable`: the 'Scripts' menu rebuilds itself after a reload, without the view having to
/// subscribe to anything.
@MainActor
@Observable
final class ScriptPluginRegistry {

    static let shared = ScriptPluginRegistry()

    private(set) var plugins: [ScriptPlugin] = []
    /// The last loading error (an unreadable manifest), kept so as to show it on first use rather
    /// than lose it in the console.
    private(set) var loadErrors: [String] = []

    static var pluginsDirectory: URL {
        CommandServer.supportDirectory().appendingPathComponent("Plugins", isDirectory: true)
    }

    private init() {}

    // MARK: Loading

    /// Rereads every manifest. Idempotent, callable from the menu.
    func reload() {
        plugins = []
        loadErrors = []

        let fm = FileManager.default
        let root = Self.pluginsDirectory
        // The folder is created if it is missing: a user looking for where to drop a script should
        // find it open, not have to guess a path that does not exist yet.
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)

        let folders = (try? fm.contentsOfDirectory(at: root,
                                                   includingPropertiesForKeys: [.isDirectoryKey],
                                                   options: [.skipsHiddenFiles])) ?? []
        for folder in folders.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: folder.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else { continue }
            let manifestURL = folder.appendingPathComponent("manifest.json")
            guard fm.fileExists(atPath: manifestURL.path) else { continue }
            do {
                let data = try Data(contentsOf: manifestURL)
                let manifest = try JSONDecoder().decode(ScriptPluginManifest.self, from: data)
                plugins.append(validated(manifest, in: folder))
            } catch {
                loadErrors.append("\(folder.lastPathComponent): \(error.localizedDescription)")
            }
        }
        NSLog("[SCRIPTS] %d script(s) loaded, %d unreadable manifest(s)",
              plugins.count, loadErrors.count)
        // The detail is logged, not only the count: a script greyed out in the menu must be able to
        // explain itself without having to hover the entry to read its tooltip.
        for plugin in plugins where !plugin.isAvailable {
            NSLog("[SCRIPTS] '%@' unavailable — %@",
                  plugin.displayName, plugin.unavailableReason ?? "?")
        }
        for error in loadErrors { NSLog("[SCRIPTS] unreadable manifest — %@", error) }
    }

    /// Checks what can be checked WITHOUT launching the script: is the executable there, is it
    /// really inside the folder, is it executable, and does the API know how to do what it asks.
    private func validated(_ manifest: ScriptPluginManifest, in folder: URL) -> ScriptPlugin {
        var plugin = ScriptPlugin(folder: folder, manifest: manifest)
        let fm = FileManager.default

        let target = folder.appendingPathComponent(manifest.executable).standardizedFileURL
        let root = folder.standardizedFileURL
        guard target.path.hasPrefix(root.path + "/") else {
            plugin.unavailableReason =
                L("script.error.executableOutsideFolder", manifest.executable)
            return plugin
        }
        guard fm.fileExists(atPath: target.path) else {
            plugin.unavailableReason = L("script.error.executableMissing", manifest.executable)
            return plugin
        }
        guard fm.isExecutableFile(atPath: target.path) else {
            plugin.unavailableReason =
                L("script.error.executableNotExecutable", manifest.executable)
            return plugin
        }

        // The registry fills itself on demand: forcing it here avoids declaring 'unknown
        // command' merely because no command has been run yet.
        CommandRegistry.shared.bootstrap()
        let known = CommandRegistry.shared.commands
        let missing = (manifest.requires ?? []).filter { known[$0] == nil }
        if !missing.isEmpty {
            plugin.unavailableReason =
                L("script.error.missingCommands", missing.joined(separator: ", "))
        }
        return plugin
    }

    // MARK: Running

    /// Launches the script. Returns `nil` if the START succeeded, an error message otherwise.
    ///
    /// We do NOT wait for the end: a script can work for several minutes, and blocking the main
    /// loop would freeze the interface AND the very socket it is trying to use.
    /// The exit code is logged when it arrives.
    @discardableResult
    func run(_ plugin: ScriptPlugin, entry: ScriptPluginManifest.MenuEntry) -> String? {
        if let reason = plugin.unavailableReason { return reason }
        guard let socketPath = CommandServer.shared.socketPath, CommandServer.shared.isRunning else {
            // With no socket, the script has nothing to drive. Saying so here is far more useful than
            // letting it fail on a 'connection refused' in its own error output.
            return L("script.error.apiDisabled")
        }

        let executable = plugin.folder.appendingPathComponent(plugin.manifest.executable)
        let process = Process()
        process.executableURL = executable
        process.arguments = plugin.arguments(for: entry)
        process.currentDirectoryURL = plugin.folder

        // The script learns WHERE to connect from the environment, never from a hard-coded path:
        // that is what lets it work under `--socket=` too (several instances).
        var environment = ProcessInfo.processInfo.environment
        environment["OBJEKAT_SOCKET"] = socketPath
        environment["OBJEKAT_PLUGIN_DIR"] = plugin.folder.path
        process.environment = environment

        process.terminationHandler = { finished in
            NSLog("[SCRIPTS] '%@' finished, code %d",
                  entry.title, finished.terminationStatus)
        }

        do {
            try process.run()
            NSLog("[SCRIPTS] launched: %@ (%@)", entry.title, executable.lastPathComponent)
            return nil
        } catch {
            return L("script.error.launchFailed", error.localizedDescription)
        }
    }
}
