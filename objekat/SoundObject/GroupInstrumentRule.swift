// The rule of a GROUP THAT CARRIES AN INSTRUMENT — pure, no engine, no view model (docs/plan_groupes_midi.md, E2).
//
// A group can host a virtual instrument (AU/VSTi), mounted on its container engine-side. The MIDI clips
// inside it carry no instrument of their own ("empty clips"): their notes go UP the container chain and the
// FIRST ancestor group that carries an instrument plays them. That only holds if nothing else sounds in the
// same container (the instrument overwrites the audio of everything below it), hence the refusals:
//
//   - an audio clip, a consolidated instance or an aux, at ANY depth under an instrument group;
//   - a MIDI clip or a sub-group that carries an instrument of its own (a second instrument);
//   - an audio recording source on an instrument group (the take would be audio, there is no use for it).
//
// and, in the other direction, an instrument cannot be put on a group whose subtree already holds one of
// those, nor UNDER a group that already has one.
//
// This file is the ONE place where the rule is written. The gestures (E5) and the API ask it; they never
// re-derive it. Everything is a function of the objects handed in: the caller builds the chains.
//
// Conventions of the parameters:
//   - `chain` is the TARGET group first, then its ancestors, nearest first (so: `[target, parent, grandparent…]`);
//   - `ancestors` is the PARENT first (`[parent, grandparent…]`), without the object itself.
//
// Compiled alone by `tools/test_group_instrument_rule.swift`.

import Foundation

enum GroupInstrumentRefusal: String, CaseIterable, Equatable {
    /// An audio clip in (or put into) an instrument group.
    case audioChild
    /// An aux in (or put into) an instrument group — its return is summed into the container, which the instrument overwrites.
    case auxChild
    /// A MIDI clip or a group that already carries an instrument of its own.
    case childWithInstrument
    /// A consolidated instance (its content is audio).
    case consolidatedChild
    /// An audio recording source on an instrument group.
    case audioInput
    /// An instrument put on a group that already sits under an instrument group.
    case insideInstrumentGroup
}

enum GroupInstrumentRule {

    // MARK: Reading

    /// True if `object` is a group or a MIDI clip that carries an instrument.
    static func carriesInstrument(_ object: SoundObject) -> Bool {
        (object.isGroup || object.isMIDI) && !object.instruments.isEmpty
    }

    /// True if `object` is a MIDI clip with no instrument of its own — the notes it holds are played by a host (or by nobody).
    static func isEmptyClip(_ object: SoundObject) -> Bool {
        object.isMIDI && object.instruments.isEmpty
    }

    /// The HOST of a MIDI clip: the first group of `ancestors` (parent first) that carries an instrument.
    /// nil for an object that is not an empty clip (an audio clip, a group, a clip with its own instrument)
    /// and for an empty clip with no instrument group above it (its notes are muted).
    static func host(of object: SoundObject, ancestors: [SoundObject]) -> UUID? {
        guard isEmptyClip(object) else { return nil }
        return ancestors.first(where: { $0.isGroup && !$0.instruments.isEmpty })?.id
    }

    // MARK: Refusals

    /// Why `objects` cannot be put in the group at the head of `chain` (target first, then its ancestors) — nil if they can.
    ///
    /// The rule only bites when SOME group of the chain carries an instrument: otherwise the target is an ordinary
    /// group and anything goes. Groups added are read down to the leaves, the first fault found (in the order of
    /// `objects`, depth first) is the one reported. A gesture that accepts only part of a selection must refuse
    /// the whole of it: the caller asks once with everything.
    static func refusal(adding objects: [SoundObject], toChain chain: [SoundObject]) -> GroupInstrumentRefusal? {
        guard chain.contains(where: { $0.isGroup && !$0.instruments.isEmpty }) else { return nil }

        for object in objects {
            if let r = firstFault(inSubtreeOf: object) { return r }
        }

        return nil
    }

    /// Why an instrument cannot be put on `group` (whose ancestors are `ancestors`, parent first) — nil if it can.
    /// nil as well for anything but a group: a MIDI clip takes its instrument by the ordinary path.
    static func refusal(puttingInstrumentOn group: SoundObject, ancestors: [SoundObject]) -> GroupInstrumentRefusal? {
        guard group.isGroup else { return nil }

        if ancestors.contains(where: { $0.isGroup && !$0.instruments.isEmpty }) { return .insideInstrumentGroup }
        if group.isConsolidateInstance { return .consolidatedChild }
        if group.recordInput != nil { return .audioInput }

        if case .group(let children, _) = group.kind {
            for child in children {
                if let r = firstFault(inSubtreeOf: child) { return r }
            }
        }

        return nil
    }

    /// Why an audio source cannot be assigned to the recording zone `group` — nil if it can. Refused when the group
    /// itself, or any group above it, carries an instrument.
    static func refusal(settingAudioInputOn group: SoundObject, ancestors: [SoundObject]) -> GroupInstrumentRefusal? {
        guard group.isGroup else { return nil }

        if !group.instruments.isEmpty || ancestors.contains(where: { $0.isGroup && !$0.instruments.isEmpty }) {
            return .audioInput
        }

        return nil
    }

    // MARK: Silence

    /// Is the NOTE-producing side of the empty clip `clip` reduced to silence?
    ///
    /// The clip's own silence (`isSilenced`, the listening composition: mute, stem mute, solo filtering, direct solo
    /// lifting) OR the silence of a group BETWEEN the clip and its host, the host excluded. The host's own fader does
    /// not matter here: it sits on the instrument's OUTPUT, the instrument's chain is the host's business. A silenced
    /// sub-group acts through its fader, which does not stop the MIDI crossing it: the clips below must be muted
    /// natively. With no host the whole chain up to the root is read.
    ///
    /// `isSilenced` is the app's rule (`AudibilitySnapshot.isSilenced`): it already lifts the objects on the way to a
    /// direct solo (`soloRootAncestors`), which is why they are not special-cased again here.
    static func midiSilenced(of clip: SoundObject,
                             ancestors: [SoundObject],
                             isSilenced: (SoundObject) -> Bool) -> Bool {
        if isSilenced(clip) { return true }

        for ancestor in ancestors {
            if ancestor.isGroup && !ancestor.instruments.isEmpty { return false }   // the host: stop, excluded
            if isSilenced(ancestor) { return true }
        }

        return false
    }

    // MARK: Subtree

    /// The first fault of `object` and everything under it, as seen from INSIDE an instrument group.
    private static func firstFault(inSubtreeOf object: SoundObject) -> GroupInstrumentRefusal? {
        if object.isConsolidateInstance { return .consolidatedChild }

        switch object.kind {
        case .clip:
            return .audioChild
        case .aux:
            return .auxChild
        case .midiClip:
            return object.instruments.isEmpty ? nil : .childWithInstrument
        case .group(let children, _):
            if !object.instruments.isEmpty { return .childWithInstrument }
            if object.recordInput != nil { return .audioInput }

            for child in children {
                if let r = firstFault(inSubtreeOf: child) { return r }
            }

            return nil
        }
    }
}
