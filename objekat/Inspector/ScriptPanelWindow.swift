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

    var body: some View {
        if let p = store.panels[panelID] {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(rows(of: p), id: \.control.id) { row in
                    controlRow(row, p)
                }
                Divider()
                HStack(spacing: 6) {
                    if p.busy { ProgressView().controlSize(.small) }
                    Text(verbatim: p.status)
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 8)
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

    /// A bool that exactly one number is enabled by is drawn INLINE with that number ("a box and a
    /// threshold": the box says whether the criterion counts, the slider how much). Any other bool
    /// is a row of its own.
    private struct Row { let control: ScriptPanelControl; let gate: ScriptPanelControl? }

    private func rows(of p: ScriptPanel) -> [Row] {
        var gateUse: [String: Int] = [:]
        for c in p.controls { if let by = c.enabledBy { gateUse[by, default: 0] += 1 } }
        let inline = Set(gateUse.filter { $0.value == 1 }.keys)
        return p.controls.compactMap { c in
            if c.kind == .bool, inline.contains(c.id) { return nil }
            let gate = c.enabledBy.flatMap { by in p.controls.first { $0.id == by } }
            return Row(control: c, gate: gate)
        }
    }

    private func isOn(_ id: String, _ p: ScriptPanel) -> Bool { p.values[id]?.boolValue ?? false }

    @ViewBuilder
    private func controlRow(_ row: Row, _ p: ScriptPanel) -> some View {
        let c = row.control
        switch c.kind {
        case .bool:
            Toggle(isOn: Binding(get: { isOn(c.id, p) },
                                 set: { set(c.id, .bool($0)) })) { Text(verbatim: c.label) }
        case .button:
            Button { press(c.id) } label: { Text(verbatim: c.label) }
        case .section:
            // A heading over the rows that follow it: the script's own text, set apart.
            VStack(alignment: .leading, spacing: 3) {
                Divider()
                Text(verbatim: c.label).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            }
            .padding(.top, 2)
        case .progress:
            // A bar the script drives: a number is a fraction, `null` is "working, no idea how far".
            let fraction = p.values[c.id]?.doubleValue
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(verbatim: c.label).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 8)
                    if let fraction {
                        Text(verbatim: "\(Int((fraction * 100).rounded())) %")
                            .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                    }
                }
                if let fraction {
                    ProgressView(value: fraction).progressViewStyle(.linear)
                } else {
                    ProgressView().progressViewStyle(.linear)
                }
            }
        case .choice:
            // A menu, the script's own labels: a model that is not installed says so in its label.
            HStack(spacing: 8) {
                Text(verbatim: c.label).frame(width: 200, alignment: .leading)
                Picker(selection: Binding(get: { p.values[c.id]?.stringValue ?? c.options.first?.id ?? "" },
                                          set: { set(c.id, .string($0)) })) {
                    ForEach(c.options, id: \.id) { o in Text(verbatim: o.label).tag(o.id) }
                } label: { EmptyView() }
                .labelsHidden()
                .pickerStyle(.menu)
            }
        case .number:
            let enabled = row.gate.map { isOn($0.id, p) } ?? true
            HStack(spacing: 8) {
                if let gate = row.gate, gate.kind == .bool, inlineGate(gate, p) {
                    Toggle(isOn: Binding(get: { isOn(gate.id, p) },
                                         set: { set(gate.id, .bool($0)) })) {
                        Text(verbatim: gate.label)
                    }
                    .frame(width: 200, alignment: .leading)
                } else {
                    Text(verbatim: c.label).frame(width: 200, alignment: .leading)
                }
                Slider(value: Binding(get: { p.values[c.id]?.doubleValue ?? c.min },
                                      set: { set(c.id, .number($0), coalesced: true) }),
                       in: c.min...c.max, step: c.step)
                    .disabled(!enabled)
                Text(verbatim: format(p.values[c.id]?.doubleValue ?? c.min, c))
                    .font(.system(.caption, design: .monospaced))
                    .frame(width: 64, alignment: .trailing)
                    .foregroundStyle(enabled ? .primary : .secondary)
            }
        }
    }

    private func inlineGate(_ gate: ScriptPanelControl, _ p: ScriptPanel) -> Bool {
        p.controls.filter { $0.enabledBy == gate.id }.count == 1
    }

    private func format(_ v: Double, _ c: ScriptPanelControl) -> String {
        let digits = c.step >= 1 ? 0 : (c.step >= 0.1 ? 1 : 2)
        let s = String(format: "%.\(digits)f", v)
        return c.unit.isEmpty ? s : s + " " + c.unit
    }

    private func set(_ id: String, _ v: JSONValue, coalesced: Bool = false) {
        try? store.input(panelID, values: [id: v], press: nil, coalesced: coalesced)
    }

    private func press(_ id: String) {
        try? store.input(panelID, values: [:], press: id)
    }
}
