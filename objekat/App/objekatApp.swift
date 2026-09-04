//
//  objekatApp.swift
//  objekat
//
//  Created by Nicolas Vair on 17/05/2026.
//

import SwiftUI
import AppKit

/// Intercepts the end of the app (Cmd+Q, the Quit menu, a system shutdown) to offer to save a
/// modified project — otherwise SwiftUI quits without asking anything.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var viewModel: EditViewModel?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let vm = viewModel else { return .terminateNow }
        return vm.confirmSaveBeforeQuit() ? .terminateNow : .terminateCancel
    }

    /// Starts the command server WITHOUT waiting for a window to appear.
    ///
    /// `ContentView`'s `.onAppear` asks for it too (and that is where the view-model gets
    /// attached), but relying on that ALONE makes the API depend on a window opening — and AppKit
    /// may decide to open none, typically when an orphaned argument is left on the command line
    /// (see the note on `socketPathFromLaunchArguments`). The API then vanished without a message.
    /// Starting here guarantees the socket exists from launch: while no document is attached, the
    /// commands answer `invalid_state`, which is a diagnosis — a silence is not. The call is
    /// idempotent.
    func applicationDidFinishLaunching(_ notification: Notification) {
        ObjekatPreferences.shared.applyAPIPreference()
        // Third-party scripts are read ONCE at launch (the 'Scripts' menu offers to read them
        // again). Rereading them every time the menu opens would mean one disk access per click for
        // a folder that, in practice, never moves during a session.
        ScriptPluginRegistry.shared.reload()
    }

    /// Shuts the command server down cleanly: the socket is a file, and leaving it behind would
    /// make the next client believe a server is still listening.
    func applicationWillTerminate(_ notification: Notification) {
        CommandServer.shared.stop()
    }
}

// No `@main` here: the entry point is main.swift, which routes between the windowed app and
// the windowless mode. Both together would be a compile error.
struct objekatApp: App {
    // The SESSION is owned here (and not in ContentView): it carries the engine, the document
    // and the transport state, all of which have to outlive the window and stay reachable both
    // from the File menu's commands and from external driving.
    @State private var session = ObjekatSession()
    private var engine: OBJEngineCore { session.engine }
    private var viewModel: EditViewModel { session.viewModel }
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    /// The registry of third-party scripts. `@State` on an `@Observable` singleton: the menu
    /// rebuilds itself after 'Reload the scripts'.
    @State private var scripts = ScriptPluginRegistry.shared

    /// One entry per script, or a submenu when the manifest declares several.
    @ViewBuilder
    private func scriptMenu(for plugin: ScriptPlugin) -> some View {
        let entries = plugin.entries
        if entries.count == 1, let only = entries.first {
            scriptButton(plugin, only, title: plugin.displayName)
        } else {
            Menu(plugin.displayName) {
                ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                    scriptButton(plugin, entry, title: entry.title)
                }
            }
            // A submenu does not grey itself out: without this, an unavailable script would stay
            // openable and its entries would fail one by one.
            .disabled(!plugin.isAvailable)
        }
    }

    private func scriptButton(_ plugin: ScriptPlugin,
                              _ entry: ScriptPluginManifest.MenuEntry,
                              title: String) -> some View {
        Button(title) {
            if let error = scripts.run(plugin, entry: entry) {
                // Goes through `notify` (and not `NSAlert` directly): under automated driving the dialogue
                // policy writes to the journal instead of freezing the app on a modal.
                viewModel.notify(L("script.run.failed", title), error)
            }
        }
        .disabled(!plugin.isAvailable)
        .helpIf(plugin.unavailableReason ?? plugin.manifest.description)
    }

    var body: some Scene {
        WindowGroup {
            ContentView(session: session)
                .preferredColorScheme(.dark)
                .onAppear {
                    appDelegate.viewModel = viewModel
                    // Command API: the context is always attached (a command arriving with no document
                    // answers `invalid_state` rather than staying silent), but the server only starts if the
                    // preference — or `--api` — asks for it.
                    CommandContext.shared.session = session
                    ObjekatPreferences.shared.applyAPIPreference()
                }
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button(L("menu.file.newProject")) { viewModel.newProject() }
                    .keyboardShortcut("n", modifiers: [.command])
                Button(L("menu.file.open")) { viewModel.loadProject() }
                    .keyboardShortcut("o", modifiers: [.command])
                Menu(L("menu.file.recentProjects")) {
                    if viewModel.recentProjects.isEmpty {
                        Button(L("menu.file.noRecentItems")) {}
                            .disabled(true)
                    } else {
                        ForEach(viewModel.recentProjects, id: \.self) { url in
                            Button(url.deletingPathExtension().lastPathComponent) {
                                viewModel.openRecentProject(url)
                            }
                        }
                        Divider()
                        Button(L("menu.file.clearRecentItems")) {
                            viewModel.clearRecentProjects()
                        }
                    }
                }
            }
            CommandGroup(replacing: .saveItem) {
                Button(L("menu.file.save")) { viewModel.save() }
                    .keyboardShortcut("s", modifiers: [.command])
                Button(L("menu.file.saveAs")) { viewModel.saveAs() }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                Button(L("menu.file.saveCopyWithAudio")) {
                    viewModel.saveCopyWithAudioFiles()
                }
                Divider()
                // Mix export: opens the settings panel; the render that follows runs in the background
                // (@see EditViewModel+Export).
                Button(L("menu.file.export")) { viewModel.openExportPanel() }
                    .keyboardShortcut("e", modifiers: [.command])
            }
            // THE 'SCRIPTS' MENU — entries declared by the manifests in
            // `~/Library/Application Support/Objekat/Plugins/`. Each entry launches a SEPARATE PROCESS
            // that connects to the socket; nothing is interpreted inside the app.
            CommandMenu(L("menu.scripts.title")) {
                if scripts.plugins.isEmpty {
                    Button(L("menu.scripts.none")) {}
                        .disabled(true)
                } else {
                    ForEach(scripts.plugins) { plugin in
                        scriptMenu(for: plugin)
                    }
                }
                Divider()
                Button(L("menu.scripts.openFolder")) {
                    let folder = ScriptPluginRegistry.pluginsDirectory
                    try? FileManager.default.createDirectory(at: folder,
                                                             withIntermediateDirectories: true)
                    NSWorkspace.shared.open(folder)
                }
                Button(L("menu.scripts.reload")) { scripts.reload() }
            }
        }

        Settings {
            PreferencesView()
        }
    }
}
