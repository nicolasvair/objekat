import Foundation

// MARK: - When a recording input dropped on a zone copies its chain (inputs panel)
//
// Dragging an input (audio or MIDI) onto the timeline copies the chain it carries — the FX of a card input, the
// instrument and the FX of a MIDI input — onto the zone the drop lands on, under ONE rule:
//
//  - a NEW zone always takes the copy;
//  - an EXISTING group takes it only if it is ENTIRELY EMPTY: no child, no instrument, no FX, no send. A send counts
//    as something (it routes sound out of the group: the user has built something there). A group that holds
//    anything keeps its chain, and only its source changes;
//  - assigning a source from the synoptic's menu is not a drop and copies nothing (it never asks this).
//
// Pure, so the rule is asserted with no screen (tools/test_record_drop_inheritance.swift).

enum RecordDropInheritance {

    /// A group with no child, no instrument, no FX (a bin or a gain stage is one) and no send.
    /// Anything that is not a group is never "empty" in this sense: it cannot take a chain.
    static func isEntirelyEmpty(_ object: SoundObject) -> Bool {
        guard case .group(let children, _) = object.kind else { return false }
        return children.isEmpty && object.instruments.isEmpty && object.plugins.isEmpty && object.sends.isEmpty
    }

    /// Whether a drop that lands on the EXISTING group `zone` copies the chain of the input.
    static func copiesChain(ontoExisting zone: SoundObject) -> Bool { isEntirelyEmpty(zone) }
}
