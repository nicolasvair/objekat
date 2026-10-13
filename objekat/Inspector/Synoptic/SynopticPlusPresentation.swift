import Foundation

// MARK: - How the canvas presents a "+" (PURE: what is shown, what a gesture may do, what the ghost says)
//
// docs/plan_synoptic_rework.md §B.2 / §B.3, lot L4. The LAYOUT decides what a gesture on a "+" asks for
// (@see SynopticLayout.Diagram.command(for:translation:)); this unit decides the three things the canvas
// adds on top of it, with no view and no model, so they can be asserted alone
// (`tools/test_synoptic_plus_presentation.swift`):
//
//  - whether a "+" is SHOWN: while its line is hovered, always when its series is empty, and always while
//    a drag is in flight from it — and, during such a drag, no OTHER hovered "+" lights up (the hand is
//    travelling across lines it is not aiming at);
//  - whether the command is AVAILABLE: every wave-2 closure of `SynopticActions` is optional, and "a view
//    that finds one nil offers nothing for it" — a command whose closure is missing becomes `.none`, which
//    the ghost reads as "not here" (a drag that would silently do nothing is the one thing not to offer);
//  - what the GHOST says while the hand travels.

/// Which closures of `SynopticActions` the canvas was given — its own reading of the contract.
struct SynopticPlusAvailability: Equatable {
    /// `onPlusGesture`: a gain stage out of a "+" of a series (trunk, branch, bin).
    var gainStage = false
    /// `onSendPlusGesture`: a gain stage out of a send's mini-chain "+".
    var sendGainStage = false
    /// `onBranch`: a parallel branch.
    var branch = false
    /// `sendTargetSections`: the "Send to…" menu can be opened.
    var send = false
    /// `onSendPluginAdd`: a click on a send's mini-chain "+" opens the browser.
    var sendPluginAdd = false

    /// Everything wired (the bound view; the tests).
    static let all = SynopticPlusAvailability(gainStage: true, sendGainStage: true, branch: true,
                                              send: true, sendPluginAdd: true)
}

/// What the hand sees beside the pointer while it drags out of a "+".
enum SynopticPlusGhost: Equatable {
    /// Nothing drawn: the hand has not travelled past the click threshold yet.
    case none
    case gain
    case gainPanMute
    case branch
    case send
    /// The drag asks for something this "+" does not offer (or nobody is wired to do it).
    case notHere
}

/// A "+" named so that it survives a REBUILD of the tree. The bound view rebuilds its `SynopticNode`
/// tree on every refresh (the VU poll, ~70 ms). Since L8 the model mapping gives every series a STABLE id
/// (a branch's is derived from its parallel block's, @see SynopticMapping.voiceSeriesID), so for the bound
/// view a stable name is simply its series. The naming stays for every OTHER tree — one built with the
/// `.series(…)` / `.parallel(…)` constructors (the demo, the tests), whose branches get a FRESH `UUID()` at
/// each build: there a `SynopticPlusKey.series(id, i)` held in a `@State` across two builds would name a
/// series that no longer exists. A branch is named by its PLACE — its parallel block's id and its index;
/// every other series keeps its own id (the root, a bin's block), which IS stable.
enum SynopticStablePlus: Hashable {
    case series(String, Int)
    case postFader
    case sendChain(UUID, Int)
}

enum SynopticPlusPresentation {

    /// Each series of `root` → its stable name (@see SynopticStablePlus).
    static func seriesNames(of root: SynopticNode) -> [UUID: String] {
        var names: [UUID: String] = [:]
        func walk(_ node: SynopticNode, name: String) {
            switch node.kind {
            case .plugin:
                return
            case .series(let kids):
                names[node.id] = name
                for k in kids { walk(k, name: k.id.uuidString) }
            case .parallel(let voices):
                for (i, v) in voices.enumerated() { walk(v, name: "\(node.id.uuidString)#\(i)") }
            }
        }
        walk(root, name: root.id.uuidString)
        return names
    }

    /// `key` under its stable name. A series the table does not know keeps its own id.
    static func stable(_ key: SynopticPlusKey, names: [UUID: String]) -> SynopticStablePlus {
        switch key {
        case .series(let id, let i):          return .series(names[id] ?? id.uuidString, i)
        case .postFader:                      return .postFader
        case .sendChain(let aux, let index):  return .sendChain(aux, index)
        }
    }

    /// Whether the "+" `key` is drawn (and can be grabbed).
    /// - Parameters:
    ///   - hovered: the "+" whose line is under the pointer (nil = none).
    ///   - dragging: the "+" a drag is in flight from (nil = none).
    ///   - alwaysVisible: the "+" of the empty series.
    static func isShown(_ key: SynopticStablePlus, hovered: SynopticStablePlus?, dragging: SynopticStablePlus?,
                        alwaysVisible: Set<SynopticStablePlus>) -> Bool {
        if alwaysVisible.contains(key) { return true }
        if let d = dragging { return d == key }
        return hovered == key
    }

    /// `command` as the canvas can carry it out: `.none` when the closure it goes to is missing.
    static func available(_ command: SynopticPlusCommand, _ a: SynopticPlusAvailability) -> SynopticPlusCommand {
        switch command {
        case .none:
            return .none
        case .openBrowser(let key):
            switch key {
            case .series:    return command                       // `onInsertSeries` is not optional
            case .sendChain: return a.sendPluginAdd ? command : .none
            case .postFader: return a.send ? command : .none       // never produced (a click there = a send)
            }
        case .insertGainStage(let key, _):
            switch key {
            case .series:    return a.gainStage ? command : .none
            case .sendChain: return a.sendGainStage ? command : .none
            case .postFader: return .none                          // a gain is never offered after the fader
            }
        case .branch:
            return a.branch ? command : .none
        case .send:
            return a.send ? command : .none
        }
    }

    /// The gestures a "+" still offers once the missing closures are taken out (what its tooltip lists).
    static func offered(_ allowed: Set<PlusGestureResult>, key: SynopticPlusKey,
                        _ a: SynopticPlusAvailability) -> Set<PlusGestureResult> {
        allowed.filter { r in
            switch r {
            case .none:               return false
            case .gain, .gainPanMute:
                switch key {
                case .series:    return a.gainStage
                case .sendChain: return a.sendGainStage
                case .postFader: return false
                }
            case .branch:             return a.branch
            case .send:               return a.send
            }
        }
    }

    /// What the ghost says for a drag of `translation` that would carry out `command` (already filtered
    /// by `available`).
    static func ghost(for command: SynopticPlusCommand, translation: CGSize) -> SynopticPlusGhost {
        if SynopticPlusGesture.isClick(translation) { return .none }
        switch command {
        case .none:                                return .notHere
        case .openBrowser:                         return .none     // only a click opens it
        case .insertGainStage(_, .gain):           return .gain
        case .insertGainStage(_, .gainPanMute):    return .gainPanMute
        case .branch:                              return .branch
        case .send:                                return .send
        }
    }
}
