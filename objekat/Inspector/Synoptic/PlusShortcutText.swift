import Foundation

// MARK: - The words of the "+" directions (what the tooltip, the settings and the browser's menu say)
//
// One place for the wording of a direction and of an action, so the '+''s tooltip, the settings' "+
// shortcuts" tab and the plugin browser's "Assign to a direction of the +" submenu say the same thing. The
// model (PlusDirection, PlusAction) stays pure and wordless; every visible word here goes through `L()`
// with a LITERAL key (the orphans check greps for them).

enum PlusShortcutText {

    /// The icon of a direction bound to a plugin (the zone and the ghost).
    static let pluginSymbol = "puzzlepiece.extension"

    /// The direction's name, as a phrase that follows "Drag …" ("right", "down and right"…).
    static func directionName(_ d: PlusDirection) -> String {
        switch d {
        case .right:     return L("plusDirection.right")
        case .downRight: return L("plusDirection.downRight")
        case .down:      return L("plusDirection.down")
        case .downLeft:  return L("plusDirection.downLeft")
        case .left:      return L("plusDirection.left")
        case .upLeft:    return L("plusDirection.upLeft")
        case .up:        return L("plusDirection.up")
        case .upRight:   return L("plusDirection.upRight")
        }
    }

    /// The direction's arrow, then its name ("→ right").
    static func directionLabel(_ d: PlusDirection) -> String { d.arrow + " " + directionName(d) }

    /// The action's short name, as a menu lists it.
    /// - Parameter missing: the action is a plugin that is not installed.
    static func actionName(_ a: PlusAction, missing: Bool = false) -> String {
        switch a {
        case .none:           return L("plusAction.none")
        case .gainStage:      return L("plusAction.gainStage")
        case .gain:           return L("synoptic.plus.ghost.gain")
        case .gainPanMute:    return L("synoptic.plus.ghost.gainPanMute")
        case .branch:         return L("synoptic.plus.ghost.branch")
        case .send:           return L("plusAction.send")
        case .plugin(let r):  return missing ? L("synoptic.plus.ghost.pluginMissing", r.name) : r.name
        }
    }

    /// What the action does, as a phrase that follows "Drag right: …" in a tooltip.
    static func helpDescription(_ a: PlusAction, missing: Bool = false) -> String {
        switch a {
        case .none:           return L("plusAction.none")
        case .gainStage:      return L("plusAction.help.gainStage")
        case .gain:           return L("plusAction.help.gain")
        case .gainPanMute:    return L("plusAction.help.gainPanMute")
        case .branch:         return L("plusAction.help.branch")
        case .send:           return L("plusAction.help.send")
        case .plugin(let r):  return missing ? L("plusAction.help.pluginMissing", r.name)
                                             : L("plusAction.help.plugin", r.name)
        }
    }
}
