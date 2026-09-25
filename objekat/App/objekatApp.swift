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
/// modified project — otherwise SwiftUI quits without asking anything. And receives the sessions
/// the Finder hands over (`application(_:open:)`), which a `WindowGroup` has no door for.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var viewModel: EditViewModel?
    /// Tabs (INC 1): weak for the same reason `CommandContext.session` is — the delegate must not
    /// keep a workspace alive the app has let go of. Quitting goes through it rather than through
    /// `viewModel` alone, since an inactive tab's own unsaved changes are things only the
    /// workspace knows about.
    ///
    /// Setting it is also what releases the sessions the Finder handed over BEFORE any window
    /// existed (a cold launch by a double-click, @see `application(_:open:)`): they wait in
    /// `pendingOpenURLs` until there is a workspace to give them to.
    weak var workspace: Workspace? {
        didSet {
            guard let workspace, !pendingOpenURLs.isEmpty else { return }
            let urls = pendingOpenURLs
            pendingOpenURLs = []
            workspace.openFromOutside(urls)
        }
    }

    /// Sessions opened from the Finder before the window's `onAppear` attached the workspace.
    private var pendingOpenURLs: [URL] = []

    /// A session handed over from OUTSIDE — a double-click on a `.objekat` in the Finder (the type
    /// `Info.plist` declares and claims, @see SessionFile), a file dropped on the Dock icon,
    /// `open -a OBJEKAT x.objekat`. AppKit calls this at a warm launch AND at a cold one, where it
    /// comes BEFORE `applicationDidFinishLaunching` — hence before any window, any `onAppear`,
    /// any workspace attached here.
    ///
    /// Only what has a session's extension is taken (a legacy `.json` included: `open -a` can hand
    /// one over although the Finder never offers it); anything else is left alone, as it always
    /// was. That includes the one case this method did not create but now meets: an ORPHANED launch
    /// argument, which AppKit turns into an opening (@see LaunchArguments) — a `.json` project left
    /// orphaned on the command line now opens, anything else is still ignored.
    func application(_ application: NSApplication, open urls: [URL]) {
        let sessions = urls.filter { $0.isFileURL && SessionFile.hasSessionExtension($0) }
        guard !sessions.isEmpty else { return }
        if let workspace {
            workspace.openFromOutside(sessions)
        } else {
            pendingOpenURLs.append(contentsOf: sessions)
            ensureDocumentWindowAfterLaunch()
        }
    }

    /// A cold launch by a DOCUMENT gets no window by itself. AppKit asks for the untitled window
    /// (`applicationOpenUntitledFile`) only when it was launched with nothing to open — which is,
    /// as far as the symptom below lets one read it, how SwiftUI's `WindowGroup` puts up its first
    /// window — and skips it when there is a file: the app would then sit there with the session
    /// queued and nowhere to show it. It is the very symptom `LaunchArguments` documents for an
    /// orphaned argument ("the app runs, mute and with no interface"), which AppKit ALSO turns into
    /// an opening at launch. So once the launch is over (the hop to the next turn of the loop), if
    /// no workspace has been attached and no document window exists, the untitled window is asked
    /// for by hand, through the application's own delegate — SwiftUI's, which forwards to this one
    /// what it does not answer itself. Asked ONLY with no titled window at all: a second window on
    /// the one session is exactly what `applicationWillFinishLaunching` turns tabbing off to avoid.
    /// If SwiftUI does not answer it, nothing worse happens than before this method existed — and a
    /// click on the Dock icon still brings a window, which then takes the queued file.
    /// NOT SEEN ON A SCREEN: this is the half of the feature that needs a real cold launch.
    private func ensureDocumentWindowAfterLaunch() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.workspace == nil, !self.pendingOpenURLs.isEmpty else { return }
            let hasDocumentWindow = NSApp.windows.contains {
                $0.styleMask.contains(.titled) && !($0 is NSPanel)
            }
            guard !hasDocumentWindow else { return }
            _ = NSApp.delegate?.applicationOpenUntitledFile?(NSApp)
        }
    }

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
        panel.allowedContentTypes = SessionFile.openableContentTypes
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

    /// "Fermer l'onglet" (Cmd+W) on the ACTIVE tab — the strip's ✕ goes through the very same
    /// door (`Workspace.closeWithConfirmation`), hence the very same question. An inactive tab's
    /// own unsaved changes are asked about by `Workspace.confirmQuit()` at quit time, never here
    /// (closing ONE tab is not the moment to relitigate every other one).
    private func closeActiveTabWithConfirmation() {
        workspace.closeWithConfirmation(workspace.activeTabID)
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
                // A session handed over by the Finder goes to THIS window, never to a new one: a
                // `WindowGroup` otherwise answers an external event by opening another window —
                // a second `ContentView` on the one session, which tabs exist precisely to avoid
                // (@see `applicationWillFinishLaunching`). `onOpenURL` is the SwiftUI half of the
                // opening, the AppDelegate's `application(_:open:)` the AppKit half: whichever of
                // the two SwiftUI delivers a document to, both feed the same queue, which opens a
                // file once however many roads it came by (@see Workspace.openFromOutside).
                .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
                .onOpenURL { url in
                    guard url.isFileURL, SessionFile.hasSessionExtension(url) else { return }
                    workspace.openFromOutside([url])
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
