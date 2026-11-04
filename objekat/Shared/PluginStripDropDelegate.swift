import SwiftUI
import UniformTypeIdentifiers

// MARK: - Dropping a plugin card on a strip (a bus's, an input's)
//
// A `DropDelegate` and not the convenience `.onDrop(of:isTargeted:perform:)`, for the one reason
// that convenience cannot do: it is `dropUpdated` — called again on every movement — that says
// what the CURSOR shows, and the convenience form answers `.copy` to everything. So a strip
// badged a '+' on a move, where the timeline shows none, and the same gesture read differently
// depending on where the hand was taking it. The rule itself is shared, not copied:
// `PluginDrop.operation`.
//
// What it refuses is as important as what it takes: a Finder drag also carries text beside its
// file URL, and a toolbar that lit up under a WAV would promise something it cannot do; an INPUT's own
// drag (the rectangle carried to the timeline) is text too, and is no plugin.
//
// One delegate for the stem strips of the toolbar and the input rectangles of the Inputs tab: what differs is the
// HOST a release lands on, which the strip names (`host`). An input's host is made on demand (the strip may have no
// chain record yet): `host` is asked on every movement and at the release, and is idempotent.

struct PluginStripDropDelegate: DropDelegate {
    /// The band at the bottom of the timeline (@see PluginDropHint), under this strip's own key.
    let hintKey: String
    let viewModel: EditViewModel
    /// The host a release here lands on; nil = none (the strip cannot take a drop now).
    let host: () -> UUID?
    /// Whether a plugin drag is hovering over this strip.
    let onHover: (Bool) -> Void

    private func carriesPlugin(_ info: DropInfo) -> Bool {
        // A rectangle of the Inputs tab being carried is text as well, and is not a plugin.
        if InputDragSession.shared.current != nil { return false }
        return info.itemProviders(for: [.plainText]).contains(where: PluginDrop.carries)
    }

    func validateDrop(info: DropInfo) -> Bool { carriesPlugin(info) }

    /// What a release here would do with the drag in flight (@see EditViewModel.pluginDropOutcome);
    /// nil when there is none to read (the legacy reading then holds).
    private func outcome() -> PluginDropOutcome? {
        // A send card never goes to a strip (a stem does not send, an input neither): "a send stays on its object".
        if SendDragSession.shared.current != nil { return .sendRefused(.refusedElsewhere) }
        guard let payload = PluginDragSession.shared.current else { return nil }
        guard let target = host() else { return .refuse("this strip takes no drop now") }
        return viewModel.pluginDropOutcome(payload, toHost: target, at: .hostEnd, flags: NSEvent.modifierFlags)
    }

    /// Lights the strip and speaks on the band when the release would DO something; withdraws both,
    /// and shows the refusing cursor, when it would not.
    private func present(_ info: DropInfo) -> DropProposal {
        guard let o = outcome() else {
            onHover(true)
            PluginDropHint.shared.present(hintKey, context: .host)
            return DropProposal(operation: PluginDrop.operation(for: NSEvent.modifierFlags))
        }
        guard let ctx = o.hintContext() else {
            onHover(false)
            PluginDropHint.shared.leave(hintKey)
            return DropProposal(operation: .forbidden)
        }
        onHover(true)
        PluginDropHint.shared.present(hintKey, context: ctx)
        return DropProposal(operation: o.operation)
    }

    func dropEntered(info: DropInfo) {
        guard carriesPlugin(info) else { onHover(false); return }
        _ = present(info)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard carriesPlugin(info) else {
            onHover(false)
            PluginDropHint.shared.leave(hintKey)
            return DropProposal(operation: .forbidden)
        }
        return present(info)
    }

    func dropExited(info: DropInfo) {
        onHover(false)
        PluginDropHint.shared.leave(hintKey)
    }

    func performDrop(info: DropInfo) -> Bool {
        onHover(false)
        PluginDropHint.shared.leave(hintKey)
        guard carriesPlugin(info),
              let provider = info.itemProviders(for: [.plainText]).first(where: PluginDrop.carries)
        else { return false }
        PluginDrop.receive(provider, in: viewModel) { host() }
        return true
    }
}
