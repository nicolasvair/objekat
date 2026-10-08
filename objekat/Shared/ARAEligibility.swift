import Foundation

// Which objects may carry an ARA source (Melodyne) — the rules of docs/ara_melodyne_plan.md §1,
// kept in this one file, with its case table (tools/fixtures/ara_eligibility_cases.json), so that
// changing a rule means changing a line here and a row there.
//
// A refusal is a REASON, never a silent no-op: the command API turns it into `invalid_state` and the
// interface (step 9) into a message. The wording here is the English text of the API; the interface
// maps `ARARefusal` to its own localised strings.
//
//     swiftc -parse-as-library <model files> objekat/Shared/ARAEligibility.swift \
//         tools/test_ara_eligibility.swift -o /tmp/ae && /tmp/ae   (see the test's header)

enum ARARefusal: String, Codable, Equatable, CaseIterable {
    case notAClip              // a group, an aux, a MIDI clip or a stem: no audio file to analyse
    case consolidatedInstance  // a consolidated instance reads a shared wave: its edits could not be its own
    case alreadySource         // one ARA source per object (Q3: one instance per object)
    case speedNotOne           // varispeed would move the notes Melodyne analysed
    case reversed
    case looped                // Q5: loops are refused in v1
    case ancestorLooped        // ... and so is a group that loops its Melodyne children
    case fileMissing           // nothing to analyse
    case pluginNotARA          // the plugin chosen does not declare ARA (VST3 only: Q2)

    /// English sentence, for the API and the logs.
    var reason: String {
        switch self {
        case .notAClip:             return "only an audio clip can be played through an ARA plugin"
        case .consolidatedInstance: return "a consolidated object cannot carry an ARA source"
        case .alreadySource:        return "this object already has an ARA source"
        case .speedNotOne:          return "an ARA source needs a speed of 1 (reset the speed first)"
        case .reversed:             return "an ARA source cannot be used on a reversed object"
        case .looped:               return "an ARA source cannot be used on a looping object (loops are not supported yet)"
        case .ancestorLooped:       return "an ARA source cannot be used inside a looping group (loops are not supported yet)"
        case .fileMissing:          return "the audio file of this object is missing"
        case .pluginNotARA:         return "this plugin is not an ARA plugin (only VST3 ARA plugins are supported)"
        }
    }
}

enum ARAEligibility {

    /// A speed counts as 1 within this much (the model stores a Double typed by hand or by the API).
    static let speedTolerance = 1e-9

    /// Why `object` may NOT receive an ARA source — nil if it may. `ancestors` = its groups, nearest
    /// first or in any order (only their loop flag matters). `isFileMissing` is the caller's answer,
    /// since the disk is not this unit's business.
    static func refusal(for object: SoundObject, ancestors: [SoundObject], isFileMissing: Bool) -> ARARefusal? {
        guard case .clip(_, _, _, let speed, let reversed) = object.kind else { return .notAClip }
        if object.isConsolidateInstance { return .consolidatedInstance }
        if object.araSource != nil { return .alreadySource }
        if abs(speed - 1.0) > speedTolerance { return .speedNotOne }
        if reversed { return .reversed }
        if object.loopEnabled { return .looped }
        if ancestors.contains(where: { $0.loopEnabled }) { return .ancestorLooped }
        if isFileMissing { return .fileMissing }
        return nil
    }

    /// The same rules read the other way round, for the operations that would BREAK an existing
    /// source (changing the speed, reversing, looping the object or one of its groups): the reason
    /// the operation is refused, nil if it is free to go. `wouldLoop`: the operation turns a loop on.
    /// A group is refused if ANY descendant carries a source.
    static func refusalOfLoop(on object: SoundObject) -> ARARefusal? {
        if object.araSource != nil { return .looped }
        if case .group(let children, _) = object.kind, children.contains(where: { hasSourceInside($0) }) {
            return .ancestorLooped
        }
        return nil
    }

    static func hasSourceInside(_ object: SoundObject) -> Bool {
        if object.araSource != nil { return true }
        if case .group(let children, _) = object.kind { return children.contains { hasSourceInside($0) } }
        return false
    }
}
