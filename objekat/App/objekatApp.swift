//
//  objekatApp.swift
//  objekat
//
//  Created by Nicolas Vair on 17/05/2026.
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Intercepts the end of the app (Cmd+Q, the Quit menu, a system shutdown) to offer to save a
/// modified project — otherwise SwiftUI quits without asking anything.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var viewModel: EditViewModel?
    /// Tabs (INC 1): weak for the same reason `CommandContext.session` is — the delegate must not
    /// keep a workspace alive the app has let go of. Quitting goes through it rather than through
    /// `viewModel` alone, since an inactive tab's own unsaved changes are things only the
    /// workspace knows about.
    weak var workspace: Workspace?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let vm = viewModel else { return .terminateNow }
        // The anti-reentrance guard (step 4): quitting mid-load would tear the engine down while
        // `applyProjectDocument` still owns it (the `ReallocationInhibitor`, the deferred-compile
        // queue) — refused outright rather than risking a half-loaded project on the next launch.
        // A tab switch under way is the same hazard under a different name.
        guard !vm.isLoadingProject, workspace?.isSwitching != true else { return .terminateCancel }
        guard let workspace else { return vm.confirmSaveBeforeQuit() ? .terminateNow : .terminateCancel }
        return workspace.confirmQuit()
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

    /// Tabs (INC 1): a native tab's own "+" would open a SECOND `WindowGroup` scene instance —
    /// hence a second `ContentView` pointed at the very same `session` — which is not what tabs
    /// mean here (one engine, several DOCUMENTS taking turns, never two windows open on it at
    /// once). Turned off before any window exists.
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false
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
    // The WORKSPACE is owned here (and not in ContentView): it carries the session — hence the
    // engine, the document and the transport state, all of which have to outlive the window and
    // stay reachable both from the File menu's commands and from external driving — plus the tab
    // list (INC 1). `session` stays a shorthand for `workspace.session`: every existing call site
    // that reads it keeps reading the SAME session, tabs being a matter of what document it is
    // pointed at, never a second one.
    @State private var workspace = Workspace()
    private var session: ObjekatSession { workspace.session }
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

    /// Every entry that touches the document, the engine or the transport is disabled for the span
    /// of a load (step 4's anti-reentrance guard) OR of a tab switch (INC 1) — the moment BETWEEN
    /// parking the outgoing tab and the incoming one's `applyProjectDocumentAsync` actually
    /// starting is not covered by `isLoadingProject` alone.
    private var busy: Bool { viewModel.isLoadingProject || workspace.isSwitching }

    /// The panel half of "Ouvrir…" (Cmd+O), kept here rather than inside `Workspace` — an
    /// `NSOpenPanel` is exactly the kind of AppKit detail `EditViewModel`'s own `loadProjectAsyncFromPanel`
    /// keeps out of the model, and `Workspace.replaceActive(with:)` is the door once a URL exists.
    private func openProjectPanel() {
        let panel = NSOpenPanel()
        panel.title = L("project.open.title")
        panel.allowedContentTypes = [.json]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { await workspace.replaceActive(with: url) }
        }
    }

    /// A tab switch refused by `tabSwitchBlocker` (export/render/consolidate edit under way) is
    /// told through `notify` rather than silently ignored — the same doctrine as every other
    /// refusal in this app.
    private func selectTab(_ id: UUID) {
        Task {
            if case .failure(.blocked(let reasonKey)) = await workspace.select(id) {
                viewModel.notify(L("tabs.switch.refused.title"), L(reasonKey))
            }
        }
    }

    private func selectRelativeTab(by delta: Int) {
        let tabs = workspace.tabs
        guard tabs.count > 1, let idx = tabs.firstIndex(where: { $0.id == workspace.activeTabID })
        else { return }
        let n = tabs.count
        selectTab(tabs[((idx + delta) % n + n) % n].id)
    }

    /// The confirmation "Fermer l'onglet" (Cmd+W) owes an unsaved ACTIVE tab — an inactive one's
    /// own dirty tab is asked about by `Workspace.confirmQuit()` at quit time, never here (closing
    /// ONE tab is not the moment to relitigate every other one).
    private func closeActiveTabWithConfirmation() {
        guard let tab = workspace.activeTab else { return }
        guard workspace.isDirty(for: tab) else {
            _ = workspace.close(tab.id, discard: false)
            return
        }
        switch viewModel.askDirtyDecision(titleKey: "dialog.dirty.title.closeTab",
                                          name: workspace.displayName(for: tab)) {
        case .cancel:
            return
        case .discard:
            _ = workspace.close(tab.id, discard: true)
        case .save:
            if viewModel.projectURL != nil {
                viewModel.save()
                _ = workspace.close(tab.id, discard: true)
            } else {
                // No file yet: the panel is asynchronous, so the tab is left open rather than
                // guessed at — a second Cmd+W once it is saved closes it cleanly.
                viewModel.saveAs()
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView(session: session, workspace: workspace)
                .preferredColorScheme(.dark)
                .onAppear {
                    appDelegate.viewModel = viewModel
                    appDelegate.workspace = workspace
                    // Command API: the context is always attached (a command arriving with no document
                    // answers `invalid_state` rather than staying silent), but the server only starts if the
                    // preference — or `--api` — asks for it.
                    CommandContext.shared.session = session
                    CommandContext.shared.workspace = workspace
                    ObjekatPreferences.shared.applyAPIPreference()
                }
        }
        .windowResizability(.contentMinSize)
        .commands {
            // The anti-reentrance guard (step 4): every entry that touches the document, the engine
            // or the transport is disabled for the span of a load — `isLoadingProject` reads
            // `viewModel.loadState`, an `@Observable` property, so the menu regreys itself with no
            // extra plumbing.
            CommandGroup(replacing: .newItem) {
                Button(L("menu.file.newProject")) { viewModel.newProject() }
                    .keyboardShortcut("n", modifiers: [.command])
                    .disabled(busy)
                Button(L("menu.file.newTab")) { _ = workspace.newTab() }
                    .keyboardShortcut("t", modifiers: [.command])
                    .disabled(busy)
                Button(L("menu.file.open")) { openProjectPanel() }
                    .keyboardShortcut("o", modifiers: [.command])
                    .disabled(busy)
                Menu(L("menu.file.recentProjects")) {
                    if viewModel.recentProjects.isEmpty {
                        Button(L("menu.file.noRecentItems")) {}
                            .disabled(true)
                    } else {
                        ForEach(viewModel.recentProjects, id: \.self) { url in
                            Button(EditViewModel.projectDisplayName(for: url)) {
                                Task { await workspace.open(url: url, inNewTab: false) }
                            }
                        }
                        Divider()
                        Button(L("menu.file.clearRecentItems")) {
                            viewModel.clearRecentProjects()
                        }
                    }
                }
                .disabled(busy)
            }
            CommandGroup(replacing: .saveItem) {
                Button(L("menu.file.save")) { viewModel.save() }
                    .keyboardShortcut("s", modifiers: [.command])
                    .disabled(busy)
                Button(L("menu.file.saveAs")) { viewModel.saveAs() }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                    .disabled(busy)
                Button(L("menu.file.saveCopyWithAudio")) {
                    viewModel.saveCopyWithAudioFiles()
                }
                    .disabled(busy)
                Divider()
                // Mix export: opens the settings panel; the render that follows runs in the background
                // (@see EditViewModel+Export).
                Button(L("menu.file.export")) { viewModel.openExportPanel() }
                    .keyboardShortcut("e", modifiers: [.command])
                    .disabled(busy)
                Divider()
                // Tabs (INC 1): a single tab falls back on the plain "close window" (whatever
                // window is key — a plugin editor, Preferences — is exactly what a hand pressing
                // Cmd+W usually means there), and so does a keypress landing on any window OTHER
                // than the document's own (`viewModel.titledWindow`, @see `adoptDocumentWindow`).
                Button(L("menu.file.closeTab")) {
                    if workspace.tabs.count <= 1 || NSApp.keyWindow !== viewModel.titledWindow {
                        NSApp.keyWindow?.performClose(nil)
                    } else {
                        closeActiveTabWithConfirmation()
                    }
                }
                    .keyboardShortcut("w", modifiers: [.command])
                    .disabled(busy)
            }
            // Tabs (INC 1): grouped with the Window menu's own arrangement entries
            // (Minimise/Zoom/Bring All to Front), which is where a list of open "things" belongs.
            CommandGroup(after: .windowArrangement) {
                Divider()
                Button(L("menu.window.nextTab")) { selectRelativeTab(by: 1) }
                    .keyboardShortcut(.tab, modifiers: [.control])
                    .disabled(workspace.tabs.count < 2)
                Button(L("menu.window.previousTab")) { selectRelativeTab(by: -1) }
                    .keyboardShortcut(.tab, modifiers: [.control, .shift])
                    .disabled(workspace.tabs.count < 2)
                if workspace.tabs.count >= 2 {
                    Menu(L("menu.window.goToTab")) {
                        ForEach(Array(workspace.tabs.prefix(9).enumerated()), id: \.element.id) { index, tab in
                            Button(workspace.displayName(for: tab)) { selectTab(tab.id) }
                                .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")),
                                                 modifiers: [.command])
                        }
                    }
                }
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
                    .disabled(busy)
                }
                Divider()
                Button(L("menu.scripts.openFolder")) {
                    let folder = ScriptPluginRegistry.pluginsDirectory
                    try? FileManager.default.createDirectory(at: folder,
                                                             withIntermediateDirectories: true)
                    NSWorkspace.shared.open(folder)
                }
                .disabled(busy)
                Button(L("menu.scripts.reload")) { scripts.reload() }
                    .disabled(busy)
            }
        }

        Settings {
            PreferencesView()
        }
    }
}
