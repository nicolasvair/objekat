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
    /// Read-only shorthands — the body of the view goes on saying `engine` and `viewModel`, which
    /// keeps this file's diff down to what really changes.
    private var engine: OBJEngineCore { session.engine }
    private var viewModel: EditViewModel { session.viewModel }
    @State private var outputDevices: [String] = []
    @State private var selectedDevice: String = ""
    @State private var leftPanelTab: LeftPanelTab = .liste
    // Height of the bottom inspector, persisted in UserDefaults and applied straight away at
    // launch (the draggable separator updates it in place).
    @AppStorage("inspectorHeight") private var inspectorHeight: Double = 190
    @State private var resizeStartHeight: Double? = nil

    private let inspectorMinHeight: Double = 120
    // The minimum height guaranteed to the list / sound library above the docked inspector
    // (the inspector cannot grow to the point of hiding it).
    private let listMinHeight: Double = 140
    // The reduced height of the inspector when nothing is selected (icon and message alone).
    private let inspectorCollapsedHeight: CGFloat = 92
    enum LeftPanelTab { case liste, sons }

    var body: some View {
        VStack(spacing: 0) {
            TransportView(
                isPlaying: $session.isPlaying,
                playheadPosition: session.playheadPosition,
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

            Divider()

            HSplitView {
                VStack(spacing: 0) {
                    // Tab switcher: project list / sound library
                    HStack(spacing: 0) {
                        tabButton(L("panel.tab.list"), tab: .liste)
                        tabButton(L("panel.tab.sounds"), tab: .sons)
                    }
                    .frame(height: 28)
                    Divider()

                    // List / sound library (top, flexible) plus the docked inspector at the bottom.
                    GeometryReader { geo in
                        VStack(spacing: 0) {
                            Group {
                                if leftPanelTab == .liste {
                                    SoundObjectListView(viewModel: viewModel)
                                } else {
                                    SoundLibraryView()
                                }
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)

                            // With no selection: the inspector shrinks to its minimum (icon and message).
                            // With a selection: resizable by the handle, the list keeping its minimum
                            // height → the inspector never hides what is above it.
                            if viewModel.selectedIDs.isEmpty {
                                Divider()
                                ObjectInspectorView(viewModel: viewModel)
                                    .frame(height: inspectorCollapsedHeight)
                            } else {
                                inspectorResizeHandle(totalHeight: geo.size.height)
                                ObjectInspectorView(viewModel: viewModel)
                                    .frame(height: clampedInspectorHeight(totalHeight: geo.size.height))
                            }
                        }
                    }
                }
                .frame(minWidth: 250, maxWidth: 360)

                TimelineView(
                    viewModel: viewModel,
                    playheadPosition: session.playheadPosition,
                    selectionCursor: viewModel.cursorPosition,
                    isPlaying: session.isPlaying,
                    isPaused: session.pausedAt != nil,
                    onTogglePlayback: { if session.isPlaying { session.stop() } else { session.play() } },
                    onTogglePause: { session.togglePause() },
                    onMoveCursor: { t in
                        viewModel.cursorPosition = max(0, t)
                    },
                    onReturnToZero: { session.returnToZero() },
                    onSoloPlay: { session.soloPlay() }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .simultaneousGesture(TapGesture().onEnded {
                    NSApp.keyWindow?.makeFirstResponder(nil)
                })
                .frame(minWidth: 420)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        .onChange(of: viewModel.seekRequest) { _, _ in
            session.applyPendingSeekRequest()
        }
        .onChange(of: viewModel.loopRegion) { _, newRegion in
            session.loopRegionChanged(newRegion)
        }
        .onChange(of: viewModel.loopModeEnabled) { _, enabled in
            session.loopModeChanged(enabled)
        }
        .onAppear {
            // Wires the engine to the document and arms the playhead tracking (idempotent).
            session.start()
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
            // Audio device status ('device — 44.1k — 512') in the title bar, on the right.
            // DISABLED for now: the title-bar accessory does not show reliably under this SwiftUI
            // WindowGroup (installation succeeds but nothing is visible). The code
            // (AudioTitlebarStatus / AudioStatusTitleView) is kept for a later attempt.
            // AudioTitlebarStatus.install(viewModel: viewModel)
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

    // MARK: - Bottom inspector: height and draggable separator

    /// Bounds the inspector's height between its minimum and the space left to the list.
    private func clampedInspectorHeight(totalHeight: CGFloat) -> CGFloat {
        let maxHeight = max(inspectorMinHeight, Double(totalHeight) - listMinHeight)
        return CGFloat(min(max(inspectorHeight, inspectorMinHeight), maxHeight))
    }

    @ViewBuilder
    private func inspectorResizeHandle(totalHeight: CGFloat) -> some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(height: 1)
        }
        .frame(height: 6)
        .contentShape(Rectangle())
        // `.onHover` plus `push()/pop()` did not hold: AppKit puts the arrow back on every window
        // update, so a couple of dozen times a second during playback, and the ↕ vanished as soon
        // as the mouse stopped on the handle (@see CursorClaim).
        .cursorZone(.resizeUpDown)
        .gesture(
            // Global coordinates: the translation stays stable even if the handle moves
            // with the layout during the resize (otherwise it jumps).
            DragGesture(coordinateSpace: .global)
                .onChanged { value in
                    let start = resizeStartHeight ?? inspectorHeight
                    if resizeStartHeight == nil { resizeStartHeight = start }
                    let maxHeight = max(inspectorMinHeight, Double(totalHeight) - listMinHeight)
                    inspectorHeight = min(max(start - Double(value.translation.height), inspectorMinHeight), maxHeight)
                }
                .onEnded { _ in resizeStartHeight = nil }
        )
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
    ContentView(session: ObjekatSession())
}
