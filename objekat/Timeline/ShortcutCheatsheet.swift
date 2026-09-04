import SwiftUI
import AppKit

// MARK: - Context

/// What the cheat sheet shows: the shortcuts of a TOOL (its key being held) or those of a HELD
/// COMBINATION OF MODIFIERS (⌘, ⌘⇧, ⌥…).
enum CheatsheetContext: Equatable, Sendable {
    case tool(ActiveTool)
    /// `NSEvent.ModifierFlags.rawValue` restricted to ⌘⇧⌥⌃ (the type is not Equatable/Sendable).
    case modifiers(UInt)
}

/// One row of the cheat sheet: the combination on the left, what it does on the right.
struct ShortcutRow: Identifiable {
    let id = UUID()
    let keys: String
    let label: String
}

struct ShortcutSection: Identifiable {
    let id = UUID()
    let title: String
    let rows: [ShortcutRow]
}

// MARK: - Content

/// The shortcut table, written by hand and kept in step with `TimelineKeyHandler`,
/// `TimelineView+TapHandler`, `TimelineView+DragHandler` and `objekatApp`'s menu.
enum ShortcutCheatsheet {

    static func title(for context: CheatsheetContext) -> String {
        switch context {
        case .tool(let t):        return L("cheatsheet.toolTitle", toolName(t))
        case .modifiers(let raw): return modifierGlyphs(raw)
        }
    }

    static func sections(for context: CheatsheetContext) -> [ShortcutSection] {
        switch context {
        case .tool(let t):        return toolSections(t)
        case .modifiers(let raw): return modifierSections(raw)
        }
    }

    // MARK: Tools

    static func toolName(_ tool: ActiveTool) -> String {
        switch tool {
        case .toolSelection:  return L("tool.edit.help")
        case .toolCut:        return L("tool.cut.name")
        case .toolVolume:     return L("tool.volume.help")
        case .toolPan:        return L("tool.pan.help")
        case .toolAux:        return L("tool.aux.help")
        case .toolStemAssign: return L("tool.stem.name")
        }
    }

    /// A key's cheat sheet only shows what THAT key opens: the global shortcuts (transport, zoom,
    /// solo, changing tool) are not repeated in every tool — drowned in the list, they made it
    /// unreadable.
    private static func toolSections(_ tool: ActiveTool) -> [ShortcutSection] {
        switch tool {
        // Edit: the list was removed on 2026-08-31, to be rewritten. The default tool does
        // EVERYTHING — the list took thirteen mouse gestures to say what the other tools say in four,
        // and read like a manual. Empty ⇒ no panel is shown (@see CheatsheetPanel).
        case .toolSelection:
            return []
        // The mouse has moved into a tooltip on the block, like Volume and Pan (@see toolZoneHelp).
        case .toolCut:
            return [
                ShortcutSection(title: L("cheatsheet.section.keyboard"), rows: [
                    ShortcutRow(keys: "⏎", label: L("cheatsheet.cut.atCursor")),
                    ShortcutRow(keys: "⏎", label: L("cheatsheet.cut.atSelection")),
                ]),
            ]
        // The mouse has moved into tooltips, laid on the zones of the block itself: the gesture
        // reads where it is made (@see TimelineView.toolZoneHelp). What is left here is the keyboard,
        // which has nowhere else to show itself.
        case .toolVolume:
            return [
                ShortcutSection(title: L("cheatsheet.section.keyboard"), rows: [
                    ShortcutRow(keys: "↑ · ↓", label: "± 1 dB"),
                    ShortcutRow(keys: "M", label: L("cheatsheet.volume.mute")),
                    ShortcutRow(keys: "⌫", label: L("cheatsheet.volume.reset")),
                ]),
            ]
        // The mouse has moved into a tooltip on the block, like Volume (@see toolZoneHelp).
        case .toolPan:
            return [
                ShortcutSection(title: L("cheatsheet.section.keyboard"), rows: [
                    ShortcutRow(keys: "↑ · ↓", label: "± 10 %"),
                    ShortcutRow(keys: "⌫", label: L("cheatsheet.pan.reset")),
                ]),
            ]
        // Aux: the list was removed on 2026-08-31. Everything there was done with the mouse, and the
        // mouse now documents itself on the object — but the aux's gestures aim at the send KNOBS
        // (@see sendRowHit), not at a block's zones: their tooltips are still to be written.
        // Empty ⇒ no panel is shown (@see CheatsheetPanel).
        case .toolAux:
            return []
        // The list was removed on 2026-08-31: the tool has its OWN band (@see
        // TimelineView.stemAssignHUD), carrying the target stem's colour, its muted state, ⏎ and M.
        // Two bands for one tool was one too many. Empty ⇒ no panel (@see
        // CheatsheetPanel).
        case .toolStemAssign:
            return []
        }
    }

    // MARK: Modifiers

    static func modifierGlyphs(_ raw: UInt) -> String {
        let f = NSEvent.ModifierFlags(rawValue: raw)
        var s = ""
        if f.contains(.control) { s += "⌃" }
        if f.contains(.option)  { s += "⌥" }
        if f.contains(.shift)   { s += "⇧" }
        if f.contains(.command) { s += "⌘" }
        return s.isEmpty ? "—" : s
    }

