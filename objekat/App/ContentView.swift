//
//  ContentView.swift
//  objekat
//

import SwiftUI
import Combine
import Perception

struct ContentView: View {
    /// The view OBSERVES the session, it does not own it: the transport state has to outlive the
    /// view and stay readable from outside (see ObjekatSession).
    @Perception.Bindable var session: ObjekatSession
    /// Project tabs (INC 1) — observed for the tab strip alone; every gesture beneath it keeps
    /// reading `session`/`viewModel` exactly as before, a tab switch being nothing more than the
    /// SAME session pointed at a different document.
    var workspace: Workspace
    /// Read-only shorthands — the body of the view goes on saying `engine` and `viewModel`, which
    /// keeps this file's diff down to what really changes.
    private var engine: OBJEngineCore { session.engine }
    private var viewModel: EditViewModel { session.viewModel }
    @State private var outputDevices: [String] = []
    @State private var selectedDevice: String = ""
    /// The Finder tab's state, owned here so that it outlives the tab: the `switch` below removes the
    /// view from the hierarchy at every change of tab, and a `@State` inside it went with it.
    @State private var soundLibrary = SoundLibraryViewModel()
    /// The monitor that gives back the click coming home from a plugin's window
    /// (@see FirstClickThrough). A token in a `@State`, removed in `.onDisappear`.
    @State private var firstClickMonitor: Any? = nil

    // The left panel's tabs (`LeftPanelTabID`) and its width live in the view-model, which saves them with the
    // project (@see EditViewModel.leftPanelTab / leftPanelWidth). The inspector is a tab of its own
    // ("Object") — it used to be docked under the list with a draggable separator; it now gets the
    // panel's whole height.

    /// The selection the LIST itself just made (a click or an arrow in it), or nil. Selecting an
    /// object brings the "Object" tab forward on its own — except when the selection comes from
    /// the list: switching away there would hide the very list one is walking. The list hands its
    /// own result over (`onOwnSelection`) BEFORE the `onChange` on `selectedIDs` runs, which
    /// compares and consumes it. Consumed at every change, so it cannot go stale: a list click
    /// that changed nothing leaves it equal to the CURRENT selection, and any later change is by
    /// definition to another set.
    @State private var listMadeSelection: Set<UUID>? = nil

    var body: some View { WithPerceptionTracking { perceivedBody } }

