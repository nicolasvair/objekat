import Foundation

// MARK: - The sound list asks the timeline to show a selection
//
// Selecting a row of the left panel means "show me that". The panel scrolls itself onto the row;
// this is the model's half of the timeline answering — and it is deliberately only the HALF that
// needs no geometry: it unfolds what hides the objects and files a REQUEST. The view (which alone
// knows the window, the scroll and the zoom) reads the request, computes the box it must show and
// asks `TimelineReveal` what to change.
//
// Called ONLY by the list's own gestures (a row's click, its arrows) and by `view.reveal`, and
// NEVER by a click in the timeline. That direction matters: the list follows the timeline's
// selection by scrolling itself, and the timeline follows the list's by moving its view. If both
// followed both, a click in the timeline would move the view under the hand that made it, and the
// list would answer by moving again — a loop with a user in the middle of it.

/// One request to bring a selection into view. The token is what makes two identical requests two
/// requests: the view observes the value, and asking for the same objects twice — after the user
/// has scrolled away — must fire again.
struct TimelineRevealRequest: Equatable {
    let ids: [UUID]
    let token: Int
}

extension EditViewModel {

    /// Unfolds every group that hides one of `ids`, then asks the timeline to show them all.
    /// Returns the ids of the groups it had to open (for a script to read; nothing else does).
    ///
    /// A group is unfolded through `toggleGroupExpansion` — the chevron's own function — so the
    /// list's fold, the timeline's fold and the rule that two groups open on one lane exclude each
    /// other stay ONE implementation. An ancestor showing its AUTOMATION band instead of its
    /// content is given its content back first: its children are not on screen, and a reveal that
    /// left them hidden would be a reveal that did nothing.
    ///
    /// An id that no longer exists, or that stays hidden after unfolding (the exclusivity rule
    /// may have closed a neighbour that another id needed), is dropped from the request rather
    /// than failing it: the rest is still worth showing.
    @discardableResult
    func revealInTimeline(ids: Set<UUID>) -> [UUID] {
        var opened: [UUID] = []
        for id in ids where find(id: id) != nil {
            // Outermost first: opening a grandparent is what makes the parent's own state matter.
            var chain: [SoundObject] = []
            var p = parentGroup(for: id)
            while let g = p { chain.insert(g, at: 0); p = parentGroup(for: g.id) }
            for ancestor in chain {
                guard let current = find(id: ancestor.id) else { continue }
                if current.automationOpen { setAutomationOpen(id: current.id, false) }
                if !isGroupExpanded(current.id) {
                    toggleGroupExpansion(id: current.id, restoringAutomation: false)
                    opened.append(current.id)
                }
            }
        }
        // `laneEntries` is rebuilt synchronously by `items.didSet`, so what is shown NOW is what
        // the view will find; only what is actually on screen is worth asking for.
        let shown = Set(laneEntries.map(\.item.id))
        let visible = ids.filter { shown.contains($0) }
        guard !visible.isEmpty else { return opened }
        timelineRevealSerial += 1
        timelineRevealRequest = TimelineRevealRequest(
            ids: visible.sorted { $0.uuidString < $1.uuidString },
            token: timelineRevealSerial)
        return opened
    }

    /// The box to show, in the timeline's own terms: the time the objects span and their DISPLAY
    /// rows. Read from `laneEntries`, which is the authority on what is drawn where (a child of an
    /// open group has a row of its own; an object folded away has none). An infinite bus has no
    /// time to speak of — its stored window is not a passage anybody traced — so it contributes
    /// its row and nothing else.
    func revealBox(for ids: [UUID]) -> TimelineReveal.Box? {
        let wanted = Set(ids)
        let entries = laneEntries.filter { wanted.contains($0.item.id) }
        guard let lo = entries.map(\.displayLane).min(),
              let hi = entries.map(\.displayLane).max() else { return nil }
        let timed = entries.filter { !$0.item.isInfiniteBus }
        var range: ClosedRange<Double>? = nil
        if let t0 = timed.map(\.absStart).min(),
           let t1 = timed.map({ $0.absStart + $0.item.duration }).max() {
            range = t0...max(t0, t1)
        }
        return TimelineReveal.Box(timeRange: range, laneRange: lo...hi, isSingleObject: entries.count == 1)
    }
}
