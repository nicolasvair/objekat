import Foundation

// MARK: - The life of what a script shows

// A script's overlays (and, below, its panel and its canvas) are session state owned by a CONNECTION: there is no
// undo for them, nothing about them is saved, and none of it must outlive what it names or the
// script that laid it. Four things end one — `overlay.clear`, the owner's connection closing (a
// script that crashed or was killed leaves nothing behind), the object disappearing (deleted,
// undone, exploded) and a change of document (a project loaded, a tab switched).
extension EditViewModel {

    /// Drops the overlays of objects that no longer exist. Called wherever an object can vanish
    /// (`remove`, an undo, an explode), and defensively by every `overlay.*` command.
    func pruneScriptOverlays() {
        scriptOverlays.prune(keepingWhere: { find(id: $0) != nil })
        scriptPanels.closeWhereObjectGone(exists: { find(id: $0) != nil })
        scriptCanvases.closeWhereObjectGone(exists: { find(id: $0) != nil })
    }

    /// The socket connection `connection` has closed: everything it laid goes.
    func scriptSessionEnded(_ connection: UUID) {
        scriptOverlays.clear(owner: connection)
        scriptPanels.connectionClosed(connection)
        scriptCanvases.connectionClosed(connection)
    }

    /// A different document is on screen (load, new project, tab switch): what a script showed
    /// about the previous one means nothing here, and its panel's object is gone.
    func resetScriptSessionState() {
        scriptOverlays.clearAll()
        scriptPanels.closeAll(reason: .closed)
        scriptCanvases.closeAll(reason: .closed)
    }
}
