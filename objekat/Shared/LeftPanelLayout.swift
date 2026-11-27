import Foundation

// MARK: - The left panel: its width, its tab, and the rules that decide them
//
// Foundation only, so that the whole of it is compiled and asserted alone:
//
//     swiftc -parse-as-library ../objekat/Shared/LeftPanelLayout.swift \
//         test_left_panel_layout.swift -o /tmp/lpl && /tmp/lpl
//
// WHY THE WIDTH IS OURS. The panel used to sit in a SwiftUI `HSplitView`, which keeps the divider
// position to itself: nothing to read, nothing to save, and a freshly built split view lays itself
// out from its children's IDEAL widths — so a new project could open with the left side taking
// the whole window (its content's ideal width being as wide as the 720 pt cap). The width is now a
// plain number in the view-model, the divider a handle that writes it (`LeftPanelDivider`), and the
// panel a fixed-width column: there is nothing left for a layout pass to guess.
//
// WHAT IS SAVED. The width and the active tab, with the project (`ProjectDocument.leftPanel`), like
// the timeline's viewport: purely visual, so changing them never marks the project modified. The
// LAST width the hand used is also remembered by the app (a preference), which is what a new
// project — and a project saved before this field existed — starts from.

/// The left panel's tabs. The raw values are what the project file carries.
enum LeftPanelTabID: String, Codable, CaseIterable {
    case objet, liste, sons, entrees
}

/// What the project keeps of the left panel. Decoding is TOLERANT on purpose: a tab name this build
/// does not know (a file from a later one) or a missing/garbled number must never cost the whole
/// project — each field falls back on its default instead of failing the document.
struct LeftPanelState: Codable, Equatable {
    var width: Double
    var tab: LeftPanelTabID

    init(width: Double, tab: LeftPanelTabID) {
        self.width = width
        self.tab = tab
    }

    private enum CodingKeys: String, CodingKey { case width, tab }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        width = (try? c.decodeIfPresent(Double.self, forKey: .width)) ?? LeftPanelLayout.defaultWidth
        let name = (try? c.decodeIfPresent(String.self, forKey: .tab)) ?? nil
        tab = name.flatMap(LeftPanelTabID.init(rawValue:)) ?? LeftPanelLayout.defaultTab
    }
}

enum LeftPanelLayout {
    /// The panel never gets narrower than this (what the old split view allowed), nor wider than the
    /// cap, nor so wide that the timeline would be left under `minTimelineWidth`.
    static let minWidth: Double = 250
    static let maxWidth: Double = 720
    static let minTimelineWidth: Double = 420
    /// The grip between the panel and the timeline: a 1 pt line in the middle of a wider hit area.
    static let dividerWidth: Double = 5
    /// Where a first-ever project (no saved width, no preference yet) starts.
    static let defaultWidth: Double = 300
    /// The tab a project with nothing saved opens on (the one the app has always started on).
    static let defaultTab: LeftPanelTabID = .liste

    /// `width` brought into range. `containerWidth` (the window's content, when known) lowers the
    /// ceiling so the timeline keeps its minimum — the STORED width is left alone by this, so a
    /// narrow window does not permanently shrink what the project remembers. A number that is not
    /// finite (a retouched file) is the default.
    static func clampedWidth(_ width: Double, containerWidth: Double? = nil) -> Double {
        var hi = maxWidth
        if let c = containerWidth, c.isFinite, c > 0 {
            hi = min(hi, max(minWidth, c - minTimelineWidth - dividerWidth))
        }
        let w = width.isFinite ? width : defaultWidth
        return min(max(w, minWidth), hi)
    }

    /// The width a drag reaches: where the panel was at the mouse-down plus the horizontal travel
    /// since, in WINDOW coordinates (the handle moves under the hand, so a travel measured in its
    /// own coordinates would feed back on itself).
    static func draggedWidth(startWidth: Double, travelX: Double, containerWidth: Double?) -> Double {
        clampedWidth(startWidth + travelX, containerWidth: containerWidth)
    }

    /// The state a document starts from. `saved` is what the file carried (nil = a project from
    /// before the field, or a new one); `appWidth` is the app's last used width, if any. The
    /// width is always brought into range; the tab of an absent field is the default one.
    static func resolved(saved: LeftPanelState?, appWidth: Double?) -> LeftPanelState {
        if let s = saved {
            return LeftPanelState(width: clampedWidth(s.width), tab: s.tab)
        }
        return LeftPanelState(width: clampedWidth(appWidth ?? defaultWidth), tab: defaultTab)
    }
}