    @ViewBuilder private var perceivedBody: some View {
        // Read here, inside the tracked body: a `Binding(get:)` is evaluated by SwiftUI OUTSIDE it,
        // where the Perception backport would see nothing and never refresh the sheet.
        let exportPanelPresented = viewModel.exportPanelPresented
        VStack(spacing: 0) {
            TransportView(
                isPlaying: $session.isPlaying,
                displayedPosition: { session.displayedPosition },
                totalDuration: viewModel.items.map { $0.startTime + $0.duration }.max() ?? 0,
                viewModel: viewModel,
                onPlay: { session.play() },
                onStop: { session.stop() },
                onRecord: { session.toggleRecording() }
            )

            // An export in progress: a full-width strip, right under the transport. It pushes the rest
            // down rather than squeezing into an already full toolbar — a long export must never look
            // like a freeze. @see ExportProgressBar
            ExportProgressBar(viewModel: viewModel)
                .animation(.easeOut(duration: 0.15), value: viewModel.exportJob?.phase)

            // Project tabs (INC 1): a bar that costs nothing to look at with a single project open
            // — it simply is not there.
            if workspace.tabs.count >= 2 {
                WorkspaceTabBar(workspace: workspace)
                Divider()
            }

            Divider()

            // The panel is a FIXED-width column and the divider a handle of ours, instead of a split view: the
            // width is a number we hold, save and restore, and a freshly built layout has nothing to guess
            // (@see Shared/LeftPanelLayout). `GeometryReader`'s closure is evaluated outside the tracked
            // body, hence the explicit `WithPerceptionTracking` inside it.
            GeometryReader { geo in WithPerceptionTracking {
                let container = geo.size.width
                let storedWidth = viewModel.leftPanelWidth
                HStack(spacing: 0) {
                    leftPanelColumn
                        .frame(width: LeftPanelLayout.clampedWidth(storedWidth, containerWidth: container))

                    LeftPanelDivider(width: storedWidth,
                                     containerWidth: container,
                                     onDrag: { viewModel.leftPanelWidth = $0 },
                                     onEnd: { ObjekatPreferences.shared.leftPanelWidth = $0 })

                    TimelineView(
                        viewModel: viewModel,
                        playheadPosition: { session.playheadPosition },
                        selectionCursor: viewModel.cursorPosition,
                        isPlaying: session.isPlaying,
                        isPaused: session.pausedAt != nil,
                        onTogglePlayback: { if session.isPlaying { session.stop() } else { session.play() } },
                        onTogglePause: { session.togglePause() },
                        onToggleRecord: { session.toggleRecording() },
                        onMoveCursor: { t in
                            viewModel.cursorPosition = max(0, t)
                        },
                        onJumpPlayhead: { t in session.jumpPlayhead(to: t) },
                        onReturnToZero: { session.returnToZero() }
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .simultaneousGesture(TapGesture().onEnded {
                        NSApp.keyWindow?.makeFirstResponder(nil)
                    })
                    .frame(minWidth: 420)
                }
            } }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // The progress overlay of a project load (step 6, project_load_progress_plan): drawn
            // on top of the content zone only — the transport bar above stays legible, if inert
            // (its own controls guard `isLoadingProject` where it matters, @see ObjekatSession).
            .overlay { ProjectLoadOverlay(viewModel: viewModel) }
        }
        .frame(minWidth: 700, minHeight: 420)
        // The export panel: a compact sheet, placed high in the window — the timeline stays visible
        // underneath, which is what lets you SEE the I/O markers move as you set the range.
        // An explicit binding: `viewModel` is a computed shorthand on the session here, and you
        // cannot project a `$` from it.
        .sheet(isPresented: Binding(get: { exportPanelPresented },
                                    set: { session.viewModel.exportPanelPresented = $0 })) { WithPerceptionTracking {
            ExportPanelView(viewModel: session.viewModel)
        } }
        // An export rendering directly suspends playback on the engine side: the SESSION's transport
        // state has to follow, otherwise the button would stay on 'stop' and the playhead would
        // freeze while claiming to play. @see EditViewModel.pendingPlaybackStop
        .onChangeCompat(of: viewModel.pendingPlaybackStop) { _, stopRequested in
            guard stopRequested else { return }
            viewModel.pendingPlaybackStop = false
            if session.isPlaying { session.stop() }
        }
        // A NEW, non-empty object selection brings the inspector forward — unless the list made
        // it (@see `listMadeSelection`). An emptied selection leaves the panel where it is.
        .onChangeCompat(of: viewModel.selectedIDs) { old, new in
            let fromList = listMadeSelection == new
            listMadeSelection = nil
            // A selection that merely RETURNS with its document (a tab switch) keeps the panel tab it was left on.
            let fromTabSwitch = viewModel.selectionRestoredByTabSwitch == new
            viewModel.selectionRestoredByTabSwitch = nil
            guard !new.isEmpty, new != old, !fromList, !fromTabSwitch else { return }
            viewModel.leftPanelTab = .objet
        }
        // A click on an object under a time selection that already selected it changes no selection, hence no
        // "new selection" above: it asks for the inspector by this counter instead.
        .onChangeCompat(of: viewModel.inspectorRequests) { _, _ in
            viewModel.leftPanelTab = .objet
        }
        .onChangeCompat(of: viewModel.seekRequest) { _, _ in
            session.applyPendingSeekRequest()
        }
        .onDisappear {
            FirstClickThrough.remove(&firstClickMonitor)
        }
        .onAppear {
            // Wires the engine to the document and arms the playhead tracking (idempotent).
            session.start()
            // A click coming back from a plugin's window must not be spent on the window itself.
            if firstClickMonitor == nil { firstClickMonitor = FirstClickThrough.install() }
            outputDevices = (engine.availableOutputDevices() as? [String]) ?? []
            // Output device: reapplies the persisted choice if it still exists, otherwise
            // aligns on the engine's CURRENT device (the picker used to show the first of
            // the list, which could differ from the device actually open → previews and
            // timeline seemed to play out of different cards from the very start).
            let saved = AudioOutputDevice.shared.name
            if !saved.isEmpty, outputDevices.contains(saved) {
                engine.setOutputDevice(saved)
                selectedDevice = saved
            } else {
                selectedDevice = engine.currentOutputDeviceName() ?? outputDevices.first ?? ""
                // `--virtual-audio` is a test fixture: it must not become the remembered choice.
                if !OBJEngineCore.isVirtualAudio() { AudioOutputDevice.shared.name = selectedDevice }
            }
            // Input card: the choice (a UID) is handed to the engine, which only remembers it until the
            // inputs open. A card that is not there any more resets the choice to "the output card".
            if !OBJEngineCore.isVirtualAudio(), let savedInput = AudioInputDevice.shared.uid {
                if engine.setInputDevice(savedInput) != nil { AudioInputDevice.shared.uid = nil }
                AudioDeviceStatus.shared.refresh()
            }
            // At launch, AppKit gives first responder to the window's first text field — the BPM
            // one — which ends up selected without anyone asking for it.
            // `NSApp.keyWindow` is still nil at that first onAppear (the window is not key):
            // the old call therefore never did anything. We try again briefly.
            Self.releaseInitialTextFocus()
            // The document window is identified HERE, while it is the only one: it then wears
            // the project's name and its file (the proxy icon, ⌘-click on the title), and a
            // plugin's editor opened later can no longer be mistaken for it.
            viewModel.adoptDocumentWindow()
        }
    }

    // MARK: - Initial focus

    /// Gives first responder back to the window if AppKit handed it to a text field at launch.
    /// Without this, the BPM field started out selected: opening a project then left it showing
    /// '120', and losing focus committed that 120 back over the project's tempo.
    /// The WindowGroup's window may not exist at the first onAppear → a few attempts.
    @MainActor
    private static func releaseInitialTextFocus(attempt: Int = 0) {
        guard let window = NSApp.keyWindow ?? NSApp.windows.first(where: {
            $0.styleMask.contains(.titled) && $0.contentView != nil
        }) else {
            if attempt < 10 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    releaseInitialTextFocus(attempt: attempt + 1)
                }
            }
            return
        }
        // Only disturbs the faulty case: a text field focused without anyone asking.
        if window.firstResponder is NSTextView {
            window.makeFirstResponder(nil)
        } else if attempt < 4 {
            // Focus may only be granted after display: we come back a few times,
            // but briefly (~0.6 s) — beyond that, it would be stealing focus from a real click.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                releaseInitialTextFocus(attempt: attempt + 1)
            }
        }
    }

    // MARK: - The left panel's column

    /// The tab strip and the active tab's content. Called from inside the tracked region of the layout above.
    @ViewBuilder
    private var leftPanelColumn: some View {
        VStack(spacing: 0) {
            // Tab switcher: project list / sound library / object inspector
            HStack(spacing: 0) {
                tabButton(L("panel.tab.object"), tab: .objet)
                tabButton(L("panel.tab.list"), tab: .liste)
                tabButton(L("panel.tab.sounds"), tab: .sons)
                tabButton(L("panel.tab.inputs"), tab: .entrees)
            }
            .frame(height: 28)
            Divider()

            Group {
                switch viewModel.leftPanelTab {
                case .liste: SoundObjectListView(viewModel: viewModel,
                                                 onOwnSelection: { listMadeSelection = $0 })
                case .sons:  SoundLibraryView(vm: soundLibrary)
                                .onAppear {
                                    // Removing a slot that holds a folder asks first, through the
                                    // view-model's dialogue policy.
                                    soundLibrary.confirm = { [viewModel] title, info, yes, no in
                                        viewModel.confirm(title, info, yes: yes, no: no)
                                    }
                                }
                case .objet: ObjectInspectorView(viewModel: viewModel)
                case .entrees: InputsPanelView(viewModel: viewModel)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Left tab switcher

    @ViewBuilder
    private func tabButton(_ label: String, tab: LeftPanelTabID) -> some View {
        let active = viewModel.leftPanelTab == tab
        return Button(action: { viewModel.leftPanelTab = tab }) {
            Text(label)
                .font(.system(size: 11, weight: active ? .semibold : .regular))
                .foregroundStyle(active ? Color.primary : Color.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // Without contentShape, `.plain` only makes the text's glyphs clickable:
                // the whole rectangle of the tab has to answer the click.
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(active ? Color(nsColor: .selectedContentBackgroundColor).opacity(0.15) : Color.clear)
    }

}

#Preview {
    let workspace = Workspace()
    ContentView(session: workspace.session, workspace: workspace)
}
