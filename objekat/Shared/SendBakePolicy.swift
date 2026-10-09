import Foundation

// What becomes of the sends that tap INSIDE a chain when that chain is baked into a wave
// (docs/plan_sends_rework.md §A.i, question Q-U6, confirmed: the user is ASKED at the moment of the
// operation).
//
// A consolidated object is created by rendering the object — its plugin chain included — into a wave;
// the placement that replaces it has NO chain left. A send at `post_fader` or `pre_fader` keeps its
// meaning (the wave IS the pre-fader signal). A send at `input` or `chain(i)` taps a signal that no
// longer exists after the bake: its marker would die with the chain, and its `input` would silently
// become the baked signal. So it is CONCERNED, and the operation must first be told what to do with it:
//
//     fold     the send goes to post-fader (its marker, if any, goes; its level and its curve stay)
//     remove   the send is deleted (entry, marker, automation lane aimed at it)
//     refuse   nothing is changed and the operation does not start (the default of the API)
//
// PURE: no engine, no view-model. The view-model asks (`EditViewModel+SendBake`), then calls
// `resolve` on the model BEFORE the existing bake path runs; that path is otherwise untouched.
//
//     swiftc -parse-as-library <the files of tools/test_send_bake_policy.swift's header> \
//         tools/test_send_bake_policy.swift -o /tmp/tsbp && /tmp/tsbp

enum SendBakePolicy {

    /// What to do with the concerned sends. The raw values are the API's `mid_chain_sends`.
    enum Choice: String, CaseIterable {
        case refuse, fold, remove
    }

    /// One send that the bake would break.
    struct Concerned: Equatable {
        let objectID: UUID
        let objectName: String
        let auxID: UUID
        let position: SendPosition
    }

    /// True for the positions that tap upstream of the baked wave.
    static func isConcerned(_ position: SendPosition) -> Bool {
        switch position {
        case .input, .chain:         return true
        case .preFader, .postFader:  return false
        }
    }

    /// The sends of `object` ITSELF (not of its children: those are baked inside, with their own aux
    /// or lost with them, exactly as in INC 1) whose position is upstream of the bake.
    static func concerned(in object: SoundObject) -> [Concerned] {
        // An aux and the Main never send; a placement that is already an instance has no chain.
        guard !object.isAux else { return [] }
        return object.sends.compactMap { send in
            guard let position = object.sendPosition(auxID: send.auxID), isConcerned(position) else { return nil }
            return Concerned(objectID: object.id, objectName: object.displayName,
                             auxID: send.auxID, position: position)
        }
    }

    static func concerned(in objects: [SoundObject]) -> [Concerned] {
        objects.flatMap { concerned(in: $0) }
    }

    /// `object` once the choice is applied to its concerned sends. `refuse` changes nothing.
    /// Sends that are not concerned are returned as they are.
    static func resolve(_ object: SoundObject, choice: Choice) -> SoundObject {
        let targets = concerned(in: object).map(\.auxID)
        guard choice != .refuse, !targets.isEmpty else { return object }
        var o = object
        switch choice {
        case .refuse:
            break
        case .fold:
            for aux in targets { o = o.settingSendPosition(auxID: aux, .postFader) }
        case .remove:
            let gone = Set(targets)
            o.sends.removeAll { gone.contains($0.auxID) }
            o.plugins = ObjectPlugin.removingSendMarkers(from: o.plugins) { gone.contains($0.auxID) }
            o.automation.removeAll { if case .send(let a) = $0.param { return gone.contains(a) } else { return false } }
            o.automationTouchOrder.removeAll { if case .send(let a) = $0 { return gone.contains(a) } else { return false } }
        }
        return o
    }
}
