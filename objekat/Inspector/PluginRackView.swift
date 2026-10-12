import SwiftUI

// What is left of the old plugin rack: the inspector's Plugins column shows the signal view
// (`SynopticBoundView`), and the rack views that used to live here (`PluginChipView`,
// `PluginPickerButton`) were no longer called by anyone. What remains is the piece still used
// elsewhere: the drag payload (timeline and signal view). The plugin browser, opened from the signal
// view, lives in `Inspector/PluginBrowser/PluginBrowserView.swift`.

// MARK: - Drag payload for LINKING instances

/// The payload of a plugin drag (JSON in an NSItemProvider under `public.plain-text` — an
/// undeclared custom type is not instantiated by the pasteboard). Received by the timeline's
/// `.onDrop`, identified by decoding successfully. Modifiers: nothing=move ⌥=copy ⌘=copy+link.
struct PluginDragPayload: Codable {
    let sourceObjectID: UUID
    /// The card actually taken in the hand — the one the reorder gestures aim with, and the
    /// anchor of the whole payload.
    let pluginID: UUID
    /// Every card the drag carries, in the source chain's reading ORDER. `[pluginID]` for a single
    /// card; a whole selection when the card taken was part of one. Optional so that a payload
    /// written before it existed still decodes — read it through `ids`, never directly.
    var pluginIDs: [UUID]? = nil

    /// What the drop must act on: the list when there is one, and the single card otherwise.
    var ids: [UUID] { (pluginIDs?.isEmpty == false) ? pluginIDs! : [pluginID] }
}
