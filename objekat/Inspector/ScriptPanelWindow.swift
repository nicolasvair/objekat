import AppKit
import SwiftUI

// MARK: - The window a script asked for

/// Draws the panels scripts declare (@see ScriptPanelStore) as floating utility panels.
///
/// Opening goes through ONE function, `show`, guarded by the same condition as `hasInterface` —
/// `--headless` opens nothing, and that is verifiable with no screen (`CGWindowListCopyWindowInfo`
/// on the headless pid). A guard at each caller would be a guard the next caller forgets; the store
/// only ever reaches a window through its two hooks, which come here.
///
/// A panel of ours, not a plugin's: a plain `NSPanel`, floating, non-activating (the project window
/// stays the active one, so the transport keys keep working while a slider is being moved), and
/// hidden when the app is. The first-click trap of `FirstClickThrough` does not concern it — a
/// panel is left alone there and takes the key on its own.
@MainActor
final class ScriptPanelWindows: NSObject, NSWindowDelegate {

    static let shared = ScriptPanelWindows()

    private var windows: [UUID: NSPanel] = [:]
    private var closing: Set<UUID> = []
    private weak var store: ScriptPanelStore?

    /// Hooks the store up to this manager. Called once, when the view-model builds its store.
    static func attach(to store: ScriptPanelStore) {
        shared.store = store
        store.panelOpened = { id in shared.show(id, store: store) }
        store.panelEnded = { id in shared.dismiss(id) }
    }

    private func show(_ id: UUID, store: ScriptPanelStore) {
        guard !LaunchArguments.process.headless else { return }   // = EditViewModel.hasInterface
        guard windows[id] == nil, let panel = store.panels[id] else { return }

        let hosting = NSHostingView(rootView: ScriptPanelView(store: store, panelID: id))
        let size = hosting.fittingSize
        let frame = NSRect(x: 0, y: 0, width: max(460, size.width), height: max(120, size.height))
        hosting.frame = frame

        let w = NSPanel(contentRect: frame,
                        styleMask: [.titled, .closable, .utilityWindow, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        w.title = panel.title.isEmpty ? L("scriptpanel.title.default") : panel.title
        w.contentView = hosting
        w.isFloatingPanel = true
        w.hidesOnDeactivate = true
        w.isReleasedWhenClosed = false
        w.delegate = self
        // Beside the project window rather than over its middle: a hand adjusting a threshold is
        // looking at the timeline.
        if let main = NSApp.windows.first(where: { $0.styleMask.contains(.titled) && !($0 is NSPanel) && $0.isVisible }) {
            w.setFrameOrigin(NSPoint(x: main.frame.maxX - frame.width - 24,
                                     y: main.frame.maxY - frame.height - 80))
        } else {
            w.center()
        }
        windows[id] = w
        objc_setAssociatedObject(w, &Self.idKey, id, .OBJC_ASSOCIATION_RETAIN)
        w.orderFrontRegardless()
        w.makeKey()
    }

    private static var idKey: UInt8 = 0

    /// Fits the window to its content again — the "Expert" button shows or hides rows. The top edge
    /// stays where it is (the panel grows downwards), as a disclosure would.
    func refit(_ id: UUID) {
        guard let w = windows[id], let hosting = w.contentView as? NSHostingView<ScriptPanelView> else { return }
        let fit = hosting.fittingSize
        let old = w.frame
        let newHeight = max(120, fit.height) + (old.height - w.contentRect(forFrameRect: old).height)
        var frame = NSRect(x: old.minX, y: old.maxY - newHeight, width: old.width, height: newHeight)
        // Never taller than the screen it is on: Validate / Cancel must stay reachable.
        if let screen = w.screen ?? NSScreen.main {
            let room = screen.visibleFrame
            frame.size.height = min(frame.height, room.height)
            frame = w.constrainFrameRect(frame, to: screen)
        }
        w.setFrame(frame, display: true, animate: true)
    }

    private func dismiss(_ id: UUID) {
        guard let w = windows.removeValue(forKey: id) else { return }
        closing.insert(id)
        w.close()
        closing.remove(id)
    }

    /// The ✕ of the title bar is a Cancel — the script is told, and cleans up.
    func windowWillClose(_ notification: Notification) {
        guard let w = notification.object as? NSPanel,
              let id = objc_getAssociatedObject(w, &Self.idKey) as? UUID,
              !closing.contains(id) else { return }
        windows.removeValue(forKey: id)
        try? store?.input(id, values: [:], press: "cancel")
    }
}

// MARK: - Its content

struct ScriptPanelView: View {
    let store: ScriptPanelStore
    let panelID: UUID
    /// The window's own state: whether the `advanced` controls are drawn.
    @State private var expert = false

    var body: some View {
        if let p = store.panels[panelID] {
            VStack(alignment: .leading, spacing: 6) {
                ScriptControlsForm(controls: p.controls, values: p.values, expert: expert,
                                   set: { id, v, coalesced in set(id, v, coalesced: coalesced) },
                                   press: { id in press(id) })
                Divider()
                HStack(spacing: 6) {
                    if p.busy { ProgressView().controlSize(.small) }
                    Text(verbatim: p.status)
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 8)
                    if p.controls.contains(where: { $0.advanced }) {
                        Button {
                            expert.toggle()
                            DispatchQueue.main.async { ScriptPanelWindows.shared.refit(panelID) }
                        } label: {
                            Label(L("scriptpanel.expert"),
                                  systemImage: expert ? "chevron.down" : "chevron.right")
                        }
                    }
                    if p.rememberKey != nil {
                        Button(L("scriptpanel.reset")) { press("reset") }
                    }
                    Button(L("common.cancel")) { press("cancel") }
                        .keyboardShortcut(.cancelAction)
                        .tint(.red)
                    Button(L("scriptpanel.validate")) { press("validate") }
                        .keyboardShortcut(.defaultAction)
                        .disabled(p.busy)
                }
            }
            .padding(12)
            .frame(width: 460)
        }
    }

    private func set(_ id: String, _ v: JSONValue, coalesced: Bool = false) {
        try? store.input(panelID, values: [id: v], press: nil, coalesced: coalesced)
    }

    private func press(_ id: String) {
        try? store.input(panelID, values: [:], press: id)
    }
}
