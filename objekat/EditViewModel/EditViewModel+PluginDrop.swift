import AppKit
import Foundation
import UniformTypeIdentifiers

// MARK: - Receiving a dragged plugin, wherever it is let go of
//
// A plugin card leaves the signal view carrying a `PluginDragPayload`, and there are now TWO
// places it can land: a timeline object, and a bus's strip in the toolbar. What happens on
// arrival is the same thing in both — the same three gestures, the same single undo point, the
// same fate for the selection — so it is written ONCE here rather than at each door. The two
// callers differ only in how they name the host: the timeline resolves it from the drop's
// position, a strip already knows which bus it is.

/// The pasteboard side of it: recognising the payload, and getting it off the provider.
enum PluginDrop {

    /// A plugin payload travels as `public.plain-text` — an undeclared custom type is not
    /// instantiated by the pasteboard at all. Text and NOT a file is what identifies it before
    /// anything is decoded; the Finder's drags carry a `fileURL` beside their text.
    static func carries(_ p: NSItemProvider) -> Bool {
        p.hasItemConformingToTypeIdentifier(UTType.plainText.identifier)
            && !p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
    }

    /// Reads the payload and lays it down on the host `host()` names.
    ///
    /// The modifiers are read HERE, synchronously, and carried into the closure: the provider's
    /// load is asynchronous, and by the time it answers the hand has let go of ⌥ or ⌘ — reading
    /// them on arrival would make the gesture depend on how long a pasteboard took.
    static func receive(_ provider: NSItemProvider, in viewModel: EditViewModel,
                        host: @escaping @MainActor () -> UUID?) {
        guard carries(provider) else { return }
        let flags = NSEvent.modifierFlags
        provider.loadDataRepresentation(forTypeIdentifier: UTType.plainText.identifier) { data, _ in
            guard let data,
                  let payload = try? JSONDecoder().decode(PluginDragPayload.self, from: data)
            else { return }
            Task { @MainActor in
                guard let targetID = host() else { return }
                viewModel.acceptPluginDrop(payload, on: targetID, modifiers: flags)
            }
        }
    }
}

extension EditViewModel {

    /// Lays a dragged payload down on a chain HOST — a timeline object or a bus, which are the
    /// same thing to a chain (@see chainPlugins). Three gestures, as everywhere a plugin is
    /// dragged: nothing = move, ⌥ = an independent copy, ⌘ = a copy that stays linked.
    ///
    /// @return true if something was laid down.
    @discardableResult
    func acceptPluginDrop(_ payload: PluginDragPayload, on targetID: UUID,
                          modifiers flags: NSEvent.ModifierFlags) -> Bool {
        // AN INSTRUMENT (the MIDI zone): it does not join the target's FX chain — it needs MIDI at
        // its input — but its instrument SLOT. The same three gestures.
        // `transferInstrument` refuses a host that is not a MIDI object on its own, which is what
        // makes a bus's strip safe to drop an instrument on: nothing happens.
        // @see EditViewModel.transferInstrument
        if isInstrument(payload.pluginID, of: payload.sourceObjectID) {
            transferInstrument(sourceObjectID: payload.sourceObjectID,
                               pluginID: payload.pluginID,
                               targetObjectID: targetID,
                               copy: flags.contains(.option) || flags.contains(.command),
                               linked: flags.contains(.command))
            return true
        }
        // ONE card or a whole SELECTION, the same three gestures either way and the same single
        // undo point: the payload says what it carries (@see PluginDragPayload.ids), the transfer
        // says what it does.
        let mode: PluginTransferMode = flags.contains(.command) ? .link
                                     : (flags.contains(.option) ? .copy : .move)
        // Was it the selection itself that was taken? Asked BEFORE the transfer, which is about to
        // move the ids it names.
        let wasSelection = selectedPluginHostID == payload.sourceObjectID
            && selectedPluginIDs == Set(payload.ids)
        let placed = transferPlugins(payload.ids, from: payload.sourceObjectID,
                                     to: targetID, mode: mode)
        // A MOVE hands the cards new identities. The selection follows them into the target chain
        // when it WAS the thing dragged; otherwise it named cards that have just left, so it is
        // given up rather than left pointing at nothing — and with it the keyboard goes back to
        // the timeline.
        if mode == .move, !placed.isEmpty {
            if wasSelection {
                setPluginSelection(Set(placed), host: targetID)
            } else if selectedPluginHostID == payload.sourceObjectID {
                clearPluginSelection()
            }
        }
        return !placed.isEmpty
    }
}
