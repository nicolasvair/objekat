import Foundation

// Taking a send card somewhere (INC 2, step 2.10, docs/plan_sends_rework.md §D.1.A.j): the PURE half.
//
// A send is moved by dragging its card. Where it can be let go is decided here, once, for every door
// that reads a drag (the signal view's cables / cards / slots, the timeline, a stem's strip): the cursor,
// the band and the drop itself all read the same answer, so what the hand is told and what happens
// cannot drift apart (the plugin drags work the same way, @see EditViewModel.pluginDropOutcome).
//
// No modifier: one send per (object, aux), so there is no copy.

/// What a send card is dragged on, as the resolver needs to know it.
enum SendDropAim: Equatable {
    /// An insert point of the TRUNK (the root series), or the card standing just after it: the send is
    /// taken before the top-level entry `index` (markers do not count).
    case trunk(index: Int)
    /// One of the three fixed slots: `.input`, `.preFader`, `.postFader`.
    case slot(SynopticSendSlot)
    /// A branch of a parallel block (a send is never taken inside one).
    case parallelBranch
    /// An FX link's block (a send is never taken inside a bin).
    case fxBlock
    /// Another send's box — its plugins' rows, its "+", its line (INC 3): a box takes plugins, not sends.
    case sendBox
    /// Anything that is not the sender's own signal view: another object, a stem's strip, the timeline,
    /// an aux's bus head, the Main (an aux, a stem and the Main do not send).
    case elsewhere
}

/// The line the band at the bottom of the timeline says while a send card is dragged (`PluginDropHint`).
enum SendDropBanner: Hashable {
    case takenHere, takenAtInput, takenBeforeFader, takenAfterFader
    case refusedParallel, refusedFXLink, refusedElsewhere, refusedSendBox

    var isRefusal: Bool {
        switch self {
        case .refusedParallel, .refusedFXLink, .refusedElsewhere, .refusedSendBox: return true
        default: return false
        }
    }

    /// The catalogue key of the line.
    var titleKey: String {
        switch self {
        case .takenHere:         return "hud.sendDrop.here"
        case .takenAtInput:      return "hud.sendDrop.input"
        case .takenBeforeFader:  return "hud.sendDrop.preFader"
        case .takenAfterFader:   return "hud.sendDrop.postFader"
        case .refusedParallel:   return "hud.sendDrop.noParallel"
        case .refusedFXLink:     return "hud.sendDrop.noFXLink"
        case .refusedElsewhere:  return "hud.sendDrop.stays"
        case .refusedSendBox:    return "hud.sendDrop.noSendBox"
        }
    }
}

/// What a release at an aim does.
enum SendDropDecision: Equatable {
    /// The send is taken at this slot.
    case move(SynopticSendSlot, SendDropBanner)
    case refuse(SendDropBanner)

    var banner: SendDropBanner {
        switch self {
        case .move(_, let b), .refuse(let b): return b
        }
    }
    var isRefusal: Bool { if case .refuse = self { return true } else { return false } }
}

enum SendDrop {
    /// The one table (the plan's A.j): trunk insert point -> `chain(i)`; a fixed slot -> that slot; a
    /// parallel branch / an FX link / another place -> refused, each with its own line.
    static func decide(_ aim: SendDropAim) -> SendDropDecision {
        switch aim {
        case .trunk(let index):
            return .move(.chain(max(0, index)), .takenHere)
        case .slot(let slot):
            switch slot {
            case .input:      return .move(.input, .takenAtInput)
            case .preFader:   return .move(.preFader, .takenBeforeFader)
            case .postFader:  return .move(.postFader, .takenAfterFader)
            case .chain(let i): return .move(.chain(max(0, i)), .takenHere)
            }
        case .parallelBranch: return .refuse(.refusedParallel)
        case .fxBlock:        return .refuse(.refusedFXLink)
        case .sendBox:        return .refuse(.refusedSendBox)
        case .elsewhere:      return .refuse(.refusedElsewhere)
        }
    }
}

// A PLUGIN let go on a send's box (INC 3). What it does is the plugin resolver's business
// (@see EditViewModel.pluginDropOutcome: move / copy, the refusals); what the band says of a REFUSAL
// is here, pure: the two reasons a hand can meet on a box each have their line.
enum SendBoxPluginRefusal {
    /// The catalogue key of the line for a refusal reason of the resolver; nil = no line (the cursor
    /// alone refuses, as everywhere else for a plugin).
    static func titleKey(reason: String) -> String? {
        switch reason {
        case "send_chain_leaves_only": return "hud.pluginDrop.send.leavesOnly"
        case "chainFull":              return "hud.pluginDrop.send.full"
        default:                       return nil
        }
    }
}

/// A send card in the hand: the sender (so that a drop on another object is refused) and the aux (the
/// send is one per pair). JSON under `public.plain-text` like the plugin payload; it does not decode as
/// a `PluginDragPayload`, so the doors that take plugins ignore it by themselves.
nonisolated struct SendDragPayload: Codable, Equatable {
    let sendSender: UUID
    let sendAux: UUID
}
