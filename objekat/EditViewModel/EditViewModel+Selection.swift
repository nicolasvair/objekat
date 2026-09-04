import Foundation

extension EditViewModel {

    // MARK: - Selection

    func selectAll() {
        // A contextual Cmd+A: if we are "inside" a group (a child selected, or the
        // caret laid within the group's lane range) → selects its direct children.
        if let group = contextGroup(), case .group(let children, _) = group.kind {
            selectedIDs = Set(children.map(\.id))
            timeSelection = nil
            return
        }
        selectedIDs = Set(items.map(\.id))
    }

    /// The "current" group for a contextual Cmd+A, or nil if we are at the root level.
    /// - From the selection: if every selected item shares the same immediate
    ///   parent group (not the root), that is the one.
    /// - Otherwise, with no selection: the expanded group whose display-lane range
    ///   contains `caretLane` (the deepest one when nested).
    func contextGroup() -> SoundObject? {
        if !selectedIDs.isEmpty {
            let parentIDs = Set(selectedIDs.map { parentGroup(for: $0)?.id })
            if parentIDs.count == 1, let pid = parentIDs.first, let pid {
                return find(id: pid)
            }
            return nil
        }
        if let cl = caretLane {
            return laneEntries
                .filter { e in
                    // `showsChildrenInline`: a group switched to automation no longer shows its
                    // children — so its band can no longer serve as context for ⌘A, otherwise the
                    // shortcut would select invisible objects.
                    guard e.item.showsChildrenInline else { return false }
                    return cl >= e.displayLane + 1 && cl <= e.displayLane + e.item.childLaneCount
                }
                .max(by: { $0.displayLane < $1.displayLane })?
                .item
        }
        return nil
    }

    func select(_ id: UUID?, additive: Bool = false) {
        guard let id else { clearSelection(); return }
        if additive {
            if selectedIDs.contains(id) { selectedIDs.remove(id) }
            else { selectedIDs.insert(id) }
        } else {
            selectedIDs = [id]
        }
    }

    func selectIDs(_ ids: Set<UUID>) { selectedIDs = ids }

    func clearSelection() {
        selectedIDs = []
        timeSelection = nil
    }

    /// The effective IDs for multi-item operations: excludes any item one of whose direct
    /// ancestors is itself selected (avoids a double move / double copy).
    var effectiveSelectedIDs: Set<UUID> {
        let selected = selectedIDs
        return selected.filter { id in
            // Excluded if ANY ancestor (parent, grandparent…) is selected.
            var ancestor = parentGroup(for: id)
            while let a = ancestor {
                if selected.contains(a.id) { return false }
                ancestor = parentGroup(for: a.id)
            }
            return true
        }
    }

    /// Returns the current TimeSelection, or the bounding box of the selected items.
    func baseTimeSelection() -> TimeSelection? {
        if let existing = timeSelection { return existing }
        let selected = items.filter { selectedIDs.contains($0.id) }
        guard let tMin = selected.map(\.startTime).min(),
              let tMax = selected.map({ $0.startTime + $0.duration }).max(),
              let lMin = selected.map(\.lane).min(),
              let lMax = selected.map(\.lane).max() else { return nil }
        return TimeSelection(timeRange: tMin...tMax, lanes: Set(lMin...lMax))
    }
}
