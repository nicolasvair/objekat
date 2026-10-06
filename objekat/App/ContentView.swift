//
//  ContentView.swift
//  objekat
//

import SwiftUI
import Combine

struct ContentView: View {
    /// The view OBSERVES the session, it does not own it: the transport state has to outlive the
    /// view and stay readable from outside (see ObjekatSession).
    @Bindable var session: ObjekatSession
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
    @State private var leftPanelTab: LeftPanelTab = .liste
    /// The monitor that gives back the click coming home from a plugin's window
    /// (@see FirstClickThrough). A token in a `@State`, removed in `.onDisappear`.
    @State private var firstClickMonitor: Any? = nil

    /// The left panel's tabs. The inspector is a tab of its own ("Object") — it used to be docked
    /// under the list with a draggable separator; it now gets the panel's whole height.
    enum LeftPanelTab { case objet, liste, sons }

    /// The selection the LIST itself just made (a click or an arrow in it), or nil. Selecting an
    /// object brings the "Object" tab forward on its own — except when the selection comes from
    /// the list: switching away there would hide the very list one is walking. The list hands its
    /// own result over (`onOwnSelection`) BEFORE the `onChange` on `selectedIDs` runs, which
    /// compares and consumes it. Consumed at every change, so it cannot go stale: a list click
    /// that changed nothing leaves it equal to the CURRENT selection, and any later change is by
    /// definition to another set.
    @State private var listMadeSelection: Set<UUID>? = nil

    var body: some View {
        VStack(spacing: 0) {
            TransportView(
                isPlaying: $session.isPlaying,
                displayedPosition: { session.displayedPosition },
                totalDuration: viewModel.items.map { $0.startTime + $0.duration }.max() ?? 0,
                viewModel: viewModel,
                onPlay: { session.play() },
                onStop: { session.stop() }
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

            HSplitView {
                VStack(spacing: 0) {
                    // Tab switcher: project list / sound library / object inspector
                    HStack(spacing: 0) {
                        tabButton(L("panel.tab.object"), tab: .objet)
                        tabButton(L("panel.tab.list"), tab: .liste)
                        tabButton(L("panel.tab.sounds"), tab: .sons)
                    }
                    .frame(height: 28)
                    Divider()

                    Group {
                        switch leftPanelTab {
                        case .liste: SoundObjectListView(viewModel: viewModel,
                                                         onOwnSelection: { listMadeSelection = $0 })
                        case .sons:  SoundLibraryView()
                        case .objet: ObjectInspectorView(viewModel: viewModel)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(minWidth: 250, maxWidth: 360)

                TimelineView(
                    viewModel: viewModel,
                    playheadPosition: { session.playheadPosition },
                    selectionCursor: viewModel.cursorPosition,
                    isPlaying: session.isPlaying,
                    isPaused: session.pausedAt != nil,
                    onTogglePlayback: { if session.isPlaying { session.stop() } else { session.play() } },
                    onTogglePause: { session.togglePause() },
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
        .sheet(isPresented: Binding(get: { session.viewModel.exportPanelPresented },
                                    set: { session.viewModel.exportPanelPresented = $0 })) {
            ExportPanelView(viewModel: session.viewModel)
        }
        // An export rendering directly suspends playback on the engine side: the SESSION's transport
        // state has to follow, otherwise the button would stay on 'stop' and the playhead would
        // freeze while claiming to play. @see EditViewModel.pendingPlaybackStop
        .onChange(of: viewModel.pendingPlaybackStop) { _, stopRequested in
            guard stopRequested else { return }
            viewModel.pendingPlaybackStop = false
            if session.isPlaying { session.stop() }
        }
        // A NEW, non-empty object selection brings the inspector forward — unless the list made
        // it (@see `listMadeSelection`). An emptied selection leaves the panel where it is.
        .onChange(of: viewModel.selectedIDs) { old, new in
            let fromList = listMadeSelection == new
            listMadeSelection = nil
            guard !new.isEmpty, new != old, !fromList else { return }
            leftPanelTab = .objet
        }
        .onChange(of: viewModel.seekRequest) { _, _ in
            session.applyPendingSeekRequest()
        }
        .onChange(of: viewModel.loopRegion) { _, newRegion in
            session.loopRegionChanged(newRegion)
        }
        .onChange(of: viewModel.loopModeEnabled) { _, enabled in
            session.loopModeChanged(enabled)
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
                AudioOutputDevice.shared.name = selectedDevice
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

    // MARK: - Left tab switcher

    @ViewBuilder
    private func tabButton(_ label: String, tab: LeftPanelTab) -> some View {
        Button(action: { leftPanelTab = tab }) {
            Text(label)
                .font(.system(size: 11, weight: leftPanelTab == tab ? .semibold : .regular))
                .foregroundStyle(leftPanelTab == tab ? Color.primary : Color.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // Without contentShape, `.plain` only makes the text's glyphs clickable:
                // the whole rectangle of the tab has to answer the click.
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(leftPanelTab == tab ? Color(nsColor: .selectedContentBackgroundColor).opacity(0.15) : Color.clear)
    }

}

#Preview {
    let workspace = Workspace()
    ContentView(session: workspace.session, workspace: workspace)
}