    private static func modifierSections(_ raw: UInt) -> [ShortcutSection] {
        let f = NSEvent.ModifierFlags(rawValue: raw)
        let cmd = f.contains(.command), shift = f.contains(.shift)
        let opt = f.contains(.option), ctrl = f.contains(.control)

        if cmd && shift && !opt && !ctrl {
            return [ShortcutSection(title: "⌘⇧", rows: [
                ShortcutRow(keys: "⌘⇧Z", label: L("cheatsheet.redo")),
                ShortcutRow(keys: "⌘⇧S", label: L("cheatsheet.saveAs")),
            ])]
        }
        if cmd && !shift && !opt && !ctrl {
            // Two sections cut down to one: the shortcuts EVERY macOS app shares
            // (⌘Z, ⌘X/C/V, ⌘S, ⌘N/O…) do not have to be relearned here. What is left are those
            // that belong to Objekat.
            return [ShortcutSection(title: "⌘", rows: [
                ShortcutRow(keys: "⌘G", label: L("cheatsheet.group")),
                ShortcutRow(keys: "⌘L", label: L("cheatsheet.loopSelection")),
                ShortcutRow(keys: L("cheatsheet.keys.cmdHeld"), label: L("cheatsheet.invertSnap")),
            ])]
        }
        if shift && !cmd && !opt && !ctrl {
            return [ShortcutSection(title: "⇧", rows: [
                ShortcutRow(keys: "⇧↑ · ⇧↓", label: L("cheatsheet.transposeOctave")),
                ShortcutRow(keys: L("cheatsheet.keys.shiftSpace"), label: L("cheatsheet.pauseResume")),
                ShortcutRow(keys: "mouse wheel", label: L("cheatsheet.zoomWheel")),
                ShortcutRow(keys: "⇧T · ⇧R", label: L("cheatsheet.zoomVertical")),
            ])]
        }
        if opt && !cmd && !shift && !ctrl {
            // The two '⌥ = copy' rows have moved into the move band, which says them DURING the
            // gesture and shows which one is held (@see TimelineView.moveDragHUD).
            return [ShortcutSection(title: "⌥", rows: [
                ShortcutRow(keys: L("cheatsheet.keys.optDragTop"),
                            label: L("cheatsheet.slip")),
            ])]
        }
        // Any other combination: nothing to say. We do NOT put up a 'no shortcut' panel — an empty
        // panel is one panel too many. `CheatsheetPanel` renders nothing on [].
        return []
    }
}

// MARK: - Panel

/// The shortcuts panel, shown after ~0.6 s of holding a tool key or a modifier. Purely
/// informative: it disappears on release.
struct CheatsheetPanel: View {
    let context: CheatsheetContext

    @ViewBuilder
    var body: some View {
        let sections = ShortcutCheatsheet.sections(for: context)
        // A context with no row at all shows NOTHING: an empty frame carrying a title and
        // 'release to close' would read as a fault.
        if sections.isEmpty {
            EmptyView()
        } else {
        // A two-column grid set on its content (no more fixed-width key column): the panel is only
        // as big as what it says, and sits at the bottom of the view.
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "keyboard")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                Text(ShortcutCheatsheet.title(for: context))
                    .font(.system(size: 12, weight: .bold))
                Text(L("cheatsheet.releaseToClose"))
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }

            HStack(alignment: .top, spacing: 18) {
                ForEach(sections) { section in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(section.title.uppercased())
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.secondary)
                            .padding(.bottom, 1)
                        Grid(alignment: .leadingFirstTextBaseline,
                             horizontalSpacing: 8, verticalSpacing: 3) {
                            ForEach(section.rows) { row in
                                GridRow {
                                    Text(row.keys)
                                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                        .gridColumnAlignment(.trailing)
                                    Text(row.label)
                                        .font(.system(size: 10))
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
        }
        .fixedSize()
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .strokeBorder(Color.accentColor.opacity(0.35), lineWidth: 1))
        .shadow(radius: 12, y: 4)
        .allowsHitTesting(false)
        }
    }
}

// MARK: - Key hold

/// Schedules the cheat sheet's appearance after a hold delay: a normal keystroke (changing
/// tool, triggering ⌘Z) must show nothing. It lives in the keyboard monitor's closure, like
/// `SoloChordState`.
final class CheatsheetHold {
    /// The hold delay before showing.
    static let delay: TimeInterval = 0.6

    private var work: DispatchWorkItem?

    /// `context == nil` cancels the hold under way and hides the panel.
    func schedule(_ context: CheatsheetContext?, in vm: EditViewModel) {
        work?.cancel()
        work = nil
        guard let context else {
            DispatchQueue.main.async { vm.cheatsheet = nil }
            return
        }
        let item = DispatchWorkItem {
            MainActor.assumeIsolated { vm.cheatsheet = context }
        }
        work = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.delay, execute: item)
    }
}
