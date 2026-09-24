import SwiftUI

/// The progress overlay shown while a project is loading — step 6 of project_load_progress_plan.
///
/// Same family as `ExportProgressBar`/`ExportPanelView`, but a centred card over the content rather
/// than a strip: unlike an export, which leaves the app usable, a load owns the model and the
/// engine for its whole duration (step 4's anti-reentrance guard) — nothing behind it can be
/// touched anyway, and its clear layer takes the clicks. It sits over the CONTENT zone only (below
/// the transport bar), placed by `ContentView` as an `.overlay` on the `HSplitView` — drawn on
/// top, it absorbs every click by itself, with no `.allowsHitTesting` needed.
///
/// The veil is laid AT ONCE, with no fade-in (user decision, 24 September 2026): the old 300 ms
/// grace let the teardown and the new project's first objects flash in the clear before the blur
/// came down. Once shown it stays for at least 300 ms — a flash the eye cannot read would be worse
/// than a veil held a beat too long — and it fades OUT over 150 ms. There is no blur: tried (the
/// system material, whole or partial) and dropped as serving no purpose.
struct ProjectLoadOverlay: View {
    @Bindable var viewModel: EditViewModel

    @State private var showOverlay = false
    @State private var pendingShowWork: DispatchWorkItem?
    @State private var shownAt: Date?

    private static let minVisible: TimeInterval = 0.3
    private static let fadeDuration: TimeInterval = 0.15

    var body: some View {
        ZStack {
            if showOverlay {
                // No blur (user decision, 24 September 2026: it served no purpose) — a clear layer
                // that still absorbs every click, the content staying in plain view behind the card.
                Color.clear
                    .contentShape(Rectangle())
                    .ignoresSafeArea()
                    .transition(.asymmetric(insertion: .identity, removal: .opacity))
                card
                    .transition(.asymmetric(insertion: .identity, removal: .opacity))
            }
        }
        .animation(.easeInOut(duration: Self.fadeDuration), value: showOverlay)
        .onChange(of: viewModel.isLoadingProject) { _, loading in
            if loading {
                armShow()
            } else {
                armHide()
            }
        }
        // A load already running when this view first appears (should not happen in practice —
        // the overlay lives as long as the window — but a defensive read costs nothing).
        .onAppear {
            if viewModel.isLoadingProject { armShow() }
        }
    }

    /// Synchronous, in the same transaction as `isLoadingProject` flipping: the veil is on screen
    /// from the load's very first frame (the loader breathes before its teardown for exactly that).
    private func armShow() {
        pendingShowWork?.cancel()
        pendingShowWork = nil
        var t = Transaction(); t.disablesAnimations = true
        withTransaction(t) {
            showOverlay = true
            shownAt = Date()
        }
    }

    private func armHide() {
        pendingShowWork?.cancel()
        pendingShowWork = nil
        guard showOverlay else { return }
        let elapsed = Date().timeIntervalSince(shownAt ?? Date())
        let remaining = max(0, Self.minVisible - elapsed)
        DispatchQueue.main.asyncAfter(deadline: .now() + remaining) {
            showOverlay = false
            shownAt = nil
            // The missing-plugins alert (if any) waits for exactly this moment — the veil finishing
            // its fade-out, `Self.fadeDuration` after `showOverlay` flips (the `.animation` above).
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.fadeDuration) {
                viewModel.flushPendingMissingPluginsReportIfAny()
            }
        }
    }

    // MARK: - The card

    private var card: some View {
        VStack(spacing: 10) {
            Text(viewModel.loadState?.projectName ?? viewModel.projectName)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)

            ProgressView(value: viewModel.loadState?.fraction ?? 0)
                .progressViewStyle(.linear)

            Text(statusLabel)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button(L("common.cancel")) { viewModel.requestCancelProjectLoad() }
                .controlSize(.small)
                // One click is enough: honoured at the next safe point, between two plugin
                // compiles — a second click would only ask the same thing twice.
                .disabled(viewModel.loadState?.cancelRequested == true)
        }
        .padding(20)
        .frame(width: 320)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.25), radius: 16, y: 4)
    }

    /// "<plugin name> — N/total" during the plugin phase (once a first entry has actually
    /// started); a plain phase label otherwise.
    private var statusLabel: String {
        guard let s = viewModel.loadState else { return "" }
        if s.phase == .plugins, s.pluginTotal > 0, let name = s.currentPluginName {
            return L("projectLoad.plugin", name, s.pluginIndex, s.pluginTotal)
        }
        switch s.phase {
        case .teardown:     return L("projectLoad.phase.teardown")
        case .structure:    return L("projectLoad.phase.structure")
        case .plugins:      return L("projectLoad.phase.plugins")
        case .stemsRouting: return L("projectLoad.phase.stemsRouting")
        case .finalize:     return L("projectLoad.phase.finalize")
        }
    }
}
